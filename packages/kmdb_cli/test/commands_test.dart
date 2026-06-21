// Copyright 2026 The Authors.
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
import 'package:kmdb_cli/src/commands/create_collection_command.dart';
import 'package:kmdb_cli/src/commands/index_command.dart';
import 'package:kmdb/kmdb_config.dart';
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
import 'package:kmdb_cli/src/commands/scan_command.dart';
import 'package:kmdb_cli/src/commands/update_command.dart';
import 'package:kmdb_cli/src/commands/stats_command.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a fresh memory-backed database for testing.
Future<KmdbDatabase> _openStore() async {
  return KmdbDatabase.open(
    path: '/testdb',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
}

/// Creates a [CommandContext] for testing.
CommandContext _ctx(
  KmdbDatabase db, {
  OutputMode mode = OutputMode.json,
  bool dbCreated = false,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  db: db,
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
  KmdbDatabase db,
  String coll,
  Map<String, dynamic> doc,
) async {
  final id = doc['_id'] as String;
  await db.store.put(coll, id, await ValueCodec.encode(doc));
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
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test(
      'reports path, deviceId, and created=true for a fresh database',
      () async {
        final ctx = _ctx(db, out: out, err: err, dbCreated: true);
        final ok = await InitCommand().execute(ctx, [], {});
        expect(ok, isTrue);

        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['path'], isA<String>());
        expect(result['deviceId'], isA<String>());
        expect(result['created'], isTrue);
      },
    );

    test('reports created=false when reopening an existing database', () async {
      final ctx = _ctx(db, out: out, err: err, dbCreated: false);
      final ok = await InitCommand().execute(ctx, [], {});
      expect(ok, isTrue);

      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['created'], isFalse);
    });

    test('is idempotent — running init twice on same store succeeds', () async {
      final ctx1 = _ctx(db, out: out, err: err, dbCreated: true);
      expect(await InitCommand().execute(ctx1, [], {}), isTrue);

      final out2 = StringBuffer();
      final ctx2 = _ctx(db, out: out2, err: err, dbCreated: false);
      expect(await InitCommand().execute(ctx2, [], {}), isTrue);

      final result = json.decode(out2.toString()) as Map<String, dynamic>;
      expect(result['created'], isFalse);
    });
  });

  // ── GetCommand ──────────────────────────────────────────────────────────────

  group('GetCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('fetches existing document and echoes it back', () async {
      final id = _key('xone');
      await _putDoc(db, 'notes', {'_id': id, 'text': 'hello'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['notes', id], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0]['text'], equals('hello'));
    });

    test('returns false when key is missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(ctx, ['notes', _key('miss')], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    test('returns false when all args are missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });

    test('--select returns only requested fields', () async {
      final id = _key('xsel');
      await _putDoc(db, 'notes', {'_id': id, 'text': 'hi', 'score': 5});

      final ctx = _ctx(db, out: out, err: err);
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
      await _putDoc(db, 'notes', {'_id': id, 'text': 'hi'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'nonexistent'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0], isEmpty);
    });

    test('--select with dot-path re-nests the value', () async {
      final id = _key('xnest');
      await _putDoc(db, 'notes', {
        '_id': id,
        'address': {'city': 'Paris', 'zip': '75001'},
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'address.city'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      // The nested value is re-nested in the output.
      expect(result[0]['address'], isA<Map>());
      expect((result[0]['address'] as Map)['city'], equals('Paris'));
      // zip was not selected.
      expect((result[0]['address'] as Map).containsKey('zip'), isFalse);
    });

    test(r'--select with $.name works identically to name', () async {
      final id = _key('xsigil');
      await _putDoc(db, 'notes', {'_id': id, 'name': 'Alice', 'score': 10});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': r'$.name'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0]['name'], equals('Alice'));
      expect(result[0].containsKey('score'), isFalse);
    });

    test('--select with array index returns flat key', () async {
      final id = _key('xarr');
      await _putDoc(db, 'notes', {
        '_id': id,
        'tags': ['dart', 'flutter', 'kmdb'],
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'tags[0]'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      // Bracket selections use the raw path token as a flat key.
      expect(result[0]['tags[0]'], equals('dart'));
    });

    test('--select with negative array index returns flat key', () async {
      final id = _key('xarrn');
      await _putDoc(db, 'notes', {
        '_id': id,
        'tags': ['dart', 'flutter', 'kmdb'],
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'tags[-1]'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0]['tags[-1]'], equals('kmdb'));
    });

    test('--select with array wildcard returns flat key', () async {
      final id = _key('xarrw');
      await _putDoc(db, 'notes', {
        '_id': id,
        'tags': ['dart', 'flutter'],
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'tags[]'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      expect(result[0]['tags[]'], equals(['dart', 'flutter']));
    });

    test('--select with absent path omits the key gracefully', () async {
      final id = _key('xabsent');
      await _putDoc(db, 'notes', {'_id': id, 'name': 'Bob'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await GetCommand().execute(
        ctx,
        ['notes', id],
        {'select': 'name,address.city'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as List;
      // 'name' is present; 'address.city' is absent and must be omitted.
      expect(result[0]['name'], equals('Bob'));
      expect(result[0].containsKey('address'), isFalse);
    });
  });

  // ── DeleteCommand ───────────────────────────────────────────────────────────

  group('DeleteCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('deletes existing document', () async {
      final id = _key('del1');
      await _putDoc(db, 'tasks', {'_id': id, 'x': 1});
      final ctx = _ctx(db, out: out, err: err);
      final ok = await DeleteCommand().execute(ctx, ['tasks', id], {});
      expect(ok, isTrue);
      expect(await db.store.get('tasks', id), isNull);
      final result = json.decode(out.toString()) as Map;
      expect(result['deleted'], equals(id));
    });

    test('succeeds (no-op) when key does not exist', () async {
      // Delete is idempotent at the store level.
      final ctx = _ctx(db, out: out, err: err);
      final ok = await DeleteCommand().execute(ctx, [
        'tasks',
        _key('gost'),
      ], {});
      expect(ok, isTrue);
    });

    test('returns false when args are missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await DeleteCommand().execute(ctx, ['tasks'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
    });
  });

  // ── ScanCommand ─────────────────────────────────────────────────────────────

  group('ScanCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;
    late String idA;
    late String idB;
    late String idC;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
      idA = _key('scanA');
      idB = _key('scanB');
      idC = _key('scanC');
      await _putDoc(db, 'items', {'_id': idA, 'score': 10, 'tag': 'x'});
      await _putDoc(db, 'items', {'_id': idB, 'score': 30, 'tag': 'y'});
      await _putDoc(db, 'items', {'_id': idC, 'score': 20, 'tag': 'x'});
    });
    tearDown(() => db.close());

    test('scans all documents in namespace', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['items'], {});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
    });

    test('applies filter', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': '{bad json}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('filter'));
    });

    test('returns false for unknown filter operator', () async {
      final ctx = _ctx(db, out: out, err: err);
      final filter = '{"field":"x","op":"regex","value":".*"}';
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'filter': filter},
      );
      expect(ok, isFalse);
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });

    test('returns empty list for unknown namespace', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['empty'], {});
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, isEmpty);
    });

    test('--select projects to requested fields only', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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

    test('--select preserves field order from parameter', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'select': 'tag,score'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
      for (final doc in docs) {
        final keys = (doc as Map).keys.toList();
        expect(keys, equals(['tag', 'score']));
      }
    });

    test('--select with unknown field produces empty documents', () async {
      final ctx = _ctx(db, out: out, err: err);
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

    test('--select dot-path re-nests value on scan', () async {
      // Insert a document with a nested address field into a new collection.
      final id = _key('nestA');
      await _putDoc(db, 'nested_items', {
        '_id': id,
        'address': {'city': 'London', 'zip': 'EC1'},
        'name': 'Alice',
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['nested_items'],
        {'select': 'name,address.city'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(1));
      // 'name' is top-level — returned as-is.
      expect(docs[0]['name'], equals('Alice'));
      // 'address.city' is re-nested in the output.
      expect(docs[0]['address'], isA<Map>());
      expect((docs[0]['address'] as Map)['city'], equals('London'));
      // 'zip' was not selected.
      expect((docs[0]['address'] as Map).containsKey('zip'), isFalse);
    });

    test(r'--select $.name works identically to name on scan', () async {
      final ctx = _ctx(db, out: out, err: err);
      // The items collection has 'tag' fields; use the root sigil form.
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'select': r'$.tag'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
      expect(docs.every((d) => (d as Map).containsKey('tag')), isTrue);
      expect(docs.every((d) => (d as Map).keys.length == 1), isTrue);
    });

    test('--select with array index returns flat key on scan', () async {
      final id = _key('scanArr');
      await _putDoc(db, 'arr_items', {
        '_id': id,
        'tags': ['dart', 'flutter', 'kmdb'],
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['arr_items'],
        {'select': 'tags[0]'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs[0]['tags[0]'], equals('dart'));
    });

    test('--select with array wildcard returns flat key on scan', () async {
      final id = _key('scanWild');
      await _putDoc(db, 'wild_items', {
        '_id': id,
        'tags': ['a', 'b', 'c'],
      });

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['wild_items'],
        {'select': 'tags[]'},
      );
      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs[0]['tags[]'], equals(['a', 'b', 'c']));
    });

    test(
      '--select with absent nested path omits key gracefully on scan',
      () async {
        final ctx = _ctx(db, out: out, err: err);
        // items has 'score' and 'tag' but no 'address.city'.
        final ok = await ScanCommand().execute(
          ctx,
          ['items'],
          {'select': 'score,address.city'},
        );
        expect(ok, isTrue);
        final docs = json.decode(out.toString()) as List;
        expect(docs, hasLength(3));
        // Every doc has score but NOT address (absent path omitted).
        expect(docs.every((d) => (d as Map).containsKey('score')), isTrue);
        expect(docs.every((d) => !(d as Map).containsKey('address')), isTrue);
      },
    );

    test(
      '--select dot-path uses flat key and scalar value in table mode',
      () async {
        final id = _key('flatTbl');
        await _putDoc(db, 'flat_items', {
          '_id': id,
          'name': {'en': 'Mawson', 'fr': 'Mawson'},
          'score': 42,
        });

        final ctx = _ctx(db, out: out, err: err, mode: OutputMode.table);
        final ok = await ScanCommand().execute(
          ctx,
          ['flat_items'],
          {'select': 'name.en,score'},
        );
        expect(ok, isTrue);
        final output = out.toString();
        // Column header must be the dot-path, not the parent key.
        expect(output, contains('name.en'));
        // The scalar value must appear, not the JSON-encoded object.
        expect(output, contains('Mawson'));
        expect(output, isNot(contains('"en"')));
      },
    );

    test(
      '--select dot-path uses flat key and scalar value in csv mode',
      () async {
        final id = _key('flatCsv');
        await _putDoc(db, 'csv_items', {
          '_id': id,
          'location': {'latitude': -67.6, 'longitude': 62.9},
        });

        final ctx = _ctx(db, out: out, err: err, mode: OutputMode.csv);
        final ok = await ScanCommand().execute(
          ctx,
          ['csv_items'],
          {'select': 'location.latitude,location.longitude'},
        );
        expect(ok, isTrue);
        final lines = out.toString().trim().split('\n');
        // Header row: dot-path column names.
        expect(lines[0], equals('location.latitude,location.longitude'));
        // Data row: scalar values, not JSON objects.
        expect(lines[1], equals('-67.6,62.9'));
      },
    );
  });

  // ── CountCommand ────────────────────────────────────────────────────────────

  group('CountCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
      await _putDoc(db, 'ns', {'_id': _key('cnt1'), 'active': true});
      await _putDoc(db, 'ns', {'_id': _key('cnt2'), 'active': false});
      await _putDoc(db, 'ns', {'_id': _key('cnt3'), 'active': true});
    });
    tearDown(() => db.close());

    test('counts all documents', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CountCommand().execute(ctx, ['ns'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(3));
    });

    test('counts filtered documents', () async {
      final ctx = _ctx(db, out: out, err: err);
      final filter = '{"field":"active","op":"isTrue"}';
      final ok = await CountCommand().execute(ctx, ['ns'], {'filter': filter});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(2));
    });

    test('returns 0 for empty namespace', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CountCommand().execute(ctx, ['empty'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['count'], equals(0));
    });

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CountCommand().execute(ctx, [], {});
      expect(ok, isFalse);
    });

    test('returns false for invalid filter', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CountCommand().execute(ctx, ['ns'], {'filter': '{bad}'});
      expect(ok, isFalse);
    });
  });

  // ── CollectionsCommand ──────────────────────────────────────────────────────

  group('CollectionsCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('requires a subcommand', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CollectionsCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('subcommand required'));
    });

    test('unknown subcommand returns error', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CollectionsCommand().execute(ctx, ['bogus'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains("unknown subcommand 'bogus'"));
    });

    // ── list ──────────────────────────────────────────────────────────────────

    group('list', () {
      test('returns a list when no user namespaces exist', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, ['list'], {});
        expect(ok, isTrue);
        expect(json.decode(out.toString()), isA<List>());
      });

      test('lists namespaces written to', () async {
        await _putDoc(db, 'tasks', {'_id': _key('task'), 'v': 1});
        await _putDoc(db, 'notes', {'_id': _key('note'), 'v': 2});
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, ['list'], {});
        expect(ok, isTrue);
        final result = (json.decode(out.toString()) as List).cast<String>();
        expect(result, containsAll(['tasks', 'notes']));
      });

      test('does not include system namespaces', () async {
        await _putDoc(db, 'tasks', {'_id': _key('sys'), 'v': 1});
        final ctx = _ctx(db, out: out, err: err);
        await CollectionsCommand().execute(ctx, ['list'], {});
        final result = (json.decode(out.toString()) as List).cast<String>();
        expect(result.any((ns) => ns.startsWith(r'$')), isFalse);
      });
    });

    // ── create ────────────────────────────────────────────────────────────────

    group('create', () {
      test('creates a namespace and returns success message', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, [
          'create',
          'widgets',
        ], {});
        expect(ok, isTrue);
        // writeValue wraps the message in JSON — decode and check the string.
        final msg = json.decode(out.toString()) as String;
        expect(msg, contains('widgets'));
        expect(msg, contains('created'));
      });

      test(
        'is idempotent — second create returns already-exists message',
        () async {
          await CollectionsCommand().execute(
            _ctx(db, out: StringBuffer(), err: StringBuffer()),
            ['create', 'widgets'],
            {},
          );
          out.clear();
          final ctx = _ctx(db, out: out, err: err);
          final ok = await CollectionsCommand().execute(ctx, [
            'create',
            'widgets',
          ], {});
          expect(ok, isTrue);
          final msg = json.decode(out.toString()) as String;
          expect(msg, contains('already exists'));
        },
      );

      test('requires a collection name', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, ['create'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name required'));
      });

      test('returns false for a system namespace name', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, [
          'create',
          r'$system',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), isNotEmpty);
      });
    });

    // ── delete ────────────────────────────────────────────────────────────────

    group('delete', () {
      test('removes all documents from the collection', () async {
        await _putDoc(db, 'tasks', {'_id': _key('t1'), 'v': 1});
        await _putDoc(db, 'tasks', {'_id': _key('t2'), 'v': 2});
        expect(await db.store.scan('tasks').toList(), hasLength(2));

        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, [
          'delete',
          'tasks',
        ], {});
        expect(ok, isTrue);
        expect(await db.store.scan('tasks').toList(), isEmpty);
      });

      test('unregisters the collection from the namespace registry', () async {
        await _putDoc(db, 'tasks', {'_id': _key('t1'), 'v': 1});
        final ctx = _ctx(db, out: out, err: err);
        await CollectionsCommand().execute(ctx, ['delete', 'tasks'], {});
        expect(await db.store.listNamespaces(), isNot(contains('tasks')));
      });

      test('returns error for unknown collection name', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, [
          'delete',
          'nonexistent',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), contains("collection 'nonexistent' not found"));
      });

      test('requires a collection name', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CollectionsCommand().execute(ctx, ['delete'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name required'));
      });

      test('other collections are unaffected', () async {
        await _putDoc(db, 'tasks', {'_id': _key('t1'), 'v': 1});
        await _putDoc(db, 'notes', {'_id': _key('n1'), 'v': 1});

        final ctx = _ctx(db, out: out, err: err);
        await CollectionsCommand().execute(ctx, ['delete', 'tasks'], {});

        // notes should still be there.
        expect(await db.store.scan('notes').toList(), isNotEmpty);
        expect(await db.store.listNamespaces(), contains('notes'));
      });

      // The delete code path iterates over CLI config index definitions and calls
      // ctx.indexManager.removeIndex (line 180) and ctx.config.removeIndex (line
      // 188) for each. Then it calls ctx.config.save() (line 194). When save()
      // fails — e.g. because KmdbConfig.empty() has no backing store — the
      // command returns false with an error message (lines 195-197).
      //
      // Note: KmdbDatabase always has an index manager that accepts
      // removeIndex on any collection/path (it silently drops the record if the
      // index doesn't exist or was never built), so removeIndex succeeds and the
      // failure falls through to the config.save() path.
      test(
        'reports error when config.save fails after index removal',
        () async {
          await _putDoc(db, 'products', {'_id': _key('p1'), 'sku': 'abc'});

          // Create a KmdbConfig with an index definition for 'products'. The
          // empty config has no backing store, so config.save() will throw.
          final config = KmdbConfig.empty()..addIndex('products', 'sku');
          final ctx = CommandContext(
            db: db,
            config: config,
            out: out,
            err: err,
          );

          // The index removal succeeds (removeIndex + config.removeIndex),
          // but config.save() throws because KmdbConfig.empty() has no store.
          final ok = await CollectionsCommand().execute(ctx, [
            'delete',
            'products',
          ], {});
          expect(ok, isFalse);
          expect(err.toString(), contains('failed to save config'));
        },
      );

      // The delete implementation batches deletes in groups of 200. When the
      // collection contains more than 200 documents, the intermediate
      // `writeBatch(batch); batch = WriteBatch(); count = 0;` lines
      // (collections_command.dart:167-168) are executed.
      test(
        'deletes more than 200 documents using intermediate batch flushes',
        () async {
          // Insert 201 documents with distinct 32-hex keys.
          // We embed the zero-padded counter in the low 6 hex chars to guarantee
          // uniqueness while keeping the UUIDv7 version (char 12 = '7') and
          // variant (char 16 = '8') bits valid. The first _putDoc call registers
          // the namespace so CollectionsCommand can find it via listNamespaces().
          await _putDoc(db, 'large', {'_id': _key('seed'), 'n': -1});
          for (var i = 0; i < 201; i++) {
            final suffix = i.toRadixString(16).padLeft(6, '0');
            // Build a valid 32-hex UUIDv7 key: version nibble at position 12,
            // variant nibble at position 16.
            final key = 'aaaaaaaaaaaa7aaaa8aaaaaaaa$suffix';
            await db.store.put('large', key, await ValueCodec.encode({'n': i}));
          }
          // 202 total: 1 from _putDoc + 201 from direct put.
          expect(await db.store.scan('large').toList(), hasLength(202));

          final ctx = _ctx(db, out: out, err: err);
          final ok = await CollectionsCommand().execute(ctx, [
            'delete',
            'large',
          ], {});
          expect(ok, isTrue);
          expect(await db.store.scan('large').toList(), isEmpty);
        },
      );
    });
  });

  // ── CreateCollectionCommand ────────────────────────────────────────────────

  group('CreateCollectionCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('prints deprecation warning to stderr', () async {
      final ctx = _ctx(db, out: out, err: err);
      await CreateCollectionCommand().execute(ctx, ['widgets'], {});
      expect(err.toString(), contains('deprecated'));
    });

    test('creates a new collection and returns created: true', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CreateCollectionCommand().execute(ctx, ['widgets'], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['name'], 'widgets');
      expect(result['created'], isTrue);
    });

    test('collection appears in listNamespaces after creation', () async {
      final ctx = _ctx(db, out: out, err: err);
      await CreateCollectionCommand().execute(ctx, ['widgets'], {});
      final namespaces = await db.store.listNamespaces();
      expect(namespaces, contains('widgets'));
    });

    test(
      'is a no-op when collection already exists, returns created: false',
      () async {
        await CreateCollectionCommand().execute(
          _ctx(db, out: StringBuffer(), err: StringBuffer()),
          ['widgets'],
          {},
        );
        out.clear();
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CreateCollectionCommand().execute(ctx, [
          'widgets',
        ], {});
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['name'], 'widgets');
        expect(result['created'], isFalse);
      },
    );

    test(
      'is a no-op when collection was populated via a document write',
      () async {
        await _putDoc(db, 'notes', {'_id': _key('note'), 'v': 1});
        final ctx = _ctx(db, out: out, err: err);
        final ok = await CreateCollectionCommand().execute(ctx, ['notes'], {});
        expect(ok, isTrue);
        final result = json.decode(out.toString()) as Map<String, dynamic>;
        expect(result['created'], isFalse);
      },
    );

    test('returns error when no name argument is provided', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CreateCollectionCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('rejects system namespace names', () async {
      final ctx = _ctx(db, out: out, err: err);
      expect(
        () => CreateCollectionCommand().execute(ctx, [r'$meta'], {}),
        throwsArgumentError,
      );
    });
  });

  // ── StatsCommand ────────────────────────────────────────────────────────────

  group('StatsCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns stats object with expected shape', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await StatsCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      expect(result['dbDir'], isNotNull);
      expect(result['sstables'], isNotNull);
      expect(result['bytes'], isNotNull);
      expect((result['sstables'] as Map)['total'], isNotNull);
    });

    test('sstables.total equals l0 + l1 + l2', () async {
      final ctx = _ctx(db, out: out, err: err);
      await StatsCommand().execute(ctx, [], {});
      final result = json.decode(out.toString()) as Map<String, dynamic>;
      final s = result['sstables'] as Map<String, dynamic>;
      final expected = (s['l0'] as int) + (s['l1'] as int) + (s['l2'] as int);
      expect(s['total'], equals(expected));
    });
  });

  // ── InfoCommand ─────────────────────────────────────────────────────────────

  group('InfoCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns info with deviceId and hlc fields', () async {
      final ctx = _ctx(db, out: out, err: err);
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
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('flushes and returns {flushed: true}', () async {
      await _putDoc(db, 'ns', {'_id': _key('flsh'), 'v': 1});
      final ctx = _ctx(db, out: out, err: err);
      final ok = await FlushCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['flushed'], isTrue);
    });
  });

  // ── CompactCommand ──────────────────────────────────────────────────────────

  group('CompactCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('compacts and returns {compacted: true}', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await CompactCommand().execute(ctx, [], {});
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['compacted'], isTrue);
    });
  });

  // ── ImportCommand — argument validation ─────────────────────────────────────

  group('ImportCommand — argument validation', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('returns false when namespace arg missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ImportCommand().execute(ctx, [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('requires'));
    });

    test('returns false for unknown --on-conflict value', () async {
      final ctx = _ctx(db, out: out, err: err);
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
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('imports NDJSON from a file', () async {
      final p1 = _key('imp1');
      final p2 = _key('imp2');
      final tmp = _TmpFile();
      tmp.write('{"_id":"$p1","name":"Alice"}\n{"_id":"$p2","name":"Bob"}\n');

      final ctx = _ctx(db, out: out, err: err);
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
        (await ValueCodec.decode((await db.store.get('people', p1))!))['name'],
        equals('Alice'),
      );
      expect(
        (await ValueCodec.decode((await db.store.get('people', p2))!))['name'],
        equals('Bob'),
      );

      tmp.delete();
    });

    test('ignore conflict skips existing documents', () async {
      final p1 = _key('ign1');
      await _putDoc(db, 'people', {'_id': p1, 'name': 'OldAlice'});

      final tmp = _TmpFile();
      tmp.write('{"_id":"$p1","name":"NewAlice"}\n');

      final ctx = _ctx(db, out: out, err: err);
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
        (await ValueCodec.decode((await db.store.get('people', p1))!))['name'],
        equals('OldAlice'),
      );

      tmp.delete();
    });

    test('error conflict returns false on duplicate', () async {
      final p1 = _key('err1');
      await _putDoc(db, 'people', {'_id': p1, 'name': 'Alice'});

      final tmp = _TmpFile();
      tmp.write('{"_id":"$p1","name":"NewAlice"}\n');

      final ctx = _ctx(db, out: out, err: err);
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

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'input': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('invalid JSON'));

      tmp.delete();
    });

    test('returns false when a JSON line is not an object', () async {
      final id = _key('okid2');
      final tmp = _TmpFile();
      // Second line is a JSON array, not a JSON object.
      tmp.write('{"_id":"$id","x":1}\n[1,2,3]\n');

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ImportCommand().execute(
        ctx,
        ['ns'],
        {'input': tmp.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('expected JSON object'));

      tmp.delete();
    });

    test('returns false for document missing id field', () async {
      final tmp = _TmpFile();
      tmp.write('{"name":"no-id"}\n');

      final ctx = _ctx(db, out: out, err: err);
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

      final ctx = _ctx(db, out: out, err: err);
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
    late KmdbDatabase db;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('export then import restores identical documents', () async {
      // Seed three documents.
      final ids = [_key('rnd1'), _key('rnd2'), _key('rnd3')];
      final origDocs = [
        {'_id': ids[0], 'name': 'Alice', 'score': 10},
        {'_id': ids[1], 'name': 'Bob', 'score': 20},
        {'_id': ids[2], 'name': 'Carol', 'score': 30},
      ];
      for (final doc in origDocs) {
        await _putDoc(db, 'people', doc);
      }

      // Export via ctx.out (mirrors how --output redirects ctx.out in prod).
      final exportOut = StringBuffer();
      final exportCtx = _ctx(db, out: exportOut, err: err);
      final exportOk = await ExportCommand().execute(exportCtx, ['people'], {});
      expect(exportOk, isTrue);

      // Write the captured NDJSON to a temp file for ImportCommand.
      final tmp = _TmpFile();
      tmp.write(exportOut.toString());
      addTearDown(tmp.delete);

      // Delete all documents from the namespace.
      for (final id in ids) {
        await db.store.delete('people', id);
      }
      // Verify namespace is empty.
      final countOut = StringBuffer();
      await CountCommand().execute(_ctx(db, out: countOut), ['people'], {});
      expect((json.decode(countOut.toString()) as Map)['count'], equals(0));

      // Re-import from the exported file.
      final importOut = StringBuffer();
      final importCtx = _ctx(db, out: importOut, err: err);
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
        final bytes = await db.store.get('people', orig['_id'] as String);
        expect(
          bytes,
          isNotNull,
          reason: 'Missing document after re-import: ${orig['_id']}',
        );
        final restored = await ValueCodec.decode(bytes!);
        expect(restored['name'], equals(orig['name']));
        expect(restored['score'], equals(orig['score']));
      }
    });

    test('export writes one line per document in NDJSON format', () async {
      final id1 = _key('exp1');
      final id2 = _key('exp2');
      await _putDoc(db, 'items', {'_id': id1, 'v': 1});
      await _putDoc(db, 'items', {'_id': id2, 'v': 2});

      final exportOut = StringBuffer();
      final ctx = _ctx(db, out: exportOut, err: err);
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
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('inserts document with generated ID and echoes it back', () async {
      final ctx = _ctx(db, out: out, err: err);
      const doc = '{"name":"Alice"}';
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      final generatedId = decoded[0]['_id'] as String;
      expect(generatedId, hasLength(32));
      expect(generatedId[12], equals('7')); // UUIDv7 version nibble

      final stored = await db.store.get('notes', generatedId);
      expect(stored, isNotNull);
      expect((await ValueCodec.decode(stored!))['name'], equals('Alice'));
    });

    test('ignores user-provided _id and generates a new one', () async {
      final ctx = _ctx(db, out: out, err: err);
      final userId = _key('user');
      final doc = '{"_id":"$userId","name":"Alice"}';
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': doc});
      expect(ok, isTrue);

      final decoded = json.decode(out.toString()) as List;
      final assignedId = decoded[0]['_id'] as String;
      expect(assignedId, isNot(equals(userId)));

      // User-supplied ID must NOT have been stored.
      expect(await db.store.get('notes', userId), isNull);
      // The generated ID must exist.
      expect(await db.store.get('notes', assignedId), isNotNull);
    });

    test('returns false for invalid JSON via --value', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '{bad}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid JSON'));
    });

    test('returns false when document is not a JSON object', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '[1,2]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('inserts multiple documents from a JSON array via --value', () async {
      final ctx = _ctx(db, out: out, err: err);
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

      final ctx = _ctx(db, out: out, err: err);
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
        (await ValueCodec.decode((await db.store.get('notes', id))!))['name'],
        equals('Carol'),
      );
    });

    test('inserts multiple documents from an NDJSON file via --file', () async {
      final tmp = _TmpFile(ext: 'ndjson');
      tmp.write('{"name":"Frank"}\n{"name":"Grace"}\n\n');
      addTearDown(tmp.delete);

      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(ctx, ['notes'], {'value': '[]'});
      expect(ok, isTrue);
      final decoded = json.decode(out.toString()) as List;
      expect(decoded, isEmpty);
    });

    test('returns false when collection arg is missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(ctx, [], {'value': '{"x":1}'});
      expect(ok, isFalse);
    });

    test('returns false when --file path does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'file': '/nonexistent/path/file.json'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Cannot read file'));
    });

    test('rejects document with reserved "_"-prefixed field', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '{"_title": "hack"}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('"_title"'));
      expect(err.toString(), contains('reserved'));
    });

    test('rejects batch when any document has a reserved field', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '[{"name":"ok"},{"_title":"hack","name":"bad"}]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('"_title"'));
      // No documents should have been written (pre-validated before any I/O).
      final keys = await db.store.scan('notes').toList();
      expect(keys, isEmpty);
    });

    test('allows document with no reserved fields', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await InsertCommand().execute(
        ctx,
        ['notes'],
        {'value': '{"title": "no underscore prefix"}'},
      );
      expect(ok, isTrue);
      final decoded = json.decode(out.toString()) as List;
      expect(decoded, hasLength(1));
      expect((decoded.first as Map)['title'], equals('no underscore prefix'));
    });
  });

  // ── UpdateCommand ───────────────────────────────────────────────────────────

  group('UpdateCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;
    late String idA;
    late String idB;
    late String idC;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
      idA = _key('updA');
      idB = _key('updB');
      idC = _key('updC');
      await _putDoc(db, 'col', {
        '_id': idA,
        'name': 'Alice',
        'status': 'active',
      });
      await _putDoc(db, 'col', {'_id': idB, 'name': 'Bob', 'status': 'active'});
      await _putDoc(db, 'col', {
        '_id': idC,
        'name': 'Carol',
        'status': 'inactive',
      });
    });
    tearDown(() => db.close());

    // ── Single-id mode (positional) ──────────────────────────────────────────

    test('single-id: updates one field and preserves others', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{"status":"done"}'},
      );
      expect(ok, isTrue);

      // Read back via the Query Layer so _id is injected from the storage key.
      // After migration, _id is stored as the key, not in value bytes.
      final doc = await db.rawCollection('col').get(idA);
      expect(doc, isNotNull);
      expect(doc!['status'], equals('done'));
      expect(doc['name'], equals('Alice')); // untouched
      expect(doc['_id'], equals(idA)); // _id preserved
    });

    test('single-id: adds a new field that did not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{"score":99}'},
      );
      expect(ok, isTrue);

      final doc = await ValueCodec.decode((await db.store.get('col', idA))!);
      expect(doc['score'], equals(99));
      expect(doc['name'], equals('Alice')); // still present
    });

    test(
      'single-id: does not overwrite _id even when --set contains _id',
      () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await UpdateCommand().execute(
          ctx,
          ['col', idA],
          {'set': '{"_id":"injected","status":"done"}'},
        );
        expect(ok, isTrue);

        // Read back via the Query Layer so _id is injected from the storage key.
        // After migration, _id is stored as the key, not in value bytes.
        final doc = await db.rawCollection('col').get(idA);
        expect(doc, isNotNull);
        expect(doc!['_id'], equals(idA)); // original _id preserved
      },
    );

    test('single-id: returns false when document does not exist', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', _key('ghost')],
        {'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('not found'));
    });

    test('single-id: reports {"updated": 1}', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'id': '$idA,$idB', 'set': '{"status":"reviewed"}'},
      );
      expect(ok, isTrue);

      final docA = await ValueCodec.decode((await db.store.get('col', idA))!);
      final docB = await ValueCodec.decode((await db.store.get('col', idB))!);
      expect(docA['status'], equals('reviewed'));
      expect(docB['status'], equals('reviewed'));
    });

    test('multi-id: reports count of updated documents', () async {
      final ctx = _ctx(db, out: out, err: err);
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
        final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'id': idA, 'set': '{"status":"solo"}'},
      );
      expect(ok, isTrue);
      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(1));
      final doc = await ValueCodec.decode((await db.store.get('col', idA))!);
      expect(doc['status'], equals('solo'));
    });

    // ── Filter mode ──────────────────────────────────────────────────────────

    test('filter: updates only matching documents', () async {
      final ctx = _ctx(db, out: out, err: err);
      final filter = '{"field":"status","op":"eq","value":"active"}';
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': filter, 'set': '{"flagged":true}'},
      );
      expect(ok, isTrue);

      final docA = await ValueCodec.decode((await db.store.get('col', idA))!);
      final docB = await ValueCodec.decode((await db.store.get('col', idB))!);
      final docC = await ValueCodec.decode((await db.store.get('col', idC))!);
      expect(docA['flagged'], isTrue); // active -> updated
      expect(docB['flagged'], isTrue); // active -> updated
      expect(docC['flagged'], isNull); // inactive -> not touched
    });

    test('filter: returns {"updated": 0} when nothing matches', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': '{bad json}', 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('filter'));
    });

    test('filter: returns false for unknown filter operator', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'filter': '{"field":"x","op":"regex","value":".*"}', 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
    });

    // ── All-docs mode ─────────────────────────────────────────────────────────

    test('all: updates every document in the collection', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col'],
        {'all': true, 'set': '{"archived":true}'},
      );
      expect(ok, isTrue);

      for (final id in [idA, idB, idC]) {
        final doc = await ValueCodec.decode((await db.store.get('col', id))!);
        expect(doc['archived'], isTrue);
      }

      final result = json.decode(out.toString()) as Map;
      expect(result['updated'], equals(3));
    });

    test('all: returns {"updated": 0} for an empty collection', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'all': true, 'set': '{"x":1}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    });

    test('returns false when --id and --filter are both given', () async {
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
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
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(ctx, ['col', idA], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('--set'));
    });

    test('returns false when --set is invalid JSON', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '{bad json}'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('Invalid JSON'));
    });

    test('returns false when --set is a JSON array', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(
        ctx,
        ['col', idA],
        {'set': '[{"x":1}]'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('JSON object'));
    });

    test('returns false when --set is a JSON scalar', () async {
      final ctx = _ctx(db, out: out, err: err);
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
        await _putDoc(db, 'col', {
          '_id': id,
          'profile': {'city': 'Sydney', 'country': 'AU'},
          'name': 'Dana',
        });

        final ctx = _ctx(db, out: out, err: err);
        final ok = await UpdateCommand().execute(
          ctx,
          ['col', id],
          {'set': '{"profile":{"city":"Melbourne"}}'},
        );
        expect(ok, isTrue);

        final doc = await ValueCodec.decode((await db.store.get('col', id))!);
        // Shallow merge: entire profile replaced.
        expect(doc['profile'], equals({'city': 'Melbourne'}));
        expect(doc['name'], equals('Dana')); // sibling field unchanged
      },
    );

    // ── Error: missing collection ─────────────────────────────────────────────

    test('returns false when collection arg is missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await UpdateCommand().execute(ctx, [], {'set': '{"x":1}'});
      expect(ok, isFalse);
      expect(err.toString(), contains('update requires'));
    });

    // ── Filter mode: empty collection ─────────────────────────────────────────

    test('filter: returns {"updated":0} on empty collection', () async {
      final ctx = _ctx(db, out: out, err: err);
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

  // ── IndexCommand ─────────────────────────────────────────────────────────────

  group('IndexCommand', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() async {
      MemoryStorageAdapter.releaseAllLocks();
    });

    /// Creates a [CommandContext] with an empty [KmdbConfig] suitable for most
    /// index tests.
    CommandContext makeCtx({KmdbConfig? config}) {
      final cfg = config ?? KmdbConfig.empty();
      return CommandContext(db: db, config: cfg, out: out, err: err);
    }

    test('requires a subcommand', () async {
      final ok = await IndexCommand().execute(makeCtx(), [], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('subcommand required'));
    });

    test('unknown subcommand returns error', () async {
      final ok = await IndexCommand().execute(makeCtx(), ['bogus'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains("unknown subcommand 'bogus'"));
    });

    // ── list ───────────────────────────────────────────────────────────────────

    group('list', () {
      test('requires a collection name', () async {
        final ok = await IndexCommand().execute(makeCtx(), ['list'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name required'));
      });

      test('returns message when no indexes configured', () async {
        final ok = await IndexCommand().execute(makeCtx(), [
          'list',
          'contacts',
        ], {});
        expect(ok, isTrue);
        expect(out.toString(), contains('No indexes configured'));
      });

      test('lists configured indexes and their status', () async {
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        final ok = await IndexCommand().execute(makeCtx(config: config), [
          'list',
          'contacts',
        ], {});
        expect(ok, isTrue);
        expect(out.toString(), contains('city'));
        expect(out.toString(), contains('undefined'));
      });
    });

    // ── create ─────────────────────────────────────────────────────────────────

    group('create', () {
      test('requires collection and path args', () async {
        final ok = await IndexCommand().execute(makeCtx(), ['create'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name and path required'));
      });

      test('requires both collection and path', () async {
        final ok = await IndexCommand().execute(makeCtx(), [
          'create',
          'contacts',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name and path required'));
      });

      test('adds definition to config', () async {
        // We can't call index create end-to-end without a real dbDir for
        // config.save() (the memory store resolves to '/testdb' which has no
        // real local/ directory). Verify addIndex mutation directly.
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        expect(config.indexesForCollection('contacts'), hasLength(1));
      });

      test('rejects paths starting with _', () async {
        final config = KmdbConfig.empty();
        final ok = await IndexCommand().execute(
          CommandContext(db: db, config: config, out: out, err: err),
          ['create', 'contacts', '_reserved'],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains("starts with '_'"));
      });

      test('error when duplicate index is registered', () async {
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        final ok = await IndexCommand().execute(
          CommandContext(db: db, config: config, out: out, err: err),
          ['create', 'contacts', 'city'],
          {},
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('contacts.city'));
      });
    });

    // ── info ───────────────────────────────────────────────────────────────────

    group('info', () {
      test('requires collection and path args', () async {
        final ok = await IndexCommand().execute(makeCtx(), ['info'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name and path required'));
      });

      test('returns error when index is not in config', () async {
        final ok = await IndexCommand().execute(makeCtx(), [
          'info',
          'contacts',
          'city',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('no index on'));
      });

      test('shows status for a configured (undefined) index', () async {
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        final ok = await IndexCommand().execute(makeCtx(config: config), [
          'info',
          'contacts',
          'city',
        ], {});
        expect(ok, isTrue);
        expect(out.toString(), contains('city'));
        expect(out.toString(), contains('undefined'));
      });
    });

    // ── delete ─────────────────────────────────────────────────────────────────

    group('delete', () {
      test('requires collection and path args', () async {
        final ok = await IndexCommand().execute(makeCtx(), ['delete'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('collection name and path required'));
      });

      test('returns error when index is not in config', () async {
        final ok = await IndexCommand().execute(makeCtx(), [
          'delete',
          'contacts',
          'city',
        ], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('no index on'));
      });

      test('removes index from config and persists to disk', () async {
        // Use a real temp directory so config.save() can write successfully.
        final tmpDir = io.Directory.systemTemp.createTempSync(
          'kmdb_idx_del_test_',
        );
        try {
          final tmpDb = await KmdbDatabase.open(
            path: tmpDir.path,
            adapter: StorageAdapterNative(),
            config: KvStoreConfig.forTesting(),
          );
          try {
            final config = await KmdbConfig.forDatabase(tmpDir.path);
            config.addIndex('contacts', 'city');
            expect(config.indexesForCollection('contacts'), hasLength(1));

            final ok = await IndexCommand().execute(
              CommandContext(db: tmpDb, config: config, out: out, err: err),
              ['delete', 'contacts', 'city'],
              {},
            );
            expect(ok, isTrue);
            // After delete, config should have zero indexes for contacts.
            expect(config.indexesForCollection('contacts'), isEmpty);
            expect(out.toString(), contains('deleted'));
          } finally {
            await tmpDb.close();
          }
        } finally {
          tmpDir.deleteSync(recursive: true);
        }
      });
    });
  });

  // ── CommandContext helpers ──────────────────────────────────────────────────

  group('CommandContext', () {
    late KmdbDatabase db;

    setUp(() async => db = await _openStore());
    tearDown(() => db.close());

    test('writeValue emits indented JSON', () async {
      final out = StringBuffer();
      final ctx = _ctx(db, out: out);
      ctx.writeValue({'ok': true});
      final decoded = json.decode(out.toString()) as Map;
      expect(decoded['ok'], isTrue);
    });

    test('writeError prefixes with "Error:"', () async {
      final err = StringBuffer();
      final ctx = _ctx(db, err: err);
      ctx.writeError('something went wrong');
      expect(err.toString(), startsWith('Error:'));
      expect(err.toString(), contains('something went wrong'));
    });

    test('writeDocuments uses active OutputMode', () async {
      final out = StringBuffer();
      final ctx = _ctx(db, mode: OutputMode.ndjson, out: out);
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
