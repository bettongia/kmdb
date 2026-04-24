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

/// Get (single-file mode) — P99 < 2 ms.
///
/// Inserts enough documents to trigger compaction to a single L2 SSTable
/// (total data ≤ 512 KB triggers the single-file shortcut). After flushing,
/// the database is closed and reopened so the memtable is empty — all reads
/// must go to the SSTable. The timed loop reads a known key from that file.
Future<BenchmarkResult> getSingleFileBenchmark() async {
  late Directory tempDir;
  late KmdbDatabase db;
  late KmdbCollection<Map<String, dynamic>> col;
  late String targetKey;

  // Use a small memtable so docs flush quickly, but keep total data well under
  // the 512 KB single-file threshold so compaction produces one L2 file.
  const config = KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    fsyncOnWrite: false,
  );

  return runBenchmark(
    name: 'Get (single-file mode)',
    target: const Duration(milliseconds: 2),
    setup: () async {
      tempDir = Directory.systemTemp.createTempSync('kmdb_bench_get_sf_');
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');

      // Insert ~50 docs (~200 bytes each = ~10 KB total), well under 512 KB,
      // so compaction collapses everything to a single L2 SSTable.
      final first = await col.insert(benchPayload(0));
      targetKey = first['_id'] as String;
      for (var i = 1; i < 50; i++) {
        await col.insert(benchPayload(i));
      }

      // Reopen so the memtable is cold and all reads hit the SSTable.
      await db.close();
      db = await KmdbDatabase.open(
        path: tempDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      col = db.rawCollection('bench');
    },
    run: () async {
      await col.get(targetKey);
    },
    teardown: () async {
      await db.close();
      tempDir.deleteSync(recursive: true);
    },
  );
}
