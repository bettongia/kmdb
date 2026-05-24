# Fix C1: Crash recovery silently deletes the active WAL (post-flush data loss)

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Opus, or strong-model review before merge —
data-loss-critical; the WAL-retention off-by-one and full-replay-vs-flush-marker
logic are easy to get subtly wrong.

## Problem statement

Any durable write that lands after the first `VersionEdit` of a session — i.e.
after the first flush, compaction, sync ingest, or manifest rotation — is
**silently and permanently destroyed** if the process crashes (is killed without
a clean `close()`) before the next flush. On the following open:

- the data is gone, and
- `OpenResult.hadInterruptedWrites` is `false`, so nothing signals the loss.

This was reproduced empirically during the 2026-05-22 code review
(`code-review-2026-05-22.md`, finding **C1**). The Write-Ahead Log does its job —
the records are fsync'd to disk — but **crash recovery deletes the WAL file that
holds them without ever replaying it.**

This is the single most important correctness issue in KMDB. A database that
discards durably-logged writes on restart cannot be trusted with user data. The
problem statement is sound and the fix is high priority.

## Investigation

### Root cause

Two independent defects combine. Either one alone causes data loss; both must be
fixed.

**Defect 1 — WAL retention off-by-one (`crash_recovery.dart`).**

Every `VersionEdit` is written with `logNumber = _walWriter.activeSequence`, i.e.
the number of the **currently active** WAL:

- flush: [lsm_engine.dart:537](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L537) (after `rotate()`, so the *new* active WAL)
- compaction: [lsm_engine.dart:621](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L621), [L658](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L658), [L695](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L695)
- sync ingest: [lsm_engine.dart:832](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L832) (`ingestAt0`, no rotate)
- manifest rotation: [lsm_engine.dart:772](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L772) (no rotate)

