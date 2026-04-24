// Copyright 2026 The KMDB Authors
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

import 'dart:io';

import 'package:kmdb/kmdb.dart';

import '../benchmark_runner.dart';
import 'shared.dart';

/// Get (multi-level, present) — P99 < 5 ms.
///
/// Seeds the database with enough data to push documents across L0, L1, and L2
/// by exceeding the single-file threshold (512 KB), producing a multi-level LSM
/// tree. The target key was written early and compacted to L2; later flushes
/// create L0/L1 files with newer keys. A get for the L2 key must check L0 and
/// L1 (Bloom misses) before finding it in L2.
Future<BenchmarkResult> getMultiLevelBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  late String deepKey;

  // Small memtable to trigger frequent flushes; total data will exceed
  // singleFileThresholdBytes so the engine cannot collapse to one file.
  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    singleFileThresholdBytes: 512 * 1024,
    fsyncOnWrite: false,
  );

  return runBenchmark(
    name: 'Get (multi-level, present)',
    target: const Duration(milliseconds: 5),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_get_ml_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');

      // Write the target key first so it ends up in the oldest SSTable.
      final first = await col.insert(benchPayload(0));
      deepKey = first['_id'] as String;

      // Write ~600 more docs (~200 bytes each = ~120 KB) to exceed the
      // singleFileThreshold and produce a multi-level layout. The small
      // memtable will flush repeatedly, driving L0→L1→L2 compaction.
      for (var i = 1; i <= 600; i++) {
        await col.insert(benchPayload(i));
      }

      // Reopen cold so the memtable is empty and all reads go to SSTables.
      await db.close();
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      await col.get(deepKey);
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
