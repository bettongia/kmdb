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
import 'package:kmdb_cli/src/commands/push_command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';
import 'package:kmdb_cli/src/config/secret_store/secret_key.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:test/test.dart';

import '../support/fake_secret_store.dart';

/// Generates a valid UUIDv7 key.
String _key() => const UuidV7KeyGenerator().next();

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a database via the production [DatabaseOpener] so the engine device ID
/// matches the meta-stored device ID, as required for sync.
Future<KmdbDatabase> _openStore(String dir) async =>
    (await DatabaseOpener.open(dir, KmdbConfig.empty())).$1;

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
  late io.Directory syncDir;
  late KmdbDatabase db;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('push_cmd_test_');
    dbDir = io.Directory('${tmpDir.path}/db')..createSync();
    syncDir = io.Directory('${tmpDir.path}/sync')..createSync();
    db = await _openStore(dbDir.path);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await db.close(flush: false);
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const pushCmd = PushCommand();
  const remoteCmd = RemoteCommand();

  test('name and description are set', () {
    expect(pushCmd.name, 'push');
    expect(pushCmd.description, isNotEmpty);
  });

  // ── Error: no remote specified and no origin ──────────────────────────────

  test('returns false when no remote and no origin is configured', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("no 'origin' remote is configured"));
  });

  // ── Error: unknown remote name ────────────────────────────────────────────

  test('returns false when named remote does not exist', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, ['nosuchremote'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("remote 'nosuchremote' not found"));
  });

  test('returns false when config.json is corrupt', () async {
    final localDir = io.Directory('${dbDir.path}/local')..createSync();
    io.File(
      '${localDir.path}/config.json',
    ).writeAsStringSync('{ this is not valid json }');

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, ['origin'], {});
    expect(ok, isFalse);
    expect(err.toString(), isNotEmpty);
  });

  // ── Error: both remote name and --sync-dir ────────────────────────────────

  test(
    'returns false when both remote name and --sync-dir are given',
    () async {
      final ctx = _ctx(db, out: out, err: err);
      final ok = await pushCmd.execute(
        ctx,
        ['origin'],
        {'sync-dir': syncDir.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    },
  );

  // ── Push via --sync-dir ───────────────────────────────────────────────────

  test('push via --sync-dir succeeds with no user namespaces', () async {
    // A freshly opened store has no user namespaces; push should succeed
    // with a "nothing to push" message.
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('nothing to push'));
  });

  test('push via --sync-dir uploads SSTables when data exists', () async {
    // Write a document so there is something to push.
    final pushKey1 = _key();
    await db.store.put(
      'notes',
      pushKey1,
      await ValueCodec.encode({
        'title': 'Hello',
      }, context: ValueContext('notes', pushKey1)),
    );

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('push: complete'));

    // Verify an SSTable was uploaded to the sync directory.
    final sstDir = io.Directory('${syncDir.path}/sstables');
    expect(
      sstDir.existsSync() &&
          sstDir.listSync().any((e) => e.path.endsWith('.sst')),
      isTrue,
    );
  });

  // ── Push via named remote ─────────────────────────────────────────────────

  test('push via named remote uses origin by default', () async {
    // A shared fake store: `remote add` mints a sync-authentication key
    // (0.10.01 WI-4 T1) that `push` must then resolve when wrapping the
    // adapter — both calls must share the same store, and neither may
    // touch the real profile-directory-backed default.
    final secretStore = FakeSecretStore();

    // Register origin.
    final ctxRemote = _ctx(db, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'origin'],
      {'path': syncDir.path},
      secretStoreOverride: secretStore,
    );

    // Write a document.
    final pushKey2 = _key();
    await db.store.put(
      'notes',
      pushKey2,
      await ValueCodec.encode({
        'title': 'World',
      }, context: ValueContext('notes', pushKey2)),
    );

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(
      ctx,
      [],
      {},
      secretStoreOverride: secretStore,
    );
    expect(ok, isTrue);
    expect(out.toString(), contains('push: complete'));
  });

  test('push via explicit remote name', () async {
    final secretStore = FakeSecretStore();

    // Register dropbox remote.
    final ctxRemote = _ctx(db, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'dropbox'],
      {'path': syncDir.path},
      secretStoreOverride: secretStore,
    );

    final pushKey3 = _key();
    await db.store.put(
      'notes',
      pushKey3,
      await ValueCodec.encode({
        'body': 'test',
      }, context: ValueContext('notes', pushKey3)),
    );

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(
      ctx,
      ['dropbox'],
      {},
      secretStoreOverride: secretStore,
    );
    expect(ok, isTrue);
    expect(out.toString(), contains('push: complete'));
  });

  // ── Namespace filtering ───────────────────────────────────────────────────

  test('--namespace restricts sync to named namespace', () async {
    final pushKey6 = _key();
    await db.store.put(
      'notes',
      pushKey6,
      await ValueCodec.encode({
        'n': 1,
      }, context: ValueContext('notes', pushKey6)),
    );
    final pushKey7 = _key();
    await db.store.put(
      'tasks',
      pushKey7,
      await ValueCodec.encode({
        't': 1,
      }, context: ValueContext('tasks', pushKey7)),
    );

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {
      'sync-dir': syncDir.path,
      'collection': 'notes',
    });
    expect(ok, isTrue);
  });

  test('system collections cannot be synced via --namespace', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {
      'sync-dir': syncDir.path,
      'collection': r'$meta',
    });
    expect(ok, isFalse);
    expect(err.toString(), contains('system collection'));
  });

  // ── Credential permission errors (N8 surfacing) ───────────────────────────
  //
  // adapterFor's call site in push_command.dart wraps SecretPermissionException
  // (and the pre-existing missing-credentials StateError) so both render as a
  // clean one-line CLI error rather than propagating to cli_runner.dart's
  // generic, stack-trace-printing handler.

  test(
    'a loose-permission Google Drive credential renders a clean one-line '
    'error, not a stack trace',
    () async {
      // push short-circuits to "nothing to push" before ever reaching
      // adapterFor when there are no user collections, so write a document
      // first to ensure the credential-resolution path is actually reached.
      final pushKey4 = _key();
      await db.store.put(
        'notes',
        pushKey4,
        await ValueCodec.encode({
          'title': 'Hello',
        }, context: ValueContext('notes', pushKey4)),
      );

      final config = await KmdbConfig.forDatabase(dbDir.path);
      config.addRemote(
        'gdrive',
        GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync'),
      );
      await config.save();

      // Seed the credential through a real, temp-rooted DirectorySecretStore
      // (never the real profile directory) so the write is correctly
      // permission-hardened, then loosen it — simulating an externally
      // widened credential — to exercise the refusal path.
      final secretRoot = io.Directory('${tmpDir.path}/secret-root');
      final secretStore = DirectorySecretStore(root: secretRoot.path);
      final key = dbScopedSecretKey(dbDir.path, 'google_credentials.json');
      await secretStore.write(key, Uint8List.fromList(utf8.encode('{}')));
      final credFile = io.File('${secretRoot.path}/$key');
      io.Process.runSync('chmod', ['644', credFile.path]);

      final ctx = _ctx(db, out: out, err: err);
      final ok = await pushCmd.execute(
        ctx,
        ['gdrive'],
        {},
        secretStoreOverride: secretStore,
      );

      expect(ok, isFalse);
      final errText = err.toString();
      expect(errText, startsWith('Error: '));
      expect(errText, contains('chmod 600'));
      // No stack trace: cli_runner.dart's generic handler would include
      // "Error executing" plus a multi-line trace; ctx.writeError does not.
      expect(errText, isNot(contains('Error executing')));
      expect(errText, isNot(contains('#0')));
    },
    skip: io.Platform.isWindows
        ? 'POSIX-only: DirectorySecretStore performs no permission '
              'checks on Windows.'
        : false,
  );

  test('missing Google Drive credentials render a clean one-line error, not '
      'a stack trace', () async {
    final pushKey5 = _key();
    await db.store.put(
      'notes',
      pushKey5,
      await ValueCodec.encode({
        'title': 'Hello',
      }, context: ValueContext('notes', pushKey5)),
    );

    final config = await KmdbConfig.forDatabase(dbDir.path);
    config.addRemote('gdrive', GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync'));
    await config.save();

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(
      ctx,
      ['gdrive'],
      {},
      secretStoreOverride: FakeSecretStore(),
    );

    expect(ok, isFalse);
    final errText = err.toString();
    expect(errText, startsWith('Error: '));
    expect(errText, contains('remote add'));
    expect(errText, isNot(contains('Error executing')));
  });
}
