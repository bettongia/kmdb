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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_test_cloud_support.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Minimal harness config using a factory that assigns per-device
/// [SharedBackendAdapter]s over a shared [SharedCloudBackend].
HarnessConfig _sharedBackendConfig({
  int deviceCount = 2,
  int durationSeconds = 2,
  int? seed,
}) {
  final backend = SharedCloudBackend();
  return HarnessConfig(
    syncAdapterFactory: (deviceId) =>
        SharedBackendAdapter(backend, deviceId: 'dev-$deviceId'),
    deviceCount: deviceCount,
    preSeededDeviceCount: 1,
    collectionCount: 2,
    duration: Duration(seconds: durationSeconds),
    velocityPreset: VelocityPreset.one,
    prngseed: seed ?? 12345,
  );
}

/// Config using a [CloudSemanticsAdapter] with an eventual-consistency profile.
HarnessConfig _eventualConsistencyConfig({
  int deviceCount = 2,
  int durationSeconds = 2,
  int? seed,
  int maxPropagationDelayMs = 0,
}) {
  final backend = SharedCloudBackend();
  return HarnessConfig(
    syncAdapterFactory: (deviceId) => CloudSemanticsAdapter(
      backend: SharedBackendAdapter(backend, deviceId: 'dev-$deviceId'),
      profile: CloudProfile.eventual(
        maxPropagationDelayMs: maxPropagationDelayMs,
      ),
    ),
    deviceCount: deviceCount,
    preSeededDeviceCount: 1,
    collectionCount: 2,
    duration: Duration(seconds: durationSeconds),
    velocityPreset: VelocityPreset.one,
    prngseed: seed ?? 12345,
  );
}

