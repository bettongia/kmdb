# Manifest replay applies `added` before `removed` — data loss on filename reuse

**Status**: Investigated

**PR link**: {pending}

## Problem statement

`ManifestReader._fromEdits` applies each `VersionEdit`'s `added` list **before**
its `removed` list. When a single edit contains the *same filename* in both
lists — which the compaction path legitimately and intentionally emits when a
compaction output reuses an input's filename (identical `deviceId` +
`minHlc`/`maxHlc`) — the within-edit ordering nets the file to **removed**. The
file is therefore absent from the reconstructed `ManifestState`, and crash
recovery's orphan sweep then **deletes the live SSTable from disk**. This is a
silent, permanent data-loss bug on reopen.

It exists on `main` today (HEAD `2753384`). It was surfaced by the WI-14
dirty-flag work (branch `20260727_plan_0_10_01_dirty_flag_meta_retire`, WIP
commit `288d905`), but WI-14 does **not** introduce it — WI-14 merely removes a
write pattern (a `$meta` dirty-flag put on first write) whose extra
flush/compaction traffic was masking the degenerate edit in the existing test
suite. This fix is sequenced as a prerequisite that lands **beneath** WI-14 on
`main`.

## Investigation

### The three-part defect (independently verified against HEAD `2753384`)

1. **Replay ordering.** `ManifestReader._fromEdits`
   (`packages/kmdb/lib/src/engine/manifest/manifest_reader.dart:168-180`)
   iterates `edit.added` first (lines 172-176), inserting each file into
   `liveMeta`, then iterates `edit.removed` (lines 177-179), deleting each. For
   a filename present in **both** lists of one edit, the remove runs last →
   the file is dropped from the reconstructed state. (The doc comment at
   lines 158-163 says "The last add wins for a filename", which is true
   *across* edits but false *within* one edit given this loop order.)

2. **The source of the degenerate edit is intentional and load-bearing.**
   `CompactionJob.run`
   (`packages/kmdb/lib/src/engine/compaction/compaction_job.dart:461-467`)
   builds every compaction edit as `added: <outputs>, removed: <all inputs>`.
   The output filename is `SstableInfo.flushName(deviceId, minHlc, maxHlc)`,
   derived from the surviving entries' HLC extremes. When a single input
   file's HLC range equals the output range (same device), the output filename
   equals that input's filename, so the *same name* appears in both `added`
   and `removed` of one edit. The runtime path **relies** on this: all three
   compaction methods —
   `_compactL0ToL1` (`lsm_engine.dart:960-991`),
   `_compactL1ToL2` (`lsm_engine.dart:1013-1027`),
   `_compactAll` (`lsm_engine.dart:1107+`) — carry an explicit guard that
   **evicts the stale cached reader for the reused name but skips the on-disk
   delete**, because the compaction has overwritten the file *in place*. The
   intended semantics is unambiguous: same name ⇒ in-place overwrite ⇒ file
   stays ⇒ **added wins**. Replay lacks the matching guard.

3. **Crash recovery turns the drop into deletion.** `CrashRecovery`
   (`packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart:139-146`) sweeps
   every `.sst` file not present in `state.allFiles` and deletes it. Because
   replay dropped the reused file from `state`, the still-referenced,
   fully-live SSTable is deleted as an "orphan" → permanent loss on reopen.

### Is added-wins unconditionally correct? (Yes.)

The reviewer's charge was to confirm or refute that a single edit removing and
adding the same filename can *never* legitimately mean two different logical
files that must both survive. It cannot:

- A filesystem directory holds exactly **one** file per name. The compaction
  writes its output to that path, overwriting the input. After the operation
  there is one file at the path, and it is the **output** (the `added` entry).
  Replay must mirror on-disk reality, so `added` must win.
- Filenames are `{deviceId}-{minHlcPhysHex}-{maxHlcPhysHex}[.local].sst`
  (`SstableInfo.flushName`; note only the **physical** HLC component appears —
  `toPhysicalHex()`). The uniqueness guarantee that matters is the OS path, not
  HLC uniqueness. Two distinct inputs can never share a name (they'd be the
  same path). An output collides with **at most one** input, and that input is
  the one it overwrites.
