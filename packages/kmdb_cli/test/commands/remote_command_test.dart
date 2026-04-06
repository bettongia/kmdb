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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/config/kmdb_config.dart';
import 'package:kmdb_cli/src/config/remote_config.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a native-backed store in [dir].
Future<KvStoreImpl> _openStore(String dir) async {
  final adapter = StorageAdapterNative();
  await adapter.createDirectory(dir);
  final (store, _) = await KvStoreImpl.open(dir, adapter);
  await store.ensureDeviceId();
  return store;
}

/// Creates a [CommandContext] backed by [store] with captured output buffers.
CommandContext _ctx(
  KvStoreImpl store, {
  StringBuffer? out,
  StringBuffer? err,
}) => CommandContext(
  store: store,
  out: out ?? StringBuffer(),
  err: err ?? StringBuffer(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late io.Directory tmpDir;
  late io.Directory dbDir;
  late KvStoreImpl store;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('remote_cmd_test_');
    dbDir = io.Directory('${tmpDir.path}/db')..createSync();
    store = await _openStore(dbDir.path);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await store.close(flush: false);
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
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('subcommand required'));
  });

  test('returns false for unknown subcommand', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['oops'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("unknown subcommand 'oops'"));
  });

  // ── add ─────────────────────────────────────────────────────────────────────

  test('add: returns false when name is missing', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('remote name required'));
  });

  test('add: returns false when --path is missing for local type', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add', 'origin'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('--path is required'));
  });

  test('add: returns false for unknown type', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'origin'],
      {'type': 'google_drive', 'path': '/tmp'},
    );
    expect(ok, isFalse);
    expect(err.toString(), contains("unknown type 'google_drive'"));
  });

  test('add: successfully adds a local remote', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['add', 'origin'], {'path': '/tmp/sync'});
    expect(ok, isTrue);
    expect(out.toString(), contains("Remote 'origin' added"));

    // Verify persistence.
    final config = await KmdbConfig.load(dbDir.path);
    expect(config.remotes['origin'], isA<LocalRemoteConfig>());
    expect((config.remotes['origin'] as LocalRemoteConfig).path, '/tmp/sync');
  });

  test('add: explicit --type local works', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(
      ctx,
      ['add', 'nas'],
      {'type': 'local', 'path': '/mnt/nas/sync'},
    );
    expect(ok, isTrue);
  });

  test('add: fails on duplicate without --force', () async {
    final ctx1 = _ctx(store, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/path/a'});

    final ctx2 = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['add', 'origin'], {'path': '/path/b'});
    expect(ok, isFalse);
    expect(err.toString(), contains("already exists"));
  });

  test('add: overwrites with --force', () async {
    final ctx1 = _ctx(store, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/path/a'});

    final ctx2 = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(
      ctx2,
      ['add', 'origin'],
      {'path': '/path/b', 'force': true},
    );
    expect(ok, isTrue);

    final config = await KmdbConfig.load(dbDir.path);
    expect((config.remotes['origin'] as LocalRemoteConfig).path, '/path/b');
  });

  // ── remove ───────────────────────────────────────────────────────────────────

  test('remove: returns false when name is missing', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains('remote name required'));
  });

  test('remove: returns false when remote does not exist', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['remove', 'nosuchremote'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("No remote named 'nosuchremote' found"));
  });

  test('remove: successfully removes a remote', () async {
    // First add.
    final ctx1 = _ctx(store, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/tmp/sync'});

    // Then remove.
    final ctx2 = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['remove', 'origin'], {});
    expect(ok, isTrue);
    expect(out.toString(), contains("Remote 'origin' removed"));

    final config = await KmdbConfig.load(dbDir.path);
    expect(config.remotes, isEmpty);
  });

  // ── list ─────────────────────────────────────────────────────────────────────

  test('list: shows "No remotes" when empty', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx, ['list'], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('No remotes configured'));
  });

  test('list: shows all remotes after add', () async {
    final ctx1 = _ctx(store, out: out, err: err);
    await cmd.execute(ctx1, ['add', 'origin'], {'path': '/tmp/sync'});
    await cmd.execute(ctx1, ['add', 'dropbox'], {'path': '/Dropbox/sync'});

    final ctx2 = _ctx(store, out: out, err: err);
    final ok = await cmd.execute(ctx2, ['list'], {});
    expect(ok, isTrue);
    final output = out.toString();
    expect(output, contains('origin'));
    expect(output, contains('local'));
    expect(output, contains('/tmp/sync'));
    expect(output, contains('dropbox'));
    expect(output, contains('/Dropbox/sync'));
  });

  // ── Round-trip: add → list → remove → list ───────────────────────────────────

  test('full round-trip: add, list, remove, list', () async {
    final ctx = _ctx(store, out: out, err: err);

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
}
