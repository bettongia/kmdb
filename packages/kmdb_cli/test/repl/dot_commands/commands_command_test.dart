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
import 'package:kmdb_cli/src/repl/dot_commands/commands_command.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:test/test.dart';

// ── Minimal CliCommand stubs ──────────────────────────────────────────────────

final class _SimpleCommand extends CliCommand {
  const _SimpleCommand(this.name, this.description, this.usage);

  @override
  final String name;
  @override
  final String description;
  @override
  final String usage;

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async => true;
}

final class _FlaggedCommand extends CliCommand {
  const _FlaggedCommand();

  @override
  String get name => 'scan';
  @override
  String get description => 'Scan documents in a collection.';
  @override
  String get usage => 'scan <collection>';

  @override
  void configureArgParser(ArgParser parser) {
    parser.addOption('filter', valueHelp: 'json', help: 'JSON filter');
    parser.addOption('limit', valueHelp: 'n', help: 'Max results');
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async => true;
}

final class _MultiLineCommand extends CliCommand {
  const _MultiLineCommand();

  @override
  String get name => 'remote';
  @override
  String get description => 'Manage named sync remotes.';
  @override
  String get usage =>
      'remote add <name>\n'
      '       remote remove <name>\n'
      '       remote list';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async => true;
}

// ── Test helpers ──────────────────────────────────────────────────────────────

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

  group('CommandsCommand — listing', () {
    test('lists commands alphabetically with names and descriptions', () async {
      final commands = <String, CliCommand>{
        'count': const _SimpleCommand(
          'count',
          'Count documents.',
          'count <collection>',
        ),
        'get': const _SimpleCommand(
          'get',
          'Get a document.',
          'get <col> <key>',
        ),
        'scan': const _FlaggedCommand(),
      };

      final ok = await CommandsCommand(commands).execute(state, ctx, []);

      expect(ok, isTrue);
      final text = out.toString();
      expect(text, contains('Commands:'));
      // Alphabetical order
      final countPos = text.indexOf('count');
      final getPos = text.indexOf('get');
      final scanPos = text.indexOf('scan');
      expect(countPos, lessThan(getPos));
      expect(getPos, lessThan(scanPos));
    });

    test('includes name and description for each command', () async {
      final commands = <String, CliCommand>{
        'count': const _SimpleCommand(
          'count',
          'Count documents.',
          'count <collection>',
        ),
      };
      await CommandsCommand(commands).execute(state, ctx, []);

      final text = out.toString();
      expect(text, contains('count'));
      expect(text, contains('Count documents.'));
    });

    test('shows hint to use .commands <name>', () async {
      await CommandsCommand(const {}).execute(state, ctx, []);
      expect(out.toString(), contains('.commands'));
    });

    test('empty command map lists nothing but still succeeds', () async {
      final ok = await CommandsCommand(const {}).execute(state, ctx, []);
      expect(ok, isTrue);
      expect(out.toString(), contains('Commands:'));
    });
  });

  group('CommandsCommand — detail', () {
    test('shows usage and description for known command', () async {
      final commands = <String, CliCommand>{'scan': const _FlaggedCommand()};
      final ok = await CommandsCommand(commands).execute(state, ctx, ['scan']);

      expect(ok, isTrue);
      final text = out.toString();
      expect(text, contains('scan <collection>'));
      expect(text, contains('Scan documents in a collection.'));
    });

    test('shows options block when command has flags', () async {
      final commands = <String, CliCommand>{'scan': const _FlaggedCommand()};
      await CommandsCommand(commands).execute(state, ctx, ['scan']);

      final text = out.toString();
      expect(text, contains('Options:'));
      expect(text, contains('--filter'));
      expect(text, contains('--limit'));
    });

    test('omits options block when command has no flags', () async {
      final commands = <String, CliCommand>{
        'get': const _SimpleCommand(
          'get',
          'Get a document.',
          'get <col> <key>',
        ),
      };
      await CommandsCommand(commands).execute(state, ctx, ['get']);

      expect(out.toString(), isNot(contains('Options:')));
    });

    test('shows full multi-line usage', () async {
      final commands = <String, CliCommand>{
        'remote': const _MultiLineCommand(),
      };
      await CommandsCommand(commands).execute(state, ctx, ['remote']);

      final text = out.toString();
      expect(text, contains('remote add <name>'));
      expect(text, contains('remote remove <name>'));
      expect(text, contains('remote list'));
    });

    test('returns false and writes to err for unknown command', () async {
      final ok = await CommandsCommand(
        const {},
      ).execute(state, ctx, ['nonexistent']);

      expect(ok, isFalse);
      expect(err.toString(), contains("unknown command 'nonexistent'"));
      expect(out.toString(), isEmpty);
    });

    test('error output suggests .commands for discovery', () async {
      await CommandsCommand(const {}).execute(state, ctx, ['nope']);
      expect(err.toString(), contains('.commands'));
    });
  });

  group('CommandsCommand — metadata', () {
    test('name is commands', () {
      expect(CommandsCommand(const {}).name, 'commands');
    });

    test('argSynopsis is [command]', () {
      expect(CommandsCommand(const {}).argSynopsis, '[command]');
    });

    test('has a non-empty description', () {
      expect(CommandsCommand(const {}).description, isNotEmpty);
    });
  });

  group('replVisible', () {
    test('defaults to true', () {
      expect(const _SimpleCommand('x', 'y', 'z').replVisible, isTrue);
    });
  });
}
