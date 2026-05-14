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
import 'package:kmdb_cli/src/commands/push_command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:test/test.dart';

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
    await db.store.put('notes', _key(), ValueCodec.encode({'title': 'Hello'}));

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
    // Register origin.
    final ctxRemote = _ctx(db, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'origin'],
      {'path': syncDir.path},
    );

    // Write a document.
    await db.store.put('notes', _key(), ValueCodec.encode({'title': 'World'}));

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, [], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('push: complete'));
  });

  test('push via explicit remote name', () async {
    // Register dropbox remote.
    final ctxRemote = _ctx(db, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'dropbox'],
      {'path': syncDir.path},
    );

    await db.store.put('notes', _key(), ValueCodec.encode({'body': 'test'}));

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pushCmd.execute(ctx, ['dropbox'], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('push: complete'));
  });

  // ── Namespace filtering ───────────────────────────────────────────────────

  test('--namespace restricts sync to named namespace', () async {
    await db.store.put('notes', _key(), ValueCodec.encode({'n': 1}));
    await db.store.put('tasks', _key(), ValueCodec.encode({'t': 1}));

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
}
