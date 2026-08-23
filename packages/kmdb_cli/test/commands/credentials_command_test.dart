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
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/credentials_command.dart';
import 'package:test/test.dart';

import '../support/fake_secret_store.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a native-backed database in [dir].
Future<KmdbDatabase> _openStore(String dir) async {
  final adapter = StorageAdapterNative();
  await adapter.createDirectory(dir);
  return KmdbDatabase.open(path: dir, adapter: adapter);
}

/// Creates a [CommandContext] backed by [db] with captured output buffers.
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late io.Directory tmpDir;
  late io.Directory dbDir;
  late KmdbDatabase db;
  late StringBuffer out;
  late StringBuffer err;
  late FakeSecretStore secretStore;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('credentials_cmd_test_');
    dbDir = io.Directory('${tmpDir.path}/db')..createSync();
    db = await _openStore(dbDir.path);
    out = StringBuffer();
    err = StringBuffer();
    secretStore = FakeSecretStore();
  });

  tearDown(() async {
    await db.close(flush: false);
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const cmd = CredentialsCommand();

  // ── Meta ────────────────────────────────────────────────────────────────────

  test('name and description are set', () {
    expect(cmd.name, 'credentials');
    expect(cmd.description, isNotEmpty);
  });

  test('returns false when no subcommand is given', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('subcommand required'));
  });

  test('returns false for unknown subcommand', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['oops'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("unknown subcommand 'oops'"));
  });

  // ── prune: no orphans ──────────────────────────────────────────────────────

  test('prune: empty store is a no-op', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );
    expect(ok, isTrue);
    expect(out.toString(), contains('no orphaned secrets found'));
  });

  // ── Default store resolution (no override) ─────────────────────────────────
  //
  // Exercises `secretStoreOverride ?? DirectorySecretStore.forPlatform()` for
  // real — every other test in this file deliberately injects a
  // `FakeSecretStore` to keep isolation from the real machine profile
  // directory. Safe here because `list()` is a pure read (prune only writes
  // if it finds an orphan, and a freshly-generated temp dbDir cannot already
  // have a scoped key in the real store) — nothing is ever written to the
  // real ~/.config/kmdb (or %APPDATA%\kmdb) directory by this test.
  test(
    'prune: without an override, resolves the real '
    'DirectorySecretStore.forPlatform() default (read-only, no fixture)',
    () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(ctx, ['prune'], {});
      expect(ok, isTrue);
    },
  );

  test('prune: live credential is kept', () async {
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote(
      'gdrive',
      GoogleDriveRemoteConfig(
        syncRoot: 'kmdb-sync',
        credentialsPath: 'google_credentials.json',
      ),
    );
    await config.save();

    final liveKey = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
    secretStore.secrets[liveKey] = _bytes('{"token":"abc"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(out.toString(), contains('no orphaned secrets found'));
    expect(secretStore.secrets.containsKey(liveKey), isTrue);
  });

  // ── prune: orphan removal ──────────────────────────────────────────────────

  test('prune: orphaned secret (no matching remote) is removed', () async {
    // No remotes configured at all — any secret scoped to this database is
    // orphaned by definition (the plan's "fresh database" edge case).
    final orphanKey = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
    secretStore.secrets[orphanKey] = _bytes('{"token":"stale"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(out.toString(), contains('Removed: $orphanKey'));
    expect(secretStore.secrets.containsKey(orphanKey), isFalse);
  });

  test('prune: a live remote is kept while an orphaned one is removed in the '
      'same pass', () async {
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote(
      'gdrive',
      GoogleDriveRemoteConfig(
        syncRoot: 'kmdb-sync',
        credentialsPath: 'google_credentials.json',
      ),
    );
    await config.save();

    final liveKey = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
    final orphanKey = dbScopedSecretKey(dbDir.path, 'stale_creds.json');
    secretStore.secrets[liveKey] = _bytes('{"token":"live"}');
    secretStore.secrets[orphanKey] = _bytes('{"token":"stale"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(secretStore.secrets.containsKey(liveKey), isTrue);
    expect(secretStore.secrets.containsKey(orphanKey), isFalse);
  });

  // ── prune --dry-run ────────────────────────────────────────────────────────

  test('prune --dry-run reports what would be removed without deleting '
      'anything', () async {
    final orphanKey = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
    secretStore.secrets[orphanKey] = _bytes('{"token":"stale"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {'dry-run': true},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(out.toString(), contains('Would remove: $orphanKey'));
    // Nothing was actually deleted.
    expect(secretStore.secrets.containsKey(orphanKey), isTrue);
    expect(secretStore.deleteCalls, isEmpty);
  });

  // ── prune: multi-database isolation ───────────────────────────────────────
  //
  // DirectorySecretStore.forPlatform()'s root is shared globally across every
  // KMDB database on the machine. A key scoped to a *different* database must
  // never be inspected or deleted by this database's prune pass, even though
  // it is not "live" from this database's own RemoteConfig perspective.

  test("prune never touches a different database's secret, even though it "
      'looks orphaned from this database\'s RemoteConfig', () async {
    final otherDbDir = io.Directory('${tmpDir.path}/other-db')..createSync();
    final otherKey = dbScopedSecretKey(
      otherDbDir.path,
      'google_credentials.json',
    );
    secretStore.secrets[otherKey] = _bytes('{"token":"other-db-secret"}');

    // This database has no remotes configured at all — if prune failed to
    // scope by database, the other database's key would look orphaned and
    // be deleted.
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(out.toString(), contains('no orphaned secrets found'));
    expect(secretStore.secrets.containsKey(otherKey), isTrue);
  });

  // Regression (QA finding 2026-08-10): a *sibling* database whose path has the
  // current database's path as a string prefix followed by '--' must not be
  // mis-scoped. The former encoded-path + '--'-delimiter scheme matched
  // `${dbDir}--archive`'s key against `${dbDir}` via startsWith and deleted it;
  // the hash scope makes the scope→name boundary unambiguous.
  test("prune never touches a sibling database whose path extends this one's "
      "with '--'", () async {
    final siblingDbDir = io.Directory('${dbDir.path}--archive')..createSync();
    final siblingKey = dbScopedSecretKey(
      siblingDbDir.path,
      'google_credentials.json',
    );
    // The sibling's key must not be considered this database's key.
    expect(isSecretKeyForDb(siblingKey, dbDir.path), isFalse);
    secretStore.secrets[siblingKey] = _bytes('{"token":"sibling-secret"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    expect(out.toString(), contains('no orphaned secrets found'));
    expect(secretStore.secrets.containsKey(siblingKey), isTrue);
  });

  // ── prune: corrupt config ──────────────────────────────────────────────────

  test('prune: corrupt config.json returns an error', () async {
    final localDir = io.Directory('${dbDir.path}/local')..createSync();
    io.File('${localDir.path}/config.json')
        .writeAsStringSync('{ this is not valid json }');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['prune'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isFalse);
    expect(err.toString(), isNotEmpty);
  });
}
