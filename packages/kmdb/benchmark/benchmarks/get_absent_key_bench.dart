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

/// Get (absent key) — P99 < 3 ms.
///
/// Inserts documents into a single-file database (total data < 512 KB) and
/// reads a key that was never written. The Bloom filter (~0.8% FPR) eliminates
/// SSTable reads for the absent key on the vast majority of iterations,
/// exercising the fast negative-lookup path.
Future<BenchmarkResult> getAbsentKeyBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  // Generate the absent key before any inserts so it definitely doesn't exist.
  final absentKey = generateKey();

  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    fsyncOnWrite: false,
  );

  return runBenchmark(
    name: 'Get (absent key)',
    target: const Duration(milliseconds: 3),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_get_abs_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');

      // ~50 docs (~10 KB total) → single L2 SSTable with one Bloom filter.
      for (var i = 0; i < 50; i++) {
        await col.insert(benchPayload(i));
      }

      // Reopen cold.
      await db.close();
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      await col.get(absentKey);
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
