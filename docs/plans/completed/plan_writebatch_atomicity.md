# Fix H2: WriteBatch is not crash-atomic (document/index consistency guarantee is unmet)

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/23

**Implementation model:** Sonnet, with careful review of the all-or-nothing
recovery decode and the meta-write fold (cache-generation visibility).

**Sequencing**: Implement **after `plan_crash_recovery_wal_replay.md` (C1)** —
C1 rewrites WAL replay, and this plan changes the on-WAL representation that
replay must decode, so they must be coherent. It **complements
`plan_manifest_fsync_ordering.md` (C2)**: the atomic-batch frame collapses N
per-entry fsyncs into one, which fits C2's fsync discipline and is a throughput
win. It can reuse C2's `FaultyStorageAdapter` for fsync-timing tests, but its
core all-or-nothing behaviour is testable with the in-memory adapter alone.

## Problem statement

A `WriteBatch` is documented and relied upon as atomic — `CLAUDE.md` and spec
§16 state "All index writes are in the same `WriteBatch` as the document write —
always consistent," and `KvStoreImpl.writeBatchInternal`
([kv_store_impl.dart:347](../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L347))
claims the batch "cannot be observed in a partial state." Neither holds:

- **Across a crash:** `LsmEngine.writeBatch`
  ([lsm_engine.dart:209](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L209))
  writes each entry as a separate, separately-fsynced WAL record with no group
  boundary. A crash mid-loop leaves a *prefix* of the batch durable — e.g. a
  document without its `$index:` entry (or vice versa), corrupting query results
  until a full reindex.
- **In-process, without any crash:** the loop `await`s on each record's WAL
  write between memtable mutations, so a concurrently-scheduled `get()` running
  during one of those awaits can observe a half-applied batch.

For a database whose secondary indexes are kept correct *by* batch atomicity,
this is a real correctness hole. The fix makes a batch a single all-or-nothing
unit at both the WAL and memtable levels.

## Investigation

### Current behaviour

