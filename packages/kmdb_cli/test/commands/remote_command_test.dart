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
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:test/test.dart';

import '../support/fake_credential_store.dart';

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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late io.Directory tmpDir;
  late io.Directory dbDir;
  late KmdbDatabase db;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('remote_cmd_test_');
    dbDir = io.Directory('${tmpDir.path}/db')..createSync();
    db = await _openStore(dbDir.path);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await db.close(flush: false);
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const cmd = RemoteCommand();

  // ── Meta ────────────────────────────────────────────────────────────────────

  test('name and description are set', () {
    expect(cmd.name, 'remote');
    expect(cmd.description, isNotEmpty);
  });

  // ── Error: missing subcommand ────────────────────────────────────────────────

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

  // ── add ─────────────────────────────────────────────────────────────────────

  test('add: returns false when name is missing', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('remote name required'));
  });

  test('add: returns false when --path is missing for local type', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add', 'origin'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('--path is required'));
  });

  test('add: returns false for unknown type', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'origin'],
      {'type': 'google_drive', 'path': '/tmp'},
    );
    expect(ok, isFalse);
    expect(err.toString(), contains("unknown type 'google_drive'"));
  });

  test('add: successfully adds a local remote', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add', 'origin'], {'path': '/tmp/sync'});
    expect(ok, isTrue);
    expect(out.toString(), contains("Remote 'origin' added"));

    // Verify persistence.
    final config = await KmdbConfig.forDatabase(dbDir.path);
    expect(config.remotes['origin'], isA<LocalRemoteConfig>());
    expect((config.remotes['origin'] as LocalRemoteConfig).path, '/tmp/sync');
  });

  test('add: explicit --type local works', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'nas'],
      {'type': 'local', 'path': '/mnt/nas/sync'},
    );
    expect(ok, isTrue);
  });

  test('add: fails on duplicate without --force', () async {
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/path/a'});

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['add', 'origin'], {'path': '/path/b'});
    expect(ok, isFalse);
    expect(err.toString(), contains("already exists"));
  });

  test('add: overwrites with --force', () async {
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/path/a'});

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['add', 'origin'],
      {'path': '/path/b', 'force': true},
    );
    expect(ok, isTrue);

    final config = await KmdbConfig.forDatabase(dbDir.path);
    expect((config.remotes['origin'] as LocalRemoteConfig).path, '/path/b');
  });

  // ── remove ───────────────────────────────────────────────────────────────────

  test('remove: returns false when name is missing', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('remote name required'));
  });

  test('remove: returns false when remote does not exist', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove', 'nosuchremote'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("No remote named 'nosuchremote' found"));
  });

  test('remove: successfully removes a remote', () async {
    // First add.
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/tmp/sync'});

    // Then remove.
    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['remove', 'origin'], {});
    expect(ok, isTrue);
    expect(out.toString(), contains("Remote 'origin' removed"));

    final config = await KmdbConfig.forDatabase(dbDir.path);
    expect(config.remotes, isEmpty);
  });

  // ── remove: Google Drive credential cleanup (closes the leak) ────────────────
  //
  // Prior to this plan, `remote remove` deleted the config.json entry but
  // left the credentials file behind — a stale, still-valid OAuth token
  // orphaned in {dbDir}/local/ with no config entry pointing at it.

  test(
    'remove: deletes the stored credential for a google-drive remote',
    () async {
      // Add a GoogleDriveRemoteConfig directly (bypassing the untestable
      // OAuth flow), then seed the fake store as if `remote add` had run.
      final config = await KmdbConfig.forDatabase(dbDir.path);
      config.addRemote(
        'gdrive',
        GoogleDriveRemoteConfig(
          syncRoot: 'kmdb-sync',
          credentialsPath: 'google_credentials.json',
        ),
      );
      await config.save();

      final fakeStore = FakeCredentialStore()
        ..secrets['google_credentials.json'] = '{"token":"abc"}';

      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['remove', 'gdrive'],
        {},
        credentialStoreOverride: fakeStore,
      );

      expect(ok, isTrue);
      expect(fakeStore.deleteCalls, ['google_credentials.json']);
      expect(fakeStore.secrets.containsKey('google_credentials.json'), isFalse);
    },
  );

  test(
    'remove: does not attempt credential deletion for a local remote',
    () async {
      final ctx1 = _ctx(db, out: out, err: err);
      await cmd.execute(ctx1, ['add', 'origin'], {'path': '/tmp/sync'});

      final fakeStore = FakeCredentialStore();
      final ctx2 = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx2,
        ['remove', 'origin'],
        {},
        credentialStoreOverride: fakeStore,
      );

      expect(ok, isTrue);
      expect(fakeStore.deleteCalls, isEmpty);
    },
  );

  test('remove: actually deletes the credentials file on disk (real store, no '
      'injection)', () async {
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote('gdrive', GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync'));
    await config.save();

    final localDir = io.Directory('${dbDir.path}/local')
      ..createSync(recursive: true);
    final credFile = io.File('${localDir.path}/google_credentials.json')
      ..writeAsStringSync('{"token":"abc"}');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove', 'gdrive'], {});

    expect(ok, isTrue);
    expect(credFile.existsSync(), isFalse);
  });

  // ── list ─────────────────────────────────────────────────────────────────────

  test('list: shows "No remotes" when empty', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['list'], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('No remotes configured'));
  });

  test('list: shows all remotes after add', () async {
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/tmp/sync'});
    await cmd.execute(ctx1, ['add', 'dropbox'], {'path': '/Dropbox/sync'});

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['list'], {});
    expect(ok, isTrue);
    final output = out.toString();
    expect(output, contains('origin'));
    expect(output, contains('local'));
    expect(output, contains('/tmp/sync'));
    expect(output, contains('dropbox'));
    expect(output, contains('/Dropbox/sync'));
  });

  // ── Google Drive add — validation failures ────────────────────────────────────
  //
  // The OAuth redirect flow (clientViaUserConsent) requires a real browser +
  // Google server and cannot run in automated tests.  We cover the validation
  // errors that are raised before reaching the OAuth step.

  group('add: google-drive validation', () {
    test('returns false when --folder is missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['add', 'gdrive'],
        {'type': 'google-drive', 'client-id': 'abc', 'client-secret': 'xyz'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('--folder is required'));
    });

    test('returns false when --client-id is missing', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['add', 'gdrive'],
        {'type': 'google-drive', 'folder': 'my-sync'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('--client-id is required'));
    });

    test('returns false for unknown remote type', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['add', 'remote1'],
        {'type': 'ftp', 'path': '/mnt/sync'},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains("unknown type 'ftp'"));
    });
  });

  // ── list: google-drive remote shows sync-root ─────────────────────────────────
  //
  // This test adds a GoogleDriveRemoteConfig directly via KmdbConfig (bypassing
  // the OAuth flow) and verifies that `remote list` displays it correctly.
  test('list: shows google-drive remote with syncRoot', () async {
    // Directly write a Google Drive remote to the config to bypass OAuth.
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote(
      'gdrive',
      GoogleDriveRemoteConfig(syncRoot: 'my-kmdb-sync'),
    );
    await config.save();

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['list'], {});
    expect(ok, isTrue);
    final output = out.toString();
    expect(output, contains('gdrive'));
    expect(output, contains('google-drive'));
    expect(output, contains('my-kmdb-sync'));
  });

  // ── Round-trip: add → list → remove → list ───────────────────────────────────

  test('full round-trip: add, list, remove, list', () async {
    final ctx = _ctx(db, out: out, err: err);

    // Add.
    expect(
      await cmd.execute(ctx, ['add', 'origin'], {'path': '/tmp/sync'}),
      isTrue,
    );
    // List shows it.
    expect(await cmd.execute(ctx, ['list'], {}), isTrue);
    expect(out.toString(), contains('origin'));

    // Remove.
    expect(await cmd.execute(ctx, ['remove', 'origin'], {}), isTrue);

    // List is empty again.
    out.clear();
    expect(await cmd.execute(ctx, ['list'], {}), isTrue);
    expect(out.toString(), contains('No remotes configured'));
  });

  // ── Corrupt config: FormatException propagation ───────────────────────────────

  group('corrupt config.json', () {
    /// Write an invalid JSON blob to `{dbDir}/local/config.json`.
    Future<void> writeCorruptConfig() async {
      final localDir = io.Directory('${dbDir.path}/local');
      localDir.createSync(recursive: true);
      io.File(
        '${dbDir.path}/local/config.json',
      ).writeAsStringSync('NOT VALID JSON !!!');
    }

    // Lines 168-169 in remote_command.dart: FormatException from
    // KmdbConfig.forDatabase inside _add (local add path).
    test('remote add: corrupt config returns error', () async {
      await writeCorruptConfig();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['add', 'origin'],
        {'path': '/backups'},
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });

    // Lines 204-205 in remote_command.dart: FormatException from
    // KmdbConfig.forDatabase inside _remove.
    test('remote remove: corrupt config returns error', () async {
      await writeCorruptConfig();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(ctx, ['remove', 'origin'], {});
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });

    // Lines 235-236 in remote_command.dart: FormatException from
    // KmdbConfig.forDatabase inside _list.
    test('remote list: corrupt config returns error', () async {
      await writeCorruptConfig();
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(ctx, ['list'], {});
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });
  });
}
