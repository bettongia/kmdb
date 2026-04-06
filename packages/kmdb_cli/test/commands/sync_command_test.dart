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
import 'package:kmdb_cli/src/commands/sync_command.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:test/test.dart';

/// Generates a valid UUIDv7 key.
String _key() => const UuidV7KeyGenerator().next();

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a store via [DatabaseOpener] so the engine device ID is correct.
Future<KvStoreImpl> _openStore(String dir) async =>
    (await DatabaseOpener.open(dir)).$1;

/// Opens a store with an explicit [deviceId] for tests requiring distinct
/// device identities.
Future<KvStoreImpl> _openStoreWithId(String dir, String deviceId) async {
  final adapter = StorageAdapterNative();
  await adapter.createDirectory(dir);
  final (store, _) = await KvStoreImpl.open(dir, adapter, deviceId: deviceId);
  return store;
}

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
  late io.Directory syncDir;
  late KvStoreImpl store;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    tmpDir = io.Directory.systemTemp.createTempSync('sync_cmd_test_');
    dbDir = io.Directory('${tmpDir.path}/db')..createSync();
    syncDir = io.Directory('${tmpDir.path}/sync')..createSync();
    store = await _openStore(dbDir.path);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await store.close(flush: false);
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  const syncCmd = SyncCommand();
  const remoteCmd = RemoteCommand();

  test('name and description are set', () {
    expect(syncCmd.name, 'sync');
    expect(syncCmd.description, isNotEmpty);
  });

  // ── Error: no remote ──────────────────────────────────────────────────────

  test('returns false when no remote and no origin is configured', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("no 'origin' remote is configured"));
  });

  test('returns false when named remote does not exist', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, ['nosuchremote'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("remote 'nosuchremote' not found"));
  });

  // ── Error: --sync-dir + name ──────────────────────────────────────────────

  test(
    'returns false when both remote name and --sync-dir are given',
    () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await syncCmd.execute(
        ctx,
        ['origin'],
        {'sync-dir': syncDir.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    },
  );

  // ── Sync with no user namespaces ──────────────────────────────────────────

  test('sync with no user namespaces exits successfully', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('nothing to sync'));
  });

  // ── Sync via --sync-dir ───────────────────────────────────────────────────

  test('sync via --sync-dir pushes local data', () async {
    await store.put('notes', _key(), ValueCodec.encode({'t': 'sync test'}));

    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('sync: complete'));

    // Verify SSTable was uploaded.
    final sstDir = io.Directory('${syncDir.path}/sstables');
    expect(
      sstDir.existsSync() &&
          sstDir.listSync().any((e) => e.path.endsWith('.sst')),
      isTrue,
    );
  });

  // ── Sync via named remote ─────────────────────────────────────────────────

  test('sync uses origin remote by default', () async {
    final ctxRemote = _ctx(store, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'origin'],
      {'path': syncDir.path},
    );

    await store.put('tasks', _key(), ValueCodec.encode({'task': 'test'}));

    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('sync: complete'));
  });

  // ── Round-trip: two logical devices sync via shared folder ────────────────

  test('round-trip: local writes from peer appear after sync', () async {
    // Peer device pushes data to the sync folder.
    const peerDeviceId = 'peerffff';
    final peerDbDir = io.Directory('${tmpDir.path}/peerdb')..createSync();
    final peerStore = await _openStoreWithId(peerDbDir.path, peerDeviceId);
    final peerKey = _key();
    await peerStore.put('notes', peerKey, ValueCodec.encode({'from': 'peer'}));
    await peerStore.flush();
    final peerInfo = await peerStore.storeInfo();
    final peerEngine = SyncEngine(
      store: peerStore,
      cloudAdapter: LocalDirectoryAdapter(syncDir.path),
      localAdapter: StorageAdapterNative(),
      deviceId: peerDeviceId,
      dbDir: peerInfo.dbDir,
      syncRoot: '',
      syncNamespaces: {'notes'},
    );
    await peerEngine.push();
    await peerStore.close(flush: false);

    // Our device writes data, then syncs.
    await store.put('notes', _key(), ValueCodec.encode({'local': true}));
    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('sync: complete'));

    // After sync, the peer's document should be in our local store.
    final raw = await store.get('notes', peerKey);
    expect(raw, isNotNull);
    final doc = ValueCodec.decode(raw!);
    expect(doc['from'], 'peer');
  });

  // ── Namespace filtering ───────────────────────────────────────────────────

  test('system collection cannot be synced via --namespace', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await syncCmd.execute(ctx, [], {
      'sync-dir': syncDir.path,
      'collection': r'$meta',
    });
    expect(ok, isFalse);
    expect(err.toString(), contains('system collection'));
  });
}
