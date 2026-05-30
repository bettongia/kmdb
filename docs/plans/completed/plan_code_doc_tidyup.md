# §6 Code and documentation tidy-up

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/30

**Implementation model:** Sonnet — cosmetic, except keep the `get()` three-state
semantics (don't collapse tombstone vs absent). Light review.

**Sequencing**: Independent and low-risk; can land any time. Two items have
subtleties (A and E below) that must not be "simplified" naively. Excludes the
stale "full UTF-8 for Phase 8" comments, which are owned by
`plan_utf8_namespace_encoding.md` (M2) — don't duplicate.

## Problem statement

The 2026-05-22 code review (`code-review-2026-05-22.md` §6, plus one item from §5)
listed low-severity dead code and doc drift. None affect data integrity, but two
sit in correctness-critical spots where a misleading comment or a careless
"cleanup" could later cause a real bug. This plan clears them in one small PR
while preserving the subtle behaviour.

## Investigation

### A. Dead code + redundant flag in `LsmEngine.get()`

In the L0 and L1/L2 lookup loops, the second branch is unreachable — the first
`if` already returned:

```dart
final result = await _getFromSstable('$_sstDir/${l0[i]}', prefix, prefixEnd);
if (result != null) return result.$1;
if (result != null && result.$2) return result.$1;   // unreachable
```

([lsm_engine.dart:288-289](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L288),
[L300-L302](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L300)).
`_getFromSstable` returns `(Uint8List?, bool)?`
([lsm_engine.dart:999](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L999))
where the `bool` (`found`) is **always true when the tuple is non-null**, so it is
redundant — but the **outer nullability is not**: it distinguishes three states
that must be preserved:

- `null` → key absent in this file → **continue to the next file**;
- `(null, true)` → tombstone → **stop, key is deleted** (return null);
- `(value, true)` → hit → return value.

**Trap:** collapsing the return to a plain `Uint8List?` would make "tombstone"
and "absent" both `null`, so the loop would skip past a tombstone to an older
file and **resurrect deleted data**. The cleanup must keep three states — e.g.
return `({Uint8List? value})?` (outer-null = absent; inner-null = tombstone) — and
drop only the dead `if` and the redundant `bool`.

### B. Misleading `encodeInternalKey` doc comment

The doc says the key orders "secondary on `hlc` descending (higher sequence =
newer, emitted first during merge)"
([key_codec.dart:149-151](../packages/kmdb/lib/src/engine/util/key_codec.dart#L149)).
In fact the HLC is written **big-endian ascending**, so older versions sort
*first* and the newest sorts **last**; the read path deliberately takes the *last*
entry in a prefix scan. The code is correct; the comment inverts the ordering in a
correctness-critical place. Fix the comment to describe ascending order +
newest-last + "read takes the last entry."

### C. No-op in `SyncEngine.pull`

`hwm = hwm.withCurrentHlc(hwm.currentHlc)` sets `currentHlc` to itself
([sync_engine.dart:290](../packages/kmdb/lib/src/sync/sync_engine.dart#L290)) — a
leftover. Remove the line; the subsequent `hwm.save(...)` is unaffected.

### D. `SyncEngine.sync()` doc/code mismatch

The doc says "On failure in [push], [pull] is still attempted so the local
database receives incoming changes even if the upload fails," but the code is
`await push(); await pull();` with no guard
([sync_engine.dart:298-305](../packages/kmdb/lib/src/sync/sync_engine.dart#L298)),
so a push failure skips pull. Reconcile doc and code (decision D2).

### E. Manifest-rotation snapshot drops SSTable metadata

`_doManifestRotation` writes the snapshot `VersionEdit` with empty
`minKey`/`maxKey` and `entryCount: 0` for every file
([lsm_engine.dart:758-771](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L758)),
because the in-memory `_levels` map holds only filenames, not `SstableMeta`. These
fields are diagnostic-only (not used for correctness), but after a manifest
rotation the real values are lost permanently. The honest minimal fix is to
document this; the proper fix (track `SstableMeta` in the level map, or re-read
footers for `entryCount`) is a larger change — see decision D3.

### F. General sweep (bounded)

A quick pass for other stale `Phase N` comments (excluding the M2-owned UTF-8
ones), unused locals/fields flagged by the analyzer, and leftover TODOs in the
files above. Defer anything that belongs to another authored plan; this item is
strictly cosmetic.

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — `_getFromSstable` return type.** Recommended: return
  `({Uint8List? value})?` (or a small 3-state enum), dropping the redundant
  `bool`, **without** collapsing tombstone and absent into one `null`.
- [ ] **D2 — `sync()` push-then-pull.** Recommended: **fix the doc** to match the
  code (a push failure propagates and pull is not attempted) — zero behaviour
  change, lowest risk. Alternative: make `sync()` resilient (run pull in a
  `finally`) — defer to its own change if desired, since it alters behaviour.
- [ ] **D3 — Rotation metadata.** Recommended for *this* tidy-up: **document**
  that `minKey`/`maxKey`/`entryCount` are diagnostic and may be empty after a
  rotation. Track real `SstableMeta` through the level map as a **separate**
  follow-up (it touches many engine methods and is more than tidy-up; it also
  becomes cheap once M1's reader cache lands, since `entryCount` is in the footer).

## Implementation plan

### Step 1 — `get()` dead code (A)
- [x] Change `_getFromSstable` to the 3-state return (D1); update both call sites
      to a single `if (result != null) return result.value;`; remove the dead
      second `if` in both loops.

### Step 2 — Doc fixes (B, plus D2 doc option)
- [x] Correct the `encodeInternalKey` ordering comment (ascending; newest last;
      read takes the last entry).
- [x] Reconcile the `SyncEngine.sync()` doc with the code per D2.

### Step 3 — No-op removal (C)
- [x] Delete the self-assigning `withCurrentHlc(hwm.currentHlc)` line in `pull`.

### Step 4 — Rotation metadata (E, per D3)
- [x] Add a doc comment at `_doManifestRotation` stating the snapshot's
      `minKey`/`maxKey`/`entryCount` are diagnostic and reset on rotation; record
      the proper-fix follow-up.

### Step 5 — Sweep (F)
- [x] Grep the touched files for stale `Phase N` comments / TODOs; run the
      analyzer for unused elements; clean only cosmetic findings, deferring any
      owned by another plan.
  - Updated the stale "Phase 6+" comment on `syncNamespaces` in sync_engine.dart.
  - Fixed two pre-existing `no_leading_underscores_for_local_identifiers` lint
    issues in wal_test.dart (`_put`/`_del` → `makePut`/`makeDel`).

### Step 6 — Tests
- [x] **Tombstone-suppression regression (guards A):** put a value, flush; delete
      the key (tombstone in a newer file), flush; `get` returns `null` — the
      tombstone must suppress the older value and not resurrect it. (This is the
      behaviour the redundant flag protected; the test makes the invariant
      explicit before the refactor.)
- [x] All existing tests pass unchanged (the rest are doc/no-op edits).

### Step 7 — Verify
- [x] `dart test packages/kmdb` (1525 pass, 9 E2E skips) and `cd packages/kmdb_cli && dart test` (839 pass, 1 E2E skip) pass.
- [x] `make analyze` clean.

> No release-checklist (§28) entry needed — all changes are CI-covered.

## Summary

- **`_getFromSstable` 3-state return (A/D1):** Replaced the `(Uint8List?, bool)?`
  positional tuple with the named record `({Uint8List? value})?`. Outer `null` =
  absent (continue); `({value: null})` = tombstone (stop); `({value: bytes})` =
  hit. Removed the dead unreachable second `if` in both L0 and L1/L2 loops. Added
  a tombstone-suppression regression test that exercises the correctness-critical
  cross-SSTable scenario before the refactor.
- **`encodeInternalKey` ordering comment fixed (B):** The comment said `hlc`
  descending; it is actually big-endian ascending (oldest first, newest last). The
  read path takes the last entry. The code was always correct; only the comment
  was wrong.
- **`SyncEngine.sync()` doc fixed (D2):** Doc previously claimed pull is attempted
  even when push fails. Corrected to match the code: push failure propagates and
  pull is skipped.
- **No-op line removed (C):** Deleted `hwm = hwm.withCurrentHlc(hwm.currentHlc)`
  in `SyncEngine.pull` — a self-assignment leftover with no effect.
- **Rotation metadata doc added (E/D3):** `_doManifestRotation` now has a doc
  comment noting that `minKey`/`maxKey`/`entryCount` are diagnostic-only and
  reset to empty/0 on each rotation (because `_levels` tracks filenames only).
  References the proper-fix follow-up plan `plan_sstable_meta_tracking.md`.
- **Sweep (F):** Updated the stale "Phase 6+" doc on `syncNamespaces`. Fixed
  pre-existing `no_leading_underscores_for_local_identifiers` lint in
  `wal_test.dart` (`_put`/`_del` → `makePut`/`makeDel`).
