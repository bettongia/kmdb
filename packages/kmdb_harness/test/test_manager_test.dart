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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Minimal [QuotaAwareAdapter] stub that delegates to a [MemorySyncAdapter].
final class _QuotaAdapter implements SyncStorageAdapter, QuotaAwareAdapter {
  _QuotaAdapter({required this.safeOperationThreshold})
    : _inner = MemorySyncAdapter();

  final MemorySyncAdapter _inner;

  @override
  final int safeOperationThreshold;

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) =>
      _inner.list(remoteDir, extension: extension);

  @override
  Future<Uint8List?> download(String remotePath) => _inner.download(remotePath);

  @override
  Future<void> upload(String remotePath, Uint8List bytes) =>
      _inner.upload(remotePath, bytes);

  @override
  Future<void> delete(String remotePath) => _inner.delete(remotePath);

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
  }) => _inner.compareAndSwap(path, newBytes, ifMatchEtag: ifMatchEtag);

  @override
  Future<String?> getEtag(String path) => _inner.getEtag(path);

  @override
  bool get providesAtomicCas => _inner.providesAtomicCas;
}

HarnessConfig _lowVelocityConfig({
  SyncStorageAdapter? syncAdapter,
  int deviceCount = 2,
  int preSeededDeviceCount = 1,
  int collectionCount = 2,
  int durationSeconds = 2,
  int? seed,
}) => HarnessConfig(
  syncAdapter: syncAdapter ?? MemorySyncAdapter(),
  deviceCount: deviceCount,
  preSeededDeviceCount: preSeededDeviceCount,
  collectionCount: collectionCount,
  duration: Duration(seconds: durationSeconds),
  velocityPreset: VelocityPreset.one,
  prngseed: seed ?? 12345,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('TestManager — lifecycle', () {
    test(
      'run completes and returns a HarnessReport',
      () async {
        final manager = TestManager(
          config: _lowVelocityConfig(durationSeconds: 1),
          seed: 42,
        );
        final report = await manager.run();

        expect(report, isA<HarnessReport>());
        expect(report.prngseed, equals(42));
        expect(report.deviceVerdicts, hasLength(2));
        expect(report.durationMs, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'report contains no-op counts for every device',
      () async {
        final manager = TestManager(
          config: _lowVelocityConfig(deviceCount: 3, durationSeconds: 1),
          seed: 1,
        );
        final report = await manager.run();

        expect(report.noOpCounts, hasLength(3));
        for (final n in report.noOpCounts) {
          expect(n.count, greaterThanOrEqualTo(0));
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'report seed matches provided seed override',
      () async {
        final manager = TestManager(
          config: _lowVelocityConfig(durationSeconds: 1),
          seed: 99999,
        );
        final report = await manager.run();
        expect(report.prngseed, equals(99999));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'report seed falls back to config prngseed',
      () async {
        final config = _lowVelocityConfig(durationSeconds: 1, seed: 77777);
        final manager = TestManager(config: config);
        final report = await manager.run();
        expect(report.prngseed, equals(77777));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'totalActions is positive after a run',
      () async {
        final manager = TestManager(
          config: _lowVelocityConfig(durationSeconds: 1),
          seed: 5,
        );
        final report = await manager.run();
        expect(report.totalActions, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'report includes versionForksChecked matching forkRecords count',
      () async {
        final manager = TestManager(
          config: _lowVelocityConfig(durationSeconds: 2),
          seed: 42,
        );
        final report = await manager.run();

        // The number of forks checked must equal the number of fork records
        // detected by the reconciler.
        expect(report.versionForksChecked, equals(report.forkRecords.length));
        // All checked forks should pass (version history propagates correctly).
        expect(report.versionForksPassed, equals(report.versionForksChecked));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('TestManager — quota check', () {
    test(
      'rejects config when estimated ops exceed adapter threshold',
      () async {
        // Threshold of 1 will always be exceeded for any non-trivial run.
        final adapter = _QuotaAdapter(safeOperationThreshold: 1);
        final config = HarnessConfig(
          syncAdapter: adapter,
          deviceCount: 5,
          collectionCount: 10,
          duration: const Duration(minutes: 10),
          velocityPreset: VelocityPreset.five,
          prngseed: 1,
        );
        final manager = TestManager(config: config);

        expect(() => manager.run(), throwsA(isA<HarnessConfigException>()));
      },
    );

    test(
      'accepts config when estimated ops are within threshold',
      () async {
        // Generous threshold — should always pass for a 1-second run.
        final adapter = _QuotaAdapter(safeOperationThreshold: 1000000);
        final config = _lowVelocityConfig(
          syncAdapter: adapter,
          durationSeconds: 1,
        );
        final manager = TestManager(config: config, seed: 1);

        // Should not throw.
        final report = await manager.run();
        expect(report, isA<HarnessReport>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('TestManager — HarnessConfigException', () {
    test('toString includes the message', () {
      const e = HarnessConfigException('quota exceeded');
      expect(e.toString(), contains('quota exceeded'));
    });
  });

  group('QuotaAwareAdapter interface', () {
    test('adapter reports safeOperationThreshold', () {
      final adapter = _QuotaAdapter(safeOperationThreshold: 500);
      expect(adapter.safeOperationThreshold, equals(500));
    });
  });
}
