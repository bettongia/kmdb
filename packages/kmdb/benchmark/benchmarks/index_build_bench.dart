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

/// Index build (2,000 docs) — P99 < 500 ms.
///
/// Seeds a database with 2,000 documents (no index), snapshots the directory,
/// then each timed iteration opens a fresh copy of the snapshot with an index
/// definition and triggers the lazy build via a query. The snapshot is
/// restored between iterations so the build always starts from scratch.
///
/// Uses 100 iterations / 10 warmup because each iteration can take up to
/// 500 ms (100 × 500 ms = 50 s ceiling, which is acceptable).
Future<BenchmarkResult> indexBuildBenchmark() async {
  late Directory snapshotDir;
  late Directory iterDir;

  const config = KvStoreConfig(
    memtableSizeBytes: 65536,
    l0CompactionTrigger: 2,
    fsyncOnWrite: false,
  );

  final indexDef = IndexDefinition('bench', 'category');

  return runBenchmark(
    name: 'Index build (2,000 docs)',
    target: const Duration(milliseconds: 500),
    iterations: 100,
    warmupIterations: 10,
    setup: () async {
      snapshotDir = Directory.systemTemp.createTempSync('kmdb_bench_idx_snap_');

      // Seed 2,000 documents without an index definition.
      final seedDb = await KmdbDatabase.open(
        path: snapshotDir.path,
        adapter: StorageAdapterNative(),
        config: config,
      );
      final col = seedDb.rawCollection('bench');
      for (var i = 0; i < 2000; i++) {
        await col.insert(benchPayload(i));
      }
      await seedDb.close();

      // Create the first iteration directory from the snapshot.
      iterDir = Directory.systemTemp.createTempSync('kmdb_bench_idx_iter_');
      await _copyDir(snapshotDir, iterDir);
    },
    run: () async {
      // Open the snapshot copy with the index definition; the lazy build fires
      // on the first query.
      final db = await KmdbDatabase.open(
        path: iterDir.path,
        adapter: StorageAdapterNative(),
        config: config,
        indexes: [indexDef],
      );
      final col = db.rawCollection('bench');
      await col.all().get();
      await db.close();
    },
    resetPerIteration: () async {
      // Restore the snapshot so the next iteration rebuilds from scratch.
      iterDir.deleteSync(recursive: true);
      iterDir = Directory.systemTemp.createTempSync('kmdb_bench_idx_iter_');
      await _copyDir(snapshotDir, iterDir);
    },
    teardown: () async {
      iterDir.deleteSync(recursive: true);
      snapshotDir.deleteSync(recursive: true);
    },
  );
}

/// Recursively copies the contents of [src] into [dst].
Future<void> _copyDir(Directory src, Directory dst) async {
  await for (final entity in src.list(recursive: false)) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (entity is File) {
      await entity.copy('${dst.path}/$name');
    } else if (entity is Directory) {
      final subDst = Directory('${dst.path}/$name');
      await subDst.create();
      await _copyDir(entity, subDst);
    }
  }
}
