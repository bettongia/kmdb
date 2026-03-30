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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/collections_command.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/compact_command.dart';
import 'package:kmdb_cli/src/commands/count_command.dart';
import 'package:kmdb_cli/src/commands/delete_command.dart';
import 'package:kmdb_cli/src/commands/flush_command.dart';
import 'package:kmdb_cli/src/commands/get_command.dart';
import 'package:kmdb_cli/src/commands/import_command.dart';
import 'package:kmdb_cli/src/commands/info_command.dart';
import 'package:kmdb_cli/src/commands/put_command.dart';
import 'package:kmdb_cli/src/commands/scan_command.dart';
import 'package:kmdb_cli/src/commands/stats_command.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

int _dbCounter = 0;
int _keyCounter = 0;

/// Opens a fresh in-memory [KvStoreImpl] for each test.
Future<KvStoreImpl> _openStore() async {
  final adapter = MemoryStorageAdapter();
  final dir = '/cmdtest${_dbCounter++}';
  final (store, _) = await KvStoreImpl.open(dir, adapter);
  await store.ensureDeviceId();
  return store;
}

/// Returns a unique 32-character hex key for use as a document ID.
///
/// Keys at the KvStore boundary must be exactly 32 hex characters to satisfy
/// [KeyCodec] validation.
String _key([String? tag]) {
  final n = _keyCounter++;
  final hex = n.toRadixString(16).padLeft(4, '0');
  final prefix = (tag ?? 'key').replaceAll(RegExp(r'[^0-9a-f]'), '0')
      .padRight(28, '0')
      .substring(0, 28);
  return '$prefix$hex';
}

