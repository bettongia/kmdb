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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/repl/dot_commands/io_commands.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:path/path.dart' as p;
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

  group('ReadCommand', () {
    test('no args returns false and writes error', () async {
      final cmd = ReadCommand((line, c) async => true);
      final ok = await cmd.execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('nonexistent file returns false and writes error', () async {
      final cmd = ReadCommand((line, c) async => true);
      final ok = await cmd.execute(state, ctx, ['/no/such/file.kmdb']);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('executes each non-blank, non-comment line via dispatcher', () async {
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_read_');
      final scriptPath = p.join(tmpDir.path, 'script.kmdb');
      final script = io.File(scriptPath);
      await script.writeAsString(
        '# comment\n\ncollections list\ncollections list\n',
      );

      try {
        final dispatched = <String>[];
        final cmd = ReadCommand((line, c) async {
          dispatched.add(line);
          return true;
        });
        final ok = await cmd.execute(state, ctx, [scriptPath]);
        expect(ok, isTrue);
        expect(dispatched, ['collections list', 'collections list']);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('stops on first failure when bail is set', () async {
      final tmpDir = await io.Directory.systemTemp.createTemp('kmdb_read2_');
      final scriptPath = p.join(tmpDir.path, 's.kmdb');
      await io.File(scriptPath).writeAsString('line1\nline2\nline3\n');

      try {
        state.bail = true;
        final dispatched = <String>[];
        final cmd = ReadCommand((line, c) async {
          dispatched.add(line);
          return false; // always fail
        });
        await cmd.execute(state, ctx, [scriptPath]);
        // Should stop after first failure.
        expect(dispatched.length, 1);
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });

  group('ExportAliasCommand', () {
    test('no args returns false', () async {
      final ok = await const ExportAliasCommand().execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('with collection name executes export', () async {
      await db.store.createNamespace('notes');
      final ok = await const ExportAliasCommand().execute(state, ctx, [
        'notes',
      ]);
      expect(ok, isTrue);
    });
  });

  group('ImportAliasCommand', () {
    test('insufficient args returns false', () async {
      final ok = await const ImportAliasCommand().execute(state, ctx, [
        'notes',
      ]);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('no args at all returns false', () async {
      final ok = await const ImportAliasCommand().execute(state, ctx, []);
      expect(ok, isFalse);
    });
  });

  group('DumpAliasCommand', () {
    test('no args dumps to stdout (ctx.out)', () async {
      final ok = await const DumpAliasCommand().execute(state, ctx, []);
      expect(ok, isTrue);
    });
  });

  group('RestoreAliasCommand', () {
    test('no args returns false and writes error', () async {
      final ok = await const RestoreAliasCommand().execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });
  });
}
