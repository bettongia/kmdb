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
}
