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
import 'package:kmdb_cli/src/commands/init_command.dart';
import 'package:kmdb_cli/src/commands/insert_command.dart';
import 'package:kmdb_cli/src/commands/put_command.dart';
import 'package:kmdb_cli/src/commands/scan_command.dart';
import 'package:kmdb_cli/src/commands/update_command.dart';
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
  bool dbCreated = false,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  mode: mode,
  dbCreated: dbCreated,
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

/// Helper to write a raw document to the store bypassing CLI logic.
///
/// The document map must contain a `'_id'` key whose value is the UUIDv7
/// hex string to use as the storage key.
Future<void> _putDoc(
  KvStoreImpl store,
  String coll,
  Map<String, dynamic> doc,
) async {
  final id = doc['_id'] as String;
  await store.put(coll, id, ValueCodec.encode(doc));
}

/// Simple temporary file wrapper.
class _TmpFile {
  _TmpFile({String ext = 'json'})
    : path =
          '${io.Directory.systemTemp.path}/kmdb_test_${DateTime.now().microsecondsSinceEpoch}.$ext';
  final String path;
  void write(String content) => io.File(path).writeAsStringSync(content);
  void delete() => io.File(path).deleteSync();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── InitCommand ─────────────────────────────────────────────────────────────

  group('InitCommand', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test(
      'reports path, deviceId, and created=true for a fresh database',
      () async {
        final ctx = _ctx(store, out: out, err: err, dbCreated: true);
        final ok = await InitCommand().execute(ctx, [], {});
        expect(ok, isTrue);

        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['path'], isA<String>());
        expect(result['deviceId'], isA<String>());
        expect(result['created'], isTrue);
      },
    );

