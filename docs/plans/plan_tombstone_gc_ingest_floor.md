# Tombstone GC: ingest-side horizon floor (defence-in-depth)

**Status**: Open

**PR link**: {pending}

**Origin**: H4-FU3 — explicitly deferred from H4-FU during PR2 sign-off. Roadmap
entry: [docs/roadmap/0_02_01.md → H4-FU3](../roadmap/0_02_01.md). PR2's
Step 5 "no resurrection across sync" CI test
([plan_tombstone_gc.md → Step 5](completed/plan_tombstone_gc.md#step-5--tests))
was deferred for the absence of this floor; the cross-device variant is
[RC-6](../spec/28_release_checklist.md) and the harness scenario in
[plan_harness_mixed_storage.md](plan_harness_mixed_storage.md) Step 5.

**Sequencing**: Sibling to **H4-FU2** (stale-device eviction). The pair forms
the "tombstone GC robustness" cluster. **They are independent** — H4-FU2
protects the *distributed* invariant; H4-FU3 protects the *local* invariant —
and can land in either order. Practical preference: ship H4-FU3 first
because (a) it has a smaller blast radius (one engine path, no sync-cycle
protocol change), (b) it lets PR2's CI resurrection test become defensible
on the in-process path, and (c) H4-FU2's safe re-admission lean on it as
defence-in-depth.

**Implementation model:** Opus / strong-model review. Like PR2, this is a
"silently resurrect deleted data" risk class — get the floor's write
ordering or its ingest-time comparator wrong and a returning-or-crafted
SSTable can bypass GC undetected.

## Problem statement

H4 PR2 drops a tombstone when `allLevels && tombstone.hlc < horizon`. The
safety argument rests on a **distributed invariant**: no peer can produce
an SSTable carrying records below the horizon because every peer's
`currentHlc >= horizon = min(currentHlc)` by construction. The invariant
is sound for a well-behaved sync topology — and **completely unenforced
locally**. The engine has no record of which HLCs were ever GC-eligible,
so any of the following bypass the safety net:

- An ingested SSTable carrying records older than a tombstone that
  has already been dropped (the cross-device resurrection scenario PR2
  could not write a CI test for).
- A returning H4-FU2-evicted device that pushes its pre-eviction SSTables
  before the safe-re-sync detection kicks in — the SSTable's HLC range
  satisfies no other check.
- A crafted SSTable (test, malicious peer, restore from an old backup
  into the sync folder) whose HLCs predate the local GC's actual history.
- Operator error: dragging an `.sst` file from another folder into the
  sync directory.

In every case, the local engine ingests at L0, the file flows through the
merge path, and any pre-tombstone version it carries reads as live data
because the tombstone is no longer there to suppress it.

H4-FU3 closes this loop by **persisting the highest horizon ever used for
a tombstone drop** (a per-device monotonic "GC floor" in `$meta`) and
having [`ingestSstable`](../../packages/kmdb/lib/src/engine/kvstore/kv_store.dart#L109)
reject any incoming SSTable whose `maxHlc` is at or below the floor.
After the floor is in place, the PR2 in-process resurrection test
becomes a hard correctness assertion rather than a deferred one.

## Open questions

These gate the implementation. Q1 and Q2 carry the most weight — the rest
are surfacing and ergonomics calls.

- [ ] **Q1 — Whole-file rejection or per-record filter?** Whole-file is
  cheap (filename parse only — `maxHlc` is in the name, no body scan) and
  matches how the engine already treats SSTables as the unit of sync.
  Per-record requires scanning the file, partitioning entries by HLC, and
  ingesting a rewritten subset — L0-class work on the read path, with
  format implications (split table? new manifest entry?). *(Recommended:
  **whole-file rejection.** The floor is belt-and-braces for paths that
  should not be producing sub-floor SSTables in the first place; a
  well-behaved sync topology never trips it. If a mixed-HLC file does
  arrive, the cause is upstream (a buggy producer, a hand-crafted file,
  H4-FU2 not yet landed) and a noisy rejection is more useful than
  silent partial ingest. Per-record filtering can be added later if the
  rejection rate becomes operationally painful.)*
- [ ] **Q2 — Error or silent skip on rejection?** A loud error stalls the
  sync cycle on the first sub-floor file; a silent skip continues but
  hides the failure. *(Recommended: **typed exception** thrown from
  `ingestAt0`. `SyncEngine` catches per-file (the existing per-file ingest
  loop already does), logs at WARN, and leaves the SSTable in the cloud
  folder *without updating the peer HWM for it* so it is re-considered
  next cycle. The HWM stays one step behind that file's HLC, which is
  exactly the "I have not processed this" semantic the protocol already
  models.)*
- [ ] **Q3 — When is the floor written?** Per drop, per compaction job,
  or per `_compactAll` only? *(Recommended: the floor is updated *exactly
  once per* `_compactAll` *that drops one or more tombstones*, to the
  `horizon` value passed into that job. Pure version-collapse compactions
  do not advance it. Partial compactions never advance it (they cannot
  drop tombstones anyway per PR2). One write per all-levels compaction
  is negligible.)*
- [ ] **Q4 — Where is the floor stored?** *(Recommended: `$meta` under
  the symbolic name `gc:tombstoneFloor`, encoded as a `uint64` HLC.
  Reuses the established `MetaStore` pattern (`gen:*`, `dirty`,
  `device_id`) including the WAL-backed write path and the existing
  `_nameToKey` XXH64 keying. No format change, no new namespace.)*
- [ ] **Q5 — Replication / restore semantics.** `$meta` is excluded from
  sync, so the floor is per-device. If a device's local state is wiped
  and rebuilt from the cloud, the floor reverts to zero — but so does
  its set of *already-GC'd tombstones*, so there is nothing for the
  floor to protect and zero is correct. *(Recommended: **no replication
  needed.** Document the invariant explicitly so future-us doesn't
  "fix" it by syncing `$meta`. Sub-question: what about a device that
  rolls back its local DB from a filesystem snapshot to before a GC
  cycle? That device has tombstones that were dropped on disk
  resurrected by the rollback, *and* the floor reverts — which is again
  consistent. The floor is correct against any consistent local
  state.)*
- [ ] **Q6 — Atomicity with the GC drop.** If a compaction successfully
  drops tombstones, persists the new manifest, but crashes before the
  floor is written, the next session has GC'd state without a floor —
  potentially exploitable by an immediately-ingested sub-floor file.
  Options: (a) write the floor first (it would then over-promise on
  retry); (b) accept a small post-crash window; (c) fold the floor
  write into the same WriteBatch / VersionEdit as the compaction
  output. *(Recommended: **(c) — fold into the compaction's existing
  `$meta` write or its VersionEdit footer.** The compaction already
  writes WAL records for the output SSTable's manifest entry; adding
  one batched `$meta` put for the floor keeps the floor advance
  atomic with the drop. Worth checking whether `CompactionJob`'s
  current output writer can carry a single side-`$meta` mutation
  cleanly — if not, fall back to (b) and document that the worst-case
  post-crash window admits sub-floor ingest until the next
  `_compactAll` raises the floor again.)*
- [ ] **Q7 — Comparator: `<` or `≤`?** PR2 drops a tombstone when
  `tombstone.hlc < horizon`. Symmetrically, the floor should reject
  SSTables when `sstable.maxHlc <= floor` — equality means at least one
  record sits at the boundary and could be a pre-drop version of the
  exact key/HLC we just GC'd. *(Recommended: `<=`. PR2's strict-less
  comparator is for tombstone-drop eligibility (the tombstone itself is
  at `floor` and must be retained until something strictly newer
  observes it); the ingest comparator must be the dual, rejecting at
  the boundary too.)*
- [ ] **Q8 — Surface for operators.** The CLI already exposes
  `kmdb info` / `kmdb stats` style commands; should the floor and the
  count of rejected ingests be visible there? *(Recommended: defer.
  Reject events should log structurally; CLI exposure can land later
  once the operational pattern is known.)*

## Investigation

### The ingest path today

[`KvStoreImpl.ingestSstable`](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L201)
writes the file to `sst/`, fsyncs file and directory, and calls
[`LsmEngine.ingestAt0`](../../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L896).
`ingestAt0` opens the reader (validates the footer checksum), parses the
filename via [`SstableInfo.parse`](../../packages/kmdb/lib/src/engine/sstable/sstable_info.dart#L70)
(yielding `minHlc` / `maxHlc` cheaply, no body scan), advances the local
HLC clock to `info.maxHlc`, appends a `VersionEdit` to the Manifest, and
registers the file at L0. There is no eligibility check between the
filename parse and the manifest append — that is where the floor check
goes.

The filename parse is the cheap gate H4-FU3 needs: `maxHlc` is
authoritatively in the filename for both regular flush and consolidation
formats. **No body scan, no checksum cost, just a string parse and a
comparator.** Whole-file rejection costs effectively nothing.

### The floor's write site

PR2 added [`LsmEngine._computeTombstoneHorizon`](../../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L169)
which feeds `_compactAll` via the registered provider. The natural place
to advance the floor is at the *end* of a `_compactAll` that produced a
job whose reclamation transform reported at least one tombstone drop.
PR2's transform currently does not report drop counts upward — that
plumbing is one of the small mechanical pieces this plan adds.

The horizon to persist is exactly the `horizon` value passed into the
job (not the local clock at compaction-end, not the max HLC in the
input). It's the value the safety predicate trusted.

### The floor's read site

`ingestAt0`, just after `SstableInfo.parse`, before `advanceClock`. If
`info.maxHlc <= floor`, throw a new typed `SstaleSstableIngestException`
(or similar) carrying the filename and the floor for the log. The file
on disk should be **left alone** — `KvStoreImpl.ingestSstable` wrote it
before the manifest append, and a manual rollback would risk a partial
state under retry. Sweep on next open if it becomes a hygiene problem
(it shouldn't — well-behaved peers won't produce sub-floor files).

### `$meta` plumbing

[`MetaStore`](../../packages/kmdb/lib/src/engine/kvstore/meta_store.dart)
already has the exact shape we need: WAL-backed writes via the engine
bypassing the `$` guard ([kv_store_impl.dart](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L243)
shows the `$meta` writes are intentionally engine-direct), symbolic-name
→ 16-byte key encoding, named accessors for each piece of state. Add
`getTombstoneFloor` / `setTombstoneFloor` (or batch-aware
`appendTombstoneFloorAdvance` parallel to `appendGenerationCounterBump`).
Default-on-read is `Hlc(0, 0)` — every freshly-opened DB rejects nothing.

### Crash & recovery

`$meta` writes go through the WAL and are recovered by the standard
replay path. The floor is therefore as durable as any other engine
state. The atomicity question (Q6) is specifically about the *window
between* the compaction's manifest append and the floor's WAL write —
folding the floor into the compaction's atomic unit closes the window;
not folding admits a small failure mode that is documentable and
manageable.

### The "new device" case

A device opened for the first time has no `$meta`, no floor, no GC
history, no tombstones. It ingests freely. The floor advances the first
time its own compaction drops a tombstone — which by definition cannot
happen until the device has accumulated enough deletes to compact and
the horizon (from `SyncEngine` or local-only grace) admits the drop.
The progression is monotone and self-bootstrapping.

### Interaction with PR2's deferred test

PR2's Step 5 "no resurrection across sync (CI-testable)" was deferred
with the note that the assertion can only hold with an ingest-side
floor. With H4-FU3 in place:

1. Write `delete(k)` at HLC `T_del`.
2. `_compactAll` with `horizon = T_del + 1`; tombstone drops; floor =
   `T_del + 1`.
3. Construct a sub-floor SSTable containing `put(k, v_old)` at HLC
   `T_old < T_del`.
4. `ingestSstable` it.
5. **Assert:** the call throws `StaleSstableIngestException`; `k` reads
   as absent.

That is a deterministic CI test, no harness needed. RC-6 (the harness
variant) still applies for the cross-device path because the floor is
local and a careful test should exercise both the floor *and* the
distributed invariant in the same harness scenario.

### Files to change (provisional)

| File | Change |
|------|--------|
| `lib/src/engine/kvstore/meta_store.dart` | Add `getTombstoneFloor()`, `setTombstoneFloor(Hlc)`, and `appendTombstoneFloorAdvance(Hlc, WriteBatch)`. Encode HLC as 8-byte big-endian (mirror generation-counter helper). |
| `lib/src/engine/compaction/compaction_job.dart` | Expose a `tombstonesDropped` count (or equivalent signal) on the job result so `LsmEngine` knows whether to advance the floor. |
| `lib/src/engine/kvstore/lsm_engine.dart` | After `_compactAll` completes successfully, if `tombstonesDropped > 0` advance the floor to the `horizon` used. Investigate Q6: fold the floor write into the compaction's atomic unit if practical. |
| `lib/src/engine/kvstore/lsm_engine.dart` (`ingestAt0`) | After `SstableInfo.parse`, before `advanceClock`, read the floor and throw `StaleSstableIngestException` when `info.maxHlc <= floor`. |
| `lib/src/engine/kvstore/kv_store.dart` (or sibling) | New exception type `StaleSstableIngestException`. Document on `ingestSstable`. |
| `lib/src/sync/sync_engine.dart` | Catch `StaleSstableIngestException` per-file in the existing ingest loop; log at WARN with filename + floor; do **not** update the peer HWM past that file's HLC. Confirm the loop's existing error handling does not advance HWM on the failed file. |
| `docs/spec/06_storage_engine.md` | Document the floor: write site (`_compactAll` with drops), read site (`ingestSstable`), `<=` comparator, atomicity, default-on-fresh-open. |
| `docs/spec/12_sync.md` | Document that sub-floor SSTables are rejected at ingest and the protocol behaviour (HWM not advanced, file re-considered next cycle). Cross-reference H4-FU2: a returning evicted device sees its push silently dropped on the recipient until full re-sync runs. |
| `packages/kmdb/test/engine/lsm_engine_test.dart` | The PR2 deferred Step 5 test, now CI-asserted. |
| `packages/kmdb/test/engine/meta_store_test.dart` | Floor round-trip, default `Hlc(0,0)`, monotonic advance. |
| `packages/kmdb/test/sync/sync_engine_test.dart` | Sub-floor SSTable rejection during pull; HWM not advanced; file remains in cloud folder. |

### What this plan deliberately does **not** do

- It does not introduce per-record filtering of mixed-HLC SSTables (Q1).
  Whole-file rejection is the chosen mechanism.
- It does not change PR2's tombstone-drop comparator or horizon
  computation. The floor is purely *downstream* of the existing horizon.
- It does not replicate the floor between devices (Q5). Per-device by
  design.
- It does not delete or quarantine rejected files on disk. Hygiene is a
  separate concern; sweep at open if it becomes one.
- It does not change `MetaStore`'s sync-exclusion stance.

## Implementation plan

> Provisional. Lock down after open questions are answered, particularly
> Q1 (rejection mechanism), Q6 (atomicity), and Q7 (comparator).

### Step 1 — `MetaStore` accessors for the floor
- [ ] Add `getTombstoneFloor() -> Hlc`, defaulting to `Hlc(0, 0)` when
      absent. Doc comment must spell out: per-device by design, monotonic
      under correct operation, what bounds it.
- [ ] Add `setTombstoneFloor(Hlc)` and the batch-aware
      `appendTombstoneFloorAdvance(Hlc, WriteBatch)`.
- [ ] Unit tests: round-trip, default, encoding stable across opens.

### Step 2 — `CompactionJob` reports drops
- [ ] Add a `tombstonesDropped: int` (or `bool didDropTombstones`) to the
      job's result. The streaming transform PR2 added knows when a
      surviving-tombstone path was taken; surface it.
- [ ] Test: a compaction that drops nothing reports zero; one that drops
      reports >0.

### Step 3 — Engine advances the floor
- [ ] In `LsmEngine._compactAll`, after the compaction has committed its
      VersionEdit and the new file set is durable, if
      `tombstonesDropped > 0` write the floor at `horizon`. Investigate
      Q6: prefer folding the floor write into the compaction's atomic
      unit (the same WAL frame or VersionEdit). Document the chosen
      ordering in the doc comment.
- [ ] Test: `_compactAll` that drops a tombstone advances the floor;
      one that does not, does not advance.

### Step 4 — `ingestAt0` consults the floor
- [ ] After `SstableInfo.parse`, before `advanceClock`, read the floor.
      If `info.maxHlc <= floor`, throw `StaleSstableIngestException`
      (new typed exception) carrying `filename`, `info.maxHlc`, `floor`.
- [ ] The file already on disk is left in place; document why.
- [ ] Test: synthesised sub-floor SSTable rejected; key reads stay
      absent (the PR2 deferred Step 5 assertion).

### Step 5 — `SyncEngine` handles rejection gracefully
- [ ] Confirm the existing per-file ingest loop already isolates per-file
      errors and does not advance the peer HWM on a failed ingest. If
      not, fix that as part of this step.
- [ ] Catch `StaleSstableIngestException`; log at WARN with filename,
      sub-floor HLC, and current floor; continue to the next file.
- [ ] Test: pull cycle with a mix of normal and sub-floor files — normal
      files ingest, HWM advances for those; sub-floor files are skipped,
      HWM does not advance past them, the file remains in the cloud
      folder.

### Step 6 — Floor + H4-FU2 interaction
- [ ] If H4-FU2 has landed, document the layered behaviour: a returning
      evicted device whose safe-re-sync check is bypassed (test, bug)
      will have its incremental push silently dropped at recipients —
      the floor catches what the safe-re-sync was meant to prevent.
- [ ] If H4-FU2 has not landed, document this plan's standalone behaviour
      and note that the layering is added by the sibling plan.

### Step 7 — Tests (the resurrection scenario CI test in particular)
- [ ] **Single-process no-resurrection (PR2 Step 5, now testable):**
      delete key, `_compactAll` with tombstone drop, construct an
      older-HLC SSTable, ingest → assert rejection + key stays absent.
- [ ] **Floor monotonic advance:** two GC cycles with increasing
      horizons; floor reflects the latest.
- [ ] **Default-zero on fresh DB:** ingest accepts everything when no GC
      has ever run.
- [ ] **Crash mid-compaction:** if Q6 is resolved to fold the floor into
      the compaction's atomic unit — assert recovery restores both the
      drop and the floor consistently. If not, document the window
      explicitly and test the recoverable state.
- [ ] **Sync ingest skip behaviour (Step 5):** sub-floor pull file
      rejected, HWM unchanged for that file, normal files still ingest.
- [ ] Coverage ≥ 90% (CLAUDE.md gate).

### Step 8 — Documentation
- [ ] `docs/spec/06_storage_engine.md`: full description of the floor —
      write site, read site, comparator (`<=`), atomicity decision from
      Q6, default-on-fresh-open, per-device-by-design.
- [ ] `docs/spec/12_sync.md`: ingest-side rejection of sub-floor files;
      HWM-not-advanced protocol behaviour; cross-reference H4-FU2's
      safe-re-sync.
- [ ] Doc comments on `MetaStore`, `LsmEngine.ingestAt0`,
      `KvStore.ingestSstable`, and the new exception.
- [ ] Update PR2's deferred Step 5 note in
      `plans/completed/plan_tombstone_gc.md` to record that the test
      has been claimed by H4-FU3.
- [ ] Update the H4-FU3 roadmap entry status when complete.

### Step 9 — Verify
- [ ] `make pre_commit` clean.
- [ ] `dart test` passes in `packages/kmdb` and `packages/kmdb_cli`.
- [ ] No release-checklist entry needed: this plan closes RC-6's
      in-process variant in CI. The cross-device harness scenario
      (`plan_harness_mixed_storage.md` Step 5) remains as is.

### Step 10 — PR
- [ ] Branch + worktree per `docs/plans/README.md`. Open PR against
      `main`, update **PR link** above. On merge, move this plan to
      `docs/plans/completed/`.

## Summary

{To be completed during implementation.}
