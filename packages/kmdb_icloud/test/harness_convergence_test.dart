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
import 'package:kmdb/kmdb_test_cloud_support.dart' show SharedCloudBackend;
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:kmdb_icloud/src/icloud_adapter.dart' show ICloudAdapter;
import 'package:kmdb_icloud/src/icloud_profile.dart' show kICloudProfile;
import 'package:test/test.dart';

import 'support/fake_icloud_sync_channel.dart';

// ── Scenario setup ─────────────────────────────────────────────────────────

/// Creates a [HarnessConfig] where each device gets its own [ICloudAdapter]
/// backed by a single shared [SharedCloudBackend], wrapped in
/// [SimulatorICloudQuotaAdapter] so [TestManager] can apply the iCloud quota
/// limit.
///
/// All per-device adapters share the same [SharedCloudBackend] instance (the
/// same in-memory CloudKit zone state), which is the mixed-mode scenario: each
/// device accesses the same "cloud" through its own stateful adapter.
HarnessConfig _iCloudSimulatorConfig({
  int deviceCount = 2,
  int durationSeconds = 2,
  int seed = 54321,
}) {
  // One shared backend = one shared CloudKit zone for all devices.
  // Each device gets its own ICloudAdapter with its own channel instance,
  // simulating separate app instances on different iOS/macOS devices.
  final backend = SharedCloudBackend();

  return HarnessConfig(
    syncAdapterFactory: (deviceId) {
      return quotaAdapterOverBackend(
        backend,
        syncRoot: '__harness_icloud_test__',
        profile: kICloudProfile,
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

  // ── ICloudAdapter convergence via shared SharedCloudBackend ───────────────

  group('ICloudAdapter harness convergence (FakeICloudSyncChannel)', () {
    test(
      'two devices converge when syncing through a shared iCloud simulator',
      () async {
        final manager = TestManager(
          config: _iCloudSimulatorConfig(
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
      'three devices converge via the shared iCloud simulator',
      () async {
        final manager = TestManager(
          config: _iCloudSimulatorConfig(
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
      'SimulatorICloudQuotaAdapter.safeOperationThreshold reflects iCloud quota',
      () {
        final backend = SharedCloudBackend();
        final adapter = adapterOverBackend(backend);
        final quota = SimulatorICloudQuotaAdapter(
          adapter: adapter,
          quotaProfile: kICloudProfile.quota,
        );

        // The threshold is 10× the maxOpsPerMinute from the iCloud profile.
        expect(quota.safeOperationThreshold, greaterThan(0));
        expect(
          quota.safeOperationThreshold,
          equals(kICloudProfile.quota.maxOpsPerMinute! * 10),
        );
      },
    );

    test(
      'SimulatorICloudQuotaAdapter delegates all SyncStorageAdapter methods',
      () async {
        final backend = SharedCloudBackend();
        final underlying = adapterOverBackend(backend);
        final wrapped = SimulatorICloudQuotaAdapter(
          adapter: underlying,
          quotaProfile: kICloudProfile.quota,
        );

        // providesAtomicCas must delegate to the underlying adapter.
        expect(wrapped.providesAtomicCas, equals(underlying.providesAtomicCas));
        // iCloud = non-atomic create-if-absent (Phase 4a confirmed).
        expect(wrapped.providesAtomicCas, isFalse);

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
