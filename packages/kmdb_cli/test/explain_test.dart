// Copyright 2026 The Authors.
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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/scan_command.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Each call gets a unique in-memory path so tests cannot accidentally share
/// a lock even when run concurrently.
var _dbCounter = 0;

Future<KmdbDatabase> _openStore({
  List<IndexDefinition> indexes = const [],
}) async {
  return KmdbDatabase.open(
    path: '/testdb_${_dbCounter++}',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    indexes: indexes,
  );
}

CommandContext _ctx(
  KmdbDatabase db, {
  OutputMode mode = OutputMode.json,
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  db: db,
  mode: mode,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

String _key(String seed) {
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

Future<void> _putDoc(
  KmdbDatabase db,
  String coll,
  Map<String, dynamic> doc,
) async {
  final id = doc['_id'] as String? ?? _key(doc.toString());
  await db.store.put(coll, id, ValueCodec.encode({...doc}..remove('_id')));
}

/// Waits until [manager] reports [IndexStatus.current] for [namespace]/[path],
/// or times out after 1 second.
Future<void> _waitForCurrent(
  IndexManager manager,
  String namespace,
  String path,
) async {
  for (var i = 0; i < 50; i++) {
    final state = await manager.getOrActivate(namespace, path);
    if (state.status == IndexStatus.current) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('scan --explain', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('no indexes — reports full scan in table format', () async {
      await _putDoc(db, 'people', {'name': 'Alice', 'age': 30});

      final ctx = _ctx(db, mode: OutputMode.table, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['people'],
        {
          'filter': '{"field":"name","op":"eq","value":"Alice"}',
          'explain': true,
        },
      );

      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('Query plan'));
      expect(output, contains('full scan'));
      expect(output, contains('Scanned'));
      expect(output, contains('Matched'));
      expect(output, contains('Returned'));
    });

    test(
      'no indexes — filter shows indexStatus: none in JSON explain',
      () async {
        await _putDoc(db, 'people', {'name': 'Alice', 'age': 30});

        final ctx = _ctx(db, mode: OutputMode.json, out: out, err: err);
        await ScanCommand().execute(
          ctx,
          ['people'],
          {
            'filter': '{"field":"name","op":"eq","value":"Alice"}',
            'explain': true,
          },
        );

        // Find the _explain block (first JSON object emitted).
        final raw = out.toString();
        final firstBrace = raw.indexOf('{');
        // Parse just the first JSON object.
        var depth = 0;
        var end = firstBrace;
        for (var i = firstBrace; i < raw.length; i++) {
          if (raw[i] == '{') depth++;
          if (raw[i] == '}') depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
        final explainMap =
            json.decode(raw.substring(firstBrace, end + 1))
                as Map<String, dynamic>;
        final explain = explainMap['_explain'] as Map<String, dynamic>;

        expect(explain['strategy'], 'fullScan');
        final filters = explain['filters'] as List<dynamic>;
        expect(filters, hasLength(1));
        final f = filters.first as Map<String, dynamic>;
        expect(f['indexUsed'], isFalse);
        expect(f['indexStatus'], 'none');
      },
    );

    test('--explain with no filter — empty filter list, full scan', () async {
      await _putDoc(db, 'people', {'name': 'Alice', 'age': 30});

      final ctx = _ctx(db, mode: OutputMode.table, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['people'],
        {'explain': true},
      );

      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('Query plan'));
      expect(output, contains('full scan'));
      // No filter rows (Filters line absent or shows nothing).
      expect(output, isNot(contains('Filters')));
    });

    test('current index — reports index scan in table format', () async {
      // Open a new database with the name index defined at open time.
      final dbIdx = await _openStore(
        indexes: [IndexDefinition('people', 'name')],
      );
      addTearDown(() => dbIdx.close());

      await _putDoc(dbIdx, 'people', {'name': 'Alice', 'age': 30});
      await _putDoc(dbIdx, 'people', {'name': 'Bob', 'age': 25});

      // Trigger build and wait for the index to become current.
      await _waitForCurrent(dbIdx.indexManager, 'people', 'name');

      final ctx = _ctx(dbIdx, mode: OutputMode.table, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['people'],
        {
          'filter': '{"field":"name","op":"eq","value":"Alice"}',
          'explain': true,
        },
      );

      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('Query plan'));
      expect(output, contains('index scan'));
      expect(output, contains('[index: current]'));
    });

    test('current index — JSON format includes _explain key', () async {
      // Open a new database with the name index defined at open time.
      final dbIdx = await _openStore(
        indexes: [IndexDefinition('people', 'name')],
      );
      addTearDown(() => dbIdx.close());

      await _putDoc(dbIdx, 'people', {'name': 'Alice', 'age': 30});
      await _waitForCurrent(dbIdx.indexManager, 'people', 'name');

      final ctx = _ctx(dbIdx, mode: OutputMode.json, out: out, err: err);
      await ScanCommand().execute(
        ctx,
        ['people'],
        {
          'filter': '{"field":"name","op":"eq","value":"Alice"}',
          'explain': true,
        },
      );

      // The _explain block is the first JSON object emitted.
      final raw = out.toString();
      final firstBrace = raw.indexOf('{');
      var depth = 0;
      var end = firstBrace;
      for (var i = firstBrace; i < raw.length; i++) {
        if (raw[i] == '{') depth++;
        if (raw[i] == '}') depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
      final explainMap =
          json.decode(raw.substring(firstBrace, end + 1))
              as Map<String, dynamic>;
      expect(explainMap, contains('_explain'));

      final explain = explainMap['_explain'] as Map<String, dynamic>;
      expect(explain['strategy'], 'indexScan');
      expect(explain, contains('documentsScanned'));
      expect(explain, contains('documentsMatched'));
      expect(explain, contains('documentsReturned'));

      final filters = explain['filters'] as List<dynamic>;
      expect(filters, hasLength(1));
      final f = filters.first as Map<String, dynamic>;
      expect(f['indexUsed'], isTrue);
      expect(f['field'], 'name');
    });

    test('without --explain flag — no plan output', () async {
      await _putDoc(db, 'people', {'name': 'Alice', 'age': 30});

      final ctx = _ctx(db, mode: OutputMode.table, out: out, err: err);
      await ScanCommand().execute(ctx, ['people'], {});

      expect(out.toString(), isNot(contains('Query plan')));
    });
  });

  // ── scan --key-prefix ──────────────────────────────────────────────────────

  group('scan --key-prefix', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    // Note: --key-prefix passes the value directly to store.scan(startKey:),
    // so the value must be a valid 32-char UUIDv7 key. The scan returns all
    // documents from that start key onward (not a substring prefix match).
    test('scans from the given start key onward', () async {
      // Three keys in ascending sort order. All are valid UUIDv7 keys.
      final keyA = _key('aaa'); // sorts first
      final keyB = _key('bbb'); // sorts second
      final keyC = _key('ccc'); // sorts third

      await db.store.put('items', keyA, ValueCodec.encode({'n': 1}));
      await db.store.put('items', keyB, ValueCodec.encode({'n': 2}));
      await db.store.put('items', keyC, ValueCodec.encode({'n': 3}));

      // Scanning from keyB should return keyB and keyC.
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'key-prefix': keyB},
      );

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      // keyB and keyC should be returned; keyA is before the start.
      expect(docs, hasLength(greaterThanOrEqualTo(1)));
      final ids = docs.map((d) => (d as Map)['_id']).toSet();
      expect(ids, contains(keyB));
      expect(ids, isNot(contains(keyA)));
    });

    test('scan from a key beyond all stored keys returns empty', () async {
      // Insert a document with keyA (sorts before keyC).
      final keyA = _key('abc');
      final keyC = _key('zzz'); // sorts after keyA
      await db.store.put('items', keyA, ValueCodec.encode({'x': 1}));

      // Scanning from keyC (which sorts after keyA) yields nothing.
      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'key-prefix': keyC},
      );

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, isEmpty);
    });

    test('applies filter within key-prefix scan', () async {
      final keyA = _key('aaa');
      final keyB = _key('bbb');
      await db.store.put('items', keyA, ValueCodec.encode({'n': 1}));
      await db.store.put('items', keyB, ValueCodec.encode({'n': 2}));

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['items'],
        {'key-prefix': keyA, 'filter': '{"field":"n","op":"eq","value":2}'},
      );

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(1));
      expect((docs.first as Map)['n'], equals(2));
    });
  });

  // ── scan --explain full-scan path ─────────────────────────────────────────

  group('scan --explain full-scan path', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('--explain with no filter outputs fullScan strategy', () async {
      await _putDoc(db, 'notes', {'text': 'hello'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['notes'], {'explain': true});

      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('fullScan'));
      expect(output, contains('documentsScanned'));
    });

    test('--explain with complex filter uses fullScan strategy', () async {
      await _putDoc(db, 'notes', {'score': 5});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['notes'],
        {'explain': true, 'filter': '{"field":"score","op":"gt","value":3}'},
      );

      expect(ok, isTrue);
      final output = out.toString();
      expect(output, contains('fullScan'));
    });
  });

  // ── scan --order-by ───────────────────────────────────────────────────────

  group('scan --order-by', () {
    late KmdbDatabase db;
    late StringBuffer out;
    late StringBuffer err;

    setUp(() async {
      db = await _openStore();
      out = StringBuffer();
      err = StringBuffer();
    });
    tearDown(() => db.close());

    test('sorts documents by a string field', () async {
      await _putDoc(db, 'people', {'name': 'Charlie'});
      await _putDoc(db, 'people', {'name': 'Alice'});
      await _putDoc(db, 'people', {'name': 'Bob'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['people'],
        {'order-by': 'name'},
      );

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      final names = docs.map((d) => (d as Map)['name']).toList();
      expect(names, equals(['Alice', 'Bob', 'Charlie']));
    });

    test('handles null field values during sort', () async {
      // One doc lacks the sort field (null), two have string values.
      // Exercises the null-left branch in _compareValues.
      await _putDoc(db, 'widgets', {'x': 1}); // no 'label'
      await _putDoc(db, 'widgets', {'x': 2, 'label': 'B'});
      await _putDoc(db, 'widgets', {'x': 3, 'label': 'A'});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['widgets'],
        {'order-by': 'label'},
      );

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(3));
    });

    test('accepts limit passed as a string', () async {
      await _putDoc(db, 'things', {'v': 1});
      await _putDoc(db, 'things', {'v': 2});
      await _putDoc(db, 'things', {'v': 3});

      final ctx = _ctx(db, out: out, err: err);
      final ok = await ScanCommand().execute(ctx, ['things'], {'limit': '2'});

      expect(ok, isTrue);
      final docs = json.decode(out.toString()) as List;
      expect(docs, hasLength(2));
    });
  });

  // ── scan --explain with building index ────────────────────────────────────

  group('scan --explain with building index', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    test('falls back to full scan when index is not yet current', () async {
      final dbIdx = await _openStore(
        indexes: [IndexDefinition('nodes', 'tag')],
      );
      addTearDown(() => dbIdx.close());

      await _putDoc(dbIdx, 'nodes', {'tag': 'x'});
      await _putDoc(dbIdx, 'nodes', {'tag': 'y'});

      // Do NOT call _waitForCurrent — on first getOrActivate the index manager
      // returns IndexStatus.building and triggers the async build. The scan
      // must fall back to a full scan and still report indexStatus != 'none'.
      final ctx = _ctx(dbIdx, mode: OutputMode.json, out: out, err: err);
      final ok = await ScanCommand().execute(
        ctx,
        ['nodes'],
        {'filter': '{"field":"tag","op":"eq","value":"x"}', 'explain': true},
      );

      expect(ok, isTrue);
      final raw = out.toString();
      final firstBrace = raw.indexOf('{');
      var depth = 0;
      var end = firstBrace;
      for (var i = firstBrace; i < raw.length; i++) {
        if (raw[i] == '{') depth++;
        if (raw[i] == '}') depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
      final explainMap =
          json.decode(raw.substring(firstBrace, end + 1))
              as Map<String, dynamic>;
      final explain = explainMap['_explain'] as Map<String, dynamic>;
      expect(explain['strategy'], 'fullScan');
      final filters = explain['filters'] as List<dynamic>;
      expect(filters, hasLength(1));
      final f = filters.first as Map<String, dynamic>;
      expect(f['indexUsed'], isFalse);
      // Status is 'building' (not 'none') because the index IS defined.
      expect(f['indexStatus'], isNot('none'));
    });
  });

  // ── OutputMode.displayName ────────────────────────────────────────────────

  group('OutputMode', () {
    test('displayName returns mode name', () {
      expect(OutputMode.json.displayName, equals('json'));
      expect(OutputMode.table.displayName, equals('table'));
    });
  });
}
