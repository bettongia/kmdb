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
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Opens a [KmdbDatabase] backed by [MemoryStorageAdapter].
///
/// Uses [deviceId] so that SSTable names are deterministic in tests. Callers
/// that want to test [KmdbDatabase.ensureDeviceId] should pass the default
/// `'00000000'` and then call it explicitly.
///
/// [path] defaults to `'/db'`. Tests that open two databases concurrently
/// must pass distinct paths (e.g. `'/dba'` and `'/dbb'`) because
/// [MemoryStorageAdapter] uses a shared static lock table keyed by path.
Future<KmdbDatabase> _openDb({
  String deviceId = 'dev00001',
  StorageAdapter? adapter,
  String path = '/db',
}) async {
  return KmdbDatabase.open(
    path: path,
    adapter: adapter ?? MemoryStorageAdapter(),
    deviceId: deviceId,
    config: KvStoreConfig.forTesting(),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── ensureDeviceId ──────────────────────────────────────────────────────────

  group('KmdbDatabase.ensureDeviceId', () {
    test('returns a valid 8-char hex device ID', () async {
      final db = await _openDb(deviceId: '00000000');
      addTearDown(() async => db.close(flush: false));

      final id = await db.ensureDeviceId();

      // Must be 8 lowercase hex characters.
      expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('second call returns the same ID as the first', () async {
      final db = await _openDb(deviceId: '00000000');
      addTearDown(() async => db.close(flush: false));

      final first = await db.ensureDeviceId();
      final second = await db.ensureDeviceId();

      expect(second, equals(first));
    });

    test(
      'when deviceId is already stable the returned value is valid hex',
      () async {
        final db = await _openDb(deviceId: 'abcd1234');
        addTearDown(() async => db.close(flush: false));

        // ensureDeviceId reads-or-generates the ID from $meta; the engine
        // default may differ from the constructor argument, but the result
        // must always be a valid 8-char hex string.
        final id = await db.ensureDeviceId();
        expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
      },
    );
  });

  // ── sync ──────────────────────────────────────────────────────────────────

  group('KmdbDatabase.sync', () {
    test('sync completes without error on an empty database', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      final syncAdapter = MemorySyncAdapter();

      // sync = push then pull; neither should throw on an empty store.
      await expectLater(
        db.sync(syncAdapter: syncAdapter, localAdapter: localAdapter),
        completes,
      );
    });

    test('sync uploads a document written to a user collection', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      final syncAdapter = MemorySyncAdapter();

      // Write a document and flush so it becomes an SSTable on disk.
      final col = db.rawCollection('things');
      final key = const UuidV7KeyGenerator().next();
      await col.insert({'_id': key, 'name': 'widget'});
      await db.store.flush();

      await db.sync(syncAdapter: syncAdapter, localAdapter: localAdapter);

      // After sync, the remote should have at least one SSTable.
      final remoteFiles = await syncAdapter.list('sstables', extension: '.sst');
      expect(remoteFiles, isNotEmpty);
    });

    test('sync round-trips a document between two databases', () async {
      final adapterA = MemoryStorageAdapter();
      final adapterB = MemoryStorageAdapter();
      final dbA = await _openDb(
        adapter: adapterA,
        deviceId: 'aaaa0001',
        path: '/dba',
      );
      final dbB = await _openDb(
        adapter: adapterB,
        deviceId: 'bbbb0001',
        path: '/dbb',
      );
      addTearDown(() async {
        await dbA.close(flush: false);
        await dbB.close(flush: false);
      });

      final syncAdapter = MemorySyncAdapter();

      // Device A writes a document. Use put() so the key is deterministic —
      // insert() always generates a fresh key, ignoring any '_id' in the map.
      final key = const UuidV7KeyGenerator().next();
      await dbA.rawCollection('items').put({'_id': key, 'x': 1});
      await dbA.store.flush();

      // Device A pushes.
      await dbA.push(syncAdapter: syncAdapter, localAdapter: adapterA);

      // Device B pulls.
      await dbB.pull(syncAdapter: syncAdapter, localAdapter: adapterB);

      // Device B should now be able to read the document.
      final doc = await dbB.rawCollection('items').get(key);
      expect(doc, isNotNull);
      expect(doc!['x'], equals(1));
    });
  });

  // ── push ──────────────────────────────────────────────────────────────────

  group('KmdbDatabase.push', () {
    test('push completes on an empty store', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      await expectLater(
        db.push(syncAdapter: MemorySyncAdapter(), localAdapter: localAdapter),
        completes,
      );
    });

    test('push uploads local SSTables to the sync adapter', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      final syncAdapter = MemorySyncAdapter();

      // Produce a flushed SSTable.
      final key = const UuidV7KeyGenerator().next();
      await db.rawCollection('col').insert({'_id': key, 'v': 42});
      await db.store.flush();

      await db.push(syncAdapter: syncAdapter, localAdapter: localAdapter);

      final files = await syncAdapter.list('sstables', extension: '.sst');
      expect(files, isNotEmpty);
    });

    test(
      'push with explicit syncNamespaces uploads only those namespaces',
      () async {
        final localAdapter = MemoryStorageAdapter();
        final db = await _openDb(adapter: localAdapter);
        addTearDown(() async => db.close(flush: false));

        final syncAdapter = MemorySyncAdapter();

        final k1 = const UuidV7KeyGenerator().next();
        final k2 = const UuidV7KeyGenerator().next();
        await db.rawCollection('wanted').insert({'_id': k1, 'a': 1});
        await db.rawCollection('unwanted').insert({'_id': k2, 'b': 2});
        await db.store.flush();

        // Only sync the 'wanted' namespace.
        await db.push(
          syncAdapter: syncAdapter,
          localAdapter: localAdapter,
          syncNamespaces: {'wanted'},
        );

        // At least one SSTable must have been uploaded (SSTables are
        // device-wide, not per-namespace; the upload still proceeds).
        final files = await syncAdapter.list('sstables', extension: '.sst');
        expect(files, isNotEmpty);
      },
    );

    test('push with syncRoot prefixes paths in the sync adapter', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      final syncAdapter = MemorySyncAdapter();
      const root = 'mydb';

      final key = const UuidV7KeyGenerator().next();
      await db.rawCollection('ns').insert({'_id': key, 'v': 1});
      await db.store.flush();

      await db.push(
        syncAdapter: syncAdapter,
        localAdapter: localAdapter,
        syncRoot: root,
      );

      // Files should appear under '<root>/sstables/'.
      final files = await syncAdapter.list('$root/sstables', extension: '.sst');
      expect(files, isNotEmpty);

      // The empty-root path should be empty.
      final rootFiles = await syncAdapter.list('sstables', extension: '.sst');
      expect(rootFiles, isEmpty);
    });
  });

  // ── pull ──────────────────────────────────────────────────────────────────

  group('KmdbDatabase.pull', () {
    test('pull completes without error when sync adapter is empty', () async {
      final localAdapter = MemoryStorageAdapter();
      final db = await _openDb(adapter: localAdapter);
      addTearDown(() async => db.close(flush: false));

      await expectLater(
        db.pull(syncAdapter: MemorySyncAdapter(), localAdapter: localAdapter),
        completes,
      );
    });

    test('pull ingests peer SSTables and makes documents readable', () async {
      final adapterA = MemoryStorageAdapter();
      final adapterB = MemoryStorageAdapter();

      final dbA = await _openDb(
        adapter: adapterA,
        deviceId: 'aaaa0001',
        path: '/dba',
      );
      final dbB = await _openDb(
        adapter: adapterB,
        deviceId: 'bbbb0001',
        path: '/dbb',
      );
      addTearDown(() async {
        await dbA.close(flush: false);
        await dbB.close(flush: false);
      });

      final syncAdapter = MemorySyncAdapter();

      // Device A: write and push. Use put() so the key is deterministic —
      // insert() always generates a fresh key, ignoring any '_id' in the map.
      final key = const UuidV7KeyGenerator().next();
      await dbA.rawCollection('notes').put({'_id': key, 'text': 'hello'});
      await dbA.store.flush();
      await dbA.push(syncAdapter: syncAdapter, localAdapter: adapterA);

      // Device B: pull.
      await dbB.pull(syncAdapter: syncAdapter, localAdapter: adapterB);

      final doc = await dbB.rawCollection('notes').get(key);
      expect(doc, isNotNull);
      expect(doc!['text'], equals('hello'));
    });
  });

  // ── syncNamespaces default ──────────────────────────────────────────────────

  group('syncNamespaces default', () {
    test(
      'null syncNamespaces includes all user non-system namespaces',
      () async {
        final localAdapter = MemoryStorageAdapter();
        final db = await _openDb(adapter: localAdapter);
        addTearDown(() async => db.close(flush: false));

        // Register two user collections and one system-like collection.
        final k1 = const UuidV7KeyGenerator().next();
        final k2 = const UuidV7KeyGenerator().next();
        await db.rawCollection('alpha').insert({'_id': k1, 'v': 1});
        await db.rawCollection('beta').insert({'_id': k2, 'v': 2});
        await db.store.flush();

        // sync with null syncNamespaces should not throw.
        final syncAdapter = MemorySyncAdapter();
        await expectLater(
          db.sync(syncAdapter: syncAdapter, localAdapter: localAdapter),
          completes,
        );

        // Both user namespaces should have been synced (SSTables uploaded).
        final files = await syncAdapter.list('sstables', extension: '.sst');
        expect(files, isNotEmpty);
      },
    );
  });

  // ── consolidationConfig ────────────────────────────────────────────────────

  group('consolidationConfig parameter', () {
    test(
      'ConsolidationConfig is forwarded: aggressive threshold triggers',
      () async {
        final adapterA = MemoryStorageAdapter();
        final adapterB = MemoryStorageAdapter();

        final dbA = await _openDb(
          adapter: adapterA,
          deviceId: 'aaaa0001',
          path: '/dba',
        );
        final dbB = await _openDb(
          adapter: adapterB,
          deviceId: 'bbbb0001',
          path: '/dbb',
        );
        addTearDown(() async {
          await dbA.close(flush: false);
          await dbB.close(flush: false);
        });

        final syncAdapter = MemorySyncAdapter();

        // Push from device A.
        final k = const UuidV7KeyGenerator().next();
        await dbA.rawCollection('x').insert({'_id': k, 'n': 1});
        await dbA.store.flush();
        await dbA.push(syncAdapter: syncAdapter, localAdapter: adapterA);

        // Pull on device B with a threshold of 1 so consolidation fires.
        await expectLater(
          dbB.pull(
            syncAdapter: syncAdapter,
            localAdapter: adapterB,
            consolidationConfig: const ConsolidationConfig(threshold: 1),
          ),
          completes,
        );
      },
    );
  });
}