    test('reports created=false when reopening an existing database', () async {
      final ctx = _ctx(store, out: out, err: err, dbCreated: false);
      final ok = await InitCommand().execute(ctx, [], {});
      expect(ok, isTrue);

      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['created'], isFalse);
    });

    test('is idempotent — running init twice on same store succeeds', () async {
      final ctx1 = _ctx(store, out: out, err: err, dbCreated: true);
      expect(await InitCommand().execute(ctx1, [], {}), isTrue);

      final out2 = StringBuffer();
      final ctx2 = _ctx(store, out: out2, err: err, dbCreated: false);
      expect(await InitCommand().execute(ctx2, [], {}), isTrue);

      final result = json.decode(out2.toString()) as Map<String, dynamic>;
      expect(result['created'], isFalse);
    });
  });

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
      await _putDoc(store, 'notes', {'_id': id, 'text': 'hello'});

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

    test('--select returns only requested fields', () async {
      final id = _key('xsel');
      await _putDoc(store, 'notes', {'_id': id, 'text': 'hi', 'score': 5});

      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'text'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0].keys.toList(), equals(['text']));
      expect(result[0]['text'], equals('hi'));
    });

    test('--select with unknown field returns empty document', () async {
      final id = _key('xselunk');
      await _putDoc(store, 'notes', {'_id': id, 'text': 'hi'});

      final ctx = _ctx(store, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'nonexistent'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0], isEmpty);
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
      final generatedId = decoded[0]['_id'] as String;
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
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': '[1,2]'});
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('ignores user-provided id and generates a new one', () async {
      final ctx = _ctx(store, out: out, err: err);
      final userId = _key('user');
      final doc = '{"_id":"$userId","name":"Alice"}';
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      // The echoed document uses '_id' as the system key field.
      final assignedId = decoded[0]['_id'] as String;
      expect(assignedId, isNot(equals(userId)));
      expect(assignedId, hasLength(32));

      // The user-provided ID should NOT have been written.
      expect(await store.get('notes', userId), isNull);

      // The assigned ID should have been written.
      expect(await store.get('notes', assignedId), isNotNull);
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, [], {
        'value': '{"name":"Alice"}',
      });
      expect(ok, isFalse);
    });

    test('inserts multiple documents from a JSON array via --value', () async {
      final ctx = _ctx(store, out: out, err: err);
      const arrayJson = '[{"name":"Alice"},{"name":"Bob"}]';
      final ok = await PutCommand().execute(
        ctx,
        ['notes'],
        {'value': arrayJson},
      );
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(2));
      final id0 = decoded[0]['_id'] as String;
      final id1 = decoded[1]['_id'] as String;
      expect(id0, hasLength(32));
      expect(id1, hasLength(32));
      expect(id0, isNot(equals(id1)));

      expect(
        ValueCodec.decode((await store.get('notes', id0))!)['name'],
        equals('Alice'),
      );
      expect(
        ValueCodec.decode((await store.get('notes', id1))!)['name'],
        equals('Bob'),
      );
    });

    test('inserts document from a JSON file via --file', () async {
      final tmp = _TmpFile();
      tmp.write('{"name":"Carol"}');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'file': tmp.path});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(1));
      final id = decoded[0]['_id'] as String;
      expect(
        ValueCodec.decode((await store.get('notes', id))!)['name'],
        equals('Carol'),
      );
    });

    test(
      'inserts multiple documents from a JSON array file via --file',
      () async {
        final tmp = _TmpFile();
        tmp.write('[{"name":"Dave"},{"name":"Eve"}]');
        addTearDown(tmp.delete);

        final ctx = _ctx(store, out: out, err: err);
        final ok = await PutCommand().execute(
          ctx,
          ['notes'],
          {'file': tmp.path},
        );
        expect(ok, isTrue);

        final decoded = json.decode(out.toString()) as List;
        expect(decoded, hasLength(2));
        expect(decoded.map((d) => d['name']), containsAll(['Dave', 'Eve']));
      },
    );

    test('inserts multiple documents from an NDJSON file via --file', () async {
      final tmp = _TmpFile(ext: 'ndjson');
      tmp.write('{"name":"Frank"}\n{"name":"Grace"}\n\n');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'file': tmp.path});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(2));
      expect(decoded.map((d) => d['name']), containsAll(['Frank', 'Grace']));
    });

    test('inserts multiple documents from a JSONL file via --file', () async {
      final tmp = _TmpFile(ext: 'jsonl');
      tmp.write('{"name":"Heidi"}\n{"name":"Ivan"}\n');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'file': tmp.path});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(2));
      expect(decoded.map((d) => d['name']), containsAll(['Heidi', 'Ivan']));
    });

    test('returns false when --file path does not exist', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(
        ctx,
        ['notes'],
        {'file': '/nonexistent/path/file.json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Cannot read file'));
    });

    test('returns false for non-object items in JSON array', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(
        ctx,
        ['notes'],
        {'value': '[{"name":"Alice"}, 42]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('returns false for invalid JSON line in NDJSON file', () async {
      final tmp = _TmpFile(ext: 'ndjson');
      tmp.write('{"name":"Alice"}\n{bad json}\n');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'file': tmp.path});
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));
    });

    test('inserts zero documents from an empty JSON array', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(ctx, ['notes'], {'value': '[]'});
      expect(ok, isTrue);
      final decoded = json.decode(out.toString()) as List;
      expect(decoded, isEmpty);
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
      await _putDoc(store, 'tasks', {'_id': id, 'x': 1});
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
      final ok = await DeleteCommand().execute(ctx, [
        'tasks',
        _key('gost'),
      ], {});
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
      await _putDoc(store, 'items', {'_id': idA, 'score': 10, 'tag': 'x'});
      await _putDoc(store, 'items', {'_id': idB, 'score': 30, 'tag': 'y'});
      await _putDoc(store, 'items', {'_id': idC, 'score': 20, 'tag': 'x'});
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
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': filter},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(2));
      expect(docs.every((d) => d['tag'] == 'x'), isTrue);
    });

    test('applies order-by ascending', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'order-by': 'score'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      // Sort the expected order by key first if score was same, but here scores are unique.
      expect(docs.map((d) => d['score']).toList(), equals([10, 20, 30]));
    });

    test('applies order-by descending', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'order-by': 'score', 'desc': true},
      );
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
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': '{bad json}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('filter'));
    });

    test('returns false for unknown filter operator', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"x","op":"regex","value":".*"}';
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': filter},
      );
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

    test('--select projects to requested fields only', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'select': 'score,tag'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
      for (final doc in docs) {
        final keys = (doc as Map).keys.toSet();
        expect(keys, equals({'score', 'tag'}));
      }
    });

    test('--select with single field', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'select': 'score'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
      expect(docs.every((d) => (d as Map).keys.single == 'score'), isTrue);
    });

    test('--select interacts correctly with --filter', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"tag","op":"eq","value":"x"}';
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': filter, 'select': 'score'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      // Only items with tag 'x' (score 10 and 20) but projected to score only.
      expect(docs, hasLength(2));
      final scores = docs.map((d) => d['score']).toSet();
      expect(scores, equals({10, 20}));
      expect(docs.every((d) => (d as Map).keys.single == 'score'), isTrue);
    });

    test('--select with unknown field produces empty documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'select': 'nonexistent'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
      expect(docs.every((d) => (d as Map).isEmpty), isTrue);
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
      await _putDoc(store, 'ns', {'_id': _key('cnt1'), 'active': true});
      await _putDoc(store, 'ns', {'_id': _key('cnt2'), 'active': false});
      await _putDoc(store, 'ns', {'_id': _key('cnt3'), 'active': true});
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
      final ok = await CountCommand().execute(ctx, ['ns'], {'filter': filter});
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
      final ok = await CountCommand().execute(ctx, ['ns'], {'filter': '{bad}'});
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
      await _putDoc(store, 'tasks', {'_id': _key('task'), 'v': 1});
      await _putDoc(store, 'notes', {'_id': _key('note'), 'v': 2});
      final ctx = _ctx(store, out: out, err: err);
      final ok = await CollectionsCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = (json.decode(out.toString()) as List).cast<String>();
      expect(result, containsAll(['tasks', 'notes']));
    });

    test('does not include system namespaces', () async {
      await _putDoc(store, 'tasks', {'_id': _key('sys'), 'v': 1});
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
      await _putDoc(store, 'ns', {'_id': _key('flsh'), 'v': 1});
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
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'on-conflict': 'merge'},
      );
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
      tmp.write('{"_id":"$p1","name":"Alice"}\n{"_id":"$p2","name":"Bob"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['people'],
        {'input': tmp.path},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['imported'], equals(2));
      expect(result['skipped'], equals(0));

      expect(
        ValueCodec.decode((await store.get('people', p1))!)['name'],
        equals('Alice'),
      );
      expect(
        ValueCodec.decode((await store.get('people', p2))!)['name'],
        equals('Bob'),
      );

      tmp.delete();
    });

    test('ignore conflict skips existing documents', () async {
      final p1 = _key('ign1');
      await _putDoc(store, 'people', {'_id': p1, 'name': 'OldAlice'});

      final tmp = _TmpFile();
      tmp.write('{"_id":"$p1","name":"NewAlice"}\n');

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
        equals('OldAlice'),
      );

      tmp.delete();
    });

    test('error conflict returns false on duplicate', () async {
      final p1 = _key('err1');
      await _putDoc(store, 'people', {'_id': p1, 'name': 'Alice'});

      final tmp = _TmpFile();
      tmp.write('{"_id":"$p1","name":"NewAlice"}\n');

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
      tmp.write('{"_id":"$id"}\n{bad json}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'input': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));

      tmp.delete();
    });

    test('returns false for document missing id field', () async {
      final tmp = _TmpFile();
      tmp.write('{"name":"no-id"}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'input': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('"_id"'));

      tmp.delete();
    });

    test('skips blank lines in NDJSON file', () async {
      final x1 = _key('blnk1');
      final x2 = _key('blnk2');
      final tmp = _TmpFile();
      tmp.write('{"_id":"$x1","v":1}\n\n{"_id":"$x2","v":2}\n');

      final ctx = _ctx(store, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'input': tmp.path},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['imported'], equals(2));

      tmp.delete();
    });
  });

  // ── Export → Import roundtrip ───────────────────────────────────────────────

  group('Export → Import roundtrip', () {
    late KvStoreImpl store;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('export then import restores identical documents', () async {
      // Seed three documents.
      final ids = [_key('rnd1'), _key('rnd2'), _key('rnd3')];
      final origDocs = [
        {'_id': ids[0], 'name': 'Alice', 'score': 10},
        {'_id': ids[1], 'name': 'Bob', 'score': 20},
        {'_id': ids[2], 'name': 'Carol', 'score': 30},
      ];
      for (final doc in origDocs) {
        await _putDoc(store, 'people', doc);
      }

      // Export via ctx.out (mirrors how --output redirects ctx.out in prod).
      final exportOut = StringBuffer();
      final exportCtx = _ctx(store, out: exportOut, err: err);
      final exportOk = await ExportCommand().execute(exportCtx, ['people'], {});
      expect(exportOk, isTrue);

      // Write the captured NDJSON to a temp file for ImportCommand.
      final tmp = _TmpFile();
      tmp.write(exportOut.toString());
      addTearDown(tmp.delete);

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
      final importOk = await ImportCommand().execute(
        importCtx,
        ['people'],
        {'input': tmp.path},
      );
      expect(importOk, isTrue);
      final importResult = json.decode(importOut.toString()) as Map;
      expect(importResult['imported'], equals(3));

      // Verify each document was restored correctly.
      for (final orig in origDocs) {
        final bytes = await store.get('people', orig['_id'] as String);
        expect(
          bytes,
          isNotNull,
          reason: 'Missing document after re-import: ${orig['_id']}',
        );
        final restored = ValueCodec.decode(bytes!);
        expect(restored['name'], equals(orig['name']));
        expect(restored['score'], equals(orig['score']));
      }
    });

    test('export writes one line per document in NDJSON format', () async {
      final id1 = _key('exp1');
      final id2 = _key('exp2');
      await _putDoc(store, 'items', {'_id': id1, 'v': 1});
      await _putDoc(store, 'items', {'_id': id2, 'v': 2});

      final exportOut = StringBuffer();
      final ctx = _ctx(store, out: exportOut, err: err);
      final ok = await ExportCommand().execute(ctx, ['items'], {});
      expect(ok, isTrue);

      final lines = exportOut
          .toString()
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(() => json.decode(line), returnsNormally);
      }
    });
  });

  // ── InsertCommand ───────────────────────────────────────────────────────────

  group('InsertCommand', () {
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
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      final generatedId = decoded[0]['_id'] as String;
      expect(generatedId, hasLength(32));
      expect(generatedId[12], equals('7')); // UUIDv7 version nibble

      final stored = await store.get('notes', generatedId);
      expect(stored, isNotNull);
      expect(ValueCodec.decode(stored!)['name'], equals('Alice'));
    });

    test('ignores user-provided _id and generates a new one', () async {
      final ctx = _ctx(store, out: out, err: err);
      final userId = _key('user');
      final doc = '{"_id":"$userId","name":"Alice"}';
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      final assignedId = decoded[0]['_id'] as String;
      expect(assignedId, isNot(equals(userId)));

      // User-supplied ID must NOT have been stored.
      expect(await store.get('notes', userId), isNull);
      // The generated ID must exist.
      expect(await store.get('notes', assignedId), isNotNull);
    });

    test('returns false for invalid JSON via --value', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '{bad}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid JSON'));
    });

    test('returns false when document is not a JSON object', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '[1,2]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('inserts multiple documents from a JSON array via --value', () async {
      final ctx = _ctx(store, out: out, err: err);
      const arrayJson = '[{"name":"Alice"},{"name":"Bob"}]';
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': arrayJson},
      );
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(2));
      final id0 = decoded[0]['_id'] as String;
      final id1 = decoded[1]['_id'] as String;
      expect(id0, isNot(equals(id1)));
    });

    test('inserts document from a JSON file via --file', () async {
      final tmp = _TmpFile();
      tmp.write('{"name":"Carol"}');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'file': tmp.path},
      );
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(1));
      final id = decoded[0]['_id'] as String;
      expect(
        ValueCodec.decode((await store.get('notes', id))!)['name'],
        equals('Carol'),
      );
    });

    test('inserts multiple documents from an NDJSON file via --file', () async {
      final tmp = _TmpFile(ext: 'ndjson');
      tmp.write('{"name":"Frank"}\n{"name":"Grace"}\n\n');
      addTearDown(tmp.delete);

      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'file': tmp.path},
      );
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(2));
      expect(decoded.map((d) => d['name']), containsAll(['Frank', 'Grace']));
    });

    test('inserts zero documents from an empty JSON array', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': '[]'});
      expect(ok, isTrue);
      final decoded = json.decode(out.toString()) as List;
      expect(decoded, isEmpty);
    });

    test('returns false when collection arg is missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(ctx, [], {'value': '{"x":1}'});
      expect(ok, isFalse);
    });

    test('returns false when --file path does not exist', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'file': '/nonexistent/path/file.json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Cannot read file'));
    });
  });

  // ── PutCommand (deprecated wrapper) ────────────────────────────────────────

  group('PutCommand (deprecated)', () {
    late KvStoreImpl store;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      store = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => store.close());

    test('still inserts document and emits a deprecation warning', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(
        ctx,
        ['notes'],
        {'value': '{"x":1}'},
      );
      expect(ok, isTrue);

      // Document should be stored.
      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(1));
      expect(decoded[0]['_id'], isNotNull);

      // Deprecation warning must appear on stderr.
      expect(err.toString(), contains('deprecated'));
      expect(err.toString(), contains('insert'));
    });

    test('deprecation warning appears even when insert fails', () async {
      // Pass invalid JSON so InsertCommand returns false.
      final ctx = _ctx(store, out: out, err: err);
      final ok = await PutCommand().execute(
        ctx,
        ['notes'],
        {'value': '{bad json}'},
      );
      expect(ok, isFalse);

      // Warning still emitted before delegate runs.
      expect(err.toString(), contains('deprecated'));
    });
  });

  // ── UpdateCommand ───────────────────────────────────────────────────────────

  group('UpdateCommand', () {
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
      idA = _key('updA');
      idB = _key('updB');
      idC = _key('updC');
      await _putDoc(store, 'col', {
        '_id': idA,
        'name': 'Alice',
        'status': 'active',
      });
      await _putDoc(store, 'col', {
        '_id': idB,
        'name': 'Bob',
        'status': 'active',
      });
      await _putDoc(store, 'col', {
        '_id': idC,
        'name': 'Carol',
        'status': 'inactive',
      });
    });
    tearDown(() => store.close());

    // ── Single-id mode (positional) ──────────────────────────────────────────

    test('single-id: updates one field and preserves others', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{"status":"done"}'},
      );
      expect(ok, isTrue);

      final doc = ValueCodec.decode((await store.get('col', idA))!);
      expect(doc['status'], equals('done'));
      expect(doc['name'], equals('Alice')); // untouched
      expect(doc['_id'], equals(idA)); // _id preserved
    });

    test('single-id: adds a new field that did not exist', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{"score":99}'},
      );
      expect(ok, isTrue);

      final doc = ValueCodec.decode((await store.get('col', idA))!);
      expect(doc['score'], equals(99));
      expect(doc['name'], equals('Alice')); // still present
    });

    test(
      'single-id: does not overwrite _id even when --set contains _id',
      () async {
        final ctx = _ctx(store, out: out, err: err);
        final ok = await UpdateCommand().execute(
          ctx,
          ['col', idA],
          {'set': '{"_id":"injected","status":"done"}'},
        );
        expect(ok, isTrue);

        final doc = ValueCodec.decode((await store.get('col', idA))!);
        expect(doc['_id'], equals(idA)); // original _id preserved
      },
    );

    test('single-id: returns false when document does not exist', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', _key('ghost')],
        {'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    test('single-id: reports {"updated": 1}', () async {
      final ctx = _ctx(store, out: out, err: err);
      await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{"status":"done"}'},
      );
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(1));
    });

    // ── Multi-id mode (--id) ─────────────────────────────────────────────────

    test('multi-id: updates all listed documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'id': '$idA,$idB', 'set': '{"status":"reviewed"}'},
      );
      expect(ok, isTrue);

      final docA = ValueCodec.decode((await store.get('col', idA))!);
      final docB = ValueCodec.decode((await store.get('col', idB))!);
      expect(docA['status'], equals('reviewed'));
      expect(docB['status'], equals('reviewed'));
    });

    test('multi-id: reports count of updated documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      await UpdateCommand().execute(
        ctx,
        ['col'],
        {'id': '$idA,$idB', 'set': '{"x":1}'},
      );
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(2));
    });

    test(
      'multi-id: returns false and reports error when one id is missing',
      () async {
        final ctx = _ctx(store, out: out, err: err);
        final ok = await UpdateCommand().execute(
          ctx,
          ['col'],
          {'id': '$idA,${_key("missing")}', 'set': '{"x":1}'},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('not found'));
      },
    );

    test('multi-id: single id in --id flag works', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'id': idA, 'set': '{"status":"solo"}'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(1));
      final doc = ValueCodec.decode((await store.get('col', idA))!);
      expect(doc['status'], equals('solo'));
    });

    // ── Filter mode ──────────────────────────────────────────────────────────

    test('filter: updates only matching documents', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"status","op":"eq","value":"active"}';
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': filter, 'set': '{"flagged":true}'},
      );
      expect(ok, isTrue);

      final docA = ValueCodec.decode((await store.get('col', idA))!);
      final docB = ValueCodec.decode((await store.get('col', idB))!);
      final docC = ValueCodec.decode((await store.get('col', idC))!);
      expect(docA['flagged'], isTrue); // active -> updated
      expect(docB['flagged'], isTrue); // active -> updated
      expect(docC['flagged'], isNull); // inactive -> not touched
    });

    test('filter: returns {"updated": 0} when nothing matches', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"status","op":"eq","value":"archived"}';
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': filter, 'set': '{"x":1}'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(0));
    });

    test('filter: returns false for invalid filter JSON', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': '{bad json}', 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('filter'));
    });

    test('filter: returns false for unknown filter operator', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': '{"field":"x","op":"regex","value":".*"}', 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
    });

    // ── All-docs mode ─────────────────────────────────────────────────────────

    test('all: updates every document in the collection', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'all': true, 'set': '{"archived":true}'},
      );
      expect(ok, isTrue);

      for (final id in [idA, idB, idC]) {
        final doc = ValueCodec.decode((await store.get('col', id))!);
        expect(doc['archived'], isTrue);
      }

      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(3));
    });

    test('all: returns {"updated": 0} for an empty collection', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['empty'],
        {'all': true, 'set': '{"x":1}'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(0));
    });

    // ── Mutual exclusion ─────────────────────────────────────────────────────

    test('returns false when positional id and --all are both given', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'all': true, 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('returns false when --id and --filter are both given', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {
          'id': idA,
          'filter': '{"field":"status","op":"eq","value":"active"}',
          'set': '{"x":1}',
        },
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('returns false when --filter and --all are both given', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {
          'filter': '{"field":"status","op":"eq","value":"active"}',
          'all': true,
          'set': '{"x":1}',
        },
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('returns false when no targeting mode is given', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('targeting mode'));
    });

    // ── --set validation ─────────────────────────────────────────────────────

    test('returns false when --set is missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(ctx, ['col', idA], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('--set'));
    });

    test('returns false when --set is invalid JSON', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{bad json}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid JSON'));
    });

    test('returns false when --set is a JSON array', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '[{"x":1}]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('returns false when --set is a JSON scalar', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '"just a string"'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    // ── Shallow merge semantics ──────────────────────────────────────────────

    test(
      'shallow merge: replaces entire nested object when key is in --set',
      () async {
        // Set up document with a nested object.
        final id = _key('nested');
        await _putDoc(store, 'col', {
          '_id': id,
          'profile': {'city': 'Sydney', 'country': 'AU'},
          'name': 'Dana',
        });

        final ctx = _ctx(store, out: out, err: err);
        final ok = await UpdateCommand().execute(
          ctx,
          ['col', id],
          {'set': '{"profile":{"city":"Melbourne"}}'},
        );
        expect(ok, isTrue);

        final doc = ValueCodec.decode((await store.get('col', id))!);
        // Shallow merge: entire profile replaced.
        expect(doc['profile'], equals({'city': 'Melbourne'}));
        expect(doc['name'], equals('Dana')); // sibling field unchanged
      },
    );

    // ── Error: missing collection ─────────────────────────────────────────────

    test('returns false when collection arg is missing', () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await UpdateCommand().execute(ctx, [], {'set': '{"x":1}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('update requires'));
    });

    // ── Filter mode: empty collection ─────────────────────────────────────────

    test('filter: returns {"updated":0} on empty collection', () async {
      final ctx = _ctx(store, out: out, err: err);
      final filter = '{"field":"status","op":"eq","value":"active"}';
      final ok = await UpdateCommand().execute(
        ctx,
        ['empty'],
        {'filter': filter, 'set': '{"x":1}'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(0));
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
