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

/// KMDB test harness CLI entry point.
///
/// Runs the multi-device sync protocol harness and emits a JSON report.
///
/// ## Usage
///
/// ```
/// dart run kmdb_harness [options]
///
/// Options:
///   --preset <1-5>       Velocity preset (default: 1)
///   --devices <n>        Device count (default: 3)
///   --duration <s>       Run duration in seconds (default: 30)
///   --seed <n>           Fixed PRNG seed; omit for fuzz mode
///   --output <file>      Write JSON report to file (default: stdout)
///   --compare <file>     Diff the run against a saved report
///   --runs <n>           Repeat the run N times (flakiness check; default: 1)
/// ```
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'preset',
      abbr: 'p',
      help: 'Velocity preset (1–5)',
      defaultsTo: '1',
      allowed: ['1', '2', '3', '4', '5'],
    )
    ..addOption(
      'devices',
      abbr: 'd',
      help: 'Number of simulated devices',
      defaultsTo: '3',
    )
    ..addOption(
      'duration',
      help: 'Run duration in seconds',
      defaultsTo: '30',
    )
    ..addOption(
      'seed',
      abbr: 's',
      help: 'Fixed PRNG seed (omit for fuzz mode)',
    )
    ..addOption('output', abbr: 'o', help: 'Write JSON report to file')
    ..addOption(
      'compare',
      abbr: 'c',
      help: 'Diff this run against a saved report file',
    )
    ..addOption(
      'runs',
      abbr: 'r',
      help: 'Repeat the run N times for flakiness detection',
      defaultsTo: '1',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (parsed['help'] as bool) {
    stdout.writeln('KMDB test harness — multi-device sync validator\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final presetIndex = int.parse(parsed['preset'] as String);
  final deviceCount = int.parse(parsed['devices'] as String);
  final durationSeconds = int.parse(parsed['duration'] as String);
  final seedStr = parsed['seed'] as String?;
  final seed = seedStr != null ? int.parse(seedStr) : null;
  final outputPath = parsed['output'] as String?;
  final comparePath = parsed['compare'] as String?;
  final runs = int.parse(parsed['runs'] as String);

  final preset = _presetFromIndex(presetIndex);

  final config = HarnessConfig(
    syncAdapter: MemorySyncAdapter(),
    deviceCount: deviceCount,
    velocityPreset: preset,
    duration: Duration(seconds: durationSeconds),
    prngseed: seed,
  );

  HarnessReport? lastReport;

  for (var run = 1; run <= runs; run++) {
    if (runs > 1) stdout.writeln('Run $run/$runs …');

    final manager = TestManager(config: config, seed: seed);
    HarnessReport report;
    try {
      report = await manager.run();
    } on HarnessConfigException catch (e) {
      stderr.writeln('Configuration rejected: $e');
      exit(2);
    }

    lastReport = report;

    // Print summary.
    stdout.writeln(
      '  ${report.passed ? 'PASS' : 'FAIL'} | '
      'actions=${report.totalActions} | '
      'forks=${report.forkRecords.length} | '
      'seed=${report.prngseed} | '
      '${report.durationMs}ms',
    );

    if (!report.passed) {
      for (final v in report.deviceVerdicts.where((v) => !v.passed)) {
        stdout.writeln('  Device ${v.deviceId} FAIL:');
        for (final m in v.failureDetails) {
          stdout.writeln('    key=${m.compoundKey}');
        }
      }
    }
  }

  // Write report.
  final report = lastReport!;
  final jsonStr = report.toJsonString();

  if (outputPath != null) {
    File(outputPath).writeAsStringSync(jsonStr);
    stdout.writeln('Report written to $outputPath');
  }

  // Compare against a saved report.
  if (comparePath != null) {
    final savedJson = File(comparePath).readAsStringSync();
    final savedReport = HarnessReport.fromJsonString(savedJson);
    final diffs = diffReports(savedReport, report);

    if (diffs.isEmpty) {
      stdout.writeln('Comparison: no divergences found.');
    } else {
      stdout.writeln('Comparison: ${diffs.length} divergence(s) found:');
      for (final d in diffs) {
        stdout.writeln('  - $d');
      }
      exit(3);
    }
  }

  exit(report.passed ? 0 : 1);
}

VelocityPreset _presetFromIndex(int index) => switch (index) {
  1 => VelocityPreset.one,
  2 => VelocityPreset.two,
  3 => VelocityPreset.three,
  4 => VelocityPreset.four,
  5 => VelocityPreset.five,
  _ => VelocityPreset.one,
};
