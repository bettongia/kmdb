// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

import 'support/drive_simulator.dart';

// ── Scenario setup ─────────────────────────────────────────────────────────

/// Creates a [HarnessConfig] where each device gets its own [GoogleDriveAdapter]
/// backed by a single shared [DriveSimulator], wrapped in [SimulatorQuotaAdapter]
/// so [TestManager] can apply the Drive quota limit.
///
/// All per-device adapters share the same [DriveSimulator] instance (i.e. the
/// same in-memory Drive folder state), which is the mixed-mode scenario: each
/// device accesses the same "cloud" but through its own stateful adapter with
/// its own ID cache.
HarnessConfig _driveSimulatorConfig({
  int deviceCount = 2,
  int durationSeconds = 2,
  int seed = 54321,
}) {
  // One shared simulator = one shared Drive backend for all devices.
  // Each device gets its own GoogleDriveAdapter with its own folder-ID cache,
  // simulating separate processes accessing the same Drive account.
  final simulator = DriveSimulator();

  return HarnessConfig(
    syncAdapterFactory: (deviceId) {
      final adapter = adapterOverSimulator(
        simulator,
        syncRoot: '__harness_test__',
      );
      return SimulatorQuotaAdapter(
        adapter: adapter,
        quotaProfile: kGoogleDriveProfile.quota,
      );
    },
    deviceCount: deviceCount,
    preSeededDeviceCount: 1,
    collectionCount: 2,
    duration: Duration(seconds: durationSeconds),
    velocityPreset: VelocityPreset.one,
    prngseed: seed,
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── GoogleDriveAdapter convergence via shared DriveSimulator ───────────────

  group('GoogleDriveAdapter harness convergence (DriveSimulator)', () {
    test(
      'two devices converge when syncing through a shared Drive simulator',
      () async {
        final manager = TestManager(
          config: _driveSimulatorConfig(
            deviceCount: 2,
            durationSeconds: 2,
            seed: 11111,
          ),
          seed: 11111,
        );
        final report = await manager.run();
        expect(report.passed, isTrue, reason: report.toString());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'three devices converge via the shared Drive simulator',
      () async {
        final manager = TestManager(
          config: _driveSimulatorConfig(
            deviceCount: 3,
            durationSeconds: 2,
            seed: 22222,
          ),
          seed: 22222,
        );
        final report = await manager.run();
        expect(report.passed, isTrue, reason: report.toString());
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'SimulatorQuotaAdapter.safeOperationThreshold reflects Drive quota',
      () {
        final simulator = DriveSimulator();
        final adapter = adapterOverSimulator(simulator);
        final quota = SimulatorQuotaAdapter(
          adapter: adapter,
          quotaProfile: kGoogleDriveProfile.quota,
        );

        // The threshold is 10× the maxOpsPerMinute from the Drive profile.
        // Drive's limit is 300 ops/min → threshold = 3000.
        expect(quota.safeOperationThreshold, greaterThan(0));
        expect(
          quota.safeOperationThreshold,
          equals(kGoogleDriveProfile.quota.maxOpsPerMinute! * 10),
        );
      },
    );

    test(
      'SimulatorQuotaAdapter delegates all SyncStorageAdapter methods',
      () async {
        final simulator = DriveSimulator();
        final underlying = adapterOverSimulator(simulator);
        final wrapped = SimulatorQuotaAdapter(
          adapter: underlying,
          quotaProfile: kGoogleDriveProfile.quota,
        );

        // providesAtomicCas must delegate to the underlying adapter.
        expect(wrapped.providesAtomicCas, equals(underlying.providesAtomicCas));
        expect(wrapped.providesAtomicCas, isFalse); // Drive = non-atomic create

        // Functional round-trip through the wrapper.
        const path = 'sstables/wrapper-test.sst';
        final bytes = List.generate(8, (i) => i + 1);
        final uint8bytes = Uint8List.fromList(bytes);

        await wrapped.upload(path, uint8bytes);
        expect(await wrapped.download(path), equals(uint8bytes));

        final etag = await wrapped.getEtag(path);
        expect(etag, isNotNull);

        final files = await wrapped.list('sstables', extension: '.sst');
        expect(files, contains('wrapper-test.sst'));

        await wrapped.delete(path);
        expect(await wrapped.download(path), isNull);
      },
    );
  });
}
