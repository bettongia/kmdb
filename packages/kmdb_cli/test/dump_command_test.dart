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
import 'package:kmdb_cli/src/commands/dump_command.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

var _dbCounter = 0;

Future<KmdbDatabase> _openStore() async {
  return KmdbDatabase.open(
    path: '/testdb_dump_${_dbCounter++}',
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
  );
}

CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('DumpCommand — standard NDJSON dump', () {
    test('empty database produces no output', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final out = StringBuffer();
      final ok = await DumpCommand().execute(_ctx(db, out: out), [], {});
      expect(ok, isTrue);
      expect(out.toString(), isEmpty);
    });

    test('writes collection header and document lines', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final id1 = _key('doc1');
      final id2 = _key('doc2');
      await db.store.put('notes', id1, ValueCodec.encode({'title': 'Hello'}));
      await db.store.put('notes', id2, ValueCodec.encode({'title': 'World'}));

      final out = StringBuffer();
      final ok = await DumpCommand().execute(_ctx(db, out: out), [], {});
      expect(ok, isTrue);

      final lines = out
          .toString()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, contains('# collection: notes'));
      // Find the JSON lines and decode them.
      final docLines = lines.where((l) => !l.startsWith('#')).toList();
      expect(docLines, hasLength(2));
      final decoded = docLines.map((l) => json.decode(l) as Map).toList();
      final titles = decoded.map((d) => d['title']).toSet();
      expect(titles, containsAll(['Hello', 'World']));
      // The _id field must be injected from the entry key.
      expect(decoded.every((d) => d.containsKey('_id')), isTrue);
    });

    test('writes headers and documents for multiple collections', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      await db.store.put('notes', _key('n1'), ValueCodec.encode({'n': 1}));
      await db.store.put('tasks', _key('t1'), ValueCodec.encode({'t': 1}));

      final out = StringBuffer();
      final ok = await DumpCommand().execute(_ctx(db, out: out), [], {});
      expect(ok, isTrue);

      final output = out.toString();
      expect(output, contains('# collection: notes'));
      expect(output, contains('# collection: tasks'));
    });
  });

  group('DumpCommand --vault without vault configured', () {
    test('returns false and writes error', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final err = StringBuffer();

      final ok = await DumpCommand().execute(_ctx(db, err: err), [], {
        'vault': true,
      });

      expect(ok, isFalse);
      expect(err.toString(), contains('--vault requires vault'));
    });
  });
}
