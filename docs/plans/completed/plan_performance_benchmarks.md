# Performance Benchmarks

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

**Roadmap link**:
[0.01 Performance Benchmarks (High priority)](../docs/roadmap/0_01.md)

## Problem statement

KMDB's architecture documentation (§18 Concurrency) defines P99 latency targets
for every major operation — puts, gets, scans, compaction, database open, and
index build. There is currently no benchmark suite to verify these targets are
met, detect regressions, or give contributors a reproducible way to measure
performance. The roadmap flags this as high priority.

## Open questions

- [x] **Location**: `packages/kmdb/benchmark/` — conventional Dart placement
      alongside `lib/` and `test/`. No separate package needed.
- [x] **Framework**: `benchmark_harness` (pub.dev) measures
      score/iteration-rate, not raw latency. We need raw `Stopwatch` timings so
      we can compute P99. A thin custom harness collects N durations, sorts
      them, and reports the 99th-percentile. `benchmark_harness` will not be
      used.
- [x] **Pass/fail vs report**: Report-only. A structured table is printed to
      stdout with actual P99 vs target; a non-zero exit code is emitted if any
      target is exceeded. This lets CI capture failures without needing a
      separate assertion library, while keeping the output human-readable.
- [x] **Coverage**: All 8 operations from §18 (superset of the 6 in the
      roadmap). The two extras — Get (multi-level, present) and Get (absent key)
      — are trivially addable and complete the picture.
