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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/wal/wal_exceptions.dart';
import 'package:kmdb/src/engine/wal/wal_reader.dart';
import 'package:kmdb/src/engine/wal/wal_record.dart';
import 'package:kmdb/src/engine/wal/wal_writer.dart';

const _dir = '/db';
final _seq1 = const Hlc(1000, 0);
final _seq2 = const Hlc(2000, 1);
// Use a valid UUIDv7 key.
final _key = KeyCodec.keyToBytes('aaaaaaaaaaaa7aa8aaaaaaaaaaaaaaaa');
final _value = Uint8List.fromList([0x00, 0x01, 0x02]);

WalWriter _writer(MemoryStorageAdapter adapter, {int seq = 1}) => WalWriter(
  dirPath: _dir,
  adapter: adapter,
  initialSequence: seq,
  fsyncOnWrite: false,
);

WalReader _reader(MemoryStorageAdapter adapter) => WalReader(adapter: adapter);

void main() {
  group('WalRecord encoding', () {
    test('put record round-trips', () {
      final r = WalRecord(
        type: WalRecordType.put,
        sequence: _seq1,
        namespace: 'contacts',
        key: _key,
        value: _value,
      );
      final bytes = r.encode();
      final result = WalRecord.tryDecode(bytes, 0);
      expect(result, isNotNull);
      final (decoded, consumed) = result!;
      expect(consumed, equals(bytes.length));
      expect(decoded.type, equals(WalRecordType.put));
      expect(decoded.sequence, equals(_seq1));
      expect(decoded.namespace, equals('contacts'));
      expect(decoded.key, equals(_key));
      expect(decoded.value, equals(_value));
    });

    test('delete record round-trips (no value)', () {
      final r = WalRecord(
        type: WalRecordType.delete,
        sequence: _seq2,
        namespace: 'tasks',
        key: _key,
      );
      final bytes = r.encode();
      final (decoded, _) = WalRecord.tryDecode(bytes, 0)!;
      expect(decoded.type, equals(WalRecordType.delete));
      expect(decoded.value, isEmpty);
    });

    test('flush marker round-trips (no ns/key/value)', () {
      final r = WalRecord(type: WalRecordType.flushMarker, sequence: _seq1);
      final bytes = r.encode();
      final (decoded, consumed) = WalRecord.tryDecode(bytes, 0)!;
      expect(decoded.type, equals(WalRecordType.flushMarker));
      expect(consumed, equals(bytes.length));
    });

    test('corrupted checksum returns null', () {
      final r = WalRecord(
        type: WalRecordType.put,
        sequence: _seq1,
        namespace: 'ns',
        key: _key,
        value: _value,
      );
      final bytes = r.encode();
      bytes[0] ^= 0xFF; // flip bits in checksum
      expect(WalRecord.tryDecode(bytes, 0), isNull);
    });

    test('truncated buffer returns null', () {
      final r = WalRecord(
        type: WalRecordType.put,
        sequence: _seq1,
        namespace: 'ns',
        key: _key,
        value: _value,
      );
      final bytes = r.encode();
      // Truncate to half.
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length ~/ 2);
      expect(WalRecord.tryDecode(truncated, 0), isNull);
    });
  });

  group('WalWriter', () {
    test('writes and reads back multiple records', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      await writer.writePut(
        sequence: _seq1,
        namespace: 'ns',
        keyBytes: _key,
        value: _value,
      );
      await writer.writeDelete(
        sequence: _seq2,
        namespace: 'ns',
        keyBytes: _key,
      );

      final reader = _reader(adapter);
      final records = await reader.replay(writer.activePath).toList();
      expect(records.length, equals(2));
      expect(records[0].type, equals(WalRecordType.put));
      expect(records[1].type, equals(WalRecordType.delete));
    });

    test('rotate increments sequence and returns the retired path', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter, seq: 3);

      expect(writer.activeSequence, equals(3));
      await writer.writePut(
        sequence: _seq1,
        namespace: 'n',
        keyBytes: _key,
        value: _value,
      );
      final oldPath = await writer.rotate();
      expect(oldPath, contains('wal-00003.log'));
      expect(writer.activeSequence, equals(4));
      expect(writer.activePath, contains('wal-00004.log'));

      // Rotate no longer writes a boundary marker: the retired file holds only
      // the records that were appended to it.
      final reader = _reader(adapter);
      final records = await reader.replay(oldPath).toList();
      expect(records, hasLength(1));
      expect(records.single.type, equals(WalRecordType.put));
    });
  });

  group('WalReader.replay', () {
    test(
      'returns every record in full, including legacy flush markers',
      () async {
        final adapter = MemoryStorageAdapter();
        final writer = _writer(adapter);

        await writer.writePut(
          sequence: const Hlc(1, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );
        // A legacy marker (as written by older builds) must still decode and be
        // returned by full replay; crash recovery skips it as a no-op.
        await writer.append(
          WalRecord(type: WalRecordType.flushMarker, sequence: const Hlc(2, 0)),
        );
        await writer.writePut(
          sequence: const Hlc(3, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );

        final reader = _reader(adapter);
        final records = await reader.replay(writer.activePath).toList();
        expect(records, hasLength(3));
        expect(records[0].type, equals(WalRecordType.put));
        expect(records[1].type, equals(WalRecordType.flushMarker));
        expect(records[2].type, equals(WalRecordType.put));
      },
    );

    test('returns empty stream for non-existent file', () async {
      final adapter = MemoryStorageAdapter();
      final reader = _reader(adapter);
      final records = await reader.replay('/missing.log').toList();
      expect(records, isEmpty);
    });
  });

  group('WalRecordType', () {
    test('fromByte round-trips all types', () {
      expect(WalRecordType.fromByte(0x01), equals(WalRecordType.put));
      expect(WalRecordType.fromByte(0x02), equals(WalRecordType.delete));
      expect(WalRecordType.fromByte(0x03), equals(WalRecordType.flushMarker));
    });

    test('fromByte throws for unknown byte', () {
      expect(
        () => WalRecordType.fromByte(0xFF),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ── CorruptedWalException / replayStrict ────────────────────────────────────

  group('CorruptedWalException', () {
    test('toString without path or offset', () {
      const e = CorruptedWalException('bad checksum');
      expect(e.toString(), contains('CorruptedWalException'));
      expect(e.toString(), contains('bad checksum'));
    });

    test('toString includes path and offset when provided', () {
      const e = CorruptedWalException(
        'bad checksum',
        path: '/db/wal-00001.log',
        offset: 42,
      );
      expect(e.toString(), contains('/db/wal-00001.log'));
      expect(e.toString(), contains('42'));
    });

    test('implements Exception', () {
      expect(const CorruptedWalException('x'), isA<Exception>());
    });
  });

  group('WalReader.replayStrict', () {
    late MemoryStorageAdapter adapter;
    late WalReader reader;

    setUp(() {
      adapter = MemoryStorageAdapter();
      reader = _reader(adapter);
    });

    test('replays all valid records without error', () async {
      final writer = _writer(adapter);
      await writer.append(
        WalRecord(
          type: WalRecordType.put,
          sequence: _seq1,
          namespace: 'ns',
          key: _key,
          value: _value,
        ),
      );
      await writer.append(
        WalRecord(
          type: WalRecordType.put,
          sequence: _seq2,
          namespace: 'ns',
          key: _key,
          value: _value,
        ),
      );

      final records = <WalRecord>[];
      await for (final r in reader.replayStrict('$_dir/wal-00001.log')) {
        records.add(r);
      }
      expect(records, hasLength(2));
    });

    test('returns empty stream when file does not exist', () async {
      final records = <WalRecord>[];
      await for (final r in reader.replayStrict('$_dir/nonexistent.log')) {
        records.add(r);
      }
      expect(records, isEmpty);
    });

    test('throws CorruptedWalException on checksum failure', () async {
      // Write one valid record, then corrupt the file by appending bytes that
      // look like a record header (≥ 17 bytes) but have a bad checksum.
      final writer = _writer(adapter);
      await writer.append(
        WalRecord(
          type: WalRecordType.put,
          sequence: _seq1,
          namespace: 'ns',
          key: _key,
          value: _value,
        ),
      );
      final path = '$_dir/wal-00001.log';
      final existing = await adapter.readFile(path);
      final corrupted = Uint8List(existing.length + 32);
      corrupted.setAll(0, existing);
      // Fill the appended region with 0xAA — guaranteed bad checksum.
      corrupted.fillRange(existing.length, corrupted.length, 0xAA);
      await adapter.writeFile(path, corrupted);

      expect(() async {
        await for (final _ in reader.replayStrict(path)) {}
      }, throwsA(isA<CorruptedWalException>()));
    });
  });
}
