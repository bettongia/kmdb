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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/introspection_commands.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:test/test.dart';

Future<KmdbDatabase> _openDb() => KmdbDatabase.open(
  path: '/testdb',
  adapter: MemoryStorageAdapter(),
  config: KvStoreConfig.forTesting(),
);

void main() {
  late KmdbDatabase db;
  late SessionState state;
  late StringBuffer out;
  late StringBuffer err;
  late CommandContext ctx;

  setUp(() async {
    db = await _openDb();
    state = SessionState();
    out = StringBuffer();
    err = StringBuffer();
    ctx = CommandContext(db: db, out: out, err: err);
  });

  tearDown(() => db.close());

  group('CollectionsAliasCommand', () {
    test('lists collections', () async {
      await db.store.createNamespace('notes');
      final ok = await const CollectionsAliasCommand().execute(state, ctx, []);
      expect(ok, isTrue);
      expect(out.toString(), contains('notes'));
    });
  });

  group('IndexesAliasCommand', () {
    test('no active collection and no arg returns error', () async {
      final ok = await const IndexesAliasCommand().execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('uses active collection from state', () async {
      state.activeCollection = 'notes';
      await db.store.createNamespace('notes');
      final ok = await const IndexesAliasCommand().execute(state, ctx, []);
      expect(ok, isTrue);
    });

    test('uses arg over active collection', () async {
      state.activeCollection = 'other';
      await db.store.createNamespace('notes');
      final ok = await const IndexesAliasCommand().execute(state, ctx, [
        'notes',
      ]);
      expect(ok, isTrue);
    });
  });

  group('SchemaAliasCommand', () {
    test('no active collection and no arg returns error', () async {
      final ok = await const SchemaAliasCommand().execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('uses active collection from state', () async {
      state.activeCollection = 'notes';
      await db.store.createNamespace('notes');
      // schema show on a collection with no schema reports "no schema", not an error.
      await const SchemaAliasCommand().execute(state, ctx, []);
      // Not asserting specific output — just that it doesn't crash.
    });

    test('uses arg over active collection', () async {
      state.activeCollection = 'other';
      await db.store.createNamespace('articles');
      await const SchemaAliasCommand().execute(state, ctx, ['articles']);
    });
  });
}
