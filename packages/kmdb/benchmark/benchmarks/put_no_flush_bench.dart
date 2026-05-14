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

/// Put / Delete (no flush) — P99 < 5 ms.
///
/// Uses an oversized memtable (100 MB) so no flush fires during measurement.
/// Each timed iteration inserts a new document. With ~300 bytes per doc and
/// 1,050 iterations (50 warmup + 1,000 timed) the memtable stays well under
/// 100 MB, so the flush path is never exercised.
Future<BenchmarkResult> putNoFlushBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  var counter = 0;

  return runBenchmark(
    name: 'Put / Delete (no flush)',
    target: const Duration(milliseconds: 5),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_put_');
      // Oversized memtable ensures no flush fires during the timed loop.
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: const KvStoreConfig(
          memtableSizeBytes: 100 * 1024 * 1024,
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
