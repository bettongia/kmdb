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

import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('HighwaterMark', () {
    late MemorySyncAdapter adapter;

    setUp(() {
      adapter = MemorySyncAdapter();
    });

    // ── load ─────────────────────────────────────────────────────────────────

    test('load returns null when file does not exist', () async {
      final hwm = await HighwaterMark.load('nofile.hwm', adapter);
      expect(hwm, isNull);
    });

    test('load returns null for empty path before any push', () async {
      final result = await HighwaterMark.load(
        'sync/highwater/dev1.hwm',
        adapter,
      );
      expect(result, isNull);
    });

    // ── save / load roundtrip ─────────────────────────────────────────────────

    test('save then load roundtrips all fields', () async {
      final hlc = Hlc(1711540200000, 0);
      final peerHlc = Hlc(1711540100000, 5);
      const path = 'sync/highwater/a1b2c3d4.hwm';
      final lastUpdated = DateTime.utc(2026, 3, 27, 10, 30, 0);

      final original = HighwaterMark(
        deviceId: 'a1b2c3d4',
        currentHlc: hlc,
        lastUpdated: lastUpdated,
        peers: {'f9e8d7c6': peerHlc},
      );

      await original.save(path, adapter);
      final loaded = await HighwaterMark.load(path, adapter);

      expect(loaded, isNotNull);
      expect(loaded!.deviceId, equals('a1b2c3d4'));
      expect(loaded.currentHlc.physicalMs, equals(hlc.physicalMs));
      expect(loaded.peers['f9e8d7c6']?.physicalMs, equals(peerHlc.physicalMs));
      expect(loaded.lastUpdated.toUtc(), equals(lastUpdated));
    });

    test('save then load with no peers', () async {
      const path = 'hwm/dev.hwm';
      final hwm = HighwaterMark(
        deviceId: '00000001',
        currentHlc: const Hlc(1000000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      await hwm.save(path, adapter);
      final loaded = await HighwaterMark.load(path, adapter);
      expect(loaded!.peers, isEmpty);
    });

    test('save then load with multiple peers', () async {
      const path = 'hwm/dev.hwm';
      final hwm = HighwaterMark(
        deviceId: '00000001',
        currentHlc: const Hlc(5000000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {
          'peer0001': const Hlc(1000000, 0),
          'peer0002': const Hlc(2000000, 10),
          'peer0003': const Hlc(3000000, 0),
        },
      );
      await hwm.save(path, adapter);
      final loaded = await HighwaterMark.load(path, adapter);
      expect(loaded!.peers.length, equals(3));
      expect(loaded.peers['peer0001']?.physicalMs, equals(1000000));
      expect(loaded.peers['peer0002']?.physicalMs, equals(2000000));
      expect(loaded.peers['peer0003']?.physicalMs, equals(3000000));
    });

    // ── load: error cases ─────────────────────────────────────────────────────

    test('load throws FormatException for invalid JSON', () async {
      const path = 'bad.hwm';
      await adapter.upload(path, Uint8List.fromList('not json'.codeUnits));
      expect(
        () => HighwaterMark.load(path, adapter),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'load throws FormatException for JSON array instead of object',
      () async {
        const path = 'bad.hwm';
        await adapter.upload(path, Uint8List.fromList('[1, 2, 3]'.codeUnits));
        expect(
          () => HighwaterMark.load(path, adapter),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'load throws FormatException when required fields are missing',
      () async {
        const path = 'bad.hwm';
        final json = '{"deviceId":"x"}'; // missing currentHlc and lastUpdated
        await adapter.upload(path, Uint8List.fromList(json.codeUnits));
        expect(
          () => HighwaterMark.load(path, adapter),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('load throws FormatException for invalid currentHlc', () async {
      const path = 'bad.hwm';
      final json =
          '{"deviceId":"x","currentHlc":"ZZZZ","lastUpdated":"2026-01-01T00:00:00Z","peers":{}}';
      await adapter.upload(path, Uint8List.fromList(json.codeUnits));
      expect(
        () => HighwaterMark.load(path, adapter),
        throwsA(isA<FormatException>()),
      );
    });

    test('load throws FormatException for invalid peer HLC', () async {
      const path = 'bad.hwm';
      final json =
          '{"deviceId":"x","currentHlc":"000000000000","lastUpdated":"2026-01-01T00:00:00Z",'
          '"peers":{"peer1":"NOTAHEX"}}';
      await adapter.upload(path, Uint8List.fromList(json.codeUnits));
      expect(
        () => HighwaterMark.load(path, adapter),
        throwsA(isA<FormatException>()),
      );
    });

    // ── withPeer ──────────────────────────────────────────────────────────────

    test('withPeer adds a new peer entry', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      final updated = hwm.withPeer('dev2', const Hlc(500, 0));
      expect(updated.peers['dev2']?.physicalMs, equals(500));
      // Original unchanged.
      expect(hwm.peers, isEmpty);
    });

    test('withPeer updates peer if new HLC is higher', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {'dev2': const Hlc(100, 0)},
      );
      final updated = hwm.withPeer('dev2', const Hlc(200, 0));
      expect(updated.peers['dev2']?.physicalMs, equals(200));
    });

    test('withPeer does NOT downgrade an existing peer HLC', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {'dev2': const Hlc(500, 0)},
      );
      final updated = hwm.withPeer('dev2', const Hlc(100, 0)); // lower HLC
      expect(updated.peers['dev2']?.physicalMs, equals(500)); // unchanged
    });

    test('withPeer does not mutate the original', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {'dev2': const Hlc(100, 0)},
      );
      hwm.withPeer('dev3', const Hlc(200, 0));
      expect(hwm.peers.containsKey('dev3'), isFalse);
    });

    // ── withCurrentHlc ────────────────────────────────────────────────────────

    test('withCurrentHlc returns new instance with updated HLC', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(100, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      final now = DateTime.utc(2026, 3, 27, 12, 0, 0);
      final updated = hwm.withCurrentHlc(const Hlc(999, 5), now: now);
      expect(updated.currentHlc.physicalMs, equals(999));
      expect(updated.currentHlc.logical, equals(5));
      expect(updated.lastUpdated, equals(now));
      // Original unchanged.
      expect(hwm.currentHlc.physicalMs, equals(100));
    });

    test('withCurrentHlc preserves peers', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(100, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {'peer': const Hlc(50, 0)},
      );
      final updated = hwm.withCurrentHlc(const Hlc(200, 0));
      expect(updated.peers['peer']?.physicalMs, equals(50));
    });

    // ── isPeerStale ───────────────────────────────────────────────────────────

    test('isPeerStale returns true for unknown peer', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      expect(hwm.isPeerStale('unknown-peer'), isTrue);
    });

    test('isPeerStale returns false for known peer', () {
      final hwm = HighwaterMark(
        deviceId: 'dev1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: {'dev2': const Hlc(500, 0)},
      );
      expect(hwm.isPeerStale('dev2'), isFalse);
    });

    // ── toString ──────────────────────────────────────────────────────────────

    test('toString includes deviceId', () {
      final hwm = HighwaterMark(
        deviceId: 'a1b2c3d4',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      expect(hwm.toString(), contains('a1b2c3d4'));
    });
  });

  // ── H4 PR2: minCurrentHlcAcrossDevices ───────────────────────────────────
  //
  // The principled tombstone-GC horizon for a synced database is
  // `min(currentHlc)` across all `.hwm` files in the sync folder. Every
  // device has synced past it, so a tombstone with HLC strictly below it
  // has been observed by every device and may be dropped without risk of
  // resurrection.

  group('HighwaterMark.minCurrentHlcAcrossDevices', () {
    late MemorySyncAdapter adapter;

    setUp(() {
      adapter = MemorySyncAdapter();
    });

    Future<void> writeHwm(String deviceId, Hlc currentHlc) async {
      final hwm = HighwaterMark(
        deviceId: deviceId,
        currentHlc: currentHlc,
        lastUpdated: DateTime.utc(2026, 1, 1),
        peers: const {},
      );
      await hwm.save('highwater/$deviceId.hwm', adapter);
    }

    test('returns null when the hwm directory has no .hwm files', () async {
      final result = await HighwaterMark.minCurrentHlcAcrossDevices(
        'highwater',
        adapter,
      );
      expect(result, isNull);
    });

    test(
      'returns the only device\'s currentHlc when one HWM is present',
      () async {
        await writeHwm('dev1', const Hlc(500, 0));
        final result = await HighwaterMark.minCurrentHlcAcrossDevices(
          'highwater',
          adapter,
        );
        expect(result, equals(const Hlc(500, 0)));
      },
    );

    test('returns the minimum across multiple devices', () async {
      // Three devices, mixed currentHlc values. Min should be 300.
      await writeHwm('dev1', const Hlc(700, 0));
      await writeHwm('dev2', const Hlc(300, 0));
      await writeHwm('dev3', const Hlc(900, 0));
      final result = await HighwaterMark.minCurrentHlcAcrossDevices(
        'highwater',
        adapter,
      );
      expect(result, equals(const Hlc(300, 0)));
    });

    test(
      'the slowest device pegs the horizon (the documented PR2 limitation)',
      () async {
        // A "dead/inactive" peer pegs the strict-min horizon. The newer
        // devices' high currentHlc does not advance the horizon past the
        // slow one. PR2 ships this conservative behaviour; an eviction
        // rule (max device staleness) is intentionally deferred per
        // plan_tombstone_gc.md.
        await writeHwm('newcomer', const Hlc(10000, 0));
        await writeHwm('idle-peer', const Hlc(1, 0));
        final result = await HighwaterMark.minCurrentHlcAcrossDevices(
          'highwater',
          adapter,
        );
        expect(result, equals(const Hlc(1, 0)));
      },
    );

    test(
      'serialisation normalises the logical component to 0 (HWM file format '
      'stores physical-only), so the helper compares physical ms only',
      () async {
        // HighwaterMark serialises currentHlc as the 12-char physical-only
        // hex (see [HighwaterMark.save] / [Hlc.toPhysicalHex]). The logical
        // component is *not* round-tripped — both writes below collapse to
        // `Hlc(100, 0)` on disk, and the helper returns that.
        await writeHwm('dev1', const Hlc(100, 5));
        await writeHwm('dev2', const Hlc(100, 2));
        final result = await HighwaterMark.minCurrentHlcAcrossDevices(
          'highwater',
          adapter,
        );
        expect(result, equals(const Hlc(100, 0)));
      },
    );
  });
}
