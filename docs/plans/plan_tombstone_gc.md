# Fix H4 PR2: Safe tombstone GC (sync-horizon-gated, no resurrection)

**Status**: Investigated

**PR link**: {pending}

**Depends on:** [plan_compaction_reclamation.md](completed/plan_compaction_reclamation.md)
(PR1 — version collapse + reclamation policy hook, now merged). PR2 builds on the same
streaming transform and the same policy hook; it does not duplicate the
investigation and refers back to PR1 for context.

**Implementation model:** Opus, or strong-model review. The all-levels +
sync-horizon rule is easy to get *almost* right and silently resurrect deleted
data — this is the part of H4 that warrants the highest review bar.

## Problem statement

PR1 collapses superseded versions but leaves every delete-tombstone in place,
forever. Tombstones are not free: each one occupies SSTable space, contributes
to read cost (the merge has to scan past it), and — crucially in a synced
database — is the **only** mechanism that prevents a peer's older copy from
"resurrecting" a deleted key on next sync. Until PR2, KMDB's storage footprint
for any actively-deleting workload still grows without bound.

PR2 introduces **safe tombstone GC**: drop a group's tombstone only when both
safety conditions hold simultaneously. Get either wrong and we either retain
tombstones forever (no benefit) or resurrect deleted rows on next sync (silent
data loss).

## Investigation

