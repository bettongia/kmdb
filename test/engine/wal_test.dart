import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/wal/wal_reader.dart';
import 'package:kmdb/src/engine/wal/wal_record.dart';
import 'package:kmdb/src/engine/wal/wal_writer.dart';

const _dir = '/db';
final _seq1 = const Hlc(1000, 0);
final _seq2 = const Hlc(2000, 1);
final _key = KeyCodec.keyToBytes('a' * 32);
final _value = Uint8List.fromList([0x00, 0x01, 0x02]);

WalWriter _writer(MemoryStorageAdapter adapter, {int seq = 1}) => WalWriter(
      dirPath: _dir,
      adapter: adapter,
      initialSequence: seq,
      fsyncOnWrite: false,
    );

WalReader _reader(MemoryStorageAdapter adapter) =>
    WalReader(adapter: adapter);

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
      final r = WalRecord(
        type: WalRecordType.flushMarker,
        sequence: _seq1,
      );
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

    test('rotate writes flush marker and increments sequence', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter, seq: 3);

      expect(writer.activeSequence, equals(3));
      await writer.writePut(
          sequence: _seq1, namespace: 'n', keyBytes: _key, value: _value);
      final oldPath = await writer.rotate(_seq2);
      expect(oldPath, contains('wal-00003.log'));
      expect(writer.activeSequence, equals(4));
      expect(writer.activePath, contains('wal-00004.log'));

      // Old file ends with a flush marker.
      final reader = _reader(adapter);
      final records = await reader.replay(oldPath).toList();
      expect(records.last.type, equals(WalRecordType.flushMarker));
    });
  });

  group('WalReader.replayFromLastFlush', () {
    test('skips records before flush marker', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      // Write two records, then a flush marker, then one more record.
      await writer.writePut(
          sequence: const Hlc(1, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value);
      await writer.writePut(
          sequence: const Hlc(2, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value);
      // Manually write a flush marker mid-file.
      await writer.append(WalRecord(
        type: WalRecordType.flushMarker,
        sequence: const Hlc(3, 0),
      ));
      await writer.writePut(
          sequence: const Hlc(4, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value);

      final reader = _reader(adapter);
      final records =
          await reader.replayFromLastFlush(writer.activePath).toList();
      // Only the record after the flush marker should be returned.
      expect(records.length, equals(1));
      expect(records[0].sequence, equals(const Hlc(4, 0)));
    });

    test('returns all records when no flush marker present', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      for (var i = 1; i <= 3; i++) {
        await writer.writePut(
          sequence: Hlc(i, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );
      }

      final reader = _reader(adapter);
      final records =
          await reader.replayFromLastFlush(writer.activePath).toList();
      expect(records.length, equals(3));
    });

    test('returns empty stream for non-existent file', () async {
      final adapter = MemoryStorageAdapter();
      final reader = _reader(adapter);
      final records = await reader.replay('/missing.log').toList();
      expect(records, isEmpty);
    });
  });

  group('WalReader.replayAll', () {
    test('replays multiple files in order', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter, seq: 1);

      // File 1: two puts + flush marker.
      await writer.writePut(
          sequence: const Hlc(1, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value);
      final file1 = await writer.rotate(const Hlc(2, 0));

      // File 2: one put.
      await writer.writePut(
          sequence: const Hlc(3, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value);

      final reader = _reader(adapter);
      final records =
          await reader.replayAll([file1, writer.activePath]).toList();
      // file1 has flush marker at end — replay from flush gives 0 records.
      // file2 has no flush marker — all 1 record returned.
      expect(records.length, equals(1));
      expect(records[0].sequence, equals(const Hlc(3, 0)));
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
}
