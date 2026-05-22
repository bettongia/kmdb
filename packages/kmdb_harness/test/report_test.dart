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

import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

HarnessReport _sampleReport({
  int seed = 42,
  bool device0Pass = true,
  bool device1Pass = true,
  int forkCount = 0,
  int noOpCount = 0,
}) {
  final verdicts = [
    DeviceVerdict(deviceId: 0, passed: device0Pass),
    DeviceVerdict(deviceId: 1, passed: device1Pass),
  ];

  final forks = [
    for (var i = 0; i < forkCount; i++)
      ForkRecord(
        collectionName: 'col',
        key: 'key$i',
        deviceA: 0,
        deviceB: 1,
        lwwWinnerDeviceId: i % 2,
        lwwWinnerActionId: i + 1,
      ),
  ];

  final noOps = [
    NoOpCount(deviceId: 0, count: noOpCount),
    NoOpCount(deviceId: 1, count: 0),
  ];

  return HarnessReport(
    prngseed: seed,
    deviceVerdicts: verdicts,
    forkRecords: forks,
    noOpCounts: noOps,
    totalActions: 100,
    durationMs: 1234,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('HarnessReport — serialisation round-trip', () {
    test('toJson / fromJson preserves all fields', () {
      final original = _sampleReport(seed: 99, forkCount: 2, noOpCount: 3);
      final restored = HarnessReport.fromJson(original.toJson());

      expect(restored.prngseed, equals(original.prngseed));
      expect(restored.totalActions, equals(original.totalActions));
      expect(restored.durationMs, equals(original.durationMs));
      expect(restored.deviceVerdicts.length, equals(2));
      expect(restored.forkRecords.length, equals(2));
      expect(restored.noOpCounts.length, equals(2));
      expect(restored.noOpCounts.first.count, equals(3));
    });

    test('toJsonString / fromJsonString round-trip', () {
      final original = _sampleReport(seed: 77, forkCount: 1);
      final json = original.toJsonString();
      final restored = HarnessReport.fromJsonString(json);

      expect(restored.prngseed, equals(original.prngseed));
      expect(restored.forkRecords.first.key, equals('key0'));
    });

    test('passed is true when all devices pass', () {
      final report = _sampleReport(device0Pass: true, device1Pass: true);
      expect(report.passed, isTrue);
    });

    test('passed is false when any device fails', () {
      final report = _sampleReport(device0Pass: true, device1Pass: false);
      expect(report.passed, isFalse);
    });
  });

  group('DeviceVerdict serialisation', () {
    test('round-trips with failure details', () {
      final verdict = DeviceVerdict(
        deviceId: 2,
        passed: false,
        failureDetails: [
          const KeyMismatch(
            compoundKey: 'col\x00key1',
            expected: {'v': 1},
            actual: {'v': 2},
          ),
        ],
      );

      final restored = DeviceVerdict.fromJson(verdict.toJson());
      expect(restored.deviceId, equals(2));
      expect(restored.passed, isFalse);
      expect(restored.failureDetails, hasLength(1));
      expect(restored.failureDetails.first.compoundKey, equals('col\x00key1'));
    });

    test('round-trips with null expected / actual', () {
      const mismatch = KeyMismatch(
        compoundKey: 'col\x00k',
        expected: null,
        actual: null,
      );
      final restored = KeyMismatch.fromJson(mismatch.toJson());
      expect(restored.expected, isNull);
      expect(restored.actual, isNull);
    });
  });

  group('ForkRecord serialisation', () {
    test('round-trips all fields', () {
      const record = ForkRecord(
        collectionName: 'notes',
        key: 'abc123',
        deviceA: 0,
        deviceB: 2,
        lwwWinnerDeviceId: 2,
        lwwWinnerActionId: 7,
      );

      final restored = ForkRecord.fromJson(record.toJson());
      expect(restored.collectionName, equals('notes'));
      expect(restored.key, equals('abc123'));
      expect(restored.deviceA, equals(0));
      expect(restored.deviceB, equals(2));
      expect(restored.lwwWinnerDeviceId, equals(2));
      expect(restored.lwwWinnerActionId, equals(7));
    });
  });

  group('NoOpCount serialisation', () {
    test('round-trips', () {
      const entry = NoOpCount(deviceId: 1, count: 42);
      final restored = NoOpCount.fromJson(entry.toJson());
      expect(restored.deviceId, equals(1));
      expect(restored.count, equals(42));
    });
  });

  group('diffReports', () {
    test('identical reports produce no diffs', () {
      final a = _sampleReport(seed: 1, forkCount: 1, noOpCount: 2);
      final b = _sampleReport(seed: 1, forkCount: 1, noOpCount: 2);
      expect(diffReports(a, b), isEmpty);
    });

    test('different device counts produce a diff', () {
      final a = HarnessReport(
        prngseed: 1,
        deviceVerdicts: [DeviceVerdict(deviceId: 0, passed: true)],
        forkRecords: [],
        noOpCounts: [],
        totalActions: 10,
        durationMs: 100,
      );
      final b = _sampleReport(); // 2 devices
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
      expect(diffs.first.toString(), contains('Device count'));
    });

    test('differing pass/fail produces a diff', () {
      final a = _sampleReport(device0Pass: true);
      final b = _sampleReport(device0Pass: false);
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
      expect(diffs.first.toString(), contains('passed'));
    });

    test('differing fork outcomes produce a diff', () {
      final a = HarnessReport(
        prngseed: 1,
        deviceVerdicts: [DeviceVerdict(deviceId: 0, passed: true)],
        forkRecords: [
          const ForkRecord(
            collectionName: 'col',
            key: 'k',
            deviceA: 0,
            deviceB: 1,
            lwwWinnerDeviceId: 0,
            lwwWinnerActionId: 1,
          ),
        ],
        noOpCounts: [],
        totalActions: 10,
        durationMs: 100,
      );
      final b = HarnessReport(
        prngseed: 1,
        deviceVerdicts: [DeviceVerdict(deviceId: 0, passed: true)],
        forkRecords: [
          const ForkRecord(
            collectionName: 'col',
            key: 'k',
            deviceA: 0,
            deviceB: 1,
            lwwWinnerDeviceId: 1, // different winner
            lwwWinnerActionId: 2,
          ),
        ],
        noOpCounts: [],
        totalActions: 10,
        durationMs: 100,
      );
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
      expect(diffs.first.toString(), contains('Fork'));
    });

    test('differing no-op counts produce a diff', () {
      final a = _sampleReport(noOpCount: 5);
      final b = _sampleReport(noOpCount: 10);
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
      expect(diffs.first.toString(), contains('no-op count'));
    });

    test('different fork counts produce a diff', () {
      final a = _sampleReport(forkCount: 1);
      final b = _sampleReport(forkCount: 2);
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
    });

    test('differing failure detail counts produce a diff', () {
      // Build two reports where device 0 has different failure detail counts.
      final a = HarnessReport(
        prngseed: 1,
        deviceVerdicts: [
          DeviceVerdict(
            deviceId: 0,
            passed: false,
            failureDetails: [
              const KeyMismatch(
                compoundKey: 'col\x00k1',
                expected: {'v': 1},
                actual: {'v': 2},
              ),
            ],
          ),
        ],
        forkRecords: [],
        noOpCounts: [],
        totalActions: 10,
        durationMs: 100,
      );
      final b = HarnessReport(
        prngseed: 1,
        deviceVerdicts: [
          DeviceVerdict(deviceId: 0, passed: false, failureDetails: []),
        ],
        forkRecords: [],
        noOpCounts: [],
        totalActions: 10,
        durationMs: 100,
      );
      final diffs = diffReports(a, b);
      expect(diffs, isNotEmpty);
      expect(diffs.any((d) => d.toString().contains('failure count')), isTrue);
    });

    test('toString on ReportDiff returns the description', () {
      const diff = ReportDiff(description: 'test divergence');
      expect(diff.toString(), equals('test divergence'));
    });
  });

  group('ForkRecord.fromForkEvent', () {
    test('converts a ForkEvent into a ForkRecord', () {
      final agent = ReconciliationAgent(deviceCount: 2);

      // Device 0 writes key.
      agent.record(
        ActionResult(
          actionId: 1,
          deviceId: 0,
          type: ActionType.put,
          isNoOp: false,
          key: 'k1',
          collectionName: 'col',
          document: {'v': 'a'},
          hlcEncoded: 100,
        ),
      );
      // Device 1 writes same key — fork.
      agent.record(
        ActionResult(
          actionId: 2,
          deviceId: 1,
          type: ActionType.put,
          isNoOp: false,
          key: 'k1',
          collectionName: 'col',
          document: {'v': 'b'},
          hlcEncoded: 200,
        ),
      );

      expect(agent.detectedForks, hasLength(1));
      final fork = agent.detectedForks.first;
      final record = ForkRecord.fromForkEvent(fork);

      expect(record.collectionName, equals('col'));
      expect(record.key, equals('k1'));
      expect(record.deviceA, equals(fork.writeA.deviceId));
      expect(record.deviceB, equals(fork.writeB.deviceId));
      expect(record.lwwWinnerDeviceId, equals(fork.lwwWinner.deviceId));
      expect(record.lwwWinnerActionId, equals(fork.lwwWinner.actionId));
    });
  });
}
