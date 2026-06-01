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
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

void main() {
  group('KeyPoolRatios', () {
    test('defaults sum to 100', () {
      const r = KeyPoolRatios.defaults();
      expect(r.shared + r.deviceLocal + r.hot, equals(100));
    });

    test('custom values', () {
      const r = KeyPoolRatios(shared: 60, deviceLocal: 30, hot: 10);
      expect(r.shared, 60);
      expect(r.deviceLocal, 30);
      expect(r.hot, 10);
    });
  });

  group('DocSizeDistribution', () {
    test('defaults sum to 100', () {
      const d = DocSizeDistribution.defaults();
      expect(d.small + d.medium + d.large, equals(100));
    });

    test('custom values', () {
      const d = DocSizeDistribution(small: 50, medium: 40, large: 10);
      expect(d.small, 50);
      expect(d.medium, 40);
      expect(d.large, 10);
    });
  });

  group('HarnessConfig', () {
    group('preset expansion', () {
      test('preset 1 sets correct values', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          deviceCount: 3,
        );
        expect(config.actionsPerMinute, equals(2));
        expect(config.simultaneousDevices, equals(1));
        expect(config.syncIntervalSeconds, equals(300));
        expect(config.syncAfterWrites, equals(20));
      });

      test('preset 2 sets correct values', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.two,
          deviceCount: 4,
        );
        expect(config.actionsPerMinute, equals(5));
        expect(config.simultaneousDevices, equals(2));
        expect(config.syncIntervalSeconds, equals(120));
        expect(config.syncAfterWrites, equals(15));
      });

      test('preset 3 computes simultaneous from device count', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.three,
          deviceCount: 6,
        );
        expect(config.actionsPerMinute, equals(10));
        expect(config.simultaneousDevices, equals(3)); // floor(6/2)
        expect(config.syncIntervalSeconds, equals(60));
        expect(config.syncAfterWrites, equals(10));
      });

      test('preset 4 uses N-1 devices', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.four,
          deviceCount: 4,
        );
        expect(config.simultaneousDevices, equals(3)); // 4-1
        expect(config.actionsPerMinute, equals(30));
      });

      test('preset 5 uses all devices', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.five,
          deviceCount: 3,
        );
        expect(config.simultaneousDevices, equals(3));
        expect(config.actionsPerMinute, equals(120));
        expect(config.syncIntervalSeconds, equals(10));
        expect(config.syncAfterWrites, equals(3));
      });
    });

    group('knob overrides', () {
      test('direct actionsPerMinute overrides preset', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          actionsPerMinute: 42,
        );
        expect(config.actionsPerMinute, equals(42));
      });

      test('direct syncIntervalSeconds overrides preset', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          syncIntervalSeconds: 99,
        );
        expect(config.syncIntervalSeconds, equals(99));
      });

      test('direct syncAfterWrites overrides preset', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          syncAfterWrites: 7,
        );
        expect(config.syncAfterWrites, equals(7));
      });

      test('direct simultaneousDevices overrides preset', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          deviceCount: 5,
          simultaneousDevices: 4,
        );
        expect(config.simultaneousDevices, equals(4));
      });
    });

    group('syncAdapterFactory', () {
      test('factory is called with the correct device index', () {
        final seen = <int>[];
        final config = HarnessConfig(
          syncAdapterFactory: (i) {
            seen.add(i);
            return MemorySyncAdapter();
          },
          velocityPreset: VelocityPreset.one,
          deviceCount: 3,
        );
        for (var i = 0; i < 3; i++) {
          config.resolveAdapter(i);
        }
        expect(seen, equals([0, 1, 2]));
      });

      test('resolveAdapter returns distinct instances from factory', () {
        final config = HarnessConfig(
          syncAdapterFactory: (_) => MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
        );
        // Each call produces a fresh instance.
        final a = config.resolveAdapter(0);
        final b = config.resolveAdapter(0);
        expect(a, isNot(same(b)));
      });

      test('resolveAdapter returns same instance from syncAdapter field', () {
        final adapter = MemorySyncAdapter();
        final config = HarnessConfig(
          syncAdapter: adapter,
          velocityPreset: VelocityPreset.one,
        );
        expect(config.resolveAdapter(0), same(adapter));
        expect(config.resolveAdapter(1), same(adapter));
      });

      test('rejects both syncAdapter and syncAdapterFactory', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            syncAdapterFactory: (_) => MemorySyncAdapter(),
            velocityPreset: VelocityPreset.one,
          ),
          throwsArgumentError,
        );
      });

      test('rejects neither syncAdapter nor syncAdapterFactory', () {
        expect(
          () => HarnessConfig(velocityPreset: VelocityPreset.one),
          throwsArgumentError,
        );
      });

      test('syncAdapter getter returns null when factory was used', () {
        final config = HarnessConfig(
          syncAdapterFactory: (_) => MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
        );
        expect(config.syncAdapter, isNull);
        expect(config.syncAdapterFactory, isNotNull);
      });

      test('syncAdapterFactory getter returns null when field was used', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
        );
        expect(config.syncAdapterFactory, isNull);
        expect(config.syncAdapter, isNotNull);
      });
    });

    group('validation', () {
      test('rejects when no sync trigger is configured', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            // No preset and no explicit sync triggers — must throw.
            actionsPerMinute: 5,
            simultaneousDevices: 1,
          ),
          throwsArgumentError,
        );
      });

      test('rejects deviceCount < 1', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            deviceCount: 0,
            velocityPreset: VelocityPreset.one,
          ),
          throwsArgumentError,
        );
      });

      test('rejects preSeededDeviceCount > deviceCount', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            deviceCount: 2,
            preSeededDeviceCount: 3,
            velocityPreset: VelocityPreset.one,
          ),
          throwsArgumentError,
        );
      });

      test('rejects collectionCount < 1', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            collectionCount: 0,
            velocityPreset: VelocityPreset.one,
          ),
          throwsArgumentError,
        );
      });

      test('rejects actionsPerMinute < 1', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            velocityPreset: VelocityPreset.one,
            actionsPerMinute: 0,
          ),
          throwsArgumentError,
        );
      });

      test('rejects simultaneousDevices > deviceCount', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            deviceCount: 2,
            simultaneousDevices: 5,
            velocityPreset: VelocityPreset.one,
          ),
          throwsArgumentError,
        );
      });

      test('rejects syncIntervalSeconds < 1', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            velocityPreset: VelocityPreset.one,
            syncIntervalSeconds: 0,
          ),
          throwsArgumentError,
        );
      });

      test('rejects syncAfterWrites < 1', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            velocityPreset: VelocityPreset.one,
            syncAfterWrites: 0,
          ),
          throwsArgumentError,
        );
      });

      test('accepts preSeededDeviceCount of 0', () {
        expect(
          () => HarnessConfig(
            syncAdapter: MemorySyncAdapter(),
            preSeededDeviceCount: 0,
            velocityPreset: VelocityPreset.one,
          ),
          returnsNormally,
        );
      });

      test('accepts manual sync knobs without a preset sync trigger', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          syncIntervalSeconds: 10,
          syncAfterWrites: null,
        );
        expect(config.syncIntervalSeconds, equals(10));
      });

      test('prngseed is stored', () {
        final config = HarnessConfig(
          syncAdapter: MemorySyncAdapter(),
          velocityPreset: VelocityPreset.one,
          prngseed: 12345,
        );
        expect(config.prngseed, equals(12345));
      });
    });
  });
}
