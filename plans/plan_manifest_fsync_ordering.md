# Fix C2: Manifest is never fsynced; durable data deleted before its replacement is persisted

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Opus — data-loss-critical, and the `FaultyStorageAdapter`
(Step 0) is novel design, not transcription.

**Sequencing**: Implement **after** `plan_crash_recovery_wal_replay.md` (C1).
C1 makes WAL recovery correct *given a durable manifest*; C2 makes the manifest
(and the directory entries around it) actually durable. C1 must land first
because some C2 crash scenarios assume the corrected replay semantics, and both
plans touch `flush()` / compaction / `crash_recovery.dart`.

## Problem statement

The LSM commit protocol assumes a durability ordering it does not enforce:
**write the new file → record it in the manifest → only then delete the old
copy.** In the current code the middle step is not durable, so there is a crash
window in which the only durable copy of data is deleted while the manifest entry
that points to its replacement is still in OS buffers.

Concretely (review finding **C2**, with **H1** and **M3** as inseparable parts of
the same root cause):

1. `ManifestWriter.append()` appends the `VersionEdit` and **never fsyncs**
   ([manifest_writer.dart:66](../packages/kmdb/lib/src/engine/manifest/manifest_writer.dart#L66)).
2. `flush()` then deletes the retired WAL
   ([lsm_engine.dart:556](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L556)),
   and compaction deletes its **input** SSTables
   ([lsm_engine.dart:630](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L630),
   [L664](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L664),
   [L704](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L704)) — both
   immediately after the un-fsynced append.
3. `syncDir` is implemented but **never called** anywhere (H1), so even when file
   *contents* are fsynced, the directory entries that link new SSTables / WAL
   files / the renamed `CURRENT` are not durable on Linux.
4. The `CURRENT` swap writes its temp file with `flush: false` and never fsyncs
   the temp or the directory (M3) — `CurrentFile.write`
   ([current_file.dart:67](../packages/kmdb/lib/src/engine/manifest/current_file.dart#L67))
   and the manifest-rotation path
   ([lsm_engine.dart:782](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L782)).

On crash within these windows the new SSTable becomes an orphan (deleted by
recovery step 4) while the originals (WAL or compaction inputs) are already
gone → **total loss of that flush's / compaction's data**. The manifest-rotation
variant is worse still: a crash after the `CURRENT` rename but before the new
manifest content is durable leaves `CURRENT` pointing at an empty/partial
manifest, losing the **entire level map**.

The problem statement is sound. This is the second half of making KMDB
crash-safe; without it, C1's correct recovery logic still has nothing durable to
recover from in these windows.

## Investigation

### The invariant to establish

For every operation that replaces durable state, enforce this order:

```
1. Write new file(s)         writeFile + syncFile(newFile)          [SSTables: already done]
2. Link new file(s)          syncDir(dir containing new file)        [NEW — H1]
3. Record in manifest         append + syncFile(manifest)            [NEW — C2 core]
   (rotation also: syncDir(dbDir) for the newly-created manifest file)
4. Publish (rotation only)    write+syncFile(CURRENT.tmp), rename,
                              syncDir(dbDir)                          [NEW — M3]
5. Delete obsolete file(s)    deleteFile(old WAL / inputs / old manifest)
```

The current code already orders *append-before-delete* in flush and compaction —
the defect is purely the **missing `syncFile`/`syncDir`** between them. So most of
the work is inserting fsync calls at the right points, plus one genuine
re-ordering hazard in manifest rotation (publish CURRENT only after the new
manifest is durable).

The `StorageAdapter` interface already exposes both `syncFile`
([storage_adapter_interface.dart:49](../packages/kmdb/lib/src/engine/platform/storage_adapter_interface.dart#L49))
and `syncDir`
([storage_adapter_interface.dart:55](../packages/kmdb/lib/src/engine/platform/storage_adapter_interface.dart#L55)),
and the native adapter implements both correctly
([storage_adapter_native.dart:92](../packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L92),
[L105](../packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L105)).
**No interface change is required.** The memory/web adapters keep them as no-ops.

Note `writeFile` on native uses `flush: false`
([storage_adapter_native.dart:71](../packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L71)),
so durability always depends on a following `syncFile` — already true for
SSTables, missing for `CURRENT.tmp` and the manifest.

### Per-site analysis

| Site | Current | Needs |
|------|---------|-------|
| `ManifestWriter.append` | append only | append + `syncFile(path)`; on the *first* append to a newly-created manifest, caller also `syncDir(dbDir)` |
| `flush()` | SSTable fsynced; append; delete WAL | add `syncDir(sstDir)` after SSTable write; append now fsyncs; then delete WAL |
| `CompactionJob.run` | output fsynced; append | add `syncDir(sstDir)` after output write; append now fsyncs; engine deletes inputs after `run()` returns (ordering already correct) |
| `ingestAt0` / `ingestSstable` | file fsynced; append | add `syncDir(sstDir)` after the ingested file is written, before append |
| `_doManifestRotation` | new manifest (no fsync); CURRENT.tmp (no fsync) → rename; delete old | fsync new manifest + `syncDir(dbDir)`; durable CURRENT swap; **then** delete old manifest |
| `CurrentFile.write` | writeFile(tmp) → rename | `syncFile(tmp)` before rename, `syncDir(dbDir)` after rename |
| `CrashRecovery` fresh-DB create | CURRENT + initial manifest, no fsync | inherits the `CurrentFile.write` + append-fsync fixes; add `syncDir(dbDir)` |

`sstDir` is `"$dbDir/sst"` (a subdirectory). New SSTables need `syncDir(sstDir)`;
new WAL files, the manifest, and `CURRENT` live in `dbDir` and need
`syncDir(dbDir)`.

### Why the in-memory adapter cannot test this (key difference from C1)

`MemoryStorageAdapter` makes `syncFile`/`syncDir` no-ops and never loses buffered
data — a simulated "crash" only drops the lock
([storage_adapter_memory.dart:76](../packages/kmdb/lib/src/engine/platform/storage_adapter_memory.dart#L76)).
So the entire C2/H1/M3 class of bugs is invisible to it: there is no way to make
an un-fsynced write disappear. C1 was provable with the memory adapter only
because the bug was recovery *deleting* durable data. C2 is about *non-durable*
data surviving a crash, which requires modelling durability.

**Therefore this plan must deliver a fault-injecting storage adapter** (the
harness recommended in the code review, §8). This is the single highest-leverage
test artifact in the durability work — it also unlocks regression tests for C1's
mid-flush case and any future ordering changes.

#### Proposed `FaultyStorageAdapter` (test-only)

A `StorageAdapter` that models power-loss durability:

- **File-content durability:** keep `_durable[path]` (last-fsynced bytes) and
  `_pending[path]` (current bytes). `writeFile`/`appendFile` mutate `_pending`;
  `syncFile(path)` promotes `_pending[path]` → `_durable[path]`.
- **Directory-entry durability:** `createFile`/`rename`/`delete` are recorded as
  pending namespace ops; `syncDir(dir)` commits pending ops for that directory.
- **`crash()`:** discard all un-synced content (revert each file to `_durable`,
  dropping files never synced) and all un-committed directory ops (un-create new
  files, undo un-synced renames/deletes). Reads after `crash()` see only durable
  state.

This is enough to assert, decisively, that the **buggy** flush loses data and the
**fixed** flush does not. Keep it in `test/` (e.g.
`test/support/faulty_storage_adapter.dart`); it is not shipped.

### Performance note (accepted)

The fix adds one manifest `syncFile` and one or two `syncDir` calls per flush /
compaction / ingest. These operations are already heavy (they fsync SSTables and
WAL records), so the marginal cost is small and the correctness gain is decisive.
If profiling later shows this hurts bulk-ingest throughput, manifest fsyncs can
be batched per write-burst — out of scope here.

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Where does the manifest `syncFile` live?** Recommended: inside
  `ManifestWriter.append` (it owns the file), so every edit is durable by
  construction and no call site can forget. Update the misleading doc comment at
  [manifest_writer.dart:60-65](../packages/kmdb/lib/src/engine/manifest/manifest_writer.dart#L60)
  that currently says no fsync is issued.
- [ ] **D2 — `syncDir` granularity.** Recommended: add explicit `syncDir` calls
  at the structural points listed in the table (engine-owned), rather than hiding
  them in the adapter. Keeps the durability ordering visible in `lsm_engine` and
  testable. The adapter's `syncDir` stays a primitive.
- [ ] **D3 — Scope of M3 / H1.** Recommended: **include both** in this plan, as
  fsyncing the manifest without syncing the directory is still non-durable on
  Linux — they cannot be meaningfully separated. (They were listed as distinct
  findings in the review but share one root cause and one fix.)
- [ ] **D4 — DEVICE_ID / README.txt durability.** These are written without
  fsync but are regenerable (`ensureDeviceId` falls back to `$meta`). Recommended:
  **out of scope** (note only); optionally fsync DEVICE_ID since identity churn
  triggers SSTable re-upload.

## Implementation plan

### Step 0 — Build the fault-injection adapter
- [ ] Implement `FaultyStorageAdapter` in `test/support/` per the design above
      (content + directory durability, `crash()`).
- [ ] Unit-test the adapter itself: un-synced writes vanish on `crash()`; synced
      writes survive; un-synced creates/renames/deletes revert.

### Step 1 — Manifest fsync (C2 core)
- [ ] `ManifestWriter.append`: `await adapter.syncFile(path)` after `appendFile`;
      rewrite the doc comment.
- [ ] Where a *new* manifest file is first created (fresh-DB create in
      `crash_recovery.dart`, and `_doManifestRotation`), add `syncDir(dbDir)` so
      the new file's directory entry is durable.

### Step 2 — `syncDir` after new SSTables (H1)
- [ ] `LsmEngine.flush`: `await _adapter.syncDir(_sstDir)` after
      `syncFile(sstPath)` ([lsm_engine.dart:526](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L526)),
      before the manifest append / WAL delete.
- [ ] `CompactionJob.run`: `await adapter.syncDir(sstDir)` after
      `syncFile(outputPath)` ([compaction_job.dart:160](../packages/kmdb/lib/src/engine/compaction/compaction_job.dart#L160)),
      before `manifestWriter.append`.
- [ ] `KvStoreImpl.ingestSstable` / `LsmEngine.ingestAt0`: `syncDir(sstDir)` after
      the ingested file is written
      ([kv_store_impl.dart:196](../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L196)),
      before the manifest append.

### Step 3 — Durable `CURRENT` swap (M3)
- [ ] `CurrentFile.write`: `syncFile(tmpPath)` before `renameFile`, then
      `syncDir(dbDir)` after the rename.
- [ ] `_doManifestRotation`: reorder/strengthen so the sequence is — write new
      manifest (append now fsyncs) → `syncDir(dbDir)` → durable `CURRENT` swap
      (reuse `CurrentFile.write`) → **then** `deleteFile(old manifest)`. Currently
      it writes `CURRENT` inline ([lsm_engine.dart:783-785](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L783));
      refactor to call `CurrentFile.write` so the fsync logic lives in one place.

### Step 4 — Confirm delete-after-durable ordering
- [ ] Verify flush deletes WAL only after Steps 1–2 (it already appends before
      deleting; just ensure the new fsyncs sit between).
- [ ] Verify compaction deletes inputs only after `run()` (which now fsyncs the
      output's dir + the manifest) returns.
- [ ] (Optional, nice-to-have) `syncDir` after deletions so freed space is
      durable; not required for correctness (a resurrected obsolete file is
      safely re-deleted by recovery).

### Step 5 — Tests (using `FaultyStorageAdapter`)
Each: perform the operation, `crash()` at the vulnerable point, reopen, assert
data present. Confirm each test **fails before the fix** and **passes after**.
- [ ] **flush: crash after WAL delete, manifest append not synced** — buggy code
      loses the flushed batch; fixed code recovers it (manifest durable before WAL
      deleted, or WAL still present).
- [ ] **compaction: crash after inputs deleted, manifest append not synced** —
      buggy code loses all data folded into the compaction; fixed code recovers.
- [ ] **new SSTable not in a synced dir vanishes** — model a crash where the
      SSTable content was fsynced but the dir entry was not; assert the fix's
      `syncDir(sstDir)` keeps it (Linux-semantics test).
- [ ] **manifest rotation: crash after CURRENT rename, new manifest not durable**
      — buggy code loses the level map; fixed code keeps the old manifest valid
      (CURRENT swapped only after new manifest durable).
- [ ] **ingest: crash after file write** — ingested SSTable durable and
      referenced after reopen.
- [ ] **fresh DB create: crash immediately after open** — CURRENT + initial
      manifest durable; reopen succeeds.

### Step 6 — Documentation
- [ ] `docs/spec/09_integrity.md` and `docs/spec/10_manifest.md`: state the
      fsync/`syncDir` ordering invariant as a hard requirement.
- [ ] Register **RC-4 (Linux directory-fsync durability)** in the release
      checklist `docs/spec/28_release_checklist.md` — the fault adapter covers the
      logic deterministically, but `syncDir` no-ops off Linux, so real-Linux
      power-loss verification stays out-of-band.
- [ ] `docs/spec/17_crash_recovery.md`: finish correcting the failure table left
      from the C1 plan — the "after SSTable fsync, before VersionEdit" and
      compaction rows are now genuinely "None" *because* of this fix; reference
      this plan.
- [ ] Update doc comments on `ManifestWriter.append`, `CurrentFile.write`, and
      the relevant `LsmEngine` methods to describe the ordering they uphold.

### Step 7 — Verify
- [ ] `dart test packages/kmdb` — all pass, including the new fault tests.
- [ ] `cd packages/kmdb_cli && dart test` — all pass.
- [ ] `make analyze` — clean.
- [ ] Manual/CI check on Linux that `syncDir` is exercised (the native path is
      Linux-only; macOS dev machines no-op it).

## Summary

{To be completed during implementation.}
