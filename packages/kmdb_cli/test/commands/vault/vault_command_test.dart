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
import 'package:kmdb_cli/src/commands/vault/vault_command.dart';
import 'package:test/test.dart';

var _dbCounter = 0;

Future<KmdbDatabase> _openStore({String? path, VaultStore? vault}) async {
  final dbPath = path ?? '/testdb_vault_command_${_dbCounter++}';
  return KmdbDatabase.open(
    path: dbPath,
    adapter: MemoryStorageAdapter(),
    config: KvStoreConfig.forTesting(),
    vaultStore: vault,
  );
}

CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('VaultCommand', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    // ── vault help ───────────────────────────────────────────────────────

    test('vault help succeeds without a vault store configured', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final ctx = _ctx(db, out: out, err: err);

      final ok = await VaultCommand().execute(ctx, ['help'], {});

      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
      // Each sub-command's usage and description must be listed.
      final summary = out.toString();
      expect(summary, contains('vault get <uri>'));
      expect(summary, contains('vault export <uri> --output <path>'));
      expect(summary, contains('vault search <query> --collection <name>'));
      expect(summary, contains('vault reindex'));
      expect(summary, contains('vault status'));
    });

    test('vault help succeeds with a vault store configured', () async {
      final db = await _openStore(
        vault: VaultStore(
          adapter: MemoryStorageAdapter(),
          dbDir: '/testdb_vault_command_help_${_dbCounter++}',
        ),
      );
      addTearDown(() => db.close());
      final ctx = _ctx(db, out: out, err: err);

      final ok = await VaultCommand().execute(ctx, ['help'], {});

      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
    });

    // ── No sub-command ──────────────────────────────────────────────────

    test('vault with no args behaves the same as vault help', () async {
      final db = await _openStore();
      addTearDown(() => db.close());
      final ctx = _ctx(db, out: out, err: err);

      final ok = await VaultCommand().execute(ctx, [], {});

      expect(ok, isTrue);
      expect(err.toString(), isEmpty);
      expect(out.toString(), contains('vault get <uri>'));
    });

    // ── Vault store not configured (non-help sub-command) ───────────────

    test(
      'a non-help sub-command fails when no vault store is configured',
      () async {
        final db = await _openStore();
        addTearDown(() => db.close());
        final ctx = _ctx(db, out: out, err: err);

        final ok = await VaultCommand().execute(ctx, ['get', 'x'], {});

        expect(ok, isFalse);
        expect(err.toString(), contains('not available'));
      },
    );

    // ── Unknown sub-command ─────────────────────────────────────────────

    test('an unknown sub-command still errors', () async {
      final db = await _openStore(
        vault: VaultStore(
          adapter: MemoryStorageAdapter(),
          dbDir: '/testdb_vault_command_unknown_${_dbCounter++}',
        ),
      );
      addTearDown(() => db.close());
      final ctx = _ctx(db, out: out, err: err);

      final ok = await VaultCommand().execute(ctx, ['bogus'], {});

      expect(ok, isFalse);
      expect(err.toString(), contains('Unknown vault sub-command'));
    });

    // ── Known sub-command dispatch ───────────────────────────────────────

    test(
      'dispatches a known sub-command, passing through its remaining args',
      () async {
        final db = await _openStore(
          vault: VaultStore(
            adapter: MemoryStorageAdapter(),
            dbDir: '/testdb_vault_command_dispatch_${_dbCounter++}',
          ),
        );
        addTearDown(() => db.close());
        final ctx = _ctx(db, out: out, err: err);

        // 'get' itself fails (object not found), but reaching that failure
        // proves VaultCommand dispatched to VaultGetCommand rather than
        // erroring out itself.
        final ok = await VaultCommand().execute(ctx, [
          'get',
          'kmdb-vault://sha256/${'a' * 64}',
        ], {});

        expect(ok, isFalse);
        expect(err.toString(), contains('not found'));
      },
    );
  });
}
