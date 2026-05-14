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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/repl/completer.dart';
import 'package:kmdb_cli/src/repl/dot_command.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:test/test.dart';

Future<KmdbDatabase> _openDb() => KmdbDatabase.open(
  path: '/testdb',
  adapter: MemoryStorageAdapter(),
  config: KvStoreConfig.forTesting(),
);

void main() {
  late KmdbDatabase db;
  late CommandContext ctx;
  late LiveCompletionProvider completer;
  late DotCommandRegistry emptyRegistry;

  setUp(() async {
    db = await _openDb();
    ctx = CommandContext(db: db);
    emptyRegistry = DotCommandRegistry([]);
    completer = LiveCompletionProvider(ctx, emptyRegistry);

    // Seed a collection.
    await db.store.createNamespace('notes');
    await db.store.createNamespace('tasks');
  });

  tearDown(() => db.close());

  group('first token completion', () {
    test('empty input returns all REPL commands', () async {
      final c = await completer.complete('', 0);
      expect(c, containsAll(['scan', 'get', 'insert', 'collections']));
    });

    test('partial command name filters results', () async {
      final c = await completer.complete('sc', 2);
      expect(c, contains('scan'));
      expect(c, isNot(contains('get')));
    });

    test('dot prefix returns dot-command names', () async {
      final c = await completer.complete('.', 1);
      // With empty registry, no completions.
      expect(c, isEmpty);
    });
  });

  group('collection-positional commands', () {
    test('scan <tab> suggests collection names', () async {
      final text = 'scan ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['notes', 'tasks']));
    });

    test('get <tab> suggests collection names', () async {
      final text = 'get ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('notes'));
    });

    test('delete <tab> suggests collection names', () async {
      final text = 'delete ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('tasks'));
    });
  });

  group('schema subcommands', () {
    test('schema <tab> suggests subcommands', () async {
      final text = 'schema ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['set', 'show', 'list', 'remove', 'validate']));
    });

    test('schema sh<tab> filters to show', () async {
      final text = 'schema sh';
      final c = await completer.complete(text, text.length);
      expect(c, contains('show'));
      expect(c, isNot(contains('list')));
    });
  });

  group('index subcommands', () {
    test('index <tab> suggests subcommands', () async {
      final text = 'index ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['list', 'create', 'info', 'delete']));
    });
  });

  group('vault subcommands', () {
    test('vault <tab> suggests get', () async {
      final text = 'vault ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('get'));
    });
  });

  group('remote subcommands', () {
    test('remote <tab> suggests add list remove', () async {
      final text = 'remote ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['add', 'list', 'remove']));
    });
  });

  group('schema third-token completion', () {
    test('schema show <tab> returns collections with schemas', () async {
      // Register a schema so schemaManager has something.
      await db.registerSchema(
        CollectionSchema(
          collection: 'articles',
          jsonSchema: {'type': 'object'},
        ),
      );
      final text = 'schema show ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('articles'));
    });

    test(
      'schema set <tab> returns empty (no third-token completion)',
      () async {
        final text = 'schema set ';
        final c = await completer.complete(text, text.length);
        expect(c, isEmpty);
      },
    );

    test('schema remove <tab> returns schema collections', () async {
      await db.registerSchema(
        CollectionSchema(collection: 'posts', jsonSchema: {'type': 'object'}),
      );
      final text = 'schema remove ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('posts'));
    });
  });

  group('search subcommands', () {
    test('search <tab> returns collection names and subcommands', () async {
      final text = 'search ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['notes', 'tasks']));
      expect(c, containsAll(['list', 'create', 'delete']));
    });

    test('search create <tab> returns collection names', () async {
      final text = 'search create ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['notes', 'tasks']));
    });

    test('search list <tab> returns empty', () async {
      final text = 'search list ';
      final c = await completer.complete(text, text.length);
      expect(c, isEmpty);
    });
  });

  group('index third-token completion', () {
    test('index list <tab> returns collection names', () async {
      final text = 'index list ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['notes', 'tasks']));
    });

    test('index create <tab> returns collection names', () async {
      final text = 'index create ';
      final c = await completer.complete(text, text.length);
      expect(c, contains('notes'));
    });
  });

  group('--order-by flag completion', () {
    test('--order-by <tab> returns field names from collection', () async {
      // Insert a document so _fieldNames has something to return.
      final col = db.rawCollection('notes');
      await col.insert({'title': 'hello', 'body': 'world'});

      final text = 'scan notes --order-by ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['title', 'body']));
    });

    test('--order-by with no collection returns empty', () async {
      // No collection token present — edge case.
      final text = '--order-by ';
      final c = await completer.complete(text, text.length);
      expect(c, isEmpty);
    });
  });

  group('dot-command completion with populated registry', () {
    test('.m<tab> filters to .mode when registry contains it', () async {
      // Build a registry with at least one command.
      final registry = DotCommandRegistry([
        _FakeDotCommand('mode'),
        _FakeDotCommand('output'),
      ]);
      final prov = LiveCompletionProvider(ctx, registry);
      final c = await prov.complete('.m', 2);
      expect(c, contains('.mode'));
      expect(c, isNot(contains('.output')));
    });

    test('.mode <tab> returns output modes', () async {
      final text = '.mode ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['json', 'table', 'csv', 'ndjson']));
    });

    test('.collection <tab> returns collection names', () async {
      final text = '.collection ';
      final c = await completer.complete(text, text.length);
      expect(c, containsAll(['notes', 'tasks']));
    });
  });
}

// Minimal DotCommand stub for registry tests.
class _FakeDotCommand implements DotCommand {
  const _FakeDotCommand(this.name);
  @override
  final String name;
  @override
  String get description => '';
  @override
  String get argSynopsis => '';
  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async => true;
}
