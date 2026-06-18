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
import 'package:kmdb_cli/src/commands/pull_command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/commands/sync_helpers.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:test/test.dart';

/// Generates a valid UUIDv7 key.
String _key() => const UuidV7KeyGenerator().next();

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a database via [DatabaseOpener] so the engine device ID is correct.
Future<KmdbDatabase> _openStore(String dir) async =>
    (await DatabaseOpener.open(dir, KmdbConfig.empty())).$1;

/// Opens a raw store with a specific [deviceId] (bypasses meta for the engine
/// ID). Used for "peer" stores in sync tests to ensure distinct device
/// identities regardless of how quickly the test opens two databases. Peer
/// stores are used with [SyncEngine] directly and do not need [KmdbDatabase].
Future<KvStoreImpl> _openStoreWithId(String dir, String deviceId) async {
  final adapter = StorageAdapterNative();
  await adapter.createDirectory(dir);
  final (store, _) = await KvStoreImpl.open(dir, adapter, deviceId: deviceId);
  return store;
}

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
    tmpDir = io.Directory.systemTemp.createTempSync('pull_cmd_test_');
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

  const pullCmd = PullCommand();
  const remoteCmd = RemoteCommand();

  test('name and description are set', () {
    expect(pullCmd.name, 'pull');
    expect(pullCmd.description, isNotEmpty);
  });

  // ── Error: no remote ──────────────────────────────────────────────────────

  test('returns false when no remote and no origin is configured', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("no 'origin' remote is configured"));
  });

  test('returns false when named remote does not exist', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, ['nosuch'], {});
    expect(ok, isFalse);
    expect(err.toString(), contains("remote 'nosuch' not found"));
  });

  test('returns false when config.json is corrupt', () async {
    // Write a malformed config.json into the database's local/ dir so that
    // KmdbConfig.load throws a FormatException when resolving the remote.
    final localDir = io.Directory('${dbDir.path}/local')..createSync();
    io.File(
      '${localDir.path}/config.json',
    ).writeAsStringSync('{ this is not valid json }');

    final ctx = _ctx(db, out: out, err: err);
    // Use a named remote (not --sync-dir) so the command loads config.json.
    final ok = await pullCmd.execute(ctx, ['origin'], {});
    expect(ok, isFalse);
    expect(err.toString(), isNotEmpty);
  });

  // ── Error: --sync-dir + remote name ──────────────────────────────────────

  test(
    'returns false when both remote name and --sync-dir are given',
    () async {
      final ctx = _ctx(db, out: out, err: err);
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
    final ctx = _ctx(db, out: out, err: err);

    // Need a namespace to pull: add a doc first so pull doesn't exit early.
    await db.store.put('notes', _key(), await ValueCodec.encode({'x': 1}));

    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));
  });

  // ── Pull on empty local store ─────────────────────────────────────────────

  test('pull on empty local store succeeds and reports complete', () async {
    // Fresh store with no local collections — pull should still run so that
    // a device with no data can receive peer SSTables on its first sync.
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));
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
      await ValueCodec.encode({'msg': 'from peer'}),
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
    await db.store.put(
      'notes',
      _key(),
      await ValueCodec.encode({'local': true}),
    );

    // Now pull from the sync folder.
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {'sync-dir': syncDir.path});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));

    // The peer's document should now be in our local store.
    final raw = await db.store.get('notes', peerKey);
    expect(raw, isNotNull);
    final doc = await ValueCodec.decode(raw!);
    expect(doc['msg'], 'from peer');
  });

  // ── Pull via named remote ─────────────────────────────────────────────────

  test('pull via named remote', () async {
    // Register the remote.
    final ctxRemote = _ctx(db, out: out, err: err);
    await remoteCmd.execute(
      ctxRemote,
      ['add', 'origin'],
      {'path': syncDir.path},
    );

    // Add a namespace so pull doesn't exit early.
    await db.store.put('notes', _key(), await ValueCodec.encode({'y': 2}));

    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {});
    expect(ok, isTrue);
    expect(out.toString(), contains('pull: complete'));
  });

  // ── Namespace filtering ───────────────────────────────────────────────────

  test('system collection cannot be synced via --namespace', () async {
    final ctx = _ctx(db, out: out, err: err);
    final ok = await pullCmd.execute(ctx, [], {
      'sync-dir': syncDir.path,
      'collection': r'$meta',
    });
    expect(ok, isFalse);
    expect(err.toString(), contains('system collection'));
  });

  // ── purgeOrphanedIndexes ──────────────────────────────────────────────────

  group('purgeOrphanedIndexes', () {
    /// Creates a [CommandContext] backed by [db] with the given [config].
    CommandContext makeCtx(KmdbDatabase d, KmdbConfig config) =>
        CommandContext(db: d, config: config, out: out, err: err);

    test('no-op when no index definitions are configured', () async {
      // A collection with documents but no index config — nothing should happen.
      await db.store.put('notes', _key(), await ValueCodec.encode({'x': 1}));
      final config = KmdbConfig.empty();
      final ctx = makeCtx(db, config);
      await SyncHelpers.purgeOrphanedIndexes(ctx, dbDir.path);
      // Collection should still be registered.
      final namespaces = await db.store.listNamespaces();
      expect(namespaces, contains('notes'));
    });

    test(
      'collection with live docs is unaffected even when indexes configured',
      () async {
        // Register a collection with a live document and configure an index.
        await db.store.put(
          'contacts',
          _key(),
          await ValueCodec.encode({'city': 'Sydney'}),
        );
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        final ctx = makeCtx(db, config);

        await SyncHelpers.purgeOrphanedIndexes(ctx, dbDir.path);

        // Collection must still be registered and index config untouched.
        final namespaces = await db.store.listNamespaces();
        expect(namespaces, contains('contacts'));
        expect(config.indexesForCollection('contacts'), hasLength(1));
      },
    );

    test(
      'orphaned collection is unregistered and config cleared when all docs tombstoned',
      () async {
        // Simulate a collection that has been entirely deleted (all tombstones).
        // We can achieve this by registering the namespace without inserting any
        // documents — createNamespace registers it but leaves it empty.
        await db.store.createNamespace('contacts');
        final config = KmdbConfig.empty();
        config.addIndex('contacts', 'city');
        expect(config.indexesForCollection('contacts'), hasLength(1));

        final ctx = makeCtx(db, config);
        await SyncHelpers.purgeOrphanedIndexes(ctx, dbDir.path);

        // Index config should be cleared.
        expect(config.indexesForCollection('contacts'), isEmpty);
        // Namespace should be unregistered.
        final namespaces = await db.store.listNamespaces();
        expect(namespaces, isNot(contains('contacts')));
      },
    );

    test(
      'cleanup runs for multiple orphaned collections in one pass',
      () async {
        // Two collections: both empty after "full tombstone" scenario.
        await db.store.createNamespace('collA');
        await db.store.createNamespace('collB');
        final config = KmdbConfig.empty();
        config.addIndex('collA', 'field1');
        config.addIndex('collB', 'field2');

        final ctx = makeCtx(db, config);
        await SyncHelpers.purgeOrphanedIndexes(ctx, dbDir.path);

        // Both index definitions should be removed.
        expect(config.indexesForCollection('collA'), isEmpty);
        expect(config.indexesForCollection('collB'), isEmpty);
        // Both namespaces should be unregistered.
        final namespaces = await db.store.listNamespaces();
        expect(namespaces, isNot(contains('collA')));
        expect(namespaces, isNot(contains('collB')));
      },
    );

    test('collection not registered in meta is silently skipped', () async {
      // A collection is in config but was never registered in $meta (e.g. it
      // was added to config on another device and then sync'd, but the
      // namespace registry was never set). purgeOrphanedIndexes should be a
      // no-op and not throw.
      final config = KmdbConfig.empty();
      config.addIndex('ghost', 'field');
      final ctx = makeCtx(db, config);

      // Should not throw.
      await expectLater(
        SyncHelpers.purgeOrphanedIndexes(ctx, dbDir.path),
        completes,
      );
      // Config is untouched because the collection was not in $meta.
      expect(config.indexesForCollection('ghost'), hasLength(1));
    });
  });
}
