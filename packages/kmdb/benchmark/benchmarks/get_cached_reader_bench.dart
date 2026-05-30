// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Benchmark: Get (multi-file, warm table cache) — P99 < 5 ms.
///
/// Exercises the [TableCache] introduced in M1. The database has enough data
/// to span multiple SSTables (several L0/L1/L2 files). After an initial
/// warm-up the table cache is populated; subsequent reads must NOT re-hash the
/// SSTable files. This benchmark confirms that per-read cost is now O(block)
/// rather than O(database-size).
///
/// ## Why this exposes the M1 regression
///
/// Before the fix, every `get()` call on a multi-file database would call
/// `SstableReader.open()` for each file — hashing the whole file from 0 to
/// fileSize-8 — giving O(database size) per read. With the [TableCache] the
/// hash is paid once per file per process; subsequent reads for the same file
/// reuse the cached reader without any I/O on the header/index/filter sections.
///
/// The dataset (~4 MB spread across multiple SSTables) is large enough that
/// without the cache a single read would clearly exceed the 5 ms target; with
/// the cache the target should be met comfortably.
library;

import 'dart:io';

import 'package:kmdb/kmdb.dart';

import '../benchmark_runner.dart';
import 'shared.dart';

/// Get (warm table cache, multi-file) — P99 < 5 ms.
Future<BenchmarkResult> getCachedReaderBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  late String targetKey;

  // Configuration: small memtable forces many flushes producing multiple
  // SSTables. Total data (~4 MB) exceeds the single-file threshold so we get
  // a true multi-file layout with L0, L1, and L2 files present.
  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    l1MaxBytes: 512 * 1024,
    l2MaxBytes: 4 * 1024 * 1024,
    singleFileThresholdBytes: 512 * 1024,
    fsyncOnWrite: false,
    // Use the default cache size (256) — representative of production config.
    tableCacheSize: 256,
  );

  return runBenchmark(
    name: 'Get (warm cache, multi-file)',
    target: const Duration(milliseconds: 5),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_cached_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');

      // Write the target key first so it ends up deep in the oldest SSTable.
      final first = await col.insert(benchPayload(0));
      targetKey = first['_id'] as String;

      // Write ~2,000 more docs (~200 bytes each = ~400 KB) to populate many
      // SSTables and exercise the multi-level layout. The small memtable
      // (4 KB threshold) flushes every ~20 writes.
      for (var i = 1; i <= 2000; i++) {
        await col.insert(benchPayload(i));
      }

      // Reopen cold so the memtable is empty; all reads must go to SSTables.
      // The table cache starts empty on open — the first read is a cache miss
      // (the whole-file hash is paid once per file). Subsequent benchmark
      // iterations are warm-cache reads.
      await db.close();
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      // Point lookup of the deepest key — will scan Bloom filters of all
      // SSTables newer than the target (all misses) before finding it.
      // With the cache this is O(block-read); without it is O(database-size).
      await col.get(targetKey);
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
