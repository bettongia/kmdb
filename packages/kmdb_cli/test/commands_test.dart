// Copyright 2026 The KMDB Authors.
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

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/kmdb_cli.dart';
import 'package:kmdb_cli/src/commands/collections_command.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/compact_command.dart';
import 'package:kmdb_cli/src/commands/count_command.dart';
import 'package:kmdb_cli/src/commands/delete_command.dart';
import 'package:kmdb_cli/src/commands/export_command.dart';
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

/// Opens a fresh memory-backed store for testing.
Future<KvStoreImpl> _openStore() async {
  final (store, _) = await KvStoreImpl.open(
    '/testdb',
    MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
  return store;
}

/// Creates a [CommandContext] for testing.
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

/// Deterministic valid UUIDv7 keys for CLI tests.
String _key(String seed) {
  // Use a simple but valid UUIDv7-looking hex string.
  final hex = seed.codeUnits
      .map((c) => c.toRadixString(16))
      .join()
      .padRight(32, '0')
      .substring(0, 32);
  final chars = hex.split('');
  chars[12] = '7';
  chars[16] = '8';
  return chars.join();
}

/// Helper to write a raw document to the store bypass CLI logic.
Future<void> _putDoc(
    KvStoreImpl store, String ns, Map<String, dynamic> doc) async {
  final id = doc['id'] as String;
  await store.put(ns, id, ValueCodec.encode(doc));
}

/// Simple temporary file wrapper.
class _TmpFile {
  _TmpFile() : path = '${io.Directory.systemTemp.path}/kmdb_test_${DateTime.now().microsecondsSinceEpoch}.json';
  final String path;
  void write(String content) => io.File(path).writeAsStringSync(content);
  void delete() => io.File(path).deleteSync();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

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

    test('fetches existing document and echoes it back', () async {
      final id = _key('xone');
      await _putDoc(store, 'notes', {'id': id, 'text': 'hello'});

      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['notes', id], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0]['text'], equals('hello'));
    });

    test('returns false when key is missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['notes', _key('miss')], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
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

    test('inserts document with generated ID and echoes it back', () async {
      final ctx = _ctx(store, out: out, err: err);
      const doc = '{"name":"Alice"}';
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);
      
      final decoded = json.decode(out.toString()) as List;
      final generatedId = decoded[0]['id'] as String;
      expect(generatedId, hasLength(32));
      expect(generatedId[12], equals('7')); // version

      final result = await store.get('notes', generatedId);
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

    test('ignores user-provided id and generates a new one', () async {
      final ctx = _ctx(store, out: out, err: err);
      final userId = _key('user');
      final doc = '{"id":"$userId","name":"Alice"}';
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      final assignedId = decoded[0]['id'] as String;
      expect(assignedId, isNot(equals(userId)));
      expect(assignedId, hasLength(32));

      // The user-provided ID should NOT have been written.
      expect(await store.get('notes', userId), isNull);
      
      // The assigned ID should have been written.
      expect(await store.get('notes', assignedId), isNotNull);
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok =
          await PutCommand().execute(ctx, [], {'value': '{"name":"Alice"}'});
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
      idA = _key('scanA');
      idB = _key('scanB');
      idC = _key('scanC');
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
      // Sort the expected order by key first if score was same, but here scores are unique.
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
      await _putDoc(store, 'ns', {'id': _key('cnt1'), 'active': true});
      await _putDoc(store, 'ns', {'id': _key('cnt2'), 'active': false});
      await _putDoc(store, 'ns', {'id': _key('cnt3'), 'active': true});
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
      final x1 = _key('blnk1');
      final x2 = _key('blnk2');
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

  // ── Export → Import roundtrip ───────────────────────────────────────────────

  group('Export → Import roundtrip', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('export then import restores identical documents', () async {
      // Seed three documents.
      final ids = [_key('rnd1'), _key('rnd2'), _key('rnd3')];
      final origDocs = [
        {'id': ids[0], 'name': 'Alice', 'score': 10},
        {'id': ids[1], 'name': 'Bob',   'score': 20},
        {'id': ids[2], 'name': 'Carol', 'score': 30},
      ];
      for (final doc in origDocs) {
        await _putDoc(store, 'people', doc);
      }

      // Export to a temp file.
      final tmp = _TmpFile();
      final exportCtx = _ctx(store, out: out, err: err);
      final exportOk = await ExportCommand()
          .execute(exportCtx, ['people'], {'output': tmp.path});
      expect(exportOk, isTrue);

      // Delete all documents from the namespace.
      for (final id in ids) {
        await store.delete('people', id);
      }
      // Verify namespace is empty.
      final countOut = StringBuffer();
      await CountCommand().execute(_ctx(store, out: countOut), ['people'], {});
      expect((json.decode(countOut.toString()) as Map)['count'], equals(0));

      // Re-import from the exported file.
      final importOut = StringBuffer();
      final importCtx = _ctx(store, out: importOut, err: err);
      final importOk = await ImportCommand()
          .execute(importCtx, ['people'], {'input': tmp.path});
      expect(importOk, isTrue);
      final importResult = json.decode(importOut.toString()) as Map;
      expect(importResult['imported'], equals(3));

      // Verify each document was restored correctly.
      for (final orig in origDocs) {
        final bytes = await store.get('people', orig['id'] as String);
        expect(bytes, isNotNull,
            reason: 'Missing document after re-import: ${orig['id']}');
        final restored = ValueCodec.decode(bytes!);
        expect(restored['name'], equals(orig['name']));
        expect(restored['score'], equals(orig['score']));
      }

      tmp.delete();
    });

    test('export writes one line per document in NDJSON format', () async {
      final id1 = _key('exp1');
      final id2 = _key('exp2');
      await _putDoc(store, 'items', {'id': id1, 'v': 1});
      await _putDoc(store, 'items', {'id': id2, 'v': 2});

      final tmp = _TmpFile();
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ExportCommand()
          .execute(ctx, ['items'], {'output': tmp.path});
      expect(ok, isTrue);

      final lines = io.File(tmp.path)
          .readAsStringSync()
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(() => json.decode(line), returnsNormally);
      }

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
