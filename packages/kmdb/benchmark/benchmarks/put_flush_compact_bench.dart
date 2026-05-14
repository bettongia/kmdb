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

import 'dart:io';

import 'package:kmdb/kmdb.dart';

import '../benchmark_runner.dart';
import 'shared.dart';

/// Put (triggers flush + compact) — P99 < 200 ms.
///
/// Uses a tiny memtable (128 bytes) with l0CompactionTrigger=1 so that every
/// put flushes the memtable to L0 and immediately triggers a compaction. This
/// ensures every timed iteration exercises the full flush + compact path.
Future<BenchmarkResult> putFlushCompactBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  var counter = 0;

  return runBenchmark(
    name: 'Put (flush + compact)',
    target: const Duration(milliseconds: 200),
    // Fewer iterations: each takes up to 200 ms, so 100 × 200 ms = 20 s ceiling.
    iterations: 100,
    warmupIterations: 10,
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_flush_');
      // 128-byte memtable: every ~1 put flushes. l0CompactionTrigger=1: every
      // flush triggers compaction. Together, each put causes flush + compact.
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: const KvStoreConfig(
          memtableSizeBytes: 128,
          l0CompactionTrigger: 1,
          fsyncOnWrite: true,
        ),
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      await col.insert(benchPayload(counter++));
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
