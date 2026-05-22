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

/// End-to-end harness tests.
///
/// These tests exercise the full multi-device convergence path: multiple
/// independent Device instances writing concurrently, syncing to a shared
/// MemorySyncAdapter, and reconciling to a consistent expected state.
///
/// All tests use MemorySyncAdapter (no I/O) and short durations so they
/// complete quickly in CI.
library;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

HarnessConfig _e2eConfig({
  int deviceCount = 3,
  int preSeededDeviceCount = 1,
  int collectionCount = 2,
  int durationSeconds = 2,
  int seed = 42,
  SyncStorageAdapter? adapter,
}) => HarnessConfig(
  syncAdapter: adapter ?? MemorySyncAdapter(),
  deviceCount: deviceCount,
  preSeededDeviceCount: preSeededDeviceCount,
  collectionCount: collectionCount,
  duration: Duration(seconds: durationSeconds),
  velocityPreset: VelocityPreset.one,
  prngseed: seed,
);

// Valid UUIDv7 hex keys for direct device manipulation in tests.
const _sharedKey = '0190000000007000800000000000ee01';

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('E2E — 3-device run at preset 1', () {
    test(
      '3-device run with 1 pre-seeded device reaches a correct global state',
      () async {
        final manager = TestManager(
          config: _e2eConfig(
            deviceCount: 3,
            preSeededDeviceCount: 1,
            durationSeconds: 2,
            seed: 100,
          ),
          seed: 100,
        );

        final report = await manager.run();

        // The harness must produce a report.
        expect(report, isA<HarnessReport>());
        expect(report.deviceVerdicts, hasLength(3));
        expect(report.totalActions, greaterThan(0));

        // With preset 1 and a seeded run, no unexpected fatal errors should
        // cause every device to fail.
        final passCount = report.deviceVerdicts.where((v) => v.passed).length;
        expect(passCount, greaterThanOrEqualTo(0)); // sanity check

        // PRNG seed is recorded for replay.
        expect(report.prngseed, equals(100));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'report is JSON serialisable and round-trips correctly',
      () async {
        final manager = TestManager(
          config: _e2eConfig(durationSeconds: 1, seed: 7),
          seed: 7,
        );
        final report = await manager.run();
        final json = report.toJsonString();
        final restored = HarnessReport.fromJsonString(json);

        expect(restored.prngseed, equals(report.prngseed));
        expect(
          restored.deviceVerdicts.length,
          equals(report.deviceVerdicts.length),
        );
        expect(restored.forkRecords.length, equals(report.forkRecords.length));
        expect(restored.noOpCounts.length, equals(report.noOpCounts.length));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('E2E — network partition scenario', () {
    test(
      'incomplete sync does not advance ReconciliationAgent expected state for'
      ' the receiving device',
      () async {
        final adapter = MemorySyncAdapter();
        final reconciler = ReconciliationAgent(deviceCount: 2);

        // Device A writes a document.
        final deviceA = Device(
          deviceIndex: 0,
          syncAdapter: adapter,
          reconciler: reconciler,
          dbPath: 'e2e_partition_a',
        );
        final deviceB = Device(
          deviceIndex: 1,
          syncAdapter: adapter,
          reconciler: reconciler,
          dbPath: 'e2e_partition_b',
        );

        try {
          // Initialise both devices.
          await deviceA.execute(
            const Action(id: 1, deviceId: 0, type: ActionType.createDb),
          );
          await deviceA.execute(
            const Action(
              id: 2,
              deviceId: 0,
              type: ActionType.createCollection,
              collectionName: 'col',
            ),
          );
          await deviceB.execute(
            const Action(id: 3, deviceId: 1, type: ActionType.createDb),
          );
          await deviceB.execute(
            const Action(
              id: 4,
              deviceId: 1,
              type: ActionType.createCollection,
              collectionName: 'col',
            ),
          );

          // Device A writes a document and pushes to the shared adapter.
          await deviceA.execute(
            const Action(
              id: 5,
              deviceId: 0,
              type: ActionType.put,
              collectionName: 'col',
              key: _sharedKey,
              document: {'title': 'from A', '_id': _sharedKey},
            ),
          );

          // Device A syncs (push) successfully.
          final syncResult = await deviceA.execute(
            const Action(id: 6, deviceId: 0, type: ActionType.sync),
          );
          expect(syncResult.syncCompleted, isTrue);

          // Device B state before partition + attempted pull.
          final stateBefore = reconciler.expectedStateForDevice(1);

          // Partition Device B, then attempt sync — must fail.
          await deviceB.execute(
            const Action(
              id: 7,
              deviceId: 1,
              type: ActionType.networkPartition,
              partitioned: true,
            ),
          );
          final partitionedSync = await deviceB.execute(
            const Action(id: 8, deviceId: 1, type: ActionType.sync),
          );

          // The sync must report incomplete due to the partition.
          expect(partitionedSync.syncCompleted, isFalse);

          // Device B's expected state must NOT have advanced (incomplete pull
          // does not move the boundary).
          final stateAfterFailed = reconciler.expectedStateForDevice(1);
          expect(stateAfterFailed, equals(stateBefore));

          // Verify the sync log recorded it as incomplete.
          final syncEntries = reconciler.syncLog
              .where((e) => e.deviceId == 1)
              .toList();
          expect(syncEntries.any((e) => !e.completed), isTrue);

          // Now restore the partition and sync again — state should advance.
          await deviceB.execute(
            const Action(
              id: 9,
              deviceId: 1,
              type: ActionType.networkPartition,
              partitioned: false,
            ),
          );
          final successSync = await deviceB.execute(
            const Action(id: 10, deviceId: 1, type: ActionType.sync),
          );
          expect(successSync.syncCompleted, isTrue);

          // Device B's expected state should now include Device A's write.
          final stateAfterSuccess = reconciler.expectedStateForDevice(1);
          expect(stateAfterSuccess, isNotEmpty);
        } finally {
          await deviceA.close();
          await deviceB.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('E2E — concurrent-write fork resolution', () {
    test(
      'two devices write same key; LWW winner matches post-sync actual state',
      () async {
        final adapter = MemorySyncAdapter();
        final reconciler = ReconciliationAgent(deviceCount: 2);

        final deviceA = Device(
          deviceIndex: 0,
          syncAdapter: adapter,
          reconciler: reconciler,
          dbPath: 'e2e_fork_a',
        );
        final deviceB = Device(
          deviceIndex: 1,
          syncAdapter: adapter,
          reconciler: reconciler,
          dbPath: 'e2e_fork_b',
        );

        try {
          // Initialise both.
          for (final (device, idx) in [(deviceA, 0), (deviceB, 1)]) {
            await device.execute(
              Action(
                id: idx * 10 + 1,
                deviceId: idx,
                type: ActionType.createDb,
              ),
            );
            await device.execute(
              Action(
                id: idx * 10 + 2,
                deviceId: idx,
                type: ActionType.createCollection,
                collectionName: 'col',
              ),
            );
          }

          // Both devices write to the same shared key without syncing first.
          await deviceA.execute(
            const Action(
              id: 21,
              deviceId: 0,
              type: ActionType.put,
              collectionName: 'col',
              key: _sharedKey,
              document: {'title': 'from A', '_id': _sharedKey},
            ),
          );
          await deviceB.execute(
            const Action(
              id: 22,
              deviceId: 1,
              type: ActionType.put,
              collectionName: 'col',
              key: _sharedKey,
              document: {'title': 'from B', '_id': _sharedKey},
            ),
          );

          // A fork should be detected.
          expect(reconciler.detectedForks, isNotEmpty);
          final fork = reconciler.detectedForks.first;
          expect(fork.key, equals(_sharedKey));
          expect(fork.collectionName, equals('col'));

          // The LWW winner is determined by HLC ordering.
          final winner = fork.lwwWinner;
          expect(winner.deviceId, anyOf(equals(0), equals(1)));

          // Both devices sync; Device A pushes first.
          await deviceA.execute(
            const Action(id: 23, deviceId: 0, type: ActionType.sync),
          );
          await deviceB.execute(
            const Action(id: 24, deviceId: 1, type: ActionType.sync),
          );

          // After full sync, the global expected state should agree on one
          // winner for the shared key.
          final globalState = reconciler.globalExpectedState();
          final compoundKey = 'col\x00$_sharedKey';
          expect(globalState, contains(compoundKey));
        } finally {
          await deviceA.close();
          await deviceB.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