/// Builds a [CommandContext] with captured [out] and [err] buffers.
CommandContext _ctx(
  KvStoreImpl store, {
  OutputMode mode = OutputMode.json,
  StringBuffer? out,
  StringBuffer? err,
}) =>
    CommandContext(
      store: store,
      mode: mode,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

/// Encodes and stores a document, using `doc['id']` as the storage key.
///
/// The `id` field must be a 32-character hex string (use [_key] to generate).
Future<void> _putDoc(
  KvStoreImpl store,
  String namespace,
  Map<String, dynamic> doc,
) async {
  final key = '${doc['id']}';
  await store.put(namespace, key, ValueCodec.encode(doc));
}

// ── TmpFile helper ────────────────────────────────────────────────────────────

/// A simple synchronous temp-file helper for tests that exercise file I/O.
class _TmpFile {
  _TmpFile() {
    final tmp = io.Directory.systemTemp.createTempSync('kmdb_test_');
    path = '${tmp.path}/data.ndjson';
  }

  late final String path;

  void write(String content) => io.File(path).writeAsStringSync(content);

  void delete() {
    try {
      final f = io.File(path);
      final dir = f.parent;
      if (f.existsSync()) f.deleteSync();
      if (dir.existsSync()) dir.deleteSync();
    } catch (_) {}
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── GetCommand ──────────────────────────────────────────────────────────────

  group('GetCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('returns document when found', () async {
      final id = _key('abc');
      await _putDoc(store, 'tasks', {'id': id, 'title': 'Do thing'});
      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['tasks', id], {});
      expect(ok, isTrue);
      final decoded = json.decode(out.toString()) as List;
      expect(decoded[0]['title'], equals('Do thing'));
    });

    test('returns false and error when document not found', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['tasks', _key('miss')], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    test('returns false when key arg is missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['tasks'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
    });

    test('returns false when all args are missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });
  });

  // ── PutCommand ──────────────────────────────────────────────────────────────

  group('PutCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('upserts document and echoes it back', () async {
      final id = _key('xone');
      final ctx = _ctx(store, out: out, err: err);
      final doc = '{"id":"$id","name":"Alice"}';
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);
      final result = await store.get('notes', id);
      expect(result, isNotNull);
      expect(ValueCodec.decode(result!)['name'], equals('Alice'));
    });

    test('returns false for invalid JSON', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': '{bad}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid JSON'));
    });

    test('returns false when document is not a JSON object', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await PutCommand().execute(ctx, ['notes'], {'value': '[1,2]'});
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('returns false when document missing id', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await PutCommand().execute(ctx, ['notes'], {'value': '{"x":1}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('"id"'));
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final id = _key('nons');
      final ok =
          await PutCommand().execute(ctx, [], {'value': '{"id":"$id"}'});
      expect(ok, isFalse);
    });
  });

  // ── DeleteCommand ───────────────────────────────────────────────────────────

  group('DeleteCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('deletes existing document', () async {
      final id = _key('del1');
      await _putDoc(store, 'tasks', {'id': id, 'x': 1});
      final ctx = _ctx(store, out: out, err: err);
      final ok = await DeleteCommand().execute(ctx, ['tasks', id], {});
      expect(ok, isTrue);
      expect(await store.get('tasks', id), isNull);
      final result = json.decode(out.toString()) as Map;
      expect(result['deleted'], equals(id));
    });

    test('succeeds (no-op) when key does not exist', () async {
      // Delete is idempotent at the store level.
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await DeleteCommand().execute(ctx, ['tasks', _key('gost')], {});
      expect(ok, isTrue);
    });

    test('returns false when args are missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await DeleteCommand().execute(ctx, ['tasks'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
    });
  });

  // ── ScanCommand ─────────────────────────────────────────────────────────────

  group('ScanCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;
    late String idA;
    late String idB;
    late String idC;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
      idA = _key('scan');
      idB = _key('scan');
      idC = _key('scan');
      await _putDoc(store, 'items', {'id': idA, 'score': 10, 'tag': 'x'});
      await _putDoc(store, 'items', {'id': idB, 'score': 30, 'tag': 'y'});
      await _putDoc(store, 'items', {'id': idC, 'score': 20, 'tag': 'x'});
    });
    tearDown(() => store.close());

    test('scans all documents in namespace', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['items'], {});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
    });

    test('applies filter', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"tag","op":"eq","value":"x"}';
      final ok =
          await ScanCommand().execute(ctx, ['items'], {'filter': filter});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(2));
      expect(docs.every((d) => d['tag'] == 'x'), isTrue);
    });

    test('applies order-by ascending', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await ScanCommand().execute(ctx, ['items'], {'order-by': 'score'});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs.map((d) => d['score']).toList(), equals([10, 20, 30]));
    });

    test('applies order-by descending', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand()
          .execute(ctx, ['items'], {'order-by': 'score', 'desc': true});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs.map((d) => d['score']).toList(), equals([30, 20, 10]));
    });

    test('applies limit and offset', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'order-by': 'score', 'limit': 2, 'offset': 1},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(2));
      expect(docs[0]['score'], equals(20));
    });

    test('returns false for invalid filter JSON', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand()
          .execute(ctx, ['items'], {'filter': '{bad json}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('filter'));
    });

    test('returns false for unknown filter operator', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"x","op":"regex","value":".*"}';
      final ok =
          await ScanCommand().execute(ctx, ['items'], {'filter': filter});
      expect(ok, isFalse);
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });

    test('returns empty list for unknown namespace', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['empty'], {});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, isEmpty);
    });
  });

  // ── CountCommand ────────────────────────────────────────────────────────────

  group('CountCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
      await _putDoc(store, 'ns', {'id': _key('cnt'), 'active': true});
      await _putDoc(store, 'ns', {'id': _key('cnt'), 'active': false});
      await _putDoc(store, 'ns', {'id': _key('cnt'), 'active': true});
    });
    tearDown(() => store.close());

    test('counts all documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CountCommand().execute(ctx, ['ns'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(3));
    });

    test('counts filtered documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"active","op":"isTrue"}';
      final ok =
          await CountCommand().execute(ctx, ['ns'], {'filter': filter});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(2));
    });

    test('returns 0 for empty namespace', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CountCommand().execute(ctx, ['empty'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(0));
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CountCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });

    test('returns false for invalid filter', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await CountCommand().execute(ctx, ['ns'], {'filter': '{bad}'});
      expect(ok, isFalse);
    });
  });

  // ── CollectionsCommand ──────────────────────────────────────────────────────

  group('CollectionsCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('returns a list when no user namespaces exist', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CollectionsCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      expect(json.decode(out.toString()), isA<List>());
    });

    test('lists namespaces written to', () async {
      await _putDoc(store, 'tasks', {'id': _key('task'), 'v': 1});
      await _putDoc(store, 'notes', {'id': _key('note'), 'v': 2});
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CollectionsCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = (json.decode(out.toString()) as List).cast<String>();
      expect(result, containsAll(['tasks', 'notes']));
    });

    test('does not include system namespaces', () async {
      await _putDoc(store, 'tasks', {'id': _key('sys'), 'v': 1});
      final ctx = _ctx(store, out: out, err: err);
      await CollectionsCommand().execute(ctx, [], {});
      final result = (json.decode(out.toString()) as List).cast<String>();
      expect(result.any((ns) => ns.startsWith(r'$')), isFalse);
    });
  });

  // ── StatsCommand ────────────────────────────────────────────────────────────

  group('StatsCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('returns stats object with expected shape', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await StatsCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['dbDir'], isNotNull);
      expect(result['sstables'], isNotNull);
      expect(result['bytes'], isNotNull);
      expect((result['sstables'] as Map)['total'], isNotNull);
    });

    test('sstables.total equals l0 + l1 + l2', () async {
      final ctx = _ctx(store, out: out, err: err);
      await StatsCommand().execute(ctx, [], {});
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final s = result['sstables'] as Map<String, dynamic>;
      final expected = (s['l0'] as int) + (s['l1'] as int) + (s['l2'] as int);
      expect(s['total'], equals(expected));
    });
  });

  // ── InfoCommand ─────────────────────────────────────────────────────────────

  group('InfoCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('returns info with deviceId and hlc fields', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InfoCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['dbDir'], isNotNull);
      expect(result['deviceId'], isA<String>());
      expect(result['hlc'], isA<String>());
      // UUIDv7 device ID is 32 hex chars (no dashes at store level)
      expect((result['deviceId'] as String).length, greaterThanOrEqualTo(8));
    });
  });

  // ── FlushCommand ────────────────────────────────────────────────────────────

  group('FlushCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('flushes and returns {flushed: true}', () async {
      await _putDoc(store, 'ns', {'id': _key('flsh'), 'v': 1});
      final ctx = _ctx(store, out: out, err: err);
      final ok = await FlushCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['flushed'], isTrue);
    });
  });

  // ── CompactCommand ──────────────────────────────────────────────────────────

  group('CompactCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('compacts and returns {compacted: true}', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CompactCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['compacted'], isTrue);
    });
  });

  // ── ImportCommand — argument validation ─────────────────────────────────────

  group('ImportCommand — argument validation', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
    });

    test('returns false for unknown --on-conflict value', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand()
          .execute(ctx, ['ns'], {'on-conflict': 'merge'});
      expect(ok, isFalse);
      expect(err.toString(), contains('on-conflict'));
    });
  });

  // ── ImportCommand — file round-trip ─────────────────────────────────────────

  group('ImportCommand — file round-trip', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('imports NDJSON from a file', () async {
      final p1 = _key('imp1');
      final p2 = _key('imp2');
      final tmp = _TmpFile();
      tmp.write('{"id":"$p1","name":"Alice"}\n{"id":"$p2","name":"Bob"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand()
          .execute(ctx, ['people'], {'input': tmp.path});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['imported'], equals(2));
      expect(result['skipped'], equals(0));

      expect(ValueCodec.decode((await store.get('people', p1))!)['name'],
          equals('Alice'));
      expect(ValueCodec.decode((await store.get('people', p2))!)['name'],
          equals('Bob'));

      tmp.delete();
    });

    test('ignore conflict skips existing documents', () async {
      final p1 = _key('ign1');
      await _putDoc(store, 'people', {'id': p1, 'name': 'OldAlice'});

      final tmp = _TmpFile();
      tmp.write('{"id":"$p1","name":"NewAlice"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['people'],
        {'input': tmp.path, 'on-conflict': 'ignore'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['skipped'], equals(1));
      // Original value must be unchanged.
      expect(
          ValueCodec.decode((await store.get('people', p1))!)['name'],
          equals('OldAlice'));

      tmp.delete();
    });

    test('error conflict returns false on duplicate', () async {
      final p1 = _key('err1');
      await _putDoc(store, 'people', {'id': p1, 'name': 'Alice'});

      final tmp = _TmpFile();
      tmp.write('{"id":"$p1","name":"NewAlice"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['people'],
        {'input': tmp.path, 'on-conflict': 'error'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('already exists'));

      tmp.delete();
    });

    test('returns false for invalid JSON in file', () async {
      final id = _key('okid');
      final tmp = _TmpFile();
      tmp.write('{"id":"$id"}\n{bad json}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await ImportCommand().execute(ctx, ['ns'], {'input': tmp.path});
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));

      tmp.delete();
    });

    test('returns false for document missing id field', () async {
      final tmp = _TmpFile();
      tmp.write('{"name":"no-id"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await ImportCommand().execute(ctx, ['ns'], {'input': tmp.path});
      expect(ok, isFalse);
      expect(err.toString(), contains('"id"'));

      tmp.delete();
    });

    test('skips blank lines in NDJSON file', () async {
      final x1 = _key('blnk');
      final x2 = _key('blnk');
      final tmp = _TmpFile();
      tmp.write('{"id":"$x1","v":1}\n\n{"id":"$x2","v":2}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await ImportCommand().execute(ctx, ['ns'], {'input': tmp.path});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['imported'], equals(2));

      tmp.delete();
    });
  });

  // ── CommandContext helpers ──────────────────────────────────────────────────

  group('CommandContext', () {
    late KvStoreImpl store;

    setUp(() async => store = await _openStore());
    tearDown(() => store.close());

    test('writeValue emits indented JSON', () async {
      final out = StringBuffer();
      final ctx = _ctx(store, out: out);
      ctx.writeValue({'ok': true});
      final decoded = json.decode(out.toString()) as Map;
      expect(decoded['ok'], isTrue);
    });

    test('writeError prefixes with "Error:"', () async {
      final err = StringBuffer();
      final ctx = _ctx(store, err: err);
      ctx.writeError('something went wrong');
      expect(err.toString(), startsWith('Error:'));
      expect(err.toString(), contains('something went wrong'));
    });

    test('writeDocuments uses active OutputMode', () async {
      final out = StringBuffer();
      final ctx = _ctx(store, mode: OutputMode.ndjson, out: out);
      ctx.writeDocuments([
        {'id': '1', 'v': 'a'},
        {'id': '2', 'v': 'b'},
      ]);
      final lines = out.toString().trim().split('\n');
      expect(lines, hasLength(2));
      expect(json.decode(lines[0])['v'], equals('a'));
    });
  });
}