- [x] **Multi-device**: The roadmap mentions "single- and multi-device" but §18
      has no P99 target for multi-device operations (sync push is listed as "<
      2s typical, dominated by network"). Multi-device benchmarks are
      **deferred** — network latency makes them non-reproducible in a local
      benchmark suite.
- [x] **Iteration count**: 1,000 iterations per operation. Enough to produce a
      stable P99 without making the suite take more than a minute to run. Each
      benchmark resets the database between iterations only where necessary
      (e.g., flush/compact benchmarks need a fresh memtable state).
- [x] **Warm-up**: 50 iterations discarded before timing starts, to let the OS
      page cache and JIT settle.

## Investigation

### §18 targets

| Operation                      | P99 target |
| :----------------------------- | :--------- |
| Put / Delete (no flush)        | < 5 ms     |
| Put (triggers flush + compact) | < 200 ms   |
| Get (in memtable)              | < 1 ms     |
| Get (single-file mode)         | < 2 ms     |
| Get (multi-level, present)     | < 5 ms     |
| Get (absent key)               | < 3 ms     |
| Scan (namespace, 100 results)  | < 10 ms    |
| Database open                  | < 100 ms   |
| Index build (2,000 docs)       | < 500 ms   |

Sync push is excluded — it is dominated by network and not a local benchmark
target.

### Benchmark structure

Each benchmark is a standalone async function in its own file under
`packages/kmdb/benchmark/`. A shared `benchmark_runner.dart` provides:

```dart
Future<BenchmarkResult> runBenchmark({
  required String name,
  required Duration target,
  required Future<void> Function() setup,    // run once before all iterations
  required Future<void> Function() run,      // timed body
  Future<void> Function()? teardown,         // run once after all iterations
  Future<void> Function()? resetPerIteration, // called between iterations
  int warmupIterations = 50,
  int iterations = 1000,
});
```

`setup` / `teardown` are outside the timing loop. `resetPerIteration` (if
provided) is also outside the timing loop — it resets state between measured
runs without inflating the measurement.

`BenchmarkResult` carries: `name`, `target`, `p50`, `p90`, `p99`, `max`,
`passed` (p99 ≤ target).

A `main.dart` entry point runs all benchmarks in sequence and prints a formatted
table, then exits with code 1 if any benchmark failed.

### Benchmark scenarios

#### 1. Put / Delete (no flush) — P99 < 5 ms

Setup: open database, pre-insert enough docs to be past the flush threshold so
no flush fires during measurement.

Run: `collection.put(doc)` where the memtable has room (i.e., stays under 64
KB). Alternate with delete to keep size stable.

Reset per iteration: none needed — successive small puts stay below the flush
threshold.

#### 2. Put (triggers flush + compact) — P99 < 200 ms

This requires every measured iteration to trigger a flush and compaction, not
just occasional ones. Strategy: each iteration writes enough documents to push
the memtable past 64 KB, measures the final put that triggers the flush, then
resets by deleting the inserted documents (outside the timing loop) so the next
iteration starts from a fresh memtable.

Reset per iteration: delete the batch of docs written during setup so the
memtable is empty again for the next iteration.

#### 3. Get (in memtable) — P99 < 1 ms

Setup: insert a known document into a fresh database (so it sits in the memtable
only). Run: `collection.get(id)`. No reset needed.

#### 4. Get (single-file mode) — P99 < 2 ms

Setup: insert enough docs to force a single L2 SSTable (total data ≤ 512 KB
triggers the single-file compaction shortcut per the architecture docs). Verify
the LSM is in single-file mode. Run: `collection.get(id)` for a key known to be
in that file.

#### 5. Get (multi-level, present) — P99 < 5 ms

Setup: write enough data to produce L0, L1, and L2 levels with overlapping key
ranges, so the get must check multiple levels. Run: `collection.get(id)` for a
key present in the upper levels (not L2), forcing level traversal.

#### 6. Get (absent key) — P99 < 3 ms

Setup: same as single-file mode (Bloom filters are most effective in single-file
mode). Run: `collection.get(nonExistentId)`. The Bloom filter should eliminate
disk reads for the absent key.

#### 7. Scan (namespace, 100 results) — P99 < 10 ms

Setup: insert 500 documents. Run: `collection.query().limit(100).get()` — a full
scan returning 100 results.

#### 8. Database open — P99 < 100 ms

This benchmark cannot reuse a single database across iterations — each iteration
must close and reopen the database. Strategy: a single fully-populated database
directory is created in `setup`, then each iteration calls `KmdbDatabase.open()`
and immediately closes it. The close is outside the timed section.

Reset per iteration: close the database (outside timing); reopen it in the timed
run.

#### 9. Index build (2,000 docs) — P99 < 500 ms

Setup: create a database with 2,000 pre-inserted documents but no index.

Run: call `KmdbDatabase.open()` with an index definition on a field present in
all 2,000 docs — the lazy first-query index build fires immediately.
Alternatively trigger index build via
`collection.query().orderBy('field').get()` on a fresh `open()` with the index
defined. Reset: drop and recreate the database from the pre-populated snapshot.

Given the reset complexity, this benchmark uses a fixed 100 iterations with 10
warmup (index build is slower; 100 × 500 ms = 50 s ceiling is acceptable).

### File layout

```
packages/kmdb/
  benchmark/
    benchmark_runner.dart     — P99 harness, BenchmarkResult, report table
    main.dart                 — runs all benchmarks, prints table, exits 0/1
    benchmarks/
      put_no_flush_bench.dart
      put_flush_compact_bench.dart
      get_memtable_bench.dart
      get_single_file_bench.dart
      get_multi_level_bench.dart
      get_absent_key_bench.dart
      scan_100_results_bench.dart
      database_open_bench.dart
      index_build_bench.dart
```

### Running the suite

```bash
dart run packages/kmdb/benchmark/main.dart
```

Output:

```
KMDB Performance Benchmarks
============================
Operation                        P50      P90      P99      Max      Target  Status
Put / Delete (no flush)          1.2ms    1.8ms    2.9ms    4.1ms    5ms     PASS
Put (flush + compact)            42ms     78ms     110ms    180ms    200ms   PASS
Get (in memtable)                0.08ms   0.12ms   0.18ms   0.4ms    1ms     PASS
...

Result: 9/9 benchmarks passed.
```

### pubspec change

Add `benchmark_harness` is not needed. The only change to
`packages/kmdb/pubspec.yaml` is adding the `benchmark/` directory (no new
dependencies required — all benchmarks use only `kmdb` itself and `dart:io`).

### Considerations and edge cases

- **Fsync variability**: WAL appends are fsynced. On macOS with APFS, fsync
  latency can spike unpredictably. P99 is the right metric here — single-outlier
  spikes don't fail the benchmark. If the suite runs in a CI environment with
  noticeably slower I/O, targets may need a machine-class qualifier (a note in
  the output, not a code change).
- **JIT warmup**: Dart's JIT compiles hot paths after several thousand
  invocations. 50 warmup iterations may not be sufficient to reach peak JIT
  performance for very fast operations (< 1 ms). If P99 is tight, increase
  warmup to 200 for sub-millisecond benchmarks.
- **Temp directories**: Each benchmark creates its database in a fresh
  `Directory.systemTemp` subdirectory and cleans it up in `teardown`. No shared
  state between benchmarks.
- **Reproducibility**: Benchmarks are deterministic in document content (fixed
  seed / fixed keys). Document size is fixed at ~200 bytes JSON to match typical
  usage.

## Implementation plan

### Phase 1 — Harness

- [x] Create `packages/kmdb/benchmark/benchmark_runner.dart`:
  - `BenchmarkResult` value type (`name`, `target`, `p50`, `p90`, `p99`, `max`,
    `passed`)
  - `runBenchmark(...)` async function — warmup loop, timed loop, percentile
    calculation, returns `BenchmarkResult`
  - `printReport(List<BenchmarkResult>)` — formatted table, summary line

### Phase 2 — Individual benchmarks

- [x] `put_no_flush_bench.dart` — Put / Delete (no flush)
- [x] `put_flush_compact_bench.dart` — Put (triggers flush + compact)
- [x] `get_memtable_bench.dart` — Get (in memtable)
- [x] `get_single_file_bench.dart` — Get (single-file mode)
- [x] `get_multi_level_bench.dart` — Get (multi-level, present)
- [x] `get_absent_key_bench.dart` — Get (absent key)
- [x] `scan_100_results_bench.dart` — Scan (namespace, 100 results)
- [x] `database_open_bench.dart` — Database open
- [x] `index_build_bench.dart` — Index build (2,000 docs)

### Phase 3 — Entry point and docs

- [x] `main.dart` — imports all benchmarks, runs sequentially, calls
      `printReport`, exits with code 1 if any `result.passed == false`
- [x] Update `CLAUDE.md` Commands section with the `dart run` invocation
- [x] Update roadmap to mark Performance Benchmarks complete

## Summary

- Added `packages/kmdb/benchmark/benchmark_runner.dart` — a lightweight custom
  P99 harness using raw `Stopwatch` timings. Collects N durations, sorts, and
  reports P50 / P90 / P99 / Max against the §18 target. No external
  dependencies. `printReport` produces a formatted table and returns the failure
  count; `main.dart` exits with code 1 if any benchmark fails.

- Added 9 benchmark files under `packages/kmdb/benchmark/benchmarks/`, one per
  §18 operation: Put/Delete (no flush), Put (flush+compact), Get (memtable), Get
  (single-file), Get (multi-level), Get (absent key), Scan (100 results),
  Database open, and Index build (2,000 docs). Each uses `StorageAdapterNative`
  with real disk I/O and `Directory.systemTemp` for isolation.

- Key design choices: oversized memtable (100 MB) for no-flush path; tiny
  memtable (128 B) + `l0CompactionTrigger=1` for flush+compact path; directory
  snapshot copy for index-build reset between iterations (avoids touching
  internal APIs); all benchmarks reopen the database cold where SSTable reads
  are required.

- All 9 benchmarks pass their §18 P99 targets on the development machine.
  Verified output:

  ```
  Put / Delete (no flush)    P99 0.71ms   target 5ms    PASS
  Put (flush + compact)      P99 4.57ms   target 200ms  PASS
  Get (in memtable)          P99 0.07ms   target 1ms    PASS
  Get (single-file mode)     P99 0.40ms   target 2ms    PASS
  Get (multi-level, present) P99 0.90ms   target 5ms    PASS
  Get (absent key)           P99 0.64ms   target 3ms    PASS
  Scan (namespace, 100)      P99 8.90ms   target 10ms   PASS
  Database open              P99 1.17ms   target 100ms  PASS
  Index build (2,000 docs)   P99 34.3ms   target 500ms  PASS
  ```

- Updated `CLAUDE.md` with `dart run packages/kmdb/benchmark/main.dart`
  invocation, and marked the roadmap item complete.