- Therefore reordering to apply `removed` before `added` within each edit is
  safe for every case: for the intersection it yields the correct
  in-place-overwrite (added-wins) result; for disjoint add/remove sets the
  order is irrelevant. Cross-edit accumulation ordering is unchanged.

### Blast radius / other consumers

- **Only one state-reconstruction consumer feeds a destructive path.**
  `ManifestReader.replay` → `ManifestState._fromEdits` is consumed by
  `crash_recovery.dart:125` (the data-loss path) and re-exported via
  `kmdb_analysis.dart` for CLI diagnostics (`util manifest`). The diagnostic
  path is read-only but would also mis-report the dropped file; the fix
  corrects both. `replayEdits` (raw edit list for `util manifest --full`) does
  no state folding and is unaffected.
- **Manifest rotation is safe.** Rotation snapshots the engine's in-memory
  `_levels` (which the runtime keeps correct) as one all-`added` edit; it does
  not go through the buggy fold.
- **Consolidation is immune.** `SstableInfo.consolidationName` embeds a
  monotonic `epoch` fencing token, so consolidation outputs never share a name
  with their (flush-named) inputs — `added`/`removed` are always disjoint.
- **All three compaction paths share the collision potential.** `_compactAll`
  requires ≥2 inputs, so with monotonic, non-overlapping per-file HLC ranges
  its combined output range equals no single input's range in normal operation
  (a same-millisecond degenerate case aside). The clean, deterministic trigger
  is a **single-input** compaction — `_compactL1ToL2` with exactly one L1 file
  over the L1 byte cap, or `_compactL0ToL1` when `l0CompactionTrigger` is 1 —
  where the sole input's range is trivially the output range.

## Open questions

- [x] **Fix replay only, or also harden the edit source so compaction never
  persists a filename in both `added` and `removed`?**
  **Decision: fix replay only. Do not change the source.** Reasons:
  1. The replay fix is *necessary regardless* — degenerate edits already exist
     in on-disk manifests of live databases, and only a replay-side fix heals
     them. A source-only change would leave existing databases exposed.
  2. The collision is **intentional and load-bearing**. The runtime cache
     eviction in all three compaction methods iterates `edit.removed` to evict
     the stale reader for the reused path. Dropping the reused name from
     `removed` at the source would silently reintroduce a **stale-reader**
     bug (a served-from-cache-after-overwrite defect). Forcing a distinct
     output filename instead would perturb SSTable/sync identity for no benefit
     and a much larger blast radius.
  3. With replay corrected to added-wins, the source is already correct: the
     edit faithfully records "these inputs were consumed; this output (which
     happens to reuse a name) is live." The bug is entirely in the reader.
  A one-line defensive note in `CompactionJob.run` documenting that a reused
  output name in both lists is expected-and-safe is a welcome nicety but not
  required.

## Implementation plan

### Fix

- [ ] In `ManifestReader._fromEdits`
  (`packages/kmdb/lib/src/engine/manifest/manifest_reader.dart`), swap the two
  loops so `edit.removed` is applied **before** `edit.added` within each edit.
  Cross-edit iteration order is unchanged; only the intra-edit order flips.
