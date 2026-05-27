# Tombstone GC: stale-device eviction from the sync horizon

**Status**: Implementing

**PR link**: {pending}

**Origin**: H4-FU2 — explicitly deferred from H4-FU during PR2 sign-off. Roadmap
entry: [docs/roadmap/0_02_01.md → H4-FU2](../roadmap/0_02_01.md). Documented as
a known limitation in
[plans/completed/plan_tombstone_gc.md](completed/plan_tombstone_gc.md#the-inactive-device-wrinkle)
and [docs/spec/12_sync.md](../spec/12_sync.md#tombstone-retention--garbage-collection).

**Sequencing**: Sibling to **H4-FU3** (ingest-side horizon floor) — together
they close the "tombstone GC robustness" follow-up cluster opened by H4 PR2.
H4-FU3 protects the *local* invariant; H4-FU2 protects the *distributed*
invariant by ensuring `min(currentHlc)` can actually advance. They are
independent and can land in either order, but the test surface overlaps —
both want a multi-device scenario where one peer is offline. Worth aligning
the test plumbing.

## Problem statement

[`HighwaterMark.minCurrentHlcAcrossDevices`](../../packages/kmdb/lib/src/sync/highwater.dart#L113)
(the synced GC horizon registered by `SyncEngine`) returns the strict
`min(currentHlc)` across every `.hwm` file in `{syncRoot}/highwater/`. The
horizon is therefore pegged by the slowest reporter — a device that uploads
a single `.hwm` and never returns blocks tombstone GC indefinitely. On any
long-lived synced workload with churning device IDs (uninstalls, lost
laptops, retired phones, ephemeral CI runners, …), the sync folder grows
without bound for *the very class of workload PR2 was meant to fix*.

The known shape of the solution — sketched in the H4-FU2 roadmap entry and in
the historical `12_sync.md` text — is **stale-device eviction**: exclude HWM
files whose `lastUpdated` is older than a configurable threshold from the
horizon computation, so the horizon can advance past the dead device. A
device that exceeds the threshold and *does* return must perform a **full
re-sync** rather than incremental catch-up; otherwise it can ingest records
older than the now-advanced horizon and deliver content that would resurrect
GC'd deletes.

The plan must answer two distinct safety questions, not just one:

1. **Eviction:** which HWMs are excluded from `min`, and on what evidence?
2. **Re-admission:** when an evicted device returns, how is its incremental
   catch-up downgraded to a safe full re-sync without silently producing
   resurrections?

Get either wrong and we either keep storage growing forever (eviction too
conservative) or resurrect deleted rows when a dormant peer comes back
(eviction too aggressive, or re-admission unguarded).

## Open questions

These gate the implementation. Q1 and Q4 are the load-bearing ones — the
others are mostly tuning and surfacing decisions.

- [x] **Q1 — What is the eviction threshold and where does it live?** The
  H4-FU2 roadmap entry suggests "90 days" (matching the historical
  `12_sync.md` text). The threshold must be **≥ the longest realistic
  offline window for a legitimately-active device** — phones in drawers,
  laptops in storage, devices that only sync from a specific Wi-Fi network.
  Where is it configured? *(Recommended: a new
  `KvStoreConfig.staleDeviceEvictionAfter: Duration` with a conservative
  default of 90 days, mirroring the `tombstoneGraceDuration` pattern. It
  pairs naturally with `tombstoneGraceDuration` — the local-only grace and
  the multi-device eviction window are the two halves of "how long until a
  delete is considered globally observed.")*
  _Decision: accepted. Add `KvStoreConfig.staleDeviceEvictionAfter: Duration`
  with a 90-day default. Doc comment must pair it explicitly with
  `tombstoneGraceDuration` and spell out the re-admission consequence. Both
  durations are public API; they share a conceptual grouping and should be
  positioned adjacent in the config class._
- [x] **Q2 — Whose clock authorises eviction?** `lastUpdated` is the
  uploading device's wall clock and is unsigned. A misbehaving / unsynced
  peer could write a future-dated `lastUpdated` and avoid eviction forever,
  or a far-past one and force its own eviction. Compare to "now" on the
  evaluating device, or fold in HLC-derived monotonic skew? *(Recommended:
  evaluating device's wall clock vs. uploader's `lastUpdated`. Worst-case
  damage is bounded — a misbehaving uploader either persists past the
  threshold (delaying GC for that peer's contribution) or excludes itself
  (advancing GC for everyone else); neither produces a resurrection. Skew
  is already part of the wider sync model.)*
  _Decision: accepted. Use the evaluating device's wall clock (`DateTime.now()`,
  injectable as `now: DateTime` for test seam) compared against the file's
  `lastUpdated`. The damage bound is asymmetric but safe: a future-dated
  file delays GC (the conservative error); a past-dated file only affects
  that peer's own contribution (no resurrection on other peers). No
  additional HLC-skew logic needed._
- [x] **Q3 — Does the evaluating device need to evict itself?** The local
  device's own `.hwm` is included in the `min` scan today (see Q3a in the
  investigation). If the local device hasn't synced in > threshold its
  `currentHlc` will already be small, pegging GC even though it's the one
  doing the eviction. *(Recommended: never exclude the local device's
  HWM. Its `currentHlc` advances on every push; if the device is online
  enough to run compaction, it has by definition just updated its own
  HWM.)*
  _Decision: accepted. The local device is always included. Rationale: the
  eviction helper is called at compaction time (triggered by a write), so
  the local HWM has already been updated by the preceding push. The
  `localDeviceId` parameter serves as the self-exclusion guard's inverse:
  it is the one ID that is **never** filtered out regardless of staleness._
- [x] **Q4 — How does an evicted device re-admit safely?** This is the
  hazardous side. A device that returns after the eviction window holds
  SSTables whose `maxHlc` is below the now-advanced horizon. If those
  SSTables are ingested, peers can resurrect deletes that GC has already
  reclaimed. Three candidate strategies, in increasing order of complexity:
  - **(a) Full re-sync on return.** When a device's local state shows
    `currentHlc < horizon - staleDeviceEvictionAfter` on next push (i.e.
    "I have been excluded"), it discards its local SSTables, downloads the
    current consolidated set, and rebuilds. Simple, expensive, *correct*.
    The historical `12_sync.md` text named this approach.
  - **(b) Ingest-side filter at the recipient.** Recipients reject any
    SSTable whose `maxHlc < horizon` from a known-stale peer. Cheaper, but
    couples to H4-FU3's ingest-side floor; the floor would do this for
    *all* peers, not just stale ones.
  - **(c) Sender-side floor.** The returning device, on detecting "I was
    evicted," self-prunes its outbound SSTables. Avoids the recipient
    needing to know who is stale, but requires the device to discover the
    current horizon before pushing — which means reading peer HWMs first.
  *(Recommended: **(a)** as the spec-level guarantee, with **(b)** as the
  defence-in-depth backstop once H4-FU3 lands. The pair makes both ends
  responsible for the invariant, which is appropriate for a silent-data-
  loss class of bug. Implementation can ship (a) first.)*
  _Decision: accepted, with the re-admission step **included in this plan
  rather than deferred**. Step 4 in the implementation plan is correctness-
  critical and the plan is not Investigated without it being specified. The
  split-to-sub-plan escape hatch (Step 4 text "if it grows large") is
  retained as a size-management valve but must not be used to defer the
  spec-level guarantee. See Review 1 for the expanded treatment of the
  detection invariant and the full-re-sync scope._
- [x] **Q5 — Detection of one's own evicted state.** On return, how does a
  device know it was evicted vs. merely behind? `lastUpdated` on its own
  prior `.hwm` is the obvious signal but is self-reported. Reading the
  *other* devices' HWMs and observing `min(currentHlc)` over peers (with
  self excluded) is more robust. *(Recommended: read peer HWMs first; treat
  `localCurrentHlc < min(peers.currentHlc)` *and* local
  `lastUpdated < now - staleDeviceEvictionAfter` as a re-sync trigger.)*
  _Decision: accepted with clarification. The two-condition test —
  `localCurrentHlc < min(peers.currentHlc)` AND
  `localLastUpdated < now - staleDeviceEvictionAfter` — is the correct
  detection rule. "Merely behind" (first condition alone) must not trigger
  a full re-sync; both conditions must hold. Peer HWMs are already read at
  push start (step 1 of the pull/push cycle), so there is no extra round
  trip. The `min(peers.currentHlc)` here uses the eviction-filtered peer
  list (i.e. only live peers count), not the strict min across all peers._
- [x] **Q6 — Garbage-collecting the evicted `.hwm` file itself.** A
  permanently dead device's `.hwm` will be excluded forever but stays in
  the sync folder. Should the consolidation coordinator delete it after
  some second, much longer threshold (or never)? *(Recommended: leave it
  for a follow-up; the per-file cost is trivial and a returning device
  that finds its old HWM still present can rejoin without coordination.)*
  _Decision: accepted. Out of scope for H4-FU2. Stale `.hwm` files are
  excluded from the min computation (not deleted), so their presence is
  inert. A returning device's old HWM remaining in place is actually
  beneficial: it can be updated in place on re-admission rather than
  requiring a fresh file create. Defer HWM file GC to a consolidation-
  coordinator follow-up._
- [x] **Q7 — Interaction with [`HighwaterMark.isPeerStale`](../../packages/kmdb/lib/src/sync/highwater.dart#L190).**
  This method exists, takes a `staleness: Duration = 90 days` parameter,
  and is unused outside its own tests (grep'd: only `highwater_test.dart`).
  Its current implementation only checks "have I ever seen this peer" — it
  ignores `staleness`. Is this the natural home for the new logic
  (operating against the *peers* map within one HWM), or should the
  eviction live in `minCurrentHlcAcrossDevices` (operating across *HWM
  files*)? They are different data: the peers map records "highest HLC I
  processed from X," not "X's last self-reported update." *(Recommended:
  eviction lives in / next to `minCurrentHlcAcrossDevices` because it
  operates on `lastUpdated` of the HWM files themselves, not peers
  entries. `isPeerStale` is concerned with a different lifecycle — peer
  *liveness* per-this-device — and should either be wired up properly or
  deprecated as a separate cleanup. Keep it out of scope here.)*
  _Decision: accepted. `isPeerStale` stays untouched by this plan. Its
  comment ("Phase 5: full staleness detection deferred to Phase 8") already
  documents it as a placeholder; H4-FU2 is not "Phase 8" — it is a
  targeted GC fix. The eviction logic belongs in `minCurrentHlcAcrossDevices`
  (or a sibling helper) where it can operate on the file-level `lastUpdated`.
  Wire-up or deprecation of `isPeerStale` is a separate micro-plan._

## Investigation

### Current behaviour and the exact peg

`minCurrentHlcAcrossDevices`
([highwater.dart:113](../../packages/kmdb/lib/src/sync/highwater.dart#L113))
lists every `*.hwm` in the HWM directory, loads each, and tracks the strict
minimum `currentHlc`. There is no filter — corrupt files throw, but a
syntactically valid but ancient `lastUpdated` is honoured at full weight. The
result feeds the provider registered by `SyncEngine`
([sync_engine.dart:106](../../packages/kmdb/lib/src/sync/sync_engine.dart#L106));
when the provider returns a value, `LsmEngine._computeTombstoneHorizon`
([lsm_engine.dart:169](../../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L169))
uses it verbatim (no further bounds check). So the peg flows directly from
the dead `.hwm` through to `CompactionJob`'s `dropTombstone` predicate.

### What `lastUpdated` already provides

[`HighwaterMark.lastUpdated`](../../packages/kmdb/lib/src/sync/highwater.dart#L73)
is set inside `withCurrentHlc` and persisted on every push — so for a live
peer it is at most one sync cycle behind real wall-clock time. The
[parser](../../packages/kmdb/lib/src/sync/highwater.dart#L240) normalises to
UTC. This field is exactly the eviction signal we need; nothing about the
HWM format changes for H4-FU2.

### What `isPeerStale` does and does not do today

[`HighwaterMark.isPeerStale`](../../packages/kmdb/lib/src/sync/highwater.dart#L190)
operates on the `peers` map *within a single HWM file* and answers "have I
ever recorded a peer's HLC?" The `staleness` duration parameter is
**unused** (documented "reserved for future use"). Grep confirms zero
production callers — `highwater_test.dart` is the only site, and it asserts
the trivial unknown-peer-true / known-peer-false behaviour. This method is
concerned with the wrong lifecycle for H4-FU2: it asks about local peer
*tracking* within one HWM, not about whole-device liveness across HWM
files. The plan should not repurpose it.

### How an evicted-then-returning device can resurrect

A device with a 6-month-old `.hwm` and `currentHlc = T0` was the slowest
reporter; eviction lets the horizon advance to `T1 ≫ T0`. While the device
was offline:

1. Some other peer wrote `delete(k)` at HLC `T0 < hlc_del < T1`.
2. That tombstone was observed by all *remaining* peers.
3. Compaction on some peer dropped the tombstone (`hlc_del < T1` and the
   eviction means the slow peer no longer pegs the horizon).

When the dormant device returns, it still holds a pre-`delete` SSTable
containing `put(k, v_old)` at some HLC `< hlc_del`. If it pushes that
SSTable and a peer ingests it as an L0 file, the merge result reads `v_old`
because the tombstone is gone. The peer has resurrected a deleted key.

This is why **incremental re-admission is unsafe** and Q4's recommended
answer is full re-sync: the returning device's existing SSTables are no
longer trustworthy relative to the advanced horizon. They are not corrupt;
they are simply pre-decision data the rest of the topology has already
moved past.

### The "freshly-configured sync folder" interaction

`SyncEngine`'s provider returns `Hlc(0, 0)` when no `.hwm` files exist
([sync_engine.dart:111](../../packages/kmdb/lib/src/sync/sync_engine.dart#L111)),
which blocks every drop until at least one device has pushed. After
eviction, if *every* HWM is excluded (e.g. a long-quiescent project where
no device pushed within the eviction window), we land back at this case.
The conservative behaviour — block GC entirely rather than dropping to the
local-only grace fallback — appears correct: there is at least one HWM
file, so the database *is* in synced mode; we just have no current ground
truth. The plan should preserve this branch.

### Files to change (provisional)

| File | Change |
|------|--------|
| `lib/src/sync/highwater.dart` | Add an `evictAfter: Duration?` parameter (or sibling helper) to `minCurrentHlcAcrossDevices`; skip HWM files whose `lastUpdated` is older than `now - evictAfter` *except* the local device's own HWM. |
| `lib/src/sync/sync_engine.dart` | Plumb `KvStoreConfig.staleDeviceEvictionAfter` (or sibling) into the provider it registers; pass the local `deviceId` so the helper can exclude self. |
| `lib/src/engine/kvstore/kv_store.dart` | Add `staleDeviceEvictionAfter: Duration` to `KvStoreConfig` (default 90 days; document trade-offs and the re-admission requirement). |
| `lib/src/sync/sync_engine.dart` (return path) | Detect "I was evicted" on push start (Q5 rule) and trigger a **full re-sync** — discard local SSTables for synced namespaces, redownload, rebuild HWM from scratch. Phasing TBD; may split into a follow-up sub-plan. |
| `docs/spec/12_sync.md` | Replace the "known limitation" paragraph with the eviction rule, the default threshold, the re-admission protocol, and the safety argument. Reinstate (and update) the historical 90-day text. |
| `docs/spec/06_storage_engine.md` | Cross-reference the eviction rule from the tombstone-GC section. |
| `packages/kmdb/test/sync/highwater_test.dart` | Cover eviction in `minCurrentHlcAcrossDevices` (basic, self-not-evicted, all-evicted blocks GC, returning-device flow). |
| `packages/kmdb/test/sync/sync_engine_test.dart` | Eviction-aware horizon registration; re-admission trigger detection. |

### What this plan deliberately does **not** do

- It does not introduce the ingest-side horizon floor — that is **H4-FU3**.
  Once both land, the protection is layered: H4-FU2 keeps the distributed
  horizon advancing; H4-FU3 keeps any single device's ingest from
  contradicting it.
- It does not garbage-collect old `.hwm` files (Q6). That is a separate
  consolidation-coordinator concern.
- It does not change `isPeerStale` (Q7). That method's wire-up or
  deprecation is its own micro-plan.
- It does not relitigate the H4 PR2 safety conditions; it composes with
  them by ensuring the `horizon` input is no longer pegged by ghosts.

## Implementation plan

_Questions resolved — implementation plan is locked. See Q1–Q7 decisions in
the Open questions section above and Review 1 for the full safety argument._

### Step 1 — Configuration
- [ ] Add `KvStoreConfig.staleDeviceEvictionAfter: Duration` (default 90
      days), positioned adjacent to `tombstoneGraceDuration` in the class.
      Doc comment must state: (a) the safety trade-off (longer is safer but
      defers GC); (b) that a device idle longer than this threshold **must
      perform a full re-sync** on return — incremental catch-up is unsafe
      and will produce resurrections; (c) the pairing semantics —
      `tombstoneGraceDuration` is the local-only grace window and
      `staleDeviceEvictionAfter` is the distributed eviction window; they
      are the two halves of "how long until a delete is considered globally
      observed."

### Step 2 — Eviction-aware horizon
- [ ] Extend `HighwaterMark.minCurrentHlcAcrossDevices` (or add a sibling
      `minCurrentHlcExcludingStale`) to accept an `evictAfter: Duration?`,
      a `now: DateTime` (test seam, default `DateTime.now()`), and a
      required `localDeviceId: String` that is **never** excluded regardless
      of staleness.
- [ ] Skip HWM files where
      `now.difference(hwm.lastUpdated) > evictAfter`
      *and* `hwm.deviceId != localDeviceId`.
- [ ] Preserve the "no HWM files yet" / "all non-local HWMs evicted" → `null`
      contract so `SyncEngine` continues to map it to `Hlc(0, 0)` — the
      blocking horizon that prevents any drop when the sync topology has no
      current ground truth.

### Step 3 — Wire through `SyncEngine`
- [ ] Pass `_config.staleDeviceEvictionAfter` and `_deviceId` into the
      provider registered in the `SyncEngine` constructor, replacing the
      current no-argument call to `minCurrentHlcAcrossDevices`.

### Step 4 — Safe re-admission
- [ ] At the start of each push cycle, after reading peer HWMs but before
      uploading any local SSTables, apply the two-condition eviction check:
      `localCurrentHlc < min(livePeers.currentHlc)`
      AND `localHwm.lastUpdated < now - staleDeviceEvictionAfter`
      where `livePeers` is the eviction-filtered peer list (stale peers
      excluded, local device excluded).
- [ ] When **both** conditions hold: the device has been excluded from the
      GC horizon by every live peer. Perform a full re-sync:
        1. Delete all local SSTables for synced namespaces.
        2. Re-download the current consolidated SSTable set from the sync
           folder.
        3. Ingest downloaded SSTables to rebuild local state.
        4. Reset and re-upload the local HWM.
      This is the correctness-critical step — skipping it allows a
      resurrection. If implementation scope grows unexpectedly, split this
      step into `plan_sync_full_resync_after_eviction.md` and track it as a
      blocker; do **not** ship eviction without re-admission.
- [ ] When false (normal path): proceed with the existing incremental push.

### Step 5 — Tests
- [ ] **Eviction admits the horizon to advance:** two HWMs, one with
      `lastUpdated > evictAfter` ago, one fresh; `min` returns the fresh
      device's HLC, not the strict minimum.
- [ ] **Local device never self-evicts:** a stale `lastUpdated` on the
      local HWM is ignored when the helper is called with that device's
      ID; the strict minimum still includes self.
- [ ] **All-evicted → null/block:** every HWM stale (e.g. dormant project)
      collapses to `null`, which `SyncEngine` maps to `Hlc(0, 0)` so no
      tombstones drop.
- [ ] **Returning-device resurrection guard (CI):** simulate eviction +
      drop a tombstone past the advanced horizon + simulate the device's
      return *with* the re-admission check enabled — assert the device
      performs a full re-sync (no resurrection). Then disable the check —
      assert the resurrection occurs (proves the test is wired right).
- [ ] **Multi-device end-to-end:** in-process two-device test, then add a
      release-checklist entry for the cross-process variant under
      `kmdb_harness` once `plan_harness_mixed_storage.md` lands.

### Step 6 — Documentation
- [ ] `docs/spec/12_sync.md`: replace the "Known limitation: slowest-device
      peg" bullet with the eviction rule, threshold, and re-admission
      protocol. Restore the historical 90-day text adjusted for the
      current model.
- [ ] `docs/spec/06_storage_engine.md`: cross-reference the eviction rule
      from the tombstone-GC paragraph.
- [ ] Update the H4-FU2 roadmap entry status when complete.
- [ ] Update doc comments on `KvStoreConfig`, `HighwaterMark`, and
      `SyncEngine` to mention the new pairing.

### Step 7 — Verify
- [ ] `make pre_commit` clean.
- [ ] `dart test` passes in `packages/kmdb` and `packages/kmdb_cli`.
- [ ] Coverage ≥ 90% as per `CLAUDE.md`.
- [ ] Release-checklist entry added to
      `docs/spec/28_release_checklist.md` for the cross-device returning-
      stale-device scenario (companion to RC-6 from H4 PR2).

### Step 8 — PR
- [ ] Branch + worktree per `docs/plans/README.md`. Open PR against `main`,
      update **PR link** above, and on merge move this plan to
      `docs/plans/completed/`.

## Summary

{To be completed during implementation.}

## Reviews

### Review 1: 2026-05-28

#### Problem Statement Assessment

The problem is real, well-scoped, and the motivation is airtight. The plan correctly names the two distinct safety questions (eviction and re-admission) and the investigation section traces the exact code path from a dead `.hwm` through `minCurrentHlcAcrossDevices` → `SyncEngine` provider → `_computeTombstoneHorizon` → `CompactionJob.dropTombstone`. Every cited line number was verified against the current codebase and is accurate. The resurrection scenario is explained with enough concreteness that an implementer can write a test for it directly.

The "freshly-configured sync folder" interaction is handled correctly: the existing `min ?? Hlc(0, 0)` fallback in `sync_engine.dart:111` stays correct when all non-local HWMs are evicted, because the net result is still `Hlc(0, 0)` blocking all drops. The plan preserves this invariant in Step 2 by specifying the same null-to-blocking mapping.

#### Proposed Solution Assessment

The eviction approach (filter on `lastUpdated` against the evaluating device's wall clock, with the local device exempted) is sound. The clock-trust analysis in Q2 is correct: the damage from a misbehaving uploader is bounded on both sides — future-dating delays GC but is not a safety violation; past-dating causes self-eviction (conservative for that peer, irrelevant to resurrection risk for others). No HLC-skew layer is needed.

The re-admission strategy (full re-sync on detecting both conditions) is the right call. Option (b) ingest-side filter at the recipient is not a substitute for (a) — it requires the recipient to track which peers are stale, which creates coupling the plan correctly avoids. Option (c) sender-side floor requires the returning device to discover the current horizon before pushing, which is essentially what (a) does anyway, but without the clean rebuild that restores a coherent local state. Full re-sync on (a) is safe, simple, and makes the correctness argument easy to audit.

**One gap in the Q4/Step 4 treatment as written:** the original Step 4 bullet said "check whether `localCurrentHlc < min(peer.currentHlc) - staleDeviceEvictionAfter`." That comparison is dimensionally wrong — you cannot subtract a `Duration` from an `Hlc`. The correct formulation (now locked in the updated Step 4) is the two-condition AND: the device's HLC is behind the live-peer minimum **and** its `lastUpdated` is older than the eviction threshold. The first condition alone triggers a normal catch-up sync; only both conditions together indicate the device has been excluded from the GC horizon. This distinction matters because a device that is merely slow (first condition, not second) must not be forced into a full re-sync.

**Scope of the full re-sync in Step 4:** the plan says "discard local synced-namespace SSTables, redownload the consolidated set." This needs one clarification at implementation time: the consolidation coordinator must have run (or be running) to produce a consolidated set; if no consolidated SSTable exists (e.g. a single-device sync folder after the other device vanished), the returning device downloads whatever individual SSTables are present. The implementation should handle both cases. This does not block Investigated status but should be noted in the Step 4 doc comment.

#### Architecture Fit

The change sits entirely within the sync layer boundary. `KvStoreConfig` gains one new `Duration` field; `HighwaterMark` gains parameters on one static method; `SyncEngine` passes those parameters through. `LsmEngine._computeTombstoneHorizon` is untouched — it calls whatever the provider returns. The layer separation is fully preserved.

No library-architecture concerns: `highwater.dart` is core (no Flutter), `sync_engine.dart` is core, `kv_store.dart` is core. The change does not touch any UI or app layer. The `design` and `inclusivity` skills are not applicable to this plan.

The spec updates are correctly scoped: `12_sync.md` (replace the "known limitation" paragraph), `06_storage_engine.md` (cross-reference). Both are needed to close the documentation gap left by H4 PR2.

#### Risk & Edge Cases

**Covered by the plan:**
- All-evicted → blocking horizon (correct, preserved).
- Local device self-exemption (correct).
- Test seam on `now:` parameter for deterministic tests (correct).

**Not covered, but do not block Investigated status:**

1. **Consolidated-set absent during re-admission.** If the returning device triggers a full re-sync but the sync folder has never been consolidated (no 4-segment SSTable), the "redownload consolidated set" step must fall back to downloading all individual SSTables. This is a normal path; note it in the Step 4 implementation comment.

2. **Two devices returning simultaneously after joint eviction.** If two devices were both evicted and both return at the same time, each will detect the other as a live peer with a stale HLC — the two-condition detection may fire for both, triggering simultaneous full re-syncs. This is safe (both re-sync from the cloud state, which converges), but worth a test case or at minimum a comment in the detection logic.

3. **Interaction with `isPeerStale` confusion.** The doc comment on `isPeerStale` says "Phase 5: full staleness detection deferred to Phase 8." This plan is effectively "Phase 8" for eviction, but deliberately leaves `isPeerStale` alone (Q7 decision). The risk is an implementer reading the Phase 8 reference and concluding they should wire up `isPeerStale`. The Q7 decision note is clear, but the `isPeerStale` doc comment should be updated to remove the stale Phase 8 reference and redirect to `minCurrentHlcAcrossDevices`. This is a small addition to Step 6.

4. **`tombstoneGraceDuration` vs. `staleDeviceEvictionAfter` ordering hazard.** A user who sets `staleDeviceEvictionAfter` shorter than `tombstoneGraceDuration` creates a window where a device is evicted but the local-only horizon has not yet advanced past its tombstones. The doc comment on `staleDeviceEvictionAfter` should state that it is meaningless to set it shorter than `tombstoneGraceDuration`.

#### Recommendations

1. Accept all seven Q recommendations as decided.
2. Include the two-condition eviction detection (`localCurrentHlc < min(livePeers.currentHlc)` AND `localLastUpdated < now - threshold`) in the spec update — do not leave the detection rule implicit.
3. Add a doc comment update to `isPeerStale` (Step 6) to remove the stale "Phase 8" forward-reference.
4. Add a note in the `staleDeviceEvictionAfter` doc comment warning against setting it shorter than `tombstoneGraceDuration`.
5. The split-to-sub-plan escape valve in Step 4 is retained but must be treated as a hard blocker: do not land eviction (Steps 1–3) without the re-admission logic (Step 4). If they must split, H4-FU2 is not mergeable until the sub-plan is also merged.

All seven questions resolve cleanly. The plan is promoted to **Investigated**.

- [x] One doc comment gap in `isPeerStale` ("Phase 8" forward-reference) should be
      cleared as part of Step 6.
      _Decision: add a `isPeerStale` doc comment update to Step 6 — small, no
      scope impact, prevents implementer confusion._
- [x] `staleDeviceEvictionAfter < tombstoneGraceDuration` ordering hazard should be
      documented in the config field's doc comment.
      _Decision: add to Step 1 doc comment requirements — one sentence, no
      behavioural change._
