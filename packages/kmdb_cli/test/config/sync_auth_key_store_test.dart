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
import 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';
import 'package:kmdb_cli/src/config/secret_store/secret_key.dart';
import 'package:kmdb_cli/src/config/sync_auth_key_store.dart';
import 'package:test/test.dart';

import '../support/fake_secret_store.dart';

void main() {
  late FakeSecretStore store;
  const dbDir = '/db/one';
  const remoteName = 'origin';

  setUp(() {
    store = FakeSecretStore();
  });

  group('syncAuthSecretKey', () {
    test('is dbScopedSecretKey with a sync-auth: prefixed name', () {
      final key = syncAuthSecretKey(dbDir, remoteName);
      expect(key, equals(dbScopedSecretKey(dbDir, 'sync-auth:$remoteName')));
    });

    test('differs for different remote names under the same dbDir', () {
      expect(
        syncAuthSecretKey(dbDir, 'origin'),
        isNot(equals(syncAuthSecretKey(dbDir, 'dropbox'))),
      );
    });

    test('differs for the same remote name under different dbDirs', () {
      expect(
        syncAuthSecretKey('/db/a', remoteName),
        isNot(equals(syncAuthSecretKey('/db/b', remoteName))),
      );
    });
  });

  group('mintSyncAuthKey', () {
    test('generates and persists a fresh key', () async {
      final key = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(key.rootKey.length, 32);

      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, equals(key));
    });

    test('overwrites any existing key for the same remote', () async {
      final first = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      final second = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(second, isNot(equals(first)));

      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, equals(second));
    });
  });

  group('loadSyncAuthKey', () {
    test('returns null when no key has been minted (R-4)', () async {
      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, isNull);
    });

    test('is scoped independently per remote name', () async {
      final originKey = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'origin',
        secretStoreOverride: store,
      );
      final dropboxKey = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'dropbox',
        secretStoreOverride: store,
      );
      expect(originKey, isNot(equals(dropboxKey)));

      final loadedOrigin = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'origin',
        secretStoreOverride: store,
      );
      final loadedDropbox = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'dropbox',
        secretStoreOverride: store,
      );
      expect(loadedOrigin, equals(originKey));
      expect(loadedDropbox, equals(dropboxKey));
    });
  });

  group('importSyncAuthKey', () {
    test('installs an externally-provided key (remote pair import)', () async {
      final sharedKey = SyncSetKey.generate();
      await importSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        key: sharedKey,
        secretStoreOverride: store,
      );

      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, equals(sharedKey));
    });

    test('overwrites an auto-minted key from a prior remote add', () async {
      final autoMinted = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      final sharedKey = SyncSetKey.generate();
      await importSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        key: sharedKey,
        secretStoreOverride: store,
      );

      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, isNot(equals(autoMinted)));
      expect(loaded, equals(sharedKey));
    });
  });

  group('deleteSyncAuthKey', () {
    test('removes a previously-minted key', () async {
      await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      await deleteSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );

      final loaded = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loaded, isNull);
    });

    test('is a no-op when no key exists for the remote', () async {
      await deleteSyncAuthKey(
        dbDir: dbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      // No exception — verified implicitly by reaching this point.
    });

    test('does not affect a different remote\'s key', () async {
      final dropboxKey = await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'dropbox',
        secretStoreOverride: store,
      );
      await mintSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'origin',
        secretStoreOverride: store,
      );
      await deleteSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'origin',
        secretStoreOverride: store,
      );

      final loadedDropbox = await loadSyncAuthKey(
        dbDir: dbDir,
        remoteName: 'dropbox',
        secretStoreOverride: store,
      );
      expect(loadedDropbox, equals(dropboxKey));
    });
  });

  // ── Default store resolution (no override) ─────────────────────────────
  //
  // Exercises `secretStoreOverride ?? DirectorySecretStore.forPlatform()`
  // for real — every other test in this file deliberately injects a
  // [FakeSecretStore] to keep isolation from the real machine profile
  // directory. `loadSyncAuthKey` is read-only and therefore safe to call
  // unguarded against a guaranteed-absent key. `importSyncAuthKey` is a
  // write, so it explicitly cleans up via the same real
  // `DirectorySecretStore.forPlatform()` afterwards — never left behind.
  group('default store resolution', () {
    test('loadSyncAuthKey without an override resolves the real '
        'DirectorySecretStore.forPlatform() default (read-only, guaranteed-'
        'absent key, no fixture)', () async {
      final loaded = await loadSyncAuthKey(
        dbDir: '/never/a/real/db/dir/${DateTime.now().microsecondsSinceEpoch}',
        remoteName: 'never-enrolled',
      );
      expect(loaded, isNull);
    });

    test('importSyncAuthKey without an override writes through the real '
        'DirectorySecretStore.forPlatform() default, and is cleaned up '
        'afterwards', () async {
      final uniqueDbDir =
          '/tmp/sync_auth_key_store_test_${DateTime.now().microsecondsSinceEpoch}';
      final key = SyncSetKey.generate();
      try {
        await importSyncAuthKey(
          dbDir: uniqueDbDir,
          remoteName: remoteName,
          key: key,
        );
        final loaded = await loadSyncAuthKey(
          dbDir: uniqueDbDir,
          remoteName: remoteName,
        );
        expect(loaded, equals(key));
      } finally {
        // Clean up through the same real store — never leave a secret
        // behind on the developer's actual machine.
        await DirectorySecretStore.forPlatform().delete(
          syncAuthSecretKey(uniqueDbDir, remoteName),
        );
      }
    });
  });

  group('key survives device-identity changes', () {
    test('a minted sync-auth key is unaffected by KvStore.reassignDeviceId — '
        'the SecretStore key is scoped by (dbDir, remoteName) only, never '
        'deviceId', () async {
      final tmpDir = io.Directory.systemTemp.createTempSync(
        'sync_auth_key_store_test_',
      );
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final realDbDir = tmpDir.path;

      final adapter = StorageAdapterNative();
      await adapter.createDirectory(realDbDir);
      final db = await KmdbDatabase.open(path: realDbDir, adapter: adapter);
      addTearDown(() => db.close(flush: false));

      final originalDeviceId = await db.ensureDeviceId();

      final mintedKey = await mintSyncAuthKey(
        dbDir: realDbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );

      // Reassign the device identity — a completely orthogonal axis to
      // the sync-authentication key, which is keyed by (dbDir,
      // remoteName) only (see syncAuthSecretKey).
      const newDeviceId = 'a1b2c3d4';
      await db.store.reassignDeviceId(newDeviceId);
      final updatedDeviceId = await db.ensureDeviceId();
      expect(updatedDeviceId, equals(newDeviceId));
      expect(updatedDeviceId, isNot(equals(originalDeviceId)));

      final loadedAfterReassign = await loadSyncAuthKey(
        dbDir: realDbDir,
        remoteName: remoteName,
        secretStoreOverride: store,
      );
      expect(loadedAfterReassign, equals(mintedKey));
    });
  });
}