The full safety analysis is in
[plan_compaction_reclamation.md → Investigation](completed/plan_compaction_reclamation.md#investigation);
the summary that PR2 acts on:

### The two safety conditions

1. **All-levels coverage (level recency).** A tombstone may only be dropped if
   the current compaction covers **every level** that could hold an older
   version of the key. KMDB levels do **not** imply recency — sync ingest
   places old-HLC data into L0 — so "bottom level" alone is insufficient. The
   safe rule is "this compaction covers all on-disk data for the key," which
   in practice is the `_compactAll` / single-file collapse path
   ([lsm_engine.dart:678](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L678)).
   Partial compactions (`_compactL0ToL1`, `_compactL1ToL2`) must **always**
   keep tombstones.
2. **Past the sync horizon (cross-device safety).** Every device must have
   already observed the delete. Dropping a tombstone with `hlc ≥ horizon`
   while a peer still holds an older copy lets the peer's value resurrect on
   next sync.

Per D1 (revised in PR1), the horizon is **always required** — there is no
local-only fast-path:

- **Synced database:** `horizon = min(currentHlc)` across all `.hwm` files in
  the sync folder. Every device has synced past this HLC.
- **Local-only database:** `horizon = now - tombstoneGraceDuration` (wall-clock,
  conservative). The grace window protects the local → synced transition: as
  long as sync is enabled within the grace window, tombstones written before
  that transition still suppress peer values on first sync. Default grace ≥
  expected max sync lag (target a week).

Both branches feed a single `horizon: Hlc` value injected into `CompactionJob`,
so compaction stays decoupled from the sync folder.

### The "inactive device" wrinkle

`min(currentHlc)` is pegged by the slowest device. A device that goes offline
and never returns blocks GC forever. **PR2 does not solve this**, but should
document it and surface a knob (e.g. a max device staleness after which an HWM
file is excluded). A follow-up plan can refine the eviction rule; for PR2 the
safe default is the strict `min`.

### Vault ref-count boundary

Already addressed in PR1's investigation: ref counts are maintained at write
time by `VaultRefInterceptor`, so dropping a tombstone has no ref-count
side-effect. (Dropping a non-tombstone version is collapse, which is PR1.)
Restated here only so PR2 reviewers do not have to chase the cross-plan
reference.

### Files to change

| File | Change |
|------|--------|
| `lib/src/engine/compaction/compaction_job.dart` | Extend PR1's streaming transform: per-group, after collapse, drop a surviving tombstone iff `allLevels && hlc < horizon`. |
| `lib/src/engine/kvstore/lsm_engine.dart` | Thread `allLevels` (true only for `_compactAll`/single-file) and the GC horizon into `CompactionJob`. |
| `lib/src/engine/kvstore/kv_store.dart` (config) | Add `tombstoneGraceDuration` to `KvStoreConfig`; document the default. |
| `lib/src/sync/highwater.dart` (or sibling) | Helper to compute `min(currentHlc)` across `.hwm` files, callable by the engine before a compaction. |
| `lib/src/engine/kvstore/lsm_engine.dart` | At compaction start, ask the sync layer for the horizon (synced) or fall back to wall-clock minus grace (local-only). |
| `docs/spec/06_storage_engine.md`, `12_sync.md`, `18_concurrency.md` | Document tombstone GC, the all-levels rule, the level-recency caveat, the horizon rule, and the local-only grace window. |

## Implementation plan

### Step 1 — Thread `allLevels` and `horizon` into `CompactionJob`
- [ ] Add `allLevels: bool` and `horizon: Hlc` to `CompactionJob`'s constructor.
- [ ] Set `allLevels = true` only for `_compactAll` / single-file collapse; set
      it `false` for `_compactL0ToL1` and `_compactL1ToL2`.
- [ ] Plumb both values through `LsmEngine`'s compaction call sites.

### Step 2 — Drop tombstones safely in the reclamation transform
- [ ] Extend PR1's streaming transform: after collapse, if the surviving entry
      of a group is a tombstone, drop it iff `allLevels && tombstone.hlc < horizon`.
      Otherwise emit it unchanged.
- [ ] Ensure non-tombstone groups, and groups where the tombstone is *not* the
      latest version (i.e. a later write), are unaffected — only a surviving
      tombstone is eligible for drop.

### Step 3 — Horizon computation
- [ ] In the sync layer, add a helper that returns `min(currentHlc)` across all
      `.hwm` files in the sync folder. Skip the local device's own HWM only if
      the protocol already does (verify).
- [ ] In `LsmEngine`, before invoking a compaction:
      - If sync is configured → call the sync helper for `horizon`.
      - Else → `horizon = HLC(now - tombstoneGraceDuration, 0)`.
- [ ] Pass the resolved `horizon` into `CompactionJob`.

### Step 4 — Config
- [ ] Add `tombstoneGraceDuration: Duration` to `KvStoreConfig` with a
      conservative default (≥ expected max sync lag — target 7 days unless
      there's a reason for shorter). Document trade-offs in the doc comment.
- [ ] Surface the option via the CLI's existing config plumbing (mirror the
      pattern used by other `KvStoreConfig` durations — search the CLI for the
      closest analogue at implementation time rather than hard-coding here).

### Step 5 — Tests
- [ ] **Tombstone dropped only when safe:** in `_compactAll` with
      `hlc < horizon`, the tombstone is gone and the key reads as absent.
- [ ] **Tombstone NOT dropped in partial compaction:** delete a key with an
      older value in an excluded level; partial compaction keeps the tombstone;
      the key stays deleted (no resurrection).
- [ ] **Tombstone NOT dropped above horizon:** `_compactAll` where
      `tombstone.hlc >= horizon` must retain the tombstone, even though
      `allLevels == true`.
- [ ] **No resurrection across sync (CI-testable):** write + delete +
      `_compactAll` with `hlc < horizon` so the tombstone *is* dropped; then
      `ingestSstable` a crafted older-HLC SSTable for that key and assert the
      key is **not** resurrected. Construct the older value in an SSTable
      directly so it bypasses normal write-path interception.
- [ ] **Local-only grace:** with no sync configured, a tombstone older than
      `tombstoneGraceDuration` is dropped on the next `_compactAll`; one
      younger is retained.
- [ ] **Synced horizon respects slowest device:** with two HWM files, one
      "behind", a tombstone past the *current* device's HLC but before the
      slow peer's `currentHlc` must be retained.
- [ ] **Mixed group:** a key with intervening writes after a tombstone (HLCs:
      v1, tombstone, v2) — PR1's collapse already keeps only v2 there; PR2
      changes nothing for this case. Test that we don't accidentally drop a
      *non-surviving* tombstone (the safety invariant is about the surviving
      latest entry).

### Step 6 — Documentation
- [ ] `docs/spec/06_storage_engine.md`: document tombstone GC, the all-levels
      rule, and the level-recency caveat. Cross-reference the policy hook
      added in PR1.
- [ ] `docs/spec/12_sync.md`: document the tombstone GC horizon (`min` HWM),
      the local-only grace window, the local → synced transition guarantee,
      and the known limitation re: dead/inactive devices.
- [ ] `docs/spec/18_concurrency.md`: update the note PR1 added to also cover
      delete reclamation.

### Step 7 — Verify
- [ ] `make pre_commit` clean.
- [ ] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [ ] Benchmark: confirm storage no longer grows unbounded under an
      overwrite/delete workload (PR1 covered overwrites; PR2 closes deletes).
- [ ] Add a release-checklist entry to
      `docs/spec/28_release_checklist.md` for the cross-device "no
      resurrection" scenario, to be re-run via `kmdb_harness` once
      `plan_harness_mixed_storage.md` lands. The in-process ingest test
      above covers the core case in CI without it.

### Step 8 — PR
- [ ] Open PR2 against `main` after PR1 has merged; update **PR link** above;
      on merge move this plan to `docs/plans/completed/`.

## Summary

{To be completed during implementation.}
