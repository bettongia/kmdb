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

/// Database open — P99 < 100 ms.
///
/// Creates a pre-populated database in [setup], then each timed iteration
/// calls [KmdbDatabase.open] and immediately closes it outside the timing
/// window. This measures Manifest replay + WAL replay on a realistic database.
Future<BenchmarkResult> databaseOpenBenchmark() async {
  late Directory tempDir;
  KmdbDatabase? db;

  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    fsyncOnWrite: true,
  );

  return runBenchmark(
    name: 'Database open',
    target: const Duration(milliseconds: 100),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_open_');

      // Populate a realistic database with ~100 documents then close it.
      final seedDb = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      final col = seedDb.rawCollection('bench');
      for (var i = 0; i < 100; i++) {
        await col.insert(benchPayload(i));
      }
      await seedDb.close();
    },
    run: () async {
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
    },
    resetPerIteration: () async {
      // Close happens outside the timed section.
      await db?.close();
      db = null;
    },
    teardown: () async {
      await db?.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
