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

/// Get (in memtable) — P99 < 1 ms.
///
/// Inserts one document into an oversized-memtable database so the key sits in
/// the in-memory skip list. The timed loop reads it repeatedly — no disk I/O.
Future<BenchmarkResult> getMemtableBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  late String key;

  return runBenchmark(
    name: 'Get (in memtable)',
    target: const Duration(milliseconds: 1),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_get_mem_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: const KvStoreConfig(
          memtableSizeBytes: 100 * 1024 * 1024,
          fsyncOnWrite: false,
        ),
      );
      col = db.rawCollection('bench');
      final doc = await col.insert(benchPayload(0));
      key = doc['_id'] as String;
    },
    run: () async {
      await col.get(key);
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
