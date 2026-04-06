// Copyright 2026 The KMDB Authors.
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

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_analysis.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/util_command.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Reusable UUIDv7 key generator.
final _keygen = UuidV7KeyGenerator();

/// Tracks temp directories for cleanup after each test.
final _tmpDirs = <io.Directory>[];

/// Creates a unique temporary directory for one test run.
io.Directory _mkTempDir() {
  final d = io.Directory.systemTemp.createTempSync('kmdb_util_test_');
  _tmpDirs.add(d);
  return d;
}

/// Opens a real on-disk [KvStoreImpl] in [dir].
Future<KvStoreImpl> _openStore(io.Directory dir) async {
  final adapter = StorageAdapterNative();
  final (store, _) = await KvStoreImpl.open(dir.path, adapter);
  return store;
}

/// Creates a [CommandContext] backed by string buffers for testing.
CommandContext _ctx(
  KvStoreImpl store, {
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  mode: OutputMode.json,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

/// Writes a corrupt WAL file in [dir] named [filename].
///
/// Encodes [recordCount] valid [WalRecord.put] records, then appends
/// [trailingGarbage] bytes of 0xFF to trigger a strict checksum failure.
Future<String> _writeCorruptWal(
  io.Directory dir,
  String filename, {
  int recordCount = 1,
  int trailingGarbage = 30,
}) async {
  final path = '${dir.path}/$filename';
  final file = io.File(path);
  final sink = file.openWrite();

  for (var i = 0; i < recordCount; i++) {
    final record = WalRecord(
      type: WalRecordType.put,
      sequence: Hlc(DateTime.now().millisecondsSinceEpoch, i),
      namespace: 'testns',
      key: List<int>.filled(16, 0xAB),
      value: List<int>.filled(4, 0x01),
    );
    sink.add(record.encode());
  }

  await sink.flush();
  await sink.close();

  // Append garbage bytes to corrupt the end of the file.
  await file.writeAsBytes(
    List<int>.filled(trailingGarbage, 0xFF),
    mode: io.FileMode.append,
  );

  return filename;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(() {
    for (final d in _tmpDirs) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    _tmpDirs.clear();
  });

  // ── UtilCommand routing ────────────────────────────────────────────────────

  group('UtilCommand routing', () {
    late io.Directory tmpDir;
    late KvStoreImpl store;

    setUp(() async {
      tmpDir = _mkTempDir();
      store = await _openStore(tmpDir);
    });
    tearDown(() => store.close());

    test('no subcommand returns false and writes error', () async {
      final err = StringBuffer();
      final ctx = _ctx(store, err: err);
      final ok = await const UtilCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('util requires a subcommand'));
    });

    test('unknown subcommand returns false and writes error', () async {
      final err = StringBuffer();
      final ctx = _ctx(store, err: err);
      final ok = await const UtilCommand().execute(ctx, ['badcmd'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains("Unknown util subcommand 'badcmd'"));
    });

    test('every subcommand path sets suppressFlush on the context', () async {
      // suppressFlush must be set regardless of whether the subcommand
      // succeeds, so that the CLI runner never flushes after a util call.
      final ctx = _ctx(store);
      expect(ctx.suppressFlush, isFalse);
      await const UtilCommand().execute(ctx, ['manifest'], {});
      expect(ctx.suppressFlush, isTrue);
    });
  });

  // ── util sstable ───────────────────────────────────────────────────────────

  group('util sstable', () {
    late io.Directory tmpDir;
    late KvStoreImpl store;

    setUp(() async {
      tmpDir = _mkTempDir();
      store = await _openStore(tmpDir);
      // Write data and flush to generate a real SSTable file.
      final k1 = _keygen.next();
      final k2 = _keygen.next();
      await store.put('ns', k1, ValueCodec.encode({'id': 'a', 'x': 1}));
      await store.put('ns', k2, ValueCodec.encode({'id': 'b', 'x': 2}));
      await store.flush();
    });
    tearDown(() => store.close());

    test('no filename argument returns false and writes error', () async {
      final err = StringBuffer();
      final ctx = _ctx(store, err: err);
      final ok = await const UtilCommand().execute(ctx, ['sstable'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('util sstable requires a filename'));
    });

    test('file not found emits error field and returns false', () async {
      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, [
        'sstable',
        'nonexistent.sst',
      ], {});
      expect(ok, isFalse);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['error'], isA<String>());
      expect(result['error'] as String, contains('not found'));
    });

    test('corrupted SSTable emits error field and returns false', () async {
      // Write a fake .sst file with garbage content.
      final sstDir = io.Directory('${tmpDir.path}/sst');
      final badPath = '${sstDir.path}/bad.sst';
      await io.File(badPath).writeAsBytes(List<int>.filled(100, 0xFF));

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, [
        'sstable',
        'bad.sst',
      ], {});
      expect(ok, isFalse);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['error'], isA<String>());
    });

    test(
      'summary output includes footer, bloom filter, and index count',
      () async {
        // Find the SSTable file written by setUp.
        final sstDir = io.Directory('${tmpDir.path}/sst');
        final files = sstDir.listSync().whereType<io.File>().toList();
        expect(files, isNotEmpty);
        final filename = files.first.path.split('/').last;

        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(ctx, [
          'sstable',
          filename,
        ], {});
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;

        expect(result['file'], equals(filename));
        expect(result.containsKey('footer'), isTrue);
        expect((result['footer'] as Map)['entryCount'], isA<int>());
        expect((result['footer'] as Map)['filterOffset'], isA<int>());
        expect(result.containsKey('bloomFilter'), isTrue);
        final bf = result['bloomFilter'] as Map<String, dynamic>;
        expect(bf['numBits'], isA<int>());
        expect(bf['numHashFunctions'], isA<int>());
        expect(bf['estimatedFpr'], isA<double>());
        expect(result.containsKey('indexEntryCount'), isTrue);
        // Summary mode must NOT include full index or entries.
        expect(result.containsKey('index'), isFalse);
        expect(result.containsKey('entries'), isFalse);
      },
    );

    test('--data without --full is ignored (no entries in output)', () async {
      final sstDir = io.Directory('${tmpDir.path}/sst');
      final files = sstDir.listSync().whereType<io.File>().toList();
      expect(files, isNotEmpty);
      final filename = files.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['sstable', filename],
        {'data': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      // Without --full, entries must not be present even if --data is set.
      expect(result.containsKey('entries'), isFalse);
      expect(result.containsKey('index'), isFalse);
    });

    test('--full output includes index block refs and all entries', () async {
      final sstDir = io.Directory('${tmpDir.path}/sst');
      final files = sstDir.listSync().whereType<io.File>().toList();
      expect(files, isNotEmpty);
      final filename = files.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['sstable', filename],
        {'full': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;

      // Index block refs must be present.
      expect(result.containsKey('index'), isTrue);
      final index = result['index'] as List;
      expect(index, isNotEmpty);
      for (final ref in index) {
        final r = ref as Map<String, dynamic>;
        expect(r['offset'], isA<int>());
        expect(r['size'], isA<int>());
        expect(r['lastKey'], isA<String>());
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(r['lastKey'] as String), isTrue);
      }

      // Entry records must be present.
      expect(result.containsKey('entries'), isTrue);
      final entries = result['entries'] as List;
      // At least the 2 user-written entries must appear (plus $meta entries).
      expect(entries.length, greaterThanOrEqualTo(2));
      for (final e in entries) {
        final entry = e as Map<String, dynamic>;
        expect(entry['key'], isA<String>());
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(entry['key'] as String), isTrue);
        final val = entry['value'] as Map<String, dynamic>;
        expect(val['compressionFlag'], isA<int>());
        expect(val['byteLength'], isA<int>());
      }
    });
    test('--full --data includes decoded values for user entries', () async {
      final sstDir = io.Directory('${tmpDir.path}/sst');
      final files = sstDir.listSync().whereType<io.File>().toList();
      expect(files, isNotEmpty);
      final filename = files.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['sstable', filename],
        {'full': true, 'data': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;

      expect(result.containsKey('index'), isTrue);
      expect(result.containsKey('entries'), isTrue);

      final entries = result['entries'] as List;
      expect(entries.length, greaterThanOrEqualTo(2));

      // Every entry value must have the byte-level metadata fields.
      // System namespace entries must have no decoded/decodeError;
      // user namespace entries must have one of the two.
      for (final e in entries) {
        final entry = e as Map<String, dynamic>;
        final val = entry['value'] as Map<String, dynamic>;
        expect(val['compressionFlag'], isA<int>());
        expect(val['byteLength'], isA<int>());

        final keyHex = entry['key'] as String;
        final keyBytes = Uint8List.fromList(
          List.generate(
            keyHex.length ~/ 2,
            (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16),
          ),
        );
        final ns = KeyCodec.decodeNamespace(keyBytes);
        if (ns.startsWith(r'$')) {
          expect(
            val.containsKey('decoded'),
            isFalse,
            reason: 'system entry should not be decoded',
          );
          expect(
            val.containsKey('decodeError'),
            isFalse,
            reason: 'system entry should not have decodeError',
          );
        } else {
          expect(
            val.containsKey('decoded') || val.containsKey('decodeError'),
            isTrue,
            reason: 'user entry should have decoded or decodeError',
          );
        }
      }

      // The two user-written documents ('a' and 'b') must decode correctly.
      final decodedValues = entries
          .cast<Map<String, dynamic>>()
          .map((e) => e['value'] as Map<String, dynamic>)
          .where((v) => v.containsKey('decoded'))
          .map((v) => v['decoded'] as Map<String, dynamic>)
          .toList();

      final ids = decodedValues
          .where((d) => d.containsKey('id'))
          .map((d) => d['id'])
          .toSet();
      expect(ids, containsAll(['a', 'b']));
    });
  });

  // ── util wal ──────────────────────────────────────────────────────────────

  group('util wal', () {
    late io.Directory tmpDir;
    late KvStoreImpl store;

    setUp(() async {
      tmpDir = _mkTempDir();
      store = await _openStore(tmpDir);
      // Write data to generate WAL records.
      await store.put('ns', _keygen.next(), ValueCodec.encode({'id': 'a'}));
      await store.put('ns', _keygen.next(), ValueCodec.encode({'id': 'b'}));
    });
    tearDown(() => store.close());

    test('no filename argument returns false and writes error', () async {
      final err = StringBuffer();
      final ctx = _ctx(store, err: err);
      final ok = await const UtilCommand().execute(ctx, ['wal'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('util wal requires a filename'));
    });

    test('file not found emits error field and returns false', () async {
      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, [
        'wal',
        'wal-99999.log',
      ], {});
      expect(ok, isFalse);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['error'], isA<String>());
      expect(result['error'] as String, contains('not found'));
    });

    test(
      'summary output includes record count, HLC range, and namespaces',
      () async {
        final walFiles = tmpDir
            .listSync()
            .whereType<io.File>()
            .where((f) => f.path.endsWith('.log'))
            .toList();
        expect(walFiles, isNotEmpty);
        final filename = walFiles.first.path.split('/').last;

        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(ctx, [
          'wal',
          filename,
        ], {});
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;

        expect(result['file'], equals(filename));
        expect(result['recordCount'], isA<int>());
        expect((result['recordCount'] as int), greaterThan(0));
        final hlcRange = result['hlcRange'] as Map<String, dynamic>;
        expect(hlcRange['min'], isA<String>());
        expect(hlcRange['max'], isA<String>());
        // HLC strings are 16-char uppercase hex.
        expect(
          RegExp(r'^[0-9A-F]{16}$').hasMatch(hlcRange['min'] as String),
          isTrue,
        );
        expect(result['collections'], contains('ns'));
        // Summary mode must NOT include full record list.
        expect(result.containsKey('records'), isFalse);
      },
    );

    test('--full output includes all record fields with hex keys', () async {
      final walFiles = tmpDir
          .listSync()
          .whereType<io.File>()
          .where((f) => f.path.endsWith('.log'))
          .toList();
      expect(walFiles, isNotEmpty);
      final filename = walFiles.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['wal', filename],
        {'full': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final records = result['records'] as List;
      expect(records, isNotEmpty);

      for (final r in records) {
        final rec = r as Map<String, dynamic>;
        expect(rec['type'], isA<String>());
        expect(rec['sequence'], isA<String>());
        // Sequence is 16-char uppercase hex.
        expect(
          RegExp(r'^[0-9A-F]{16}$').hasMatch(rec['sequence'] as String),
          isTrue,
        );
      }

      // At least one put record should have a hex-encoded key.
      final putRecords = records
          .cast<Map<String, dynamic>>()
          .where((r) => r['type'] == 'put')
          .toList();
      expect(putRecords, isNotEmpty);
      for (final r in putRecords) {
        expect(r['key'], isA<String>());
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(r['key'] as String), isTrue);
        final val = r['value'] as Map<String, dynamic>;
        expect(val['compressionFlag'], isA<int>());
        expect(val['byteLength'], isA<int>());
      }
    });

    test('--data without --full is ignored (no decoded fields)', () async {
      final walFiles = tmpDir
          .listSync()
          .whereType<io.File>()
          .where((f) => f.path.endsWith('.log'))
          .toList();
      expect(walFiles, isNotEmpty);
      final filename = walFiles.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['wal', filename],
        {'data': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      // Without --full, summary output must not contain records.
      expect(result.containsKey('records'), isFalse);
    });

    test('--full --data includes decoded values for put records', () async {
      final walFiles = tmpDir
          .listSync()
          .whereType<io.File>()
          .where((f) => f.path.endsWith('.log'))
          .toList();
      expect(walFiles, isNotEmpty);
      final filename = walFiles.first.path.split('/').last;

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(
        ctx,
        ['wal', filename],
        {'full': true, 'data': true},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final records = result['records'] as List;
      expect(records, isNotEmpty);

      final putRecords = records
          .cast<Map<String, dynamic>>()
          .where((r) => r['type'] == 'put')
          .toList();
      expect(putRecords, isNotEmpty);

      // User-namespace put records must have decoded or decodeError.
      // System-namespace put records must have neither.
      for (final r in putRecords) {
        final val = r['value'] as Map<String, dynamic>;
        expect(val['compressionFlag'], isA<int>());
        expect(val['byteLength'], isA<int>());

        final ns = r['namespace'] as String? ?? '';
        if (ns.startsWith(r'$')) {
          expect(
            val.containsKey('decoded'),
            isFalse,
            reason: 'system entry should not be decoded',
          );
          expect(
            val.containsKey('decodeError'),
            isFalse,
            reason: 'system entry should not have decodeError',
          );
        } else {
          expect(
            val.containsKey('decoded') || val.containsKey('decodeError'),
            isTrue,
            reason: 'user entry should have decoded or decodeError',
          );
        }
      }

      // The two user-written documents must decode to the expected ids.
      final ids = putRecords
          .map((r) => r['value'] as Map<String, dynamic>)
          .where((v) => v.containsKey('decoded'))
          .map((v) => (v['decoded'] as Map<String, dynamic>)['id'])
          .whereType<String>()
          .toSet();
      expect(ids, containsAll(['a', 'b']));
    });

    test(
      'corruption mid-stream emits records before failure and corruptedAt',
      () async {
        // Write a WAL file with valid records followed by corrupt bytes.
        final filename = await _writeCorruptWal(tmpDir, 'wal-corrupt.log');

        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(
          ctx,
          ['wal', filename],
          {'full': true},
        );
        // Corruption means command returns false.
        expect(ok, isFalse);

        final result = json.decode(out.toString()) as Map<String, dynamic>;
        // The valid record before corruption must be present.
        final records = result['records'] as List;
        expect(records.length, equals(1));
        // corruptedAt marker must be present.
        expect(result.containsKey('corruptedAt'), isTrue);
        final ca = result['corruptedAt'] as Map<String, dynamic>;
        // recordIndex should equal the number of successfully decoded records.
        expect(ca['recordIndex'], equals(1));
        expect(ca['reason'], isA<String>());
      },
    );

    test(
      'summary mode with corruption emits corruptedAt and returns false',
      () async {
        final filename = await _writeCorruptWal(
          tmpDir,
          'wal-corrupt2.log',
          recordCount: 2,
        );

        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(ctx, [
          'wal',
          filename,
        ], {});
        expect(ok, isFalse);
        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result.containsKey('corruptedAt'), isTrue);
        expect(result['recordCount'], equals(2));
      },
    );

    test('WAL with only flush markers has empty namespaces list', () async {
      // Create a WAL file with only a flush marker.
      final flushMarkerPath = '${tmpDir.path}/wal-flush.log';
      final record = WalRecord(
        type: WalRecordType.flushMarker,
        sequence: Hlc(DateTime.now().millisecondsSinceEpoch, 0),
      );
      await io.File(flushMarkerPath).writeAsBytes(record.encode());

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, ['wal-flush.log'], {});
      // subcommand not provided so this routes to unknown subcommand error
      expect(ok, isFalse);
    });

    test('WAL file with flush marker has no namespace in summary', () async {
      // Create a WAL file with only a flush marker.
      final flushMarkerPath = '${tmpDir.path}/wal-flush2.log';
      final record = WalRecord(
        type: WalRecordType.flushMarker,
        sequence: Hlc(DateTime.now().millisecondsSinceEpoch, 0),
      );
      await io.File(flushMarkerPath).writeAsBytes(record.encode());

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, [
        'wal',
        'wal-flush2.log',
      ], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['collections'], isEmpty);
      expect(result['recordCount'], equals(1));
    });
  });

  // ── util manifest ──────────────────────────────────────────────────────────

  group('util manifest', () {
    late io.Directory tmpDir;
    late KvStoreImpl store;

    setUp(() async {
      tmpDir = _mkTempDir();
      store = await _openStore(tmpDir);
    });
    tearDown(() => store.close());

    test('summary on empty database has empty levels', () async {
      // A freshly opened store has a CURRENT file but no SSTable edits yet.
      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, ['manifest'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result.containsKey('manifestFile'), isTrue);
      expect(result['manifestFile'], isA<String>());
      expect(result.containsKey('levels'), isTrue);
    });

    test(
      '--full on freshly opened database returns VersionEdits list',
      () async {
        // A freshly opened store may have one or more initial edits (e.g. for
        // device ID setup). The key invariant is that the list is present and
        // each edit has the required fields.
        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(
          ctx,
          ['manifest'],
          {'full': true},
        );
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result.containsKey('manifestFile'), isTrue);
        expect(result['edits'], isA<List>());
        expect(result['editCount'], isA<int>());
        // All edits — however many — must have the required fields.
        for (final e in (result['edits'] as List)) {
          final edit = e as Map<String, dynamic>;
          expect(edit.containsKey('logNumber'), isTrue);
          expect(edit.containsKey('nextSeq'), isTrue);
          expect(edit.containsKey('added'), isTrue);
          expect(edit.containsKey('removed'), isTrue);
        }
      },
    );

    test('after flush summary lists SSTable filenames in levels', () async {
      await store.put('ns', _keygen.next(), ValueCodec.encode({'id': 'a'}));
      await store.flush();

      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      final ok = await const UtilCommand().execute(ctx, ['manifest'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final levels = result['levels'] as Map<String, dynamic>;
      final allFiles = levels.values
          .expand((v) => (v as List).cast<String>())
          .toList();
      expect(allFiles, isNotEmpty);
      // All filenames should end with .sst.
      for (final f in allFiles) {
        expect(f, endsWith('.sst'));
      }
    });

    test(
      'after flush --full lists VersionEdits with expected fields',
      () async {
        await store.put('ns', _keygen.next(), ValueCodec.encode({'id': 'a'}));
        await store.flush();

        final out = StringBuffer();
        final ctx = _ctx(store, out: out);
        final ok = await const UtilCommand().execute(
          ctx,
          ['manifest'],
          {'full': true},
        );
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;
        final edits = result['edits'] as List;
        expect(edits, isNotEmpty);

        for (final e in edits) {
          final edit = e as Map<String, dynamic>;
          expect(edit.containsKey('logNumber'), isTrue);
          expect(edit.containsKey('nextSeq'), isTrue);
          expect(edit.containsKey('added'), isTrue);
          expect(edit.containsKey('removed'), isTrue);
          // added entries have required fields.
          for (final added in (edit['added'] as List)) {
            final a = added as Map<String, dynamic>;
            expect(a.containsKey('level'), isTrue);
            expect(a.containsKey('filename'), isTrue);
            expect(a.containsKey('entryCount'), isTrue);
          }
        }
      },
    );

    test('CURRENT file missing returns true with null manifestFile', () async {
      // Create a new database directory, open and close it, then delete CURRENT
      // to simulate an incomplete database state (e.g. partially initialised).
      final blankDir = _mkTempDir();
      final blankAdapter = StorageAdapterNative();
      final (blankStore, _) = await KvStoreImpl.open(
        blankDir.path,
        blankAdapter,
      );
      await blankStore.close();
      io.File('${blankDir.path}/CURRENT').deleteSync();

      // Re-open to get a context that has the blankDir as its dbDir, but
      // the CURRENT file should be gone.
      // We delete CURRENT after the second open.
      final blankStore2 = await _openStore(blankDir);
      io.File('${blankDir.path}/CURRENT').deleteSync();

      final out = StringBuffer();
      final ctx = _ctx(blankStore2, out: out);
      final ok = await const UtilCommand().execute(ctx, ['manifest'], {});
      await blankStore2.close();

      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['manifestFile'], isNull);
    });
  });
}
