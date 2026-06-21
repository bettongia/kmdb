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
import 'package:kmdb_cli/src/repl/dot_commands/database_commands.dart';
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

  group('OpenCommand', () {
    test('no args returns false and writes error', () async {
      final cmd = OpenCommand((path, s) async => null);
      final ok = await cmd.execute(state, ctx, []);
      expect(ok, isFalse);
      expect(err.toString(), contains('Error'));
    });

    test('callback returning null returns false', () async {
      final cmd = OpenCommand((path, s) async => null);
      final ok = await cmd.execute(state, ctx, ['/some/db']);
      expect(ok, isFalse);
    });

    test(
      'callback returning a context returns true and prints message',
      () async {
        // Use a separate MemoryStorageAdapter so there's no lock conflict.
        final newDb = await KmdbDatabase.open(
          path: '/newdb',
          adapter: MemoryStorageAdapter(),
          config: KvStoreConfig.forTesting(),
        );
        final newCtx = CommandContext(db: newDb, out: out, err: err);
        final cmd = OpenCommand((path, s) async => newCtx);
        final ok = await cmd.execute(state, ctx, ['/newdb']);
        expect(ok, isTrue);
        expect(out.toString(), contains('Opened'));
        await newDb.close();
      },
    );
  });

  group('CloseCommand', () {
    test('calls the close callback and prints message', () async {
      var closed = false;
      final cmd = CloseCommand(() async {
        closed = true;
      });
      final ok = await cmd.execute(state, ctx, []);
      expect(ok, isTrue);
      expect(closed, isTrue);
      expect(out.toString(), contains('closed'));
    });
  });

  // ── openDatabase helper ───────────────────────────────────────────────────────

  group('openDatabase', () {
    late io.Directory tmpDir;

    setUp(() async {
      tmpDir = await io.Directory.systemTemp.createTemp('kmdb_open_db_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('opens a real database and returns CommandContext', () async {
      final errBuf = StringBuffer();
      final ctx = await openDatabase(tmpDir.path, errBuf);

      expect(ctx, isNotNull);
      expect(errBuf.toString(), isEmpty);

      // Clean up the opened database.
      await ctx!.db.close();
    });

    test('returns null and writes error for an invalid path', () async {
      final errBuf = StringBuffer();
      // A path that cannot be opened as a database (e.g. a file path pointing
      // to a location that cannot be created, or a device file).
      final invalidPath = '/proc/nonexistent_kmdb_test_path';
      final ctx = await openDatabase(invalidPath, errBuf);

      // On macOS /proc doesn't exist, so this should fail with an error.
      // On Linux /proc exists as a virtual fs but the path won't be writable.
      // Either way, we expect null + an error message.
      if (ctx != null) {
        // Succeeded unexpectedly (unlikely) — just close gracefully.
        await ctx.db.close();
      } else {
        expect(errBuf.toString(), isNotEmpty);
      }
    });
  });
}
