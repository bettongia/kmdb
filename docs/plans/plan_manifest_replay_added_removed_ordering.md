# Manifest replay applies `added` before `removed` — data loss on filename reuse

**Status**: Implementing

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
- **Only *same-level* filename reuse trips the bug** (corrected during
  implementation — verified empirically, not by inspection; see the Tests
  section and the new engine regression's doc comment). `_fromEdits`'s
  `liveMeta` is keyed by the **pair `(level, filename)`**, so an intra-edit
  collision only matters when the reused name appears in `added` and `removed`
  at the **same level**. The single-input `_compactL1ToL2` / `_compactL0ToL1`
  recipe originally proposed here does **not** reproduce the defect:
  `_compactL0ToL1` outputs at L1 vs. its L0 inputs at L0, and `_compactL1ToL2`
  outputs at L2 vs. its L1 inputs at L1 — the reused name lands in *different*
  level buckets, so pre-fix code already handles it correctly (confirmed: a
  test of exactly that shape passes on unmodified `main`). The genuine trigger
  is **`_compactAll`'s single-file-collapse shortcut**, whose `outputLevel: 2`
  can coincide with an existing L2 input's own level, reusing that file's exact
  name at the same level. The engine regression drives precisely this (two keys
  flushed into one L2 file, then a third key ingested with an HLC strictly
  interior to that file's range, triggering the collapse and reusing the name).

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

- [x] In `ManifestReader._fromEdits`
  (`packages/kmdb/lib/src/engine/manifest/manifest_reader.dart`), swap the two
  loops so `edit.removed` is applied **before** `edit.added` within each edit.
  Cross-edit iteration order is unchanged; only the intra-edit order flips.
- [x] Update the explanatory comment (currently lines 158-163) to state the
  invariant explicitly: *within a single edit, `removed` is applied before
  `added` so that a filename present in both lists (a compaction output that
  reused an input's name via an in-place overwrite) correctly resolves to
  present — matching the runtime, which overwrites the file on disk rather than
  deleting it.* Cross-reference the runtime guard in `LsmEngine`.
- [x] (Optional, encouraged) Add a one-line comment at the `VersionEdit`
  construction in `CompactionJob.run` noting that an output filename may
  legitimately equal an input filename and will appear in both `added` and
  `removed`, and that this is an in-place overwrite the manifest reader resolves
  as added-wins.

### Tests

- [x] **Unit regression at `ManifestReader` level (mandatory).** Construct a
  manifest (via `ManifestWriter` to a real/faulty adapter, or the existing test
  harness) whose records include an edit with the **same filename** in both
  `added` and `removed` (plus at least one unrelated live file, to prove the
  fold is otherwise intact). Replay and assert the reused file **is present** in
  `state.levels` / `state.allFiles`, with the `added` entry's metadata
  (level/minKey/maxKey/entryCount). Confirm this test **fails on pre-fix code**
  and passes after — record that verification in the PR.

  **Correction found during implementation:** `liveMeta` is keyed by the
  *pair* `(level, filename)`, not filename alone. A filename reused across
  *different* levels (e.g. an L1 file recompacted unchanged to L2 — the
  scenario this checklist item originally described) does **not** hit the
  bug: `added` and `removed` land in different `liveMeta[level]` buckets, so
  intra-edit ordering is immaterial and pre-fix code already handles it
  correctly (verified empirically — a test built exactly this way passed on
  unmodified `main`). The bug requires `level(added) == level(removed)` for
  the reused filename. The implemented unit test at
  `packages/kmdb/test/engine/manifest_test.dart` (group "ManifestReader —
  filename reuse within a single edit") uses matching levels (both 2) and
  was confirmed to fail on pre-fix code, then pass post-fix.
- [x] **Engine-level integration regression on plain `main` (mandatory — must
  not lean on WI-14).** This is a durability defect; per CLAUDE.md it must be
  proven end-to-end through real compaction → manifest → close → reopen, not
  just at the unit fold.

  **Correction found during implementation — the suggested trigger recipe
  does not reproduce the bug.** Empirically verified (see
  `packages/kmdb/test/engine/manifest_replay_filename_reuse_regression_test.dart`'s
  doc comment for the full analysis): `_compactL0ToL1` always writes to
  `outputLevel: 1` while a genuinely new L0 write always advances the HLC
  maximum (this device's clock is monotonic), so a reused-range output can
  never coincide with a pre-existing L1 input's own (older, narrower) range.
  `_compactL1ToL2` always removes at `level: 1` and adds at `level: 2` —
  different levels, so even when a single L1 input's name is reused verbatim
  the pre-fix code already resolves it correctly (see the unit-test
  correction above). Neither of the two config knobs originally suggested
  (`l1MaxBytes` tiny / `l0CompactionTrigger: 1`) produces a same-level
  collision; both were tried and produced no data loss on pre-fix code.

  The only compaction path that can produce a genuine `level(added) ==
  level(removed)` collision is `_compactAll` (`outputLevel: 2`, whose inputs
  may include existing L2 files at `level: 2`), and only when the merge's
  surviving HLC range exactly reproduces one L2 input's own range unchanged.
  The implemented test constructs this deterministically without relying on
  tombstone-GC or key-superseding timing: two keys (A, B) flushed together
  produce a single L2 file F with range `[hlcA, hlcB]`; a third, unrelated
  key C is ingested as a foreign SSTable with an HLC **strictly between**
  `hlcA` and `hlcB` (via an injected, fully controlled `HlcClock`), which
  immediately triggers `_compactAll`'s single-file-collapse shortcut. Because
  C's HLC falls entirely inside F's existing range, the merged output's range
  is unchanged from F's own — reusing F's exact filename at the same level
  (2) F itself occupied as a `removed` input. The database then simulates a
  crash (`FaultyStorageAdapter.crash()`, no clean `close()` — a clean
  `close()` after any write sets the dirty flag and triggers a `clearDirty()`
  write that cascades into a further compaction, which in this tiny-database
  test happens to supersede/mask the collision edit before reopen) and
  reopens. Confirmed to **fail on pre-fix code** (keys A/B/C become
  unreadable; the `.sst` file is deleted by the orphan sweep) and pass after
  the fix (verified via `git stash` of only the fix commit, then restored).
- [x] **Do not** make the end-to-end proof depend on WI-14's failing suite.
  WI-14 may be reworked or abandoned; a guardrail that only lives on an
  unmerged branch leaves `main` with no regression coverage and lets a future
  replay refactor silently reintroduce the loss. The two tests above stand on
  `main` independently (this branch was created directly off `main`, not
  off the WI-14 branch). WI-14's suite going green once this lands beneath it
  is a welcome corroboration, not the proof.
- [x] Confirm no existing manifest/compaction/crash-recovery tests regress.
  Full `kmdb` test suite (`dart test` from `packages/kmdb`) passes: 2409 run,
  12 skipped (E2E, skipped by default), 0 failures.

### Final step — QA sign-off and pre-commit

- [ ] Run `make coverage` — confirm >95% on changed files (the fold and both
      tests). *(Not run by kmdb-plan-implement in this session — deferred to
      kmdb-qa per the coordinator's instruction.)*
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test adequacy, code health). Resolve every blocking item before
      opening a PR.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
      *(`dart analyze` and `dart format` were run manually and are clean; the
      full `make pre_commit` gate itself is deferred to the kmdb-pre-commit
      agent per the coordinator's instruction.)*
- [x] Verify licence headers on any new files (2026). The one new file,
      `manifest_replay_filename_reuse_regression_test.dart`, has the header.
- [x] Consider whether `docs/spec/10_manifest.md` and/or
      `docs/spec/17_crash_recovery.md` should state the intra-edit
      removed-before-added invariant explicitly; add it if the spec is silent.
      Both were silent; both now state the invariant (see `docs/spec/10_manifest.md`
      "the same `(level, filename)` pair may legitimately appear in both `add`
      and `remove`" note and the "Level reconstruction" bullet, and
      `docs/spec/17_crash_recovery.md` step 4 and the compaction failure-scenario
      row).

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

**Implementation in progress — awaiting kmdb-qa sign-off and kmdb-pre-commit
before commit/PR.**

- Fixed `ManifestReader._fromEdits` to fold `edit.removed` before `edit.added`
  within each `VersionEdit`, so a filename reused in place by a compaction
  (same `deviceId` + `minHlc`/`maxHlc`) resolves to present ("added wins"),
  matching the runtime's in-place-overwrite semantics. Cross-edit order is
  unchanged.
- Added a doc comment cross-referencing the `LsmEngine` runtime guard, and an
  optional note at `CompactionJob.run`'s `VersionEdit` construction.
- Added a fail-first unit regression
  (`packages/kmdb/test/engine/manifest_test.dart`, group "ManifestReader —
  filename reuse within a single edit") and a fail-first engine-level
  regression (new file
  `packages/kmdb/test/engine/manifest_replay_filename_reuse_regression_test.dart`),
  both verified to fail on pre-fix code and pass post-fix.
- **Correction to the plan's suggested reproduction recipe**, discovered
  during implementation: the bug requires a *same-level* filename collision
  (`liveMeta` is keyed by `(level, filename)`, not filename alone). The
  plan's suggested triggers (single-input `_compactL1ToL2` or
  `_compactL0ToL1`) always produce *cross-level* reuse (output level always
  one above the reused input's own level), which the pre-fix code already
  handles correctly — verified empirically, not just reasoned. Only
  `_compactAll` can produce a same-level collision (its inputs may include
  existing L2 files at `level: 2`, matching its own `outputLevel: 2`), and
  only when the merge's surviving range exactly reproduces one L2 input's
  own range unchanged. Both regression tests were rebuilt around this
  corrected understanding; see the "Tests" checklist above and the engine
  test's doc comment for the full analysis.
- Updated `docs/spec/10_manifest.md` and `docs/spec/17_crash_recovery.md`,
  both previously silent on the intra-edit ordering invariant.
- Full `kmdb` test suite passes (2409 run, 12 E2E skipped by default, 0
  failures); `dart analyze` clean; `dart format` applied.