`LsmEngine.writeBatch` loops `batch.entries`; for each it calls
`_walWriter.writePut`/`writeDelete` → `WalWriter.append`
([wal_writer.dart:69](../packages/kmdb/lib/src/engine/wal/wal_writer.dart#L69)) =
`appendFile` + `fsync` **per record**, then `_active.put(...)`, then emits write
events at the end. So an N-entry batch is N independent records, N fsyncs, N
interleaved memtable mutations, and no atomic boundary.

The WAL record is self-delimiting and self-checksummed:
`[checksum 8B][type 1B][seq 8B][nsLen 1B][ns][keyLen 2B][key][valLen 4B][val]`
([wal_record.dart:66](../packages/kmdb/lib/src/engine/wal/wal_record.dart#L66)).
Recovery decodes records one at a time via `WalRecord.tryDecode` and applies each
to the restored memtable ([crash_recovery.dart:184](../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L184)).
There is nothing that groups records, so recovery cannot know a set of records
was meant to be atomic.

### The surrounding meta-writes are also separate

A single user write is actually several independent engine operations.
`KvStoreImpl.writeBatchInternal`
([kv_store_impl.dart:358](../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L358))
calls `_meta.incrementGenerationCounter` (a `get` + `_engine.put`,
[meta_store.dart:72](../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L72))
and `_meta.registerNamespace` (`get` + conditional `_engine.put`,
[meta_store.dart:154](../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L154))
**outside** the engine batch, plus `setDirty` on first write. So even after the
document+index batch is made atomic, the generation counter and namespace
registry land as distinct WAL records. For full document/index/metadata
consistency these should be folded into the same atomic unit (see D2).

### Why single `put`/`delete` are already fine

A single `put`/`delete` is one checksummed record with one fsync and one
synchronous memtable mutation after a single await — already atomic across crash
and in-process. **Only the multi-entry batch path needs framing.**

### Design options

**Option A — single batch frame (recommended).** Define one WAL frame that
carries all entries under **one checksum**, written with **one append + one
fsync**:

```
[checksum 8B][type=batch 1B][count 4B][entry][entry]…[entry]
entry := [recType 1B][seq 8B][nsLen 1B][ns][keyLen 2B][key][valLen 4B][val]
```

On decode, a checksum failure (truncation/corruption anywhere in the frame)
discards the **whole** frame → all-or-nothing by construction. Bonus: N fsyncs
become 1 — a meaningful write-throughput improvement.

**Option B — begin/commit markers.** Write a `batchBegin`, the N existing
records (no fsync), then `batchCommit`, fsync once. Recovery buffers records
after `batchBegin` and applies them only on seeing `batchCommit`; a truncation
before commit discards the buffer. Smaller format delta but more record types and
more bookkeeping in recovery.

Option A is simpler to reason about and is the gold standard; recommended.

### In-process atomicity

After the single append+fsync completes, apply **all** entries to the memtable in
one synchronous block (no `await` between mutations), then emit events. Because
nothing yields the event loop between the memtable mutations, no concurrent
`get()` can observe a partial batch.

### Back-compatibility

Existing on-disk WALs contain individual `put`/`delete` records (an old batch was
just N of them). The new `batch` frame is a new `type` byte, so recovery
dispatches on type and reads **both** formats: old individual records apply as
today; new frames apply atomically. A database written by an older build replays
correctly; new writes use frames. No migration step is required.

### Interactions

- **C1** owns the recovery replay loop; this plan adds frame decoding/application
  to it — do it on top of C1.
- **C2** fsync ordering is unaffected in shape; the single-fsync-per-batch simply
  reduces the number of fsyncs. The `FaultyStorageAdapter` from C2 is useful here
  but not required (truncating a frame in the memory adapter already exercises
  all-or-nothing recovery, à la the C1 probe).

### Files to change

| File | Change |
|------|--------|
| `lib/src/engine/wal/wal_record.dart` (or new `wal_batch.dart`) | Add the batch-frame encode/decode (Option A) with a single checksum |
| `lib/src/engine/wal/wal_writer.dart` | `appendBatch(records)` → one frame, one append, one fsync |
| `lib/src/engine/kvstore/lsm_engine.dart` | `writeBatch`: build frame, single append+fsync, **synchronous** memtable application of all entries, then emit events |
| `lib/src/engine/kvstore/crash_recovery.dart` | Decode batch frames; apply all-or-nothing; drop a truncated trailing frame |
| `lib/src/engine/kvstore/kv_store_impl.dart` | (D2) fold gen-counter + namespace-registry mutations into the same batch |
| `lib/src/engine/kvstore/meta_store.dart` | (D2) add batch-aware mutation helpers that append to a `WriteBatch` instead of issuing their own `put` |
| `docs/spec/07_wal.md`, `16_secondary_indexes.md`, `18_concurrency.md` | Document the frame format and the now-true atomicity guarantee |

## Decisions (confirmed 2026-05-26)

- [x] **D1 — Frame vs markers.** **Option A** (single frame, single checksum,
  single fsync) — simplest atomicity and a throughput win.
- [x] **D2 — Fold meta-writes into the batch.** **Yes** — add the
  generation-counter bump and namespace registration into the *same* engine
  batch as the document+index entries, so a single user write is one atomic unit.
  Preserve the existing invariant that subscribers see the bumped generation when
  the write event fires (events are emitted after the batch is applied to the
  memtable, so a folded gen counter is already visible). This is the part needing
  the most test care.
- [x] **D3 — Keep single `put`/`delete` unframed.** **Yes** — they are already
  atomic; routing them through a 1-entry frame is optional and only for code
  uniformity.
- [x] **D4 — Migration.** Decode both old individual records and new frames; no
  on-disk migration. Accepted that batches written by a pre-fix build (already
  non-atomic) cannot be retroactively made atomic.

## Implementation plan

### Step 1 — Batch frame format
- [x] Implement Option A encode/decode with one checksum over the whole frame;
      a checksum failure yields `null` (drop the frame) exactly like
      `WalRecord.tryDecode`.
- [x] Unit-test the codec: round-trip N entries; truncation at every boundary
      yields `null` (no partial decode).

### Step 2 — Writer
- [x] `WalWriter.appendBatch(List<WalRecord> records)` → encode one frame,
      `appendFile` once, fsync once (respecting `fsyncOnWrite`).

### Step 3 — Engine writeBatch
- [x] Build the frame from all entries; `await` the single append+fsync; then
      apply **all** entries to the memtable synchronously; then emit write events.
- [x] Confirm no `await` separates the memtable mutations (in-process atomicity).

### Step 4 — Recovery
- [x] Extend the replay loop (on top of C1) to decode batch frames and apply all
      entries atomically; a truncated trailing frame is dropped whole and flagged
      via `hadInterruptedWrites`.

### Step 5 — Fold meta-writes (D2)
- [x] Add `MetaStore` helpers that append gen-counter/namespace-registry
      mutations to a `WriteBatch`.
- [x] Update `KvStoreImpl.put`/`delete`/`writeBatch`/`writeBatchInternal` to
      include those mutations in the single engine batch; keep `setDirty`
      semantics (first-write) intact.
- [x] Verify cache subscribers still observe the new generation on the write
      event.

### Step 6 — Tests
- [x] **Crash all-or-nothing:** write a multi-entry batch, truncate the WAL frame
      bytes (memory adapter), reopen → assert **none** of the batch is present
      and `hadInterruptedWrites` is true; with an intact frame → assert **all**
      present. Confirm fails before the fix (prefix survives) / passes after.
- [x] **Document+index consistency:** a doc + its `$index:` entries either all
      survive a crash or none do (never a doc without its index entry).
- [x] **In-process atomicity:** assert that `writeEvents` only fires after every
      memtable mutation is visible, so a subscriber that re-reads observes the
      full batch (the original "racy concurrent get" framing reliably tested
      only microtask scheduling, not the post-fix invariant — switched to the
      event-visibility contract instead).
- [x] **Meta folded (D2):** generation counter and namespace registry advance
      atomically with the document; a crash never leaves the doc without its gen
      bump.
- [x] **Back-compat:** a WAL containing legacy individual records still replays,
      and a WAL containing a mix of batch frames and legacy records replays
      both correctly.
- [x] **Wire-format sanity:** confirm an N-entry batch lands as a single frame
      (one batch record on disk) rather than N individual records — the
      structural prerequisite for one fsync per batch.

### Step 7 — Documentation
- [x] `docs/spec/07_wal.md`: documents the batch frame format and that a batch
      is the atomic WAL unit; back-compat with legacy records is noted.
- [x] `docs/spec/16_secondary_indexes.md`: the "always consistent" guarantee
      now states crash-atomicity comes from the batch frame.
- [x] `docs/spec/18_concurrency.md`: notes the in-process atomicity
      (synchronous memtable application after the single fsync).
- [x] Update `writeBatchInternal` and `writeBatch` doc comments to match reality.

### Step 8 — Verify
- [x] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [x] `make analyze` clean.

> No release-checklist (§28) entry is required: both the crash all-or-nothing and
> in-process atomicity behaviours are fully testable in CI with the in-memory
> adapter.

## Summary

Implemented all four confirmed decisions (D1–D4) on top of C1 and C2.

**Wire format.** Added a new WAL frame type `0x04` (`WalBatchFrame`) carrying N
entries under one XXH64 checksum, encoded with one `appendFile` call and one
`fsync`. The legacy individual-record format (types `0x01` Put / `0x02` Delete
/ `0x03` Flush marker) is still decoded for back-compat — recovery dispatches
on the type byte. `WalReader` transparently flattens frames into the same
`WalRecord` stream so CLI tooling (`util wal`) and other consumers needed no
changes.

**Engine.** `LsmEngine.writeBatch` builds the frame in one phase, performs the
single append+fsync await, then applies every entry to the memtable
synchronously (no `await` between mutations) before emitting write events.
This makes the batch atomic at both the WAL and memtable levels: a crash can
only leave the entire frame durable or absent, and a concurrent reader can
only observe pre-batch or post-batch state.

**Meta fold (D2).** Added `MetaStore.appendDirtyFlag`,
`appendGenerationCounterBump`, and `appendNamespaceRegistration` helpers that
attach the per-write metadata to the caller's `WriteBatch` rather than
issuing separate `_engine.put` calls. `KvStoreImpl.put`/`delete`/`writeBatch`/
`writeBatchInternal` now copy the user batch, append the meta mutations, and
commit the whole thing as one atomic frame. `createNamespace` was refactored
to use the same pattern (without a gen-counter bump, since it doesn't write a
document).

**Recovery.** `CrashRecovery` now peeks at the type byte for each record and
dispatches to either `WalBatchFrame.tryDecode` (applies all entries
atomically) or `WalRecord.tryDecode` (legacy path). A truncated trailing
frame is dropped whole and sets `hadInterruptedWrites` to true.

**Tests.** 21 new tests:
- 7 in `wal_test.dart` covering `WalBatchFrame` encode/decode, truncation at
  every byte boundary, payload bit-flips, wrong-type rejection, and the
  single-frame wire shape.
- 14 in `writebatch_atomicity_test.dart` covering the all-or-nothing crash
  guarantee, doc+index co-survival, meta-fold visibility, dirty-flag fold,
  back-compat with legacy records, mixed legacy + frame WALs, and the event
  visibility contract that implements in-process atomicity.

All 1385 kmdb tests and 839 kmdb_cli tests pass; `make pre_commit` (format,
analyze, license check, scoped tests) is green.
