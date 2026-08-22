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
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';
import 'package:kmdb_cli/src/config/sync_auth_key_store.dart';
import 'package:kmdb/kmdb_config.dart';
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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late io.Directory tmpDir;
  late io.Directory dbDir;
  late KmdbDatabase db;
  late StringBuffer out;
  late StringBuffer err;
  // Every test in this file that calls `remote add` (or `remote pair
  // import`) must inject a store — `remote add` now mints a
  // sync-authentication key automatically (0.10.01 WI-4 T1), and without an
  // override that write lands on the real, per-user profile-directory-backed
  // DirectorySecretStore.forPlatform() default, polluting the developer's
  // actual machine. A single shared FakeSecretStore per test, reset in
  // setUp, keeps every test hermetic. The two tests that deliberately
  // exercise the real default-store-resolution path are called out
  // explicitly where they omit this override.
  late FakeSecretStore secretStore;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('remote_cmd_test_');
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
    final ok = await cmd.execute(
      ctx,
      ['add'],
      {},
      secretStoreOverride: secretStore,
    );
    expect(ok, isFalse);
    expect(err.toString(), contains('remote name required'));
  });

  test('add: returns false when --path is missing for local type', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'origin'],
      {},
      secretStoreOverride: secretStore,
    );
    expect(ok, isFalse);
    expect(err.toString(), contains('--path is required'));
  });

  test('add: returns false for unknown type', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'origin'],
      {'type': 'google_drive', 'path': '/tmp'},
      secretStoreOverride: secretStore,
    );
    expect(ok, isFalse);
    expect(err.toString(), contains("unknown type 'google_drive'"));
  });

  test('add: successfully adds a local remote', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'origin'],
      {'path': '/tmp/sync'},
      secretStoreOverride: secretStore,
    );
    expect(ok, isTrue);
    expect(out.toString(), contains("Remote 'origin' added"));

    // Verify persistence.
    final config = await KmdbConfig.forDatabase(dbDir.path);
    expect(config.remotes['origin'], isA<LocalRemoteConfig>());
    expect((config.remotes['origin'] as LocalRemoteConfig).path, '/tmp/sync');

    // A sync-authentication key was minted automatically (0.10.01 WI-4 T1).
    final key = await loadSyncAuthKey(
      dbDir: dbDir.path,
      remoteName: 'origin',
      secretStoreOverride: secretStore,
    );
    expect(key, isNotNull);
  });

  test('add: explicit --type local works', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'nas'],
      {'type': 'local', 'path': '/mnt/nas/sync'},
      secretStoreOverride: secretStore,
    );
    expect(ok, isTrue);
  });

  test('add: fails on duplicate without --force', () async {
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(
      ctx1,
      ['add', 'origin'],
      {'path': '/path/a'},
      secretStoreOverride: secretStore,
    );

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['add', 'origin'],
      {'path': '/path/b'},
      secretStoreOverride: secretStore,
    );
    expect(ok, isFalse);
    expect(err.toString(), contains("already exists"));
  });

  test('add: overwrites with --force', () async {
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(
      ctx1,
      ['add', 'origin'],
      {'path': '/path/a'},
      secretStoreOverride: secretStore,
    );

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['add', 'origin'],
      {'path': '/path/b', 'force': true},
      secretStoreOverride: secretStore,
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
    await cmd.execute(
      ctx1,
      ['add', 'origin'],
      {'path': '/tmp/sync'},
      secretStoreOverride: secretStore,
    );

    // Then remove.
    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['remove', 'origin'],
      {},
      secretStoreOverride: secretStore,
    );
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

      final expectedKey = dbScopedSecretKey(
        dbDir.path,
        'google_credentials.json',
      );
      final fakeStore = FakeSecretStore()
        ..secrets[expectedKey] = Uint8List.fromList(
          utf8.encode('{"token":"abc"}'),
        );

      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['remove', 'gdrive'],
        {},
        secretStoreOverride: fakeStore,
      );

      // Removing a remote now also deletes its sync-authentication key
      // (0.10.01 WI-4 T1) — unconditionally, alongside the Google Drive
      // credential this test seeded directly.
      final syncAuthKey = syncAuthSecretKey(dbDir.path, 'gdrive');
      expect(ok, isTrue);
      expect(fakeStore.deleteCalls, [expectedKey, syncAuthKey]);
      expect(fakeStore.secrets.containsKey(expectedKey), isFalse);
    },
  );

  test('remove: does not attempt Google-Drive-credential deletion for a local '
      'remote, but always deletes the sync-authentication key', () async {
    // Use the same fake store for both `add` (which now mints a
    // sync-authentication key automatically) and `remove`, so the test
    // never touches the real profile-directory-backed SecretStore.
    final ctx1 = _ctx(db, out: out, err: err);
    await cmd.execute(
      ctx1,
      ['add', 'origin'],
      {'path': '/tmp/sync'},
      secretStoreOverride: secretStore,
    );

    final ctx2 = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['remove', 'origin'],
      {},
      secretStoreOverride: secretStore,
    );

    expect(ok, isTrue);
    // No Google-Drive-credential-shaped key was ever deleted — only the
    // sync-authentication key every remote (regardless of type) has.
    expect(secretStore.deleteCalls, [syncAuthSecretKey(dbDir.path, 'origin')]);
  });

  test('remove: actually deletes the credential from the real store (rooted at '
      'a temp directory, not the real profile directory)', () async {
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote('gdrive', GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync'));
    await config.save();

    final secretRoot = io.Directory('${tmpDir.path}/secret-root');
    final realStore = DirectorySecretStore(root: secretRoot.path);
    final key = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
    await realStore.write(
      key,
      Uint8List.fromList(utf8.encode('{"token":"abc"}')),
    );

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['remove', 'gdrive'],
      {},
      secretStoreOverride: realStore,
    );

    expect(ok, isTrue);
    expect(await realStore.read(key), isNull);
  });

  // ── Default store resolution (no override) ─────────────────────────────────
  //
  // Exercises `secretStoreOverride ?? DirectorySecretStore.forPlatform()` for
  // real — every other `remove`/`add` test in this file deliberately injects
  // a store to keep isolation from the real machine profile directory. Safe
  // here because dbDir is a freshly-generated temp directory, so its scoped
  // key cannot already exist in the real store, and `delete()` is a no-op
  // for an absent key — nothing is ever written to the real ~/.config/kmdb
  // (or %APPDATA%\kmdb) directory by this test (unlike `add`, `remove` never
  // *writes* a new secret, only deletes — so omitting the override here is
  // safe in a way it is not for `add`).
  test('remove: without an override, resolves the real '
      'DirectorySecretStore.forPlatform() default (delete-of-absent-key, no '
      'fixture)', () async {
    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote('gdrive', GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync'));
    await config.save();

    final ctx = _ctx(db, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove', 'gdrive'], {});

    expect(ok, isTrue);
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
    await cmd.execute(
      ctx1,
      ['add', 'origin'],
      {'path': '/tmp/sync'},
      secretStoreOverride: secretStore,
    );
    await cmd.execute(
      ctx1,
      ['add', 'dropbox'],
      {'path': '/Dropbox/sync'},
      secretStoreOverride: secretStore,
    );

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
        secretStoreOverride: secretStore,
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
        secretStoreOverride: secretStore,
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
        secretStoreOverride: secretStore,
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
      await cmd.execute(
        ctx,
        ['add', 'origin'],
        {'path': '/tmp/sync'},
        secretStoreOverride: secretStore,
      ),
      isTrue,
    );
    // List shows it.
    expect(await cmd.execute(ctx, ['list'], {}), isTrue);
    expect(out.toString(), contains('origin'));

    // Remove.
    expect(
      await cmd.execute(
        ctx,
        ['remove', 'origin'],
        {},
        secretStoreOverride: secretStore,
      ),
      isTrue,
    );

    // List is empty again.
    out.clear();
    expect(await cmd.execute(ctx, ['list'], {}), isTrue);
    expect(out.toString(), contains('No remotes configured'));
  });

  // ── pair ─────────────────────────────────────────────────────────────────────

  group('pair', () {
    test('returns false when no subcommand is given', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(ctx, ['pair'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains('subcommand required'));
    });

    test('returns false for an unknown subcommand', () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(ctx, ['pair', 'oops'], {});
      expect(ok, isFalse);
      expect(err.toString(), contains("unknown subcommand 'oops'"));
    });

    group('show', () {
      test('returns false when remote name is missing', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await cmd.execute(ctx, ['pair', 'show'], {});
        expect(ok, isFalse);
        expect(err.toString(), contains('remote name required'));
      });

      test(
        'returns false when the remote has no sync-authentication key',
        () async {
          final ctx = _ctx(db, out: out, err: err);
          final ok = await cmd.execute(
            ctx,
            ['pair', 'show', 'origin'],
            {},
            secretStoreOverride: secretStore,
          );
          expect(ok, isFalse);
          expect(err.toString(), contains('no sync-authentication key'));
        },
      );

      test(
        'prints a KSA1--prefixed pairing code for an enrolled remote',
        () async {
          final addCtx = _ctx(db, out: out, err: err);
          await cmd.execute(
            addCtx,
            ['add', 'origin'],
            {'path': '/tmp/sync'},
            secretStoreOverride: secretStore,
          );

          // A fresh context (not sharing the outer `out` buffer, which
          // already accumulated the `add` command's own output above) so
          // this assertion sees only the `pair show` output.
          final ctx = _ctx(db);
          final ok = await cmd.execute(
            ctx,
            ['pair', 'show', 'origin'],
            {},
            secretStoreOverride: secretStore,
          );
          expect(ok, isTrue);
          expect(ctx.out.toString().trim(), startsWith('KSA1-'));
        },
      );
    });

    group('import', () {
      test('returns false when remote name or code is missing', () async {
        final ctx = _ctx(db, out: out, err: err);
        final ok = await cmd.execute(
          ctx,
          ['pair', 'import', 'origin'],
          {},
          secretStoreOverride: secretStore,
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('pairing code required'));
      });

      test(
        'returns false when the remote is not configured on this device',
        () async {
          final key = SyncSetKey.generate();
          final code = await PairingCode.encode(key);
          final ctx = _ctx(db, out: out, err: err);
          final ok = await cmd.execute(
            ctx,
            ['pair', 'import', 'origin', code],
            {},
            secretStoreOverride: secretStore,
          );
          expect(ok, isFalse);
          expect(err.toString(), contains("no remote named 'origin'"));
        },
      );

      test('returns false for a malformed pairing code', () async {
        final addCtx = _ctx(db, out: out, err: err);
        await cmd.execute(
          addCtx,
          ['add', 'origin'],
          {'path': '/tmp/sync'},
          secretStoreOverride: secretStore,
        );

        final ctx = _ctx(db, out: out, err: err);
        final ok = await cmd.execute(
          ctx,
          ['pair', 'import', 'origin', 'not-a-valid-code'],
          {},
          secretStoreOverride: secretStore,
        );
        expect(ok, isFalse);
        expect(err.toString(), contains('invalid pairing code'));
      });

      test('installs the shared key, overwriting the auto-minted one from '
          "this device's own `remote add`", () async {
        // This device runs its own `remote add` first (its own connection
        // details), which auto-mints a key.
        final addCtx = _ctx(db, out: out, err: err);
        await cmd.execute(
          addCtx,
          ['add', 'origin'],
          {'path': '/tmp/sync'},
          secretStoreOverride: secretStore,
        );
        final autoMinted = await loadSyncAuthKey(
          dbDir: dbDir.path,
          remoteName: 'origin',
          secretStoreOverride: secretStore,
        );

        // A different device's `remote pair show` produced this code.
        final sharedKey = SyncSetKey.generate();
        final code = await PairingCode.encode(sharedKey);

        final ctx = _ctx(db, out: out, err: err);
        final ok = await cmd.execute(
          ctx,
          ['pair', 'import', 'origin', code],
          {},
          secretStoreOverride: secretStore,
        );
        expect(ok, isTrue);
        expect(
          out.toString(),
          contains("Remote 'origin' enrolled with the shared"),
        );

        final installed = await loadSyncAuthKey(
          dbDir: dbDir.path,
          remoteName: 'origin',
          secretStoreOverride: secretStore,
        );
        expect(installed, equals(sharedKey));
        expect(installed, isNot(equals(autoMinted)));
      });

      test('decode tolerates whitespace-padded pairing codes', () async {
        final addCtx = _ctx(db, out: out, err: err);
        await cmd.execute(
          addCtx,
          ['add', 'origin'],
          {'path': '/tmp/sync'},
          secretStoreOverride: secretStore,
        );

        final sharedKey = SyncSetKey.generate();
        final code = '  ${await PairingCode.encode(sharedKey)}  ';

        final ctx = _ctx(db, out: out, err: err);
        final ok = await cmd.execute(
          ctx,
          ['pair', 'import', 'origin', code],
          {},
          secretStoreOverride: secretStore,
        );
        expect(ok, isTrue);
      });
    });

    test('round-trip: pair show on one "device" (store) can be imported by '
        'another', () async {
      // Simulate two devices with two independent fake stores.
      final deviceA = FakeSecretStore();
      final deviceB = FakeSecretStore();

      final addCtx = _ctx(db, out: out, err: err);
      await cmd.execute(
        addCtx,
        ['add', 'origin'],
        {'path': '/tmp/sync'},
        secretStoreOverride: deviceA,
      );
      await cmd.execute(
        addCtx,
        ['add', 'origin'],
        {'path': '/tmp/sync-on-device-b'},
        secretStoreOverride: deviceB,
      );

      // Fresh contexts (not sharing the outer `out` buffer, which already
      // accumulated the two `add` commands' own output above).
      final showCtx = _ctx(db);
      await cmd.execute(
        showCtx,
        ['pair', 'show', 'origin'],
        {},
        secretStoreOverride: deviceA,
      );
      final code = showCtx.out.toString().trim();

      final importCtx = _ctx(db);
      final ok = await cmd.execute(
        importCtx,
        ['pair', 'import', 'origin', code],
        {},
        secretStoreOverride: deviceB,
      );
      expect(ok, isTrue);

      final keyA = await loadSyncAuthKey(
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: deviceA,
      );
      final keyB = await loadSyncAuthKey(
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: deviceB,
      );
      expect(keyB, equals(keyA));
    });
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
        secretStoreOverride: secretStore,
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

    // remote pair import: FormatException from KmdbConfig.forDatabase when
    // checking whether the remote is configured.
    test('remote pair import: corrupt config returns error', () async {
      await writeCorruptConfig();
      final key = SyncSetKey.generate();
      final code = await PairingCode.encode(key);
      final ctx = _ctx(db, out: out, err: err);
      final ok = await cmd.execute(
        ctx,
        ['pair', 'import', 'origin', code],
        {},
        secretStoreOverride: secretStore,
      );
      expect(ok, isFalse);
      expect(err.toString(), isNotEmpty);
    });
  });
}