`ManifestState` then takes `maxLogNumber = max(logNumber)` across all edits
([manifest_reader.dart:165](../packages/kmdb/lib/src/engine/manifest/manifest_reader.dart#L165)).
So once *any* edit has been written, **`maxLogNumber == the active WAL's
sequence number`** (the cases without a rotate set it to the current active WAL;
flush sets it to the new active WAL it just rotated to).

Recovery then does ([crash_recovery.dart:154](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L154)):

```dart
if (seq <= state.maxLogNumber) {
  await adapter.deleteFile(path);   // "already persisted in an SSTable"
  continue;
}
```

Because the active WAL's `seq == maxLogNumber`, the predicate `seq <= maxLogNumber`
is **true for the active WAL**, so recovery deletes the very file holding the
unflushed writes — without replaying it. The comparison should be `<`, not `<=`:
WAL files with `seq < maxLogNumber` are obsolete; files with `seq >= maxLogNumber`
must be **replayed**.

The only reason this isn't caught immediately is the fresh-database case: the
initial edit is `VersionEdit(logNumber: 0)`
([crash_recovery.dart:93](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L93)),
so the first WAL (`seq 1 > 0`) is correctly replayed. The bug only manifests
*after the first edit of a database's life*, which in practice is almost always.

**Defect 2 — flush markers are written before the SSTable is durable.**

Even with Defect 1 fixed, recovery replays retained WALs via
`replayFromLastFlush` ([wal_reader.dart:79](../packages/kmdb/lib/src/engine/wal/wal_reader.dart#L79)),
which skips every record up to and including the **last flush marker**.
`flush()` writes that marker during `rotate()`
([lsm_engine.dart:495](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L495),
[wal_writer.dart:117](../packages/kmdb/lib/src/engine/wal/wal_writer.dart#L117))
**before** the SSTable is written ([lsm_engine.dart:525](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L525))
and before the `VersionEdit` is appended. If a crash occurs after the marker is
fsync'd but before the SSTable + manifest are durable, recovery sees a WAL whose
trailing marker claims "everything before is in an SSTable" — but the SSTable was
never written. `replayFromLastFlush` skips those records → data loss.

The marker is therefore an unsafe recovery optimisation. The correct behaviour is
to **replay retained WAL files in full** and rely on HLC last-write-wins to make
any re-applied (already-flushed) record idempotent.

### Why full replay is safe (no double-application)

- After a *successful* flush, the retired WAL is deleted in flush step 6
  ([lsm_engine.dart:556](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L556)),
  so it is never replayed. The new active WAL contains only its own un-flushed
  records.
- A retired WAL that survived a crash (deletion didn't run) has `seq <
  maxLogNumber` once its flush's `VersionEdit` is durable, so recovery deletes it
  without replay — its data is in the SSTable.
- A WAL replayed because its flush's `VersionEdit` did **not** persist has no
  corresponding SSTable, so re-applying its records restores (not duplicates)
  data.
- If a record ever *is* applied twice (same internal key — same namespace, user
  key, HLC, and type), it is byte-identical and collapses under the existing
  merge/dedup logic. HLC LWW guarantees idempotency.

### Reproduction (already verified)

Using the in-memory adapter, whose `files` map survives a simulated crash (only
the lock is dropped). This is sufficient because C1 is a pure recovery-logic
defect — the data is genuinely on disk; recovery deletes it.

```dart
final adapter = MemoryStorageAdapter();
final (store, _) = await KvStoreImpl.open('/db', adapter,
    config: KvStoreConfig.forTesting(), deviceId: 'testdev1');
await store.put('ns', key1, bytes('flushed'));
await store.flush();                                // key1 -> SSTable; WAL rotated
await store.put('ns', key2, bytes('unflushed'));    // key2 only in active WAL
MemoryStorageAdapter.releaseAllLocks();             // crash: no close()

final (store2, result) = await KvStoreImpl.open('/db', adapter,
    config: KvStoreConfig.forTesting(), deviceId: 'testdev1');
// OBSERVED (buggy):  result.hadInterruptedWrites == false
//                    get('ns', key1) == 'flushed'
//                    get('ns', key2) == null        // SILENT DATA LOSS
// EXPECTED (fixed):  get('ns', key2) == 'unflushed'
```

### Scope boundary — relationship to C2

This plan makes recovery correct **given a durable manifest**. There remains a
separate crash window (review finding **C2**): `ManifestWriter.append` never
fsyncs ([manifest_writer.dart:66](../packages/kmdb/lib/src/engine/manifest/manifest_writer.dart#L66)),
yet `flush()`/compaction delete WALs/inputs immediately afterward. If the
manifest edit is lost, the new SSTable is orphaned *and* its source WAL/inputs
are already gone. That fsync-ordering fix is **out of scope here** and will be a
separate plan; the two together provide end-to-end crash safety. This plan does
not depend on C2 and can land first.

### Files to change

| File | Change |
|------|--------|
| `engine/kvstore/crash_recovery.dart` | `seq <= maxLogNumber` → `seq < maxLogNumber`; replace `replayFromLastFlush` with full replay; keep tail-truncation detection |
| `engine/wal/wal_reader.dart` | Recovery uses `replay` (full). Remove/deprecate `replayFromLastFlush` and `replayAll` if unused after the change |
| `engine/wal/wal_writer.dart` | Decision-dependent: stop writing flush markers in `rotate()` (see Decisions) |
| `engine/kvstore/lsm_engine.dart` | If markers removed: `rotate()` no longer appends a marker; update flush step 2 comment |
| `engine/wal/wal_record.dart` | If markers removed: keep `flushMarker` decodable for back-compat with existing WALs, but stop emitting it |
| `docs/spec/17_crash_recovery.md` | Rewrite step 5 (replay `seq >= logNumber` in full) and correct the failure table |
| `docs/spec/07_wal.md` | Update flush-marker description to match |
| `test/engine/crash_recovery_test.dart` | Add the regression tests below; fix the mislabelled "un-flushed WAL records" test |
| `test/engine/wal_test.dart` | Adjust for marker changes if applicable |

### Test-infrastructure note

C1's regression tests need **only the existing `MemoryStorageAdapter`** — the
data is durably in its `files` map and the bug is recovery deleting it, which the
memory adapter models faithfully (`deleteFile` removes the key). The broader
fault-injection adapter recommended in the review (§8) is **not required** for
this plan; it is needed for C2/H1 (fsync ordering) and will come with those.

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Stop writing flush markers entirely?** Recommended: **yes.** Once
  recovery does full replay, markers are unused. Removing the write in `rotate()`
  simplifies the format and removes a foot-gun. Keep `WalRecordType.flushMarker`
  *decodable* so databases written by older builds (which have markers in their
  WALs) still replay — full replay simply skips marker records as no-ops
  (`crash_recovery.dart` already does `if (record.type == flushMarker) continue;`).
  Alternative: keep writing markers but ignore them in recovery (lower diff, but
  retains dead complexity).
- [ ] **D2 — Backfill a recovery checkpoint?** Optional. After replay, recovery
  could append a fresh `VersionEdit` (advancing `logNumber`) so replayed WALs are
  reclaimed immediately rather than at the next flush. Recommended: **no** (keep
  this plan minimal; the next flush already cleans them, and adding a write on
  open complicates read-only opens). Note for a future optimisation only.
- [ ] **D3 — Migration / existing on-disk databases.** The change is
  backward-compatible: existing WALs (with markers) replay correctly under full
  replay, and the `<` comparison is strictly more conservative (it replays files
  the old code deleted). No data migration required. Confirm we accept that an
  already-corrupted (already-lost) database cannot be retroactively repaired —
  this fixes future crashes only.

## Implementation plan

### Step 1 — Fix the WAL retention predicate

In `crash_recovery.dart`, the WAL loop ([L150–L202](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L150)):

1. Change the skip/delete predicate from `seq <= state.maxLogNumber` to
   `seq < state.maxLogNumber`.
2. Files with `seq >= state.maxLogNumber` are replayed.

### Step 2 — Replace flush-marker skipping with full replay

In the same loop:

1. Replace the `walReader.replayFromLastFlush(path)` call
   ([crash_recovery.dart:179](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L179))
   with full replay (`walReader.replay(path)`), keeping the existing
   `if (record.type == WalRecordType.flushMarker) continue;` guard so any legacy
   markers are skipped.
2. Preserve tail-truncation detection: the existing byte-consumed-vs-file-size
   check ([crash_recovery.dart:166–176](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L166))
   stays and continues to set `hadInterruptedWrites`. Consider collapsing the
   double pass (consumed-count loop + replay) into a single `tryDecode` walk that
   both counts consumed bytes and yields records, to avoid decoding twice.
3. Continue tracking `replayedMaxHlc` across all replayed records to seed the
   clock.

### Step 3 — Stop emitting flush markers (pending D1 = yes)

1. `WalWriter.rotate()` ([wal_writer.dart:117](../packages/kmdb/lib/src/engine/wal/wal_writer.dart#L117)):
   no longer append a `flushMarker`; just increment `_sequence` and return the
   old path. Update the doc comment.
2. `LsmEngine.flush()` step 2 ([lsm_engine.dart:493](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L493)):
   update the comment; the rotate call still establishes the WAL boundary.
3. `WalReader`: remove `replayFromLastFlush` and `replayAll` if no other
   callers remain (grep first); keep `replay` and `replayStrict`.
4. `WalRecordType.flushMarker`: keep the enum value and `tryDecode` support for
   backward compatibility; only the *writing* is removed.

### Step 4 — Tests (regression suite for C1)

Add to `crash_recovery_test.dart` a group `'CrashRecovery — durable WAL replay'`.
All use the "crash" pattern: write, `MemoryStorageAdapter.releaseAllLocks()`
(no `close()`), reopen with the same adapter.

- [ ] **put after flush survives** — the exact reproduction above; assert key2
      restored and key1 intact.
- [ ] **delete after flush survives** — put+flush a key, delete it, crash,
      reopen; assert it stays deleted (a lost tombstone *resurrects* data).
- [ ] **write after sync ingest survives** — `ingestSstable` a peer file, then a
      local `put`, crash, reopen; assert the local put survives (ingest writes a
      `VersionEdit` with `logNumber = activeSequence`, which also triggers C1).
- [ ] **write after compaction survives** — force enough flushes to trigger
      compaction, write, crash, reopen; assert the post-compaction write survives.
- [ ] **multiple flush cycles** — interleave flushes and writes; crash; assert
      all acknowledged writes are present.
- [ ] **crash mid-flush (pre-SSTable)** — construct on-disk state of a WAL with
      records but a flush whose SSTable/`VersionEdit` never landed (e.g. via a
      seam that aborts `flush()` after `rotate()`), reopen; assert the records
      replay (covers Defect 2 directly).
- [ ] **truncated active WAL still flags `hadInterruptedWrites`** — truncate the
      last record of the active WAL; assert good records survive and
      `hadInterruptedWrites == true`.
- [ ] **fix the mislabelled existing test** — "un-flushed WAL records restored on
      reopen" ([crash_recovery_test.dart:79](../packages/kmdb/test/engine/crash_recovery_test.dart#L79))
      calls `close()` (which flushes), so it never exercises WAL replay. Change it
      to crash without `close()`, or rename it to reflect that it tests clean
      close.

### Step 5 — Documentation

- [ ] Rewrite `docs/spec/17_crash_recovery.md` step 5: replay WAL files with
      `seq >= logNumber` **in full**; remove "from their last flush marker".
- [ ] Correct the §17 failure table: the "After SSTable fsync, before VersionEdit
      appended" and compaction rows must reflect the corrected guarantees (and
      reference C2 for the manifest-fsync dependency rather than claiming
      unconditional "None").
- [ ] Update `docs/spec/07_wal.md` to describe markers as legacy/decoded-only
      (pending D1).
- [ ] Add a short note to the `OpenResult`/recovery doc comments describing the
      replay semantics.

### Step 6 — Verify

- [ ] `dart test packages/kmdb` — all pass (was 1264 + 9 skipped).
- [ ] `cd packages/kmdb_cli && dart test` — all pass.
- [ ] `make analyze` — clean.
- [ ] Confirm the new C1 regression tests **fail on `main`** (before the fix) and
      **pass after** — proving they guard the bug.

## Summary

{To be completed during implementation.}
