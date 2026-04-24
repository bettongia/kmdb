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

/// Scan (namespace, 100 results) — P99 < 10 ms.
///
/// Inserts 500 documents and runs a full-namespace scan with a limit of 100.
/// The database is reopened cold so reads go to SSTables, exercising sequential
/// block reads across one or more files.
Future<BenchmarkResult> scan100ResultsBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;

  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    fsyncOnWrite: false,
  );

  return runBenchmark(
    name: 'Scan (namespace, 100 results)',
    target: const Duration(milliseconds: 10),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_scan_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');

      for (var i = 0; i < 500; i++) {
        await col.insert(benchPayload(i));
      }

      // Reopen cold so all reads go to SSTables.
      await db.close();
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      await col.all().limit(100).get();
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
