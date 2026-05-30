# Fix M1: SSTable reads are O(database size) — add a reader cache (and cheap open)

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/28

**Implementation model:** Sonnet — mechanical; Phase 1 (reader cache) needs no
format change. Light review.

**Sequencing**: Independent of the durability/sync fixes. Touches only the
storage read path. Worth doing before any performance/scale milestone, as it
directly governs whether the §18 P99 targets hold beyond toy databases.

## Problem statement

Every read can re-hash entire SSTable files, and a fresh reader is opened per
file on every `get`/`scan`. `SstableReader.open()` validates integrity by reading
**the whole file** and hashing bytes `0..fileSize-8`
([sstable_reader.dart:144](../packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L144)),
and `LsmEngine.get()`/`scan()` call `_openReader` — a fresh `SstableReader.open`
— for **each file on every call**
([lsm_engine.dart:986](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L986),
used by `get` [L283](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L283),
`scan` [L337](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L337), and
`allStoredNamespaces` [L415](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L415)).

So a single point lookup that falls through to an L2 file reads that whole file
(up to ~20 MB) into memory and XXH64s it — and a lookup touching several files
does so for each. This is O(database size) per read and contradicts the 4 KiB
block + Bloom-filter random-access design; the §18 P99 targets will not hold once
data exceeds a few hundred KB. The benchmark
([benchmark/main.dart](../packages/kmdb/benchmark/main.dart)) likely only exercises
small datasets, hiding this.

## Investigation

### Why open is expensive

The footer carries offsets/sizes plus a single `checksum` field that is the hash
of the **entire file** (`_parseFooter` [sstable_reader.dart:253](../packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L253)),
so validating it means re-reading and hashing the whole file on every open.
There is no separate, cheap footer-only checksum.

### Two independent problems

1. **No reader cache.** Even setting aside the whole-file hash, re-reading the
   footer/index/filter for every file on every read is wasteful. A cache of open
   readers makes the whole-file validation a **one-time** cost per file rather
   than per-read — and amortises the index/filter parsing.
2. **Expensive cold open.** The whole-file hash is paid the first time each file
   is opened. For a 20 MB L2 file that is a one-off 20 MB hash. Acceptable as a
   one-time integrity check; only a problem for startup-latency-sensitive cases.

Reader caching (1) is the high-value, low-risk fix and needs **no format change**.
Cheap open (2) is a secondary optimisation that does need a format change (see
below).

### What caching does and doesn't hold

The native `readFileRange` opens and closes the file per call
([storage_adapter_native.dart:47](../packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L47)),
so a cached `SstableReader` holds the parsed **footer + index + Bloom filter** in
memory, **not** a file descriptor or the whole file. Data-block reads still hit
disk per access (each block validates its own trailing checksum,
[sstable_reader.dart:301](../packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L301)).
A hot data-block cache is a possible further step but is out of scope here.

### Integrity must be preserved

Data blocks are individually checksummed, so read-time block integrity is intact
regardless of caching. The **footer, index, and filter blocks** are currently
covered *only* by the whole-file hash — confirm whether they carry their own
checksums (the reader does not appear to validate any). If they do not, then
"footer-only validation" (skipping the whole-file hash on open) would leave those
sections unvalidated, so it requires **adding per-section checksums** — a
format change. Caching keeps the whole-file validation (once per file), so it does
not weaken integrity.

### Invalidation

Cached readers must be evicted when their file is removed or replaced — i.e. on
flush (new L0 file), every compaction path (`_compactL0ToL1`/`_compactL1ToL2`/
`_compactAll`), `ingestAt0`, manifest rotation, and `reassignDeviceId` (renames).
Single isolate, so no locking is needed; just evict on level-map mutation.

### Distinct from the §15 Cache Layer

This is a **storage-layer table cache** (open readers / index / filter), not the
§15 query-layer object/materialised-view cache. They are complementary and live at
different layers; name accordingly (e.g. `TableCache`) to avoid confusion.

### Files to change

| File | Change |
|------|--------|
| `lib/src/engine/sstable/` (new `table_cache.dart`) | LRU cache of open `SstableReader`s keyed by path, bounded by count |
| `lib/src/engine/kvstore/lsm_engine.dart` | Route `_openReader` through the cache; evict on every level-map mutation (flush/compaction/ingest/rotation/rename) |
| `lib/src/engine/kvstore/kv_store.dart` (config) | Add a cache-size knob (desktop vs mobile defaults, mirroring §15 tiering) |
| `benchmark/main.dart` | Add a large-dataset read benchmark that would expose the regression |
| *(optional phase)* `sstable_writer.dart` / `sstable_reader.dart` | Per-section checksums for footer/index/filter to enable cheap (footer-only) open |
| `docs/spec/08_sstable.md`, `18_concurrency.md` | Document the table cache and (if added) per-section checksums |

## Decisions (recommended answers — confirm before implementation)

- [x] **D1 — Cache scope.** Recommended: cache **open readers** (footer + index +
  filter) only; defer a hot data-block cache. Biggest win, smallest surface.
