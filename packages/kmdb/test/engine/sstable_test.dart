// Copyright 2026 The KMDB Authors
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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _ikey(String ns, String hexSuffix, Hlc hlc) {
  final hexKey = hexSuffix.padLeft(12, '0') + '70008' + hexSuffix.padLeft(15, '0');
  return KeyCodec.encodeInternalKey(
      ns, KeyCodec.keyToBytes(hexKey), hlc, RecordType.put);
}

Uint8List _val(int b) => Uint8List.fromList([b]);

Future<SstableReader> _buildAndOpen(
  List<(Uint8List, Uint8List)> entries, {
  MemoryStorageAdapter? adapter,
}) async {
  adapter ??= MemoryStorageAdapter();
  final writer = SstableWriter();
  for (final (k, v) in entries) {
    writer.add(k, v);
  }
  final bytes = writer.finish();
  const path = '/sst/test.sst';
  await adapter.writeFile(path, bytes);
  return SstableReader.open(path, adapter);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('SstableWriter / SstableReader round-trip', () {
    test('single entry is readable', () async {
      final k = _ikey('ns', 'a', const Hlc(1, 0));
      final reader = await _buildAndOpen([(k, _val(42))]);
      final result = await reader.get(k);
      expect(result, equals(_val(42)));
    });

    test('absent key returns null', () async {
      final k = _ikey('ns', 'a', const Hlc(1, 0));
      final k2 = _ikey('ns', 'b', const Hlc(1, 0));
      final reader = await _buildAndOpen([(k, _val(1))]);
      expect(await reader.get(k2), isNull);
    });

    test('entry count reported correctly', () async {
      final entries = [
        for (var i = 1; i <= 10; i++)
          (_ikey('ns', i.toRadixString(16), const Hlc(1, 0)), _val(i)),
      ];
      final reader = await _buildAndOpen(entries);
      expect(reader.entryCount, equals(10));
    });
  });

  group('SstableWriter: block boundaries', () {
    test('many entries span multiple blocks and all are readable', () async {
      // Each key is ~34 bytes and each value is 100 bytes. 4KB / 134B ≈ 30
      // entries per block; 200 entries → ~7 blocks.
      final adapter = MemoryStorageAdapter();
      final writer = SstableWriter();
      final keys = <Uint8List>[];
      for (var i = 0; i < 200; i++) {
        final k = _ikey('ns', i.toRadixString(16), Hlc(i, 0));
        final v = Uint8List(100)..fillRange(0, 100, i & 0xFF);
        writer.add(k, v);
        keys.add(k);
      }
      final bytes = writer.finish();
      await adapter.writeFile('/sst/large.sst', bytes);
      final reader = await SstableReader.open('/sst/large.sst', adapter);
      expect(reader.entryCount, equals(200));

      // Spot-check several entries.
      for (final k in [keys[0], keys[99], keys[199]]) {
        final result = await reader.get(k);
        expect(result, isNotNull);
      }
    });
  });

  group('SstableReader.scan', () {
    late SstableReader reader;
    late List<Uint8List> keys;

    setUp(() async {
      keys = [
        for (var i = 1; i <= 20; i++)
          _ikey('ns', i.toRadixString(16), const Hlc(1, 0)),
      ];
      // Keys must be in sorted order for the writer.
      keys.sort((a, b) {
        final min = a.length < b.length ? a.length : b.length;
        for (var i = 0; i < min; i++) {
          if (a[i] != b[i]) return a[i] - b[i];
        }
        return a.length - b.length;
      });
      reader = await _buildAndOpen([
        for (var i = 0; i < keys.length; i++) (keys[i], _val(i + 1)),
      ]);
    });

    test('full scan returns all entries in order', () async {
      final entries = await reader.scan().toList();
      expect(entries.length, equals(20));
      for (var i = 0; i < entries.length - 1; i++) {
        final cmp = _cmpKey(entries[i].key, entries[i + 1].key);
        expect(cmp, lessThan(0));
      }
    });

    test('scan with start bound', () async {
      final start = keys[10];
      final entries = await reader.scan(start: start).toList();
      for (final e in entries) {
        expect(_cmpKey(e.key, start), greaterThanOrEqualTo(0));
      }
    });

    test('scan with end bound (exclusive)', () async {
      final end = keys[10];
      final entries = await reader.scan(end: end).toList();
      for (final e in entries) {
        expect(_cmpKey(e.key, end), lessThan(0));
      }
    });

    test('scan with start and end bounds', () async {
      final start = keys[5];
      final end = keys[15];
      final entries = await reader.scan(start: start, end: end).toList();
      expect(entries.isNotEmpty, isTrue);
      for (final e in entries) {
        expect(_cmpKey(e.key, start), greaterThanOrEqualTo(0));
        expect(_cmpKey(e.key, end), lessThan(0));
      }
    });
  });

  group('SstableReader: corruption detection', () {
    test('corrupted footer checksum throws CorruptedSstableException', () async {
      final k = _ikey('ns', 'a', const Hlc(1, 0));
      final writer = SstableWriter()..add(k, _val(1));
      final bytes = writer.finish();
      // Corrupt the checksum field (last 8 bytes of the 48-byte footer).
      bytes[bytes.length - 1] ^= 0xFF;
      final adapter = MemoryStorageAdapter();
      await adapter.writeFile('/sst/corrupt.sst', bytes);
      expect(
        () => SstableReader.open('/sst/corrupt.sst', adapter),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('file shorter than 48 bytes throws CorruptedSstableException', () async {
      final adapter = MemoryStorageAdapter();
      await adapter.writeFile('/sst/tiny.sst', Uint8List(10));
      expect(
        () => SstableReader.open('/sst/tiny.sst', adapter),
        throwsA(isA<CorruptedSstableException>()),
      );
    });
  });

  group('SstableWriter: empty file', () {
    test('finish() throws on empty writer', () {
      expect(() => SstableWriter().finish(), throwsA(isA<StateError>()));
    });
  });

  group('SstableInfo', () {
    test('parses regular flush filename', () {
      const name = 'a1b2c3d4-017F8A0A0000-017F8A0AFFFF.sst';
      final info = SstableInfo.parse(name);
      expect(info.deviceId, equals('a1b2c3d4'));
      expect(info.epoch, isNull);
      expect(info.isConsolidation, isFalse);
      expect(info.minHlc.physicalMs, equals(0x017F8A0A0000));
      expect(info.maxHlc.physicalMs, equals(0x017F8A0AFFFF));
    });

    test('parses consolidation filename', () {
      const name = 'a3f2b1c9-7-017F8A090000-017F8A0AFFFF.sst';
      final info = SstableInfo.parse(name);
      expect(info.deviceId, equals('a3f2b1c9'));
      expect(info.epoch, equals(7));
      expect(info.isConsolidation, isTrue);
    });

    test('throws on missing .sst extension', () {
      expect(
        () => SstableInfo.parse('a1b2c3d4-017F8A0A0000-017F8A0AFFFF'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws on wrong segment count', () {
      expect(
        () => SstableInfo.parse('a1b2c3d4-017F8A0A0000.sst'),
        throwsA(isA<FormatException>()),
      );
    });

    test('flushName generates correct filename', () {
      final name = SstableInfo.flushName(
        'a1b2c3d4',
        const Hlc(0x017F8A0A0000, 0),
        const Hlc(0x017F8A0AFFFF, 0),
      );
      expect(name, equals('a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst'));
    });

    test('consolidationName generates correct filename', () {
      final name = SstableInfo.consolidationName(
        'a3f2b1c9',
        7,
        const Hlc(0x017F8A090000, 0),
        const Hlc(0x017F8A0AFFFF, 0),
      );
      expect(name, equals('a3f2b1c9-7-017F8A090000-017F8A0AFFFF.sst'));
    });

    test('parse round-trips through flushName', () {
      final original = SstableInfo.flushName(
        'deadbeef',
        const Hlc(1000, 0),
        const Hlc(2000, 0),
      );
      final info = SstableInfo.parse(original);
      expect(info.deviceId, equals('deadbeef'));
      expect(info.minHlc.physicalMs, equals(1000));
      expect(info.maxHlc.physicalMs, equals(2000));
    });
  });
}

int _cmpKey(Uint8List a, Uint8List b) {
  final min = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < min; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
