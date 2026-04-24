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

/// P99 benchmark harness for KMDB performance targets.
///
/// Each benchmark collects raw [Stopwatch] durations, sorts them, and reports
/// P50 / P90 / P99 / Max against the §18 target. No external dependencies.
library;

import 'dart:io';

// ── Result ────────────────────────────────────────────────────────────────────

/// The outcome of a single benchmark run.
final class BenchmarkResult {
  const BenchmarkResult({
    required this.name,
    required this.target,
    required this.p50,
    required this.p90,
    required this.p99,
    required this.max,
  });

  final String name;
  final Duration target;
  final Duration p50;
  final Duration p90;
  final Duration p99;
  final Duration max;

  /// True when [p99] is within the [target] budget.
  bool get passed => p99 <= target;
}

// ── Runner ────────────────────────────────────────────────────────────────────

/// Runs [run] [iterations] times, discards [warmupIterations] before timing,
/// and returns a [BenchmarkResult] with P50 / P90 / P99 / Max latencies.
///
/// [setup] is called once before any iteration (including warmup).
/// [teardown] is called once after all iterations.
/// [resetPerIteration] is called between each iteration, outside the timed
/// section, to restore state without inflating the measurement.
Future<BenchmarkResult> runBenchmark({
  required String name,
  required Duration target,
  required Future<void> Function() run,
  Future<void> Function()? setup,
  Future<void> Function()? teardown,
  Future<void> Function()? resetPerIteration,
  int warmupIterations = 50,
  int iterations = 1000,
}) async {
  await setup?.call();

  // Warmup — results discarded.
  for (var i = 0; i < warmupIterations; i++) {
    await run();
    await resetPerIteration?.call();
  }

  final durations = <Duration>[];
  final sw = Stopwatch();

  for (var i = 0; i < iterations; i++) {
    sw.reset();
    sw.start();
    await run();
    sw.stop();
    durations.add(sw.elapsed);
    await resetPerIteration?.call();
  }

  await teardown?.call();

  durations.sort();
  final p50 = _percentile(durations, 50);
  final p90 = _percentile(durations, 90);
  final p99 = _percentile(durations, 99);
  final max = durations.last;

  return BenchmarkResult(
    name: name,
    target: target,
    p50: p50,
    p90: p90,
    p99: p99,
    max: max,
  );
}

Duration _percentile(List<Duration> sorted, int pct) {
  final idx = ((pct / 100) * sorted.length).ceil() - 1;
  return sorted[idx.clamp(0, sorted.length - 1)];
}

// ── Report ────────────────────────────────────────────────────────────────────

/// Prints a formatted table of [results] and returns the number of failures.
int printReport(List<BenchmarkResult> results) {
  const nameW = 35;
  const colW = 9;

  final sep = '-' * (nameW + colW * 5 + 2);

  stdout.writeln('\nKMDB Performance Benchmarks');
  stdout.writeln('=' * (nameW + colW * 5 + 2));
  stdout.writeln(
    '${'Operation'.padRight(nameW)}'
    '${'P50'.padLeft(colW)}'
    '${'P90'.padLeft(colW)}'
    '${'P99'.padLeft(colW)}'
    '${'Max'.padLeft(colW)}'
    '${'Target'.padLeft(colW)}'
    '  Status',
  );
  stdout.writeln(sep);

  var failures = 0;
  for (final r in results) {
    if (!r.passed) failures++;
    final status = r.passed ? 'PASS' : 'FAIL ←';
    stdout.writeln(
      '${r.name.padRight(nameW)}'
      '${_fmtMs(r.p50).padLeft(colW)}'
      '${_fmtMs(r.p90).padLeft(colW)}'
      '${_fmtMs(r.p99).padLeft(colW)}'
      '${_fmtMs(r.max).padLeft(colW)}'
      '${_fmtMs(r.target).padLeft(colW)}'
      '  $status',
    );
  }

  stdout.writeln(sep);
  final passed = results.length - failures;
  stdout.writeln('\nResult: $passed/${results.length} benchmarks passed.\n');

  return failures;
}

String _fmtMs(Duration d) {
  final ms = d.inMicroseconds / 1000;
  return '${ms.toStringAsFixed(ms < 10 ? 2 : 1)}ms';
}