- [ ] Update the explanatory comment (currently lines 158-163) to state the
  invariant explicitly: *within a single edit, `removed` is applied before
  `added` so that a filename present in both lists (a compaction output that
  reused an input's name via an in-place overwrite) correctly resolves to
  present — matching the runtime, which overwrites the file on disk rather than
  deleting it.* Cross-reference the runtime guard in `LsmEngine`.
- [ ] (Optional, encouraged) Add a one-line comment at the `VersionEdit`
  construction in `CompactionJob.run` noting that an output filename may
  legitimately equal an input filename and will appear in both `added` and
  `removed`, and that this is an in-place overwrite the manifest reader resolves
  as added-wins.

### Tests

- [ ] **Unit regression at `ManifestReader` level (mandatory).** Construct a
  manifest (via `ManifestWriter` to a real/faulty adapter, or the existing test
  harness) whose records include an edit with the **same filename** in both
  `added` and `removed` (plus at least one unrelated live file, to prove the
  fold is otherwise intact). Replay and assert the reused file **is present** in
  `state.levels` / `state.allFiles`, with the `added` entry's metadata
  (level/minKey/maxKey/entryCount). Confirm this test **fails on pre-fix code**
  and passes after — record that verification in the PR.
- [ ] **Engine-level integration regression on plain `main` (mandatory — must
  not lean on WI-14).** This is a durability defect; per CLAUDE.md it must be
  proven end-to-end through real compaction → manifest → close → reopen, not
  just at the unit fold. It **is** triggerable on `main`:
  1. Open an engine with a `KvStoreConfig` that forces a **single-input**
     compaction — e.g. tiny `l1MaxBytes` so one L1 file exceeds the cap and
     `_compactL1ToL2` runs with a single input, or `l0CompactionTrigger: 1` so
     `_compactL0ToL1` runs on a single L0 file. Either yields an output whose
     `flushName` range equals the sole input's range ⇒ reused filename ⇒ one
     edit with that name in both `added` and `removed`.
  2. Write a set of documents through that compaction and confirm they are
     readable while the engine is open.
  3. Close and **reopen** (fresh engine ⇒ manifest replay + orphan sweep).
  4. Assert every previously-written key is still readable and the reused
     `.sst` still exists on disk. This **fails on `main`** (keys gone, file
     orphan-swept) and passes after the fix.
  - Use a real/`FaultyStorageAdapter`-backed on-disk adapter, not the
    in-memory adapter — the 2026-05-22 review established that in-memory
    adapters hide exactly this class of data-loss bug (the orphan sweep +
    delete must run against a real directory listing).
- [ ] **Do not** make the end-to-end proof depend on WI-14's failing suite.
  WI-14 may be reworked or abandoned; a guardrail that only lives on an
  unmerged branch leaves `main` with no regression coverage and lets a future
  replay refactor silently reintroduce the loss. The two tests above stand on
  `main` independently. WI-14's suite going green once this lands beneath it is
  a welcome corroboration, not the proof.
- [ ] Confirm no existing manifest/compaction/crash-recovery tests regress.

### Final step — QA sign-off and pre-commit

- [ ] Run `make coverage` — confirm >95% on changed files (the fold and both
      tests).
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test adequacy, code health). Resolve every blocking item before
      opening a PR.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (2026).
- [ ] Consider whether `docs/spec/10_manifest.md` and/or
      `docs/spec/17_crash_recovery.md` should state the intra-edit
      removed-before-added invariant explicitly; add it if the spec is silent.

## Reviewer notes (kmdb-plan-reviewer, 2026-07-29)

- All three claimed defects independently confirmed against HEAD `2753384` at
  the exact lines cited. The bug is real, on `main`, and severity is data loss
  on reopen.
- The proposed primary fix (reorder replay to removed-before-added within each
  edit) is **correct and complete**. Added-wins is unconditionally safe — the
  OS path-uniqueness invariant, not HLC uniqueness, is what guarantees a single
  edit's reused name always denotes one physical file being overwritten in
  place. No refutation found.
- Open question decided in-plan: **fix replay only**; hardening the source would
  reintroduce a stale-reader bug via the cache-eviction dependency and would not
  heal already-persisted degenerate edits.
- Test bar: unit regression is necessary but **not sufficient**; a
  main-triggerable engine integration regression (single-input compaction →
  reopen → keys survive, on a real/faulty on-disk adapter) is **mandatory** and
  is constructible on `main` as specified. Leaning on WI-14's suite is rejected.
- No other destructive replay consumers; consolidation and rotation are immune.
- Plan clears the implementation-readiness bar: exact file/line targets, a
  one-line mechanical fix, a decided open question, and two concrete,
  fail-first-verified tests. **Status → Investigated.**

## Summary

{to be completed on implementation}
