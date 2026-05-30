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

/// KMDB performance benchmark suite.
///
/// Runs all §18 P99 benchmarks and prints a formatted report. Exits with
/// code 1 if any benchmark exceeds its target; exits with code 0 on success.
///
/// Run from the workspace root:
/// ```
/// dart run packages/kmdb/benchmark/main.dart
/// ```
library;

import 'dart:io';

import 'benchmark_runner.dart';
import 'benchmarks/database_open_bench.dart';
import 'benchmarks/get_absent_key_bench.dart';
import 'benchmarks/get_cached_reader_bench.dart';
import 'benchmarks/get_memtable_bench.dart';
import 'benchmarks/get_multi_level_bench.dart';
import 'benchmarks/get_single_file_bench.dart';
import 'benchmarks/index_build_bench.dart';
import 'benchmarks/put_flush_compact_bench.dart';
import 'benchmarks/put_no_flush_bench.dart';
import 'benchmarks/scan_100_results_bench.dart';

Future<void> main() async {
  final results = [
    await putNoFlushBenchmark(),
    await putFlushCompactBenchmark(),
    await getMemtableBenchmark(),
    await getSingleFileBenchmark(),
    await getMultiLevelBenchmark(),
    await getCachedReaderBenchmark(),
    await getAbsentKeyBenchmark(),
    await scan100ResultsBenchmark(),
    await databaseOpenBenchmark(),
    await indexBuildBenchmark(),
  ];

  final failures = printReport(results);
  exit(failures > 0 ? 1 : 0);
}