- [x] **D2 — Eviction + bound.** Recommended: LRU by path, bounded by a config
  count (e.g. desktop 256 readers, mobile/web 64); evict explicitly on level-map
  mutation so a deleted/compacted file is never served stale.
- [x] **D3 — Footer-only (cheap) open.** Recommended: **defer to a second phase**
  — it needs per-section checksums (format change). Ship caching first; it already
  reduces whole-file hashing to once per file per process.
- [x] **D4 — Keep whole-file validation.** Recommended: retain the whole-file hash
  on first open (good integrity), and optionally expose an explicit `verify()` for
  diagnostics; do not silently drop it.

## Implementation plan

### Step 1 — Table cache
- [x] Implement `TableCache` (LRU of `SstableReader` by path, bounded by count).
- [x] Route `LsmEngine._openReader` through it; first access opens+validates+caches,
      subsequent accesses reuse.

### Step 2 — Invalidation
- [x] Evict entries for removed/renamed files in `flush`, `_compactL0ToL1`,
      `_compactL1ToL2`, `_compactAll`, `ingestAt0`, `_doManifestRotation`, and
      `reassignDeviceId`.
- [x] On `close`, drop the cache.

**Key implementation note:** eviction must happen for **all** removed files, even
when the compaction output reuses the same filename (in-place overwrite). The
`if (outputNames.contains(ref.filename)) continue` guard skips only the
`deleteFile` call, not the eviction — failing to evict in this case caused a
`CorruptedSstableException: Data block checksum mismatch` because the stale
reader's index pointed to blocks from the old file while the file content had
changed to the compaction output.

### Step 3 — Config
- [x] Add a cache-size knob to `KvStoreConfig` with tiered defaults; document it.

### Step 4 — Tests
- [x] **Reader reuse:** instrument open count; N reads of the same file open it
      once (after the first).
- [x] **Invalidation:** after a compaction removes a file, the cache no longer
      holds/serves it; reads of the replacement open the new file.
- [x] **Correctness unchanged:** existing read/scan tests pass with caching on.
- [x] **Bound respected:** with more files than the cache size, LRU evicts and
      reads remain correct.
- [x] **Benchmark:** a large-DB read benchmark shows per-read cost no longer
      scales with total data (was O(db size), now ~O(block)).

### Step 5 — (Optional phase) cheap open
- [ ] Confirm whether index/filter blocks carry checksums; if not, add per-section
      checksums.
- [ ] Add a cheap footer-only validation path; keep whole-file `verify()` for
      diagnostics. (Format change — gate behind a version bump.)

### Step 6 — Documentation
- [x] `docs/spec/08_sstable.md`: document the table cache and integrity model;
      `18_concurrency.md`: note read cost is now bounded.

### Step 7 — Verify
- [x] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [x] `make analyze` clean; benchmark confirms the improvement.

> No release-checklist (§28) entry needed: the win is measured by the in-repo
> benchmark and verified by unit tests — no real hardware/service required.

## Summary

- Added `TableCache` (`lib/src/engine/sstable/table_cache.dart`) — a bounded LRU cache of open `SstableReader` objects, keyed by absolute file path. Eliminates the per-read O(file-size) whole-file XXH64 checksum cost; the hash is now paid once per file per process, after which subsequent reads reuse the cached reader (footer + index + Bloom filter held in memory).

- Routed `LsmEngine._openReader` and `ingestAt0` through `_tableCache.open()`. Added explicit cache eviction at every level-map mutation point: `_compactL0ToL1`, `_compactL1ToL2`, `_compactAll` (evict all removed files), `dropAllSstables` (clear), `reassignDeviceId` (evict old path before rename), `close` (clear).

- Added `KvStoreConfig.tableCacheSize` (default 256 desktop, 64 mobile/web, 16 in `forTesting()`). Documented in `docs/spec/08_sstable.md`, `18_concurrency.md`, and `11_kv_store.md`.

- Added `benchmark/benchmarks/get_cached_reader_bench.dart` — a `Get (warm cache, multi-file)` P99 < 5 ms benchmark confirming per-read cost is O(block) with the cache warm.

- **Critical invariant discovered:** when a compaction output reuses the same filename as an input (in-place overwrite — happens when the HLC range is unchanged), the stale cached reader must still be evicted before the compaction output is served. Failing to do so caused `CorruptedSstableException: Data block checksum mismatch` because the old reader's index block pointed to block offsets from the old file layout while the on-disk content had been overwritten. Fixed by separating the eviction step from the `deleteFile` step in all three compaction methods; the `if (outputNames.contains(ref.filename)) continue` guard now only skips `deleteFile`, not eviction.

- Added 14 unit tests (`test/engine/table_cache_test.dart`) covering reader reuse, invalidation, LRU promotion, prefix eviction, error propagation, and capacity. Added 9 integration tests (`test/engine/table_cache_integration_test.dart`) including a regression test for the same-filename-reuse eviction invariant. All 1486 tests pass.

- Branch: `20260530_plan_sstable_reader_cache` | Worktree: `.worktrees/20260530_plan_sstable_reader_cache`
