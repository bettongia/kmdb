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
import 'package:kmdb_cli/src/commands/pull_command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:test/test.dart';

/// Generates a valid UUIDv7 key.
String _key() => const UuidV7KeyGenerator().next();

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a store via [DatabaseOpener] so the engine device ID is correct.
Future<KvStoreImpl> _openStore(String dir) => DatabaseOpener.open(dir);

/// Opens a store with a specific [deviceId] (bypasses meta for the engine ID).
///
/// Used for "peer" stores in tests to ensure distinct device identities
/// regardless of how quickly the test opens two databases.
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
    tmpDir = io.Directory.systemTemp.createTempSync('pull_cmd_test_');
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

  const pullCmd = PullCommand();
  const remoteCmd = RemoteCommand();

  test('name and description are set', () {
    expect(pullCmd.name, 'pull');
    expect(pullCmd.description, isNotEmpty);
  });

  // ── Error: no remote ──────────────────────────────────────────────────────

  test('returns false when no remote and no origin is configured', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("no 'origin' remote is configured"));
  });

  test('returns false when named remote does not exist', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, ['nosuch'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("remote 'nosuch' not found"));
  });

  // ── Error: --sync-dir + remote name ──────────────────────────────────────

  test(
    'returns false when both remote name and --sync-dir are given',
    () async {
      final ctx = _ctx(store, out: out, err: err);
      final ok = await pullCmd.execute(
        ctx,
        ['origin'],
        {'sync-dir': syncDir.path},
      );
      expect(ok, isFalse);
      expect(err.toString(), contains('mutually exclusive'));
    },
  );

  // ── Pull with no peer data ────────────────────────────────────────────────

  test('pull with no peer SSTables is a no-op', () async {
    // Empty database, empty sync dir.
    final ctx = _ctx(store, out: out, err: err);

    // Need a namespace to pull: add a doc first so pull doesn't exit early.
    await store.put('notes', _key(), ValueCodec.encode({'x': 1}));

    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));
  });

  // ── Pull no namespaces warning ────────────────────────────────────────────

  test('pull with no user namespaces exits successfully', () async {
    // Fresh store — no user namespaces.
    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('nothing to pull'));
  });

  // ── Pull via --sync-dir ───────────────────────────────────────────────────

  test('pull ingests peer SSTables from sync folder', () async {
    // Set up a second device that pushes a document.
    // Use an explicit device ID to guarantee it differs from the device ID
    // that will be generated when we open our local store.
    const peerDeviceId = 'peerdead';
    final peerDbDir = io.Directory('${tmpDir.path}/peerdb')..createSync();
    final peerStore = await _openStoreWithId(peerDbDir.path, peerDeviceId);
    final peerKey = _key();
    await peerStore.put(
      'notes',
      peerKey,
      ValueCodec.encode({'msg': 'from peer'}),
    );
    // Flush to materialise the SSTable, then push.
    await peerStore.flush();

    // Build a SyncEngine manually for the peer to push with its explicit
    // device ID, because PushCommand uses storeInfo() which would return the
    // meta ID (undefined for a raw open) rather than the engine ID.
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

    // Add a namespace on our store so we have something to pull into.
    await store.put('notes', _key(), ValueCodec.encode({'local': true}));

    // Now pull from the sync folder.
    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));

    // The peer's document should now be in our local store.
    final raw = await store.get('notes', peerKey);
    expect(raw, isNotNull);
    final doc = ValueCodec.decode(raw!);
    expect(doc['msg'], 'from peer');
  });

  // ── Pull via named remote ─────────────────────────────────────────────────

  test('pull via named remote', () async {
    // Register the remote.
    final ctxRemote = _ctx(store, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'origin'],
      {'path': syncDir.path},
    );

    // Add a namespace so pull doesn't exit early.
    await store.put('notes', _key(), ValueCodec.encode({'y': 2}));

    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));
  });

  // ── Namespace filtering ───────────────────────────────────────────────────

  test('system namespace cannot be synced via --namespace', () async {
    final ctx = _ctx(store, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {
      'sync-dir': syncDir.path,
      'namespace': r'$meta',
    });
    expect(ok, isFalse);
    expect(err.toString(), contains('system namespace'));
  });
}