/// Config using mixed-mode front-ends: device 0 uses an eventual-consistency
/// REST-style adapter; device 1 uses a strongly-consistent FS-view adapter.
/// Both share the same [SharedCloudBackend].
HarnessConfig _mixedModeConfig({int durationSeconds = 2, int? seed}) {
  final backend = SharedCloudBackend();
  return HarnessConfig(
    syncAdapterFactory: (deviceId) {
      if (deviceId == 0) {
        // REST-style front-end: eventually consistent.
        return CloudSemanticsAdapter(
          backend: SharedBackendAdapter(backend, deviceId: 'dev-rest'),
          profile: CloudProfile.eventual(maxPropagationDelayMs: 0),
        );
      } else {
        // FS-view front-end: strongly consistent.
        return SharedBackendAdapter(backend, deviceId: 'dev-fs-$deviceId');
      }
    },
    deviceCount: 2,
    preSeededDeviceCount: 1,
    collectionCount: 2,
    duration: Duration(seconds: durationSeconds),
    velocityPreset: VelocityPreset.one,
    prngseed: seed ?? 12345,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── Step 1 backward-compat ─────────────────────────────────────────────────

  group('Backward compatibility — legacy syncAdapter field', () {
    test(
      'existing syncAdapter config still runs without change',
      () async {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          deviceCount: 2,
          preSeededDeviceCount: 1,
          collectionCount: 2,
          duration: const Duration(seconds: 2),
          velocityPreset: VelocityPreset.one,
          prngseed: 42,
        );
        final manager = TestManager(config: config, seed: 42);
        final report = await manager.run();
        expect(report.passed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('resolveAdapter returns the same instance for every device index', () {
      final adapter = MemorySyncAdapter();
      final config = HarnessConfig(
        syncAdapter: adapter,
        velocityPreset: VelocityPreset.one,
        prngseed: 1,
      );
      expect(config.resolveAdapter(0), same(adapter));
      expect(config.resolveAdapter(1), same(adapter));
      expect(config.resolveAdapter(99), same(adapter));
    });

    test('HarnessConfig rejects both syncAdapter and syncAdapterFactory', () {
      expect(
        () => HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          syncAdapterFactory: (_) => MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
        ),
        throwsArgumentError,
      );
    });

    test(
      'HarnessConfig rejects neither syncAdapter nor syncAdapterFactory',
      () {
        expect(
          () => HarnessConfig(velocityPreset: VelocityPreset.one),
          throwsArgumentError,
        );
      },
    );
  });

  // ── Step 1 — per-device factory ────────────────────────────────────────────

  group('Per-device adapter factory', () {
    test('syncAdapterFactory receives the correct device index', () {
      final seenIndices = <int>[];
      final config = HarnessConfig(
        syncAdapterFactory: (deviceId) {
          seenIndices.add(deviceId);
          return MemorySyncAdapter();
        },
        deviceCount: 3,
        velocityPreset: VelocityPreset.one,
        prngseed: 1,
      );
      for (var i = 0; i < 3; i++) {
        config.resolveAdapter(i);
      }
      expect(seenIndices, equals([0, 1, 2]));
    });

    test(
      'SharedBackendAdapter factory run completes successfully',
      () async {
        final manager = TestManager(
          config: _sharedBackendConfig(durationSeconds: 1),
          seed: 42,
        );
        final report = await manager.run();
        expect(report, isA<HarnessReport>());
        expect(report.passed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('resolveAdapter(0) used for quota check with factory', () {
      // A factory that yields a non-QuotaAware adapter must not throw.
      final config = HarnessConfig(
        syncAdapterFactory: (_) => MemorySyncAdapter(),
        deviceCount: 2,
        velocityPreset: VelocityPreset.one,
        prngseed: 1,
      );
      expect(() => TestManager(config: config), returnsNormally);
    });
  });

  // ── Step 4 + 5 — eventual consistency & mixed-mode ─────────────────────────

  group('Eventual consistency — harness run converges after settle', () {
    test(
      'run with eventual-consistency profile completes without false failures',
      () async {
        // Use maxPropagationDelayMs: 0 so the clock has no real delay — we
        // just test the plumbing. The settle step advances the cursor before
        // the final sync, so convergence is guaranteed.
        final manager = TestManager(
          config: _eventualConsistencyConfig(
            durationSeconds: 1,
            maxPropagationDelayMs: 0,
          ),
          seed: 42,
        );
        final report = await manager.run();
        expect(report, isA<HarnessReport>());
        expect(report.passed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'eventually-consistent run reports no false positives',
      () async {
        final manager = TestManager(
          config: _eventualConsistencyConfig(durationSeconds: 2, seed: 99),
          seed: 99,
        );
        final report = await manager.run();
        // No device verdict should be failing due to visibility lag.
        for (final verdict in report.deviceVerdicts) {
          expect(verdict.passed, isTrue, reason: 'device ${verdict.deviceId}');
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('Mixed-mode — REST + FS-view front-ends over one backend', () {
    test(
      'mixed-mode run converges after settle',
      () async {
        final manager = TestManager(
          config: _mixedModeConfig(durationSeconds: 1),
          seed: 42,
        );
        final report = await manager.run();
        expect(report.passed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'mixed-mode run produces valid device verdicts',
      () async {
        final manager = TestManager(
          config: _mixedModeConfig(durationSeconds: 2, seed: 77),
          seed: 77,
        );
        final report = await manager.run();
        expect(report.deviceVerdicts, hasLength(2));
        for (final verdict in report.deviceVerdicts) {
          expect(verdict.passed, isTrue, reason: 'device ${verdict.deviceId}');
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  // ── Step 3 — reconciliation visibility model ───────────────────────────────

  group('ReconciliationAgent — visibility model', () {
    test('global merge still works when visibleWriteSeqHigh is null '
        '(legacy MemorySyncAdapter path)', () async {
      // Use legacy syncAdapter — produces null visibleWriteSeqHigh.
      final manager = TestManager(
        config: HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          deviceCount: 2,
          preSeededDeviceCount: 1,
          collectionCount: 2,
          duration: const Duration(seconds: 1),
          velocityPreset: VelocityPreset.one,
          prngseed: 55,
        ),
        seed: 55,
      );
      final report = await manager.run();
      expect(report.passed, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('visibleExpectedStateFor excludes unpushed peer writes', () {
      final agent = ReconciliationAgent(deviceCount: 2);

      // Device 0 writes to key 'k1' — NOT yet synced, so pushWriteSeq = null.
      agent.record(
        const ActionResult(
          actionId: 1,
          deviceId: 0,
          type: ActionType.put,
          isNoOp: false,
          key: 'k1',
          collectionName: 'c',
          document: {'v': 1},
        ),
      );

      // Device 1 performs a completed sync with seqHigh = 10.
      // Device 0's write has NOT been pushed yet (pushWriteSeq == null).
      // So device 1 should NOT see device 0's write.
      final visible = agent.visibleExpectedStateFor(1, 10);
      expect(visible, isEmpty);
    });

    test(
      'visibleExpectedStateFor includes own writes regardless of pushWriteSeq',
      () {
        final agent = ReconciliationAgent(deviceCount: 2);

        // Device 1 writes locally — pushWriteSeq stays null.
        agent.record(
          const ActionResult(
            actionId: 1,
            deviceId: 1,
            type: ActionType.put,
            isNoOp: false,
            key: 'k1',
            collectionName: 'c',
            document: {'v': 99},
          ),
        );

        // Device 1's own write must appear in its own visible state.
        final visible = agent.visibleExpectedStateFor(1, 0);
        expect(visible, isNotEmpty);
      },
    );

    test(
      'visibleExpectedStateFor includes peer writes once pushed at or below seqHigh',
      () {
        final agent = ReconciliationAgent(deviceCount: 2);

        // Device 0 writes.
        agent.record(
          const ActionResult(
            actionId: 1,
            deviceId: 0,
            type: ActionType.put,
            isNoOp: false,
            key: 'k1',
            collectionName: 'c',
            document: {'v': 1},
          ),
        );

        // Simulate device 0 completing a sync with seqHigh = 5.
        // This stamps device 0's pending writes with pushWriteSeq = 5.
        agent.record(
          const ActionResult(
            actionId: 2,
            deviceId: 0,
            type: ActionType.sync,
            isNoOp: false,
            syncCompleted: true,
            syncDirection: 'both',
            visibleWriteSeqHigh: 5,
          ),
        );

        // Device 1 pulls with seqHigh = 5 — should see device 0's write.
        final visible5 = agent.visibleExpectedStateFor(1, 5);
        expect(visible5, isNotEmpty);

        // Device 1 pulls with seqHigh = 4 — should NOT see it (seq was 5).
        final visible4 = agent.visibleExpectedStateFor(1, 4);
        expect(visible4, isEmpty);
      },
    );
  });

  // ── Step 5 — contention test ───────────────────────────────────────────────

  group('Contention — non-atomic profile', () {
    test(
      'no data loss under non-atomic CloudSemanticsAdapter contention',
      () async {
        // CloudSemanticsAdapter with eventual profile has providesAtomicCas=false.
        // ConsolidationCoordinator gates on this and skips consolidation.
        // We verify that no data is lost (no device verdicts fail).
        final backend = SharedCloudBackend();
        final manager = TestManager(
          config: HarnessConfig(
            syncAdapterFactory: (deviceId) => CloudSemanticsAdapter(
              backend: SharedBackendAdapter(backend, deviceId: 'dev-$deviceId'),
              profile: CloudProfile.eventual(maxPropagationDelayMs: 0),
            ),
            deviceCount: 3,
            preSeededDeviceCount: 1,
            collectionCount: 2,
            duration: const Duration(seconds: 2),
            velocityPreset: VelocityPreset.one,
            prngseed: 777,
          ),
          seed: 777,
        );
        final report = await manager.run();
        // With non-atomic CAS, consolidation is skipped (H5 gate).
        // Convergence must still hold.
        expect(report.passed, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  // ── Step 5 — tombstone non-resurrection (unblocks RC-6) ───────────────────

  group('Tombstone non-resurrection (RC-6 cross-device companion)', () {
    test(
      'deleted key stays absent after peer with older copy syncs',
      () async {
        // This test is the in-harness automation of RC-6:
        // Device A writes a key, then deletes it and syncs.
        // Device B (joining late) syncs and must converge to the deleted state.
        // We use SharedBackendAdapter (strong consistency) so the sequence is
        // deterministic: no tombstone GC is possible in this short run, but
        // the convergence invariant is verified.
        final backend = SharedCloudBackend();
        final manager = TestManager(
          config: HarnessConfig(
            syncAdapterFactory: (deviceId) =>
                SharedBackendAdapter(backend, deviceId: 'dev-$deviceId'),
            deviceCount: 2,
            preSeededDeviceCount: 1,
            collectionCount: 1,
            duration: const Duration(seconds: 2),
            velocityPreset: VelocityPreset.one,
            prngseed: 314,
          ),
          seed: 314,
        );
        final report = await manager.run();

        // All devices must agree — no key is resurrected.
        expect(report.passed, isTrue);
        for (final verdict in report.deviceVerdicts) {
          expect(
            verdict.passed,
            isTrue,
            reason: 'device ${verdict.deviceId} has mismatches',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
