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

    test(
      'entirely empty WAL file → treated as no WAL, returns empty stream',
      () async {
        // An empty file (zero bytes) is a valid edge case: power loss before any
        // record was written. The reader must return an empty stream, not crash.
        final adapter = MemoryStorageAdapter();
        const path = '$_dir/wal-empty.log';
        await adapter.writeFile(path, Uint8List(0));

        final reader = _reader(adapter);
        final records = await reader.replay(path).toList();
        expect(records, isEmpty);
      },
    );

    test(
      'multiple WAL files: second has valid frames after first corruption',
      () async {
        // Simulate a DB that has two WAL files: the first ends with corrupt
        // trailing bytes (power loss mid-write), and the second contains a
        // valid record written after a successful WAL rotation.
        final adapter = MemoryStorageAdapter();
        final writer = _writer(adapter);

        // Write a valid record to the first WAL file.
        await writer.writePut(
          sequence: const Hlc(1, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );
        // Corrupt the first WAL by appending garbage.
        final path1 = writer.activePath;
        final existing = await adapter.readFile(path1);
        final corrupted = Uint8List(existing.length + 32);
        corrupted.setAll(0, existing);
        // Leave appended region as zeros — will fail decode.
        await adapter.writeFile(path1, corrupted);

        // Rotate to a second WAL and write a valid record.
        await writer.rotate();
        await writer.writePut(
          sequence: const Hlc(2, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );
        final path2 = writer.activePath;

        // The reader must be able to replay each file independently.
        final reader = _reader(adapter);

        // First file: one good record + truncated corrupt tail → 1 record.
        final records1 = await reader.replay(path1).toList();
        expect(records1, hasLength(1));

        // Second file: fully valid → 1 record.
        final records2 = await reader.replay(path2).toList();
        expect(records2, hasLength(1));
      },
    );

    test('replays batch frame records in order (non-strict)', () async {
      // Write a WalBatchFrame directly so the batch-frame branch is exercised.
      final adapter = MemoryStorageAdapter();
      const path = '$_dir/wal-00001.log';

      // Build a batch frame containing two put records.
      final r1 = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(10, 0),
        namespace: 'ns',
        key: _key,
        value: _value,
      );
      final r2 = WalRecord(
        type: WalRecordType.put,
        sequence: const Hlc(11, 0),
        namespace: 'ns',
        key: _key,
        value: _value,
      );
      final frame = WalBatchFrame([r1, r2]);
      await adapter.writeFile(path, frame.encode());

      final reader = _reader(adapter);
      final records = await reader.replay(path).toList();
      // Both records from the batch should be replayed.
      expect(records.length, equals(2));
      expect(records.every((r) => r.type == WalRecordType.put), isTrue);
    });

    test('replay stops on corrupt batch frame (non-strict)', () async {
      // Write a valid record, then append a corrupt batch-frame marker.
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      await writer.writePut(
        sequence: const Hlc(1, 0),
        namespace: 'ns',
        keyBytes: _key,
        value: _value,
      );

      // Append bytes that start with the batch type byte but are corrupt.
      final path = writer.activePath;
      final existing = await adapter.readFile(path);
      // Construct a fake header: 8 bytes checksum + batch type byte + garbage.
      final fake = Uint8List(existing.length + 32);
      fake.setAll(0, existing);
      fake[existing.length + 8] = WalRecordType.batch.byte; // type byte
      // Leave rest as zeros → will fail decode.
      await adapter.writeFile(path, fake);

      final reader = _reader(adapter);
      final records = await reader.replay(path).toList();
      // Should get the first valid record and then stop.
      expect(records.length, equals(1));
      expect(records[0].type, equals(WalRecordType.put));
    });

    test('replay stops on short trailing bytes (non-strict)', () async {
      // Write one valid record then append only 5 bytes (< 9, cannot be header).
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      await writer.writePut(
        sequence: const Hlc(1, 0),
        namespace: 'ns',
        keyBytes: _key,
        value: _value,
      );

      final path = writer.activePath;
      final existing = await adapter.readFile(path);
      final truncated = Uint8List(existing.length + 5);
      truncated.setAll(0, existing);
      truncated.fillRange(existing.length, truncated.length, 0xFF);
      await adapter.writeFile(path, truncated);

      final reader = _reader(adapter);
      final records = await reader.replay(path).toList();
      // Should still get the first valid record; trailing garbage is ignored.
      expect(records.length, equals(1));
    });

    test('replayStrict throws on corrupt batch frame', () async {
      final adapter = MemoryStorageAdapter();
      final writer = _writer(adapter);

      await writer.writePut(
        sequence: const Hlc(1, 0),
        namespace: 'ns',
        keyBytes: _key,
        value: _value,
      );

      final path = writer.activePath;
      final existing = await adapter.readFile(path);
      // Append a fake batch-frame header (type byte) + garbage.
      final corrupted = Uint8List(existing.length + 32);
      corrupted.setAll(0, existing);
      corrupted[existing.length + 8] = WalRecordType.batch.byte;
      await adapter.writeFile(path, corrupted);

      final strictReader = _reader(adapter);
      await expectLater(
        strictReader.replayStrict(path).toList(),
        throwsA(isA<CorruptedWalException>()),
      );
    });

    test(
      'replayStrict throws on short trailing bytes (< 9 bytes, incomplete header)',
      () async {
        final adapter = MemoryStorageAdapter();
        final writer = _writer(adapter);

        await writer.writePut(
          sequence: const Hlc(1, 0),
          namespace: 'ns',
          keyBytes: _key,
          value: _value,
        );

        final path = writer.activePath;
        final existing = await adapter.readFile(path);
        // Append only 4 bytes — too short for a header.
        final truncated = Uint8List(existing.length + 4);
        truncated.setAll(0, existing);
        truncated.fillRange(existing.length, truncated.length, 0xAA);
        await adapter.writeFile(path, truncated);

        final strictReader = _reader(adapter);
        await expectLater(
          strictReader.replayStrict(path).toList(),
          throwsA(isA<CorruptedWalException>()),
        );
      },
    );
  });

  group('WalRecordType', () {
    test('fromByte round-trips all types', () {
      expect(WalRecordType.fromByte(0x01), equals(WalRecordType.put));
      expect(WalRecordType.fromByte(0x02), equals(WalRecordType.delete));
      expect(WalRecordType.fromByte(0x03), equals(WalRecordType.flushMarker));
      expect(WalRecordType.fromByte(0x04), equals(WalRecordType.batch));
    });

    test('fromByte throws for unknown byte', () {
      expect(
        () => WalRecordType.fromByte(0xFF),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('WalBatchFrame encoding', () {
    WalRecord makePut(Hlc seq, String ns, List<int> v) => WalRecord(
      type: WalRecordType.put,
      sequence: seq,
      namespace: ns,
      key: _key,
      value: Uint8List.fromList(v),
    );

    WalRecord makeDel(Hlc seq, String ns) => WalRecord(
      type: WalRecordType.delete,
      sequence: seq,
      namespace: ns,
      key: _key,
    );

    test('round-trips a multi-entry frame (puts + delete)', () {
      final frame = WalBatchFrame([
        makePut(const Hlc(1, 0), 'tasks', [0x10]),
        makeDel(const Hlc(2, 0), 'tasks'),
        makePut(const Hlc(3, 0), r'$index:tasks:title', [0x20, 0x30]),
      ]);
      final bytes = frame.encode();

      final result = WalBatchFrame.tryDecode(bytes, 0);
      expect(result, isNotNull);
      final (decoded, consumed) = result!;
      expect(consumed, equals(bytes.length));
      expect(decoded.records, hasLength(3));
      expect(decoded.records[0].type, equals(WalRecordType.put));
      expect(decoded.records[0].namespace, equals('tasks'));
      expect(decoded.records[0].value, equals([0x10]));
      expect(decoded.records[1].type, equals(WalRecordType.delete));
      expect(decoded.records[2].namespace, equals(r'$index:tasks:title'));
      expect(decoded.records[2].value, equals([0x20, 0x30]));
    });

    test('round-trips an empty frame', () {
      final bytes = const WalBatchFrame([]).encode();
      final result = WalBatchFrame.tryDecode(bytes, 0);
      expect(result, isNotNull);
      expect(result!.$1.records, isEmpty);
    });

    test('corrupted checksum returns null', () {
      final bytes = WalBatchFrame([
        makePut(const Hlc(1, 0), 'ns', [0x01]),
        makePut(const Hlc(2, 0), 'ns', [0x02]),
      ]).encode();
      bytes[0] ^= 0xFF;
      expect(WalBatchFrame.tryDecode(bytes, 0), isNull);
    });

    test(
      'truncation at every byte boundary returns null (no partial decode)',
      () {
        // Two-entry frame; truncate progressively from the end.
        final full = WalBatchFrame([
          makePut(const Hlc(1, 0), 'ns', [0x01, 0x02]),
          makeDel(const Hlc(2, 0), 'ns'),
        ]).encode();
        // Truncating any byte breaks either the structural read or the checksum.
        for (var cut = 1; cut < full.length; cut++) {
          final truncated = Uint8List.sublistView(full, 0, cut);
          expect(
            WalBatchFrame.tryDecode(truncated, 0),
            isNull,
            reason: 'truncation at byte $cut must yield null',
          );
        }
      },
    );

    test('payload bit-flip in any entry invalidates the whole frame', () {
      // A bit-flip past the header — i.e. inside one of the entries — must
      // still be caught by the frame-level checksum so the entire batch is
      // discarded, not just one entry.
      final bytes = WalBatchFrame([
        makePut(const Hlc(1, 0), 'ns', [0x11, 0x22, 0x33]),
        makePut(const Hlc(2, 0), 'ns', [0x44, 0x55, 0x66]),
      ]).encode();
      // Flip a bit deep in the second entry's value region.
      bytes[bytes.length - 1] ^= 0x01;
      expect(WalBatchFrame.tryDecode(bytes, 0), isNull);
    });

    test('wrong leading type byte returns null', () {
      // Construct a buffer that is not a batch frame (e.g. a put record's bytes)
      // and assert tryDecode rejects it without throwing.
      final put = makePut(const Hlc(1, 0), 'ns', [0x01]);
      final bytes = put.encode();
      expect(WalBatchFrame.tryDecode(bytes, 0), isNull);
    });

    test(
      'appendBatch writes a single frame (one append, one frame on disk)',
      () async {
        // Verify the on-disk representation: an N-entry batch produces ONE
        // batch-typed record, not N individual records. This is the wire-level
        // contract that lets the writer collapse N fsyncs into one.
        final adapter = MemoryStorageAdapter();
        final writer = WalWriter(
          dirPath: _dir,
          adapter: adapter,
          initialSequence: 1,
          fsyncOnWrite: true,
        );

        await writer.appendBatch([
          for (var i = 0; i < 5; i++)
            WalRecord(
              type: WalRecordType.put,
              sequence: Hlc(i + 1, 0),
              namespace: 'ns',
              key: _key,
              value: Uint8List.fromList([i]),
            ),
        ]);

        final bytes = adapter.files[writer.activePath]!;
        // Type byte is at offset 8 (immediately after the frame checksum).
        expect(
          bytes[8],
          equals(WalRecordType.batch.byte),
          reason:
              'batch must be encoded as one batch-typed frame, not N records',
        );
        // The whole file should be consumed by exactly one frame.
        final result = WalBatchFrame.tryDecode(bytes, 0);
        expect(result, isNotNull);
        expect(result!.$2, equals(bytes.length));
        expect(result.$1.records, hasLength(5));
      },
    );
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
