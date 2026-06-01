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

import 'dart:convert';

import 'reconciliation_agent.dart';

// ── Per-device verdict ────────────────────────────────────────────────────────

/// The pass/fail verdict for a single device after a harness run.
///
/// A device passes when its actual post-run document state matches the
/// expected state computed by the [ReconciliationAgent]. A failure lists every
/// key where the actual value diverged from the expected value.
final class DeviceVerdict {
  /// Creates a [DeviceVerdict].
  const DeviceVerdict({
    required this.deviceId,
    required this.passed,
    this.failureDetails = const [],
  });

  /// The 0-based index of the device in the harness.
  final int deviceId;

  /// `true` if the device's actual state matched the expected state.
  final bool passed;

  /// Per-key failure details. Empty when [passed] is `true`.
  final List<KeyMismatch> failureDetails;

  /// Converts this verdict to a JSON-serialisable map.
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'passed': passed,
    'failureDetails': failureDetails.map((f) => f.toJson()).toList(),
  };

  /// Restores a [DeviceVerdict] from [json].
  factory DeviceVerdict.fromJson(Map<String, dynamic> json) => DeviceVerdict(
    deviceId: json['deviceId'] as int,
    passed: json['passed'] as bool,
    failureDetails: (json['failureDetails'] as List<dynamic>? ?? [])
        .map((e) => KeyMismatch.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// A single key where actual and expected state diverged.
final class KeyMismatch {
  /// Creates a [KeyMismatch].
  const KeyMismatch({
    required this.compoundKey,
    required this.expected,
    required this.actual,
  });

  /// The compound key in `'collectionName\x00key'` format.
  final String compoundKey;

  /// The document the [ReconciliationAgent] expected (or `null` for deleted).
  final Map<String, dynamic>? expected;

  /// The document actually found in the device store (or `null` if missing).
  final Map<String, dynamic>? actual;

  /// Converts this mismatch to a JSON-serialisable map.
  Map<String, dynamic> toJson() => {
    'compoundKey': compoundKey,
    'expected': expected,
    'actual': actual,
  };

  /// Restores a [KeyMismatch] from [json].
  factory KeyMismatch.fromJson(Map<String, dynamic> json) => KeyMismatch(
    compoundKey: json['compoundKey'] as String,
    expected: json['expected'] as Map<String, dynamic>?,
    actual: json['actual'] as Map<String, dynamic>?,
  );
}

// ── Serialisable fork event ───────────────────────────────────────────────────

/// A serialisable snapshot of a [ForkEvent].
///
/// [ForkEvent] references [WriteLogEntry] objects that are not independently
/// serialisable (they may share references with the write log). [ForkRecord]
/// captures a self-contained snapshot suitable for the [HarnessReport].
final class ForkRecord {
  /// Creates a [ForkRecord].
  const ForkRecord({
    required this.collectionName,
    required this.key,
    required this.deviceA,
    required this.deviceB,
    required this.lwwWinnerDeviceId,
    required this.lwwWinnerActionId,
  });

  /// The collection that contains the forked key.
  final String collectionName;

  /// The document key that was written by both devices.
  final String key;

  /// Device index of the first write.
  final int deviceA;

  /// Device index of the second write.
  final int deviceB;

  /// Device index of the LWW winner.
  final int lwwWinnerDeviceId;

  /// Action ID of the LWW winning write.
  final int lwwWinnerActionId;

  /// Converts this record to a JSON-serialisable map.
  Map<String, dynamic> toJson() => {
    'collectionName': collectionName,
    'key': key,
    'deviceA': deviceA,
    'deviceB': deviceB,
    'lwwWinnerDeviceId': lwwWinnerDeviceId,
    'lwwWinnerActionId': lwwWinnerActionId,
  };

  /// Restores a [ForkRecord] from [json].
  factory ForkRecord.fromJson(Map<String, dynamic> json) => ForkRecord(
    collectionName: json['collectionName'] as String,
    key: json['key'] as String,
    deviceA: json['deviceA'] as int,
    deviceB: json['deviceB'] as int,
    lwwWinnerDeviceId: json['lwwWinnerDeviceId'] as int,
    lwwWinnerActionId: json['lwwWinnerActionId'] as int,
  );

  /// Creates a [ForkRecord] from a [ForkEvent].
  factory ForkRecord.fromForkEvent(ForkEvent event) => ForkRecord(
    collectionName: event.collectionName,
    key: event.key,
    deviceA: event.writeA.deviceId,
    deviceB: event.writeB.deviceId,
    lwwWinnerDeviceId: event.lwwWinner.deviceId,
    lwwWinnerActionId: event.lwwWinner.actionId,
  );
}

// ── No-op count entry ─────────────────────────────────────────────────────────

/// The total number of no-op actions recorded for a single device.
///
/// No-ops are actions that were inapplicable in the device's current FSM state
/// and were silently skipped by the expected-state model. A high no-op count
/// may indicate the action sequence is suboptimal.
final class NoOpCount {
  /// Creates a [NoOpCount].
  const NoOpCount({required this.deviceId, required this.count});

  /// The device index.
  final int deviceId;

  /// The total number of no-op actions recorded for this device.
  final int count;

  /// Converts this entry to a JSON-serialisable map.
  Map<String, dynamic> toJson() => {'deviceId': deviceId, 'count': count};

  /// Restores a [NoOpCount] from [json].
  factory NoOpCount.fromJson(Map<String, dynamic> json) =>
      NoOpCount(deviceId: json['deviceId'] as int, count: json['count'] as int);
}

// ── HarnessReport ─────────────────────────────────────────────────────────────

/// The output of a completed harness run.
///
/// [HarnessReport] captures the overall pass/fail verdict, the fork event log,
/// the no-op log, the PRNG seed used for the run, and versioning fork
/// verification results. It is JSON-serialisable so that runs can be saved and
/// compared for regression and flakiness detection.
///
/// ## Example — serialise a report
///
/// ```dart
/// final json = report.toJson();
/// final jsonString = jsonEncode(json);
/// ```
///
/// ## Example — restore from JSON
///
/// ```dart
/// final report = HarnessReport.fromJson(jsonDecode(jsonString));
/// ```
final class HarnessReport {
  /// Creates a [HarnessReport].
  const HarnessReport({
    required this.prngseed,
    required this.deviceVerdicts,
    required this.forkRecords,
    required this.noOpCounts,
    required this.totalActions,
    required this.durationMs,
    this.versionForksPassed = 0,
    this.versionForksChecked = 0,
  });

  /// The PRNG seed used for this run. Enables exact replay in seeded mode.
  final int prngseed;

  /// Per-device pass/fail verdicts.
  final List<DeviceVerdict> deviceVerdicts;

  /// All fork events detected during the run.
  final List<ForkRecord> forkRecords;

  /// Per-device no-op counts.
  final List<NoOpCount> noOpCounts;

  /// Total actions executed across all devices.
  final int totalActions;

  /// Elapsed time in milliseconds for the run.
  final int durationMs;

  /// Number of fork losers whose document value was found in the `$ver:`
  /// history on both participating devices after the final sync.
  ///
  /// A fork check passes when both the winner and loser device can call
  /// `getVersions(docKey)` and find the loser write's value in the result.
  /// This validates that `$ver:` entries propagate through sync correctly.
  final int versionForksPassed;

  /// Total number of fork losers that were checked for version history.
  ///
  /// Equal to the number of [forkRecords]. A value less than
  /// [versionForksPassed] indicates one or more version history mismatches —
  /// use this to detect versioning regressions across runs.
  final int versionForksChecked;

  /// Whether every device passed.
  bool get passed => deviceVerdicts.every((v) => v.passed);

  /// Converts this report to a JSON-serialisable map.
  Map<String, dynamic> toJson() => {
    'prngseed': prngseed,
    'deviceVerdicts': deviceVerdicts.map((v) => v.toJson()).toList(),
    'forkRecords': forkRecords.map((f) => f.toJson()).toList(),
    'noOpCounts': noOpCounts.map((n) => n.toJson()).toList(),
    'totalActions': totalActions,
    'durationMs': durationMs,
    'versionForksPassed': versionForksPassed,
    'versionForksChecked': versionForksChecked,
  };

  /// Restores a [HarnessReport] from [json].
  factory HarnessReport.fromJson(Map<String, dynamic> json) => HarnessReport(
    prngseed: json['prngseed'] as int,
    deviceVerdicts: (json['deviceVerdicts'] as List<dynamic>)
        .map((e) => DeviceVerdict.fromJson(e as Map<String, dynamic>))
        .toList(),
    forkRecords: (json['forkRecords'] as List<dynamic>)
        .map((e) => ForkRecord.fromJson(e as Map<String, dynamic>))
        .toList(),
    noOpCounts: (json['noOpCounts'] as List<dynamic>)
        .map((e) => NoOpCount.fromJson(e as Map<String, dynamic>))
        .toList(),
    totalActions: json['totalActions'] as int,
    durationMs: json['durationMs'] as int,
    // Default to 0 for reports produced before versioning was added.
    versionForksPassed: (json['versionForksPassed'] as int?) ?? 0,
    versionForksChecked: (json['versionForksChecked'] as int?) ?? 0,
  );

  /// Serialises this report to a JSON string.
  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Restores a [HarnessReport] from a JSON string.
  factory HarnessReport.fromJsonString(String s) =>
      HarnessReport.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

// ── Diff / comparison ─────────────────────────────────────────────────────────

/// A single divergence between two [HarnessReport] runs.
final class ReportDiff {
  /// Creates a [ReportDiff].
  const ReportDiff({required this.description});

  /// A human-readable description of the divergence.
  final String description;

  @override
  String toString() => description;
}

/// Compares two [HarnessReport] instances and returns a list of divergences.
///
/// Returns an empty list when the reports are equivalent (same per-device
/// final state for every key, same fork outcomes, and same no-op counts).
///
/// A non-empty list indicates a regression (if the reports came from different
/// builds) or non-determinism (if they came from the same build and same seed).
List<ReportDiff> diffReports(HarnessReport a, HarnessReport b) {
  final diffs = <ReportDiff>[];

  // Device count mismatch.
  if (a.deviceVerdicts.length != b.deviceVerdicts.length) {
    diffs.add(
      ReportDiff(
        description:
            'Device count differs: ${a.deviceVerdicts.length} vs '
            '${b.deviceVerdicts.length}',
      ),
    );
    return diffs; // No point continuing if device counts differ.
  }

  // Per-device verdict comparison.
  for (var i = 0; i < a.deviceVerdicts.length; i++) {
    final av = a.deviceVerdicts[i];
    final bv = b.deviceVerdicts[i];
    if (av.passed != bv.passed) {
      diffs.add(
        ReportDiff(
          description:
              'Device ${av.deviceId}: passed=${av.passed} vs ${bv.passed}',
        ),
      );
    }
    // Per-key failure detail comparison.
    if (av.failureDetails.length != bv.failureDetails.length) {
      diffs.add(
        ReportDiff(
          description:
              'Device ${av.deviceId}: failure count differs '
              '(${av.failureDetails.length} vs ${bv.failureDetails.length})',
        ),
      );
    }
  }

  // Fork record count.
  if (a.forkRecords.length != b.forkRecords.length) {
    diffs.add(
      ReportDiff(
        description:
            'Fork event count differs: ${a.forkRecords.length} vs '
            '${b.forkRecords.length}',
      ),
    );
  } else {
    for (var i = 0; i < a.forkRecords.length; i++) {
      final af = a.forkRecords[i];
      final bf = b.forkRecords[i];
      if (af.lwwWinnerDeviceId != bf.lwwWinnerDeviceId ||
          af.collectionName != bf.collectionName ||
          af.key != bf.key) {
        diffs.add(
          ReportDiff(
            description:
                'Fork[$i] outcome differs: '
                '${af.collectionName}/${af.key} winner '
                'device${af.lwwWinnerDeviceId} vs device${bf.lwwWinnerDeviceId}',
          ),
        );
      }
    }
  }

  // No-op count comparison.
  if (a.noOpCounts.length == b.noOpCounts.length) {
    for (var i = 0; i < a.noOpCounts.length; i++) {
      final an = a.noOpCounts[i];
      final bn = b.noOpCounts[i];
      if (an.count != bn.count) {
        diffs.add(
          ReportDiff(
            description:
                'Device ${an.deviceId}: no-op count differs '
                '(${an.count} vs ${bn.count})',
          ),
        );
      }
    }
  }

  // Version fork pass count comparison.
  if (a.versionForksPassed != b.versionForksPassed) {
    diffs.add(
      ReportDiff(
        description:
            'versionForksPassed differs: '
            '${a.versionForksPassed} vs ${b.versionForksPassed}',
      ),
    );
  }
  if (a.versionForksChecked != b.versionForksChecked) {
    diffs.add(
      ReportDiff(
        description:
            'versionForksChecked differs: '
            '${a.versionForksChecked} vs ${b.versionForksChecked}',
      ),
    );
  }

  return diffs;
}
