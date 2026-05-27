// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/local_directory_vault_adapter.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

import 'test_kv_store.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// A [VaultStore] subclass that overrides [listFilesRecursive] for the
/// flat [MemoryStorageAdapter] key store.
class _MemVaultStore extends VaultStore {
  _MemVaultStore(MemoryStorageAdapter adapter, String dbDir)
    : _mem = adapter,
      super(adapter: adapter, dbDir: dbDir);

  final MemoryStorageAdapter _mem;

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

/// Content bytes small enough that VaultStore never triggers Zstd.
final _kContent = Uint8List.fromList(utf8.encode('vault-adapter-test-data'));

void main() {
  group('LocalDirectoryVaultAdapter', () {
    late Directory syncRoot;
    late Directory localDbDir;
    late VaultStore localStore;
    late LocalDirectoryVaultAdapter adapter;
    late TestKvStore localKvStore;

    setUp(() async {
      // Create fresh temp directories for each test.
      syncRoot = Directory.systemTemp.createTempSync('kmdb_vault_sync_');
      localDbDir = Directory.systemTemp.createTempSync('kmdb_vault_local_');

      // Local store uses the native filesystem adapter via MemoryStorageAdapter
      // for simplicity in tests.
      final memAdapter = MemoryStorageAdapter();
      localStore = _MemVaultStore(memAdapter, localDbDir.path);
      localKvStore = TestKvStore();

      adapter = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: localStore,
        kvStore: localKvStore,
      );
    });

    tearDown(() {
      try {
        syncRoot.deleteSync(recursive: true);
      } catch (_) {}
      try {
        localDbDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    // ── vaultObjectExists ─────────────────────────────────────────────────

    test('vaultObjectExists returns false when object is absent', () async {
      final sha256 = VaultStore.computeSha256ForTest(_kContent);
      expect(await adapter.vaultObjectExists(sha256), isFalse);
    });

    test('vaultObjectExists returns true after upload', () async {
      // Ingest locally, then upload.
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);
      expect(await adapter.vaultObjectExists(ref.sha256), isTrue);
    });

    // ── uploadVaultObject ─────────────────────────────────────────────────

    test('upload writes manifest.json and blob to sync vault', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);

      // Verify manifest.json and blob exist at the sync root.
      final sha256 = ref.sha256;
      final prefix = sha256.substring(0, 2);
      final suffix = sha256.substring(2);
      final remoteDir = Directory('${syncRoot.path}/vault/$prefix/$suffix');
      expect(remoteDir.existsSync(), isTrue);
      expect(File('${remoteDir.path}/manifest.json').existsSync(), isTrue);
      expect(File('${remoteDir.path}/blob').existsSync(), isTrue);
    });

    test(
      'upload skips manifest.json if already present (first-writer-wins)',
      () async {
        final ref = await localStore.ingest(
          bytes: _kContent,
          hlcTimestamp: '0000000000000001',
        );

        // First upload writes the manifest.
        await adapter.uploadVaultObject(ref.sha256);

        // Read the manifest content to verify it stays unchanged on second upload.
        final sha256 = ref.sha256;
        final prefix = sha256.substring(0, 2);
        final suffix = sha256.substring(2);
        final remotePath =
            '${syncRoot.path}/vault/$prefix/$suffix/manifest.json';
        final before = File(remotePath).readAsBytesSync();

        // Second upload from same device should be a no-op.
        await adapter.uploadVaultObject(sha256);
        final after = File(remotePath).readAsBytesSync();

        expect(after, equals(before));
      },
    );

    test('upload skips blob if already present', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);

      // Mutate blob on remote to detect re-upload.
      final sha256 = ref.sha256;
      final prefix = sha256.substring(0, 2);
      final suffix = sha256.substring(2);
      final blobPath = '${syncRoot.path}/vault/$prefix/$suffix/blob';
      File(blobPath).writeAsBytesSync(Uint8List.fromList([0xff]));

      // Second upload should skip blob since it already exists.
      await adapter.uploadVaultObject(sha256);
      // Blob stays mutated: the second upload was a no-op.
      final afterBytes = File(blobPath).readAsBytesSync();
      expect(afterBytes, equals(Uint8List.fromList([0xff])));
    });

    // ── syncVaultMetadata ─────────────────────────────────────────────────

    test(
      'syncVaultMetadata creates a stub (manifest, no blob) locally',
      () async {
        // First upload a local object to the sync vault.
        final ref = await localStore.ingest(
          bytes: _kContent,
          hlcTimestamp: '0000000000000001',
        );
        await adapter.uploadVaultObject(ref.sha256);

        // Create a fresh local store that simulates another device (no objects).
        final deviceBAdapter = MemoryStorageAdapter();
        final deviceBStore = _MemVaultStore(deviceBAdapter, '/device_b');
        final deviceBKvStore = TestKvStore();
        // Simulate the ref arriving via SSTable ingest before metadata sync —
        // the ordering precondition documented on [syncVaultMetadata].
        deviceBKvStore.setRefCount(ref.sha256, 1);
        final adapterB = LocalDirectoryVaultAdapter(
          syncRoot: syncRoot.path,
          localStore: deviceBStore,
          kvStore: deviceBKvStore,
        );

        // Sync metadata to device B.
        await adapterB.syncVaultMetadata(ref.sha256);

        // Device B should have manifest.json but no blob → stub.
        expect(await deviceBStore.exists(ref.sha256), isTrue);
        expect(await deviceBStore.isHydrated(ref.sha256), isFalse);
      },
    );

    test(
      'syncVaultMetadata throws StateError when remote manifest missing',
      () async {
        final sha256 = VaultStore.computeSha256ForTest(_kContent);
        await expectLater(
          adapter.syncVaultMetadata(sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    // ── hydrateVaultBlob ──────────────────────────────────────────────────

    test(
      'hydrateVaultBlob downloads blob and makes stub fully hydrated',
      () async {
        // Upload from device A.
        final ref = await localStore.ingest(
          bytes: _kContent,
          hlcTimestamp: '0000000000000001',
        );
        await adapter.uploadVaultObject(ref.sha256);

        // Device B syncs metadata first → stub.
        final deviceBAdapter = MemoryStorageAdapter();
        final deviceBStore = _MemVaultStore(
          deviceBAdapter,
          '/device_b_hydrate',
        );
        final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
        final adapterB = LocalDirectoryVaultAdapter(
          syncRoot: syncRoot.path,
          localStore: deviceBStore,
          kvStore: deviceBKvStore,
        );
        await adapterB.syncVaultMetadata(ref.sha256);
        expect(await deviceBStore.isHydrated(ref.sha256), isFalse);

        // Now hydrate.
        await adapterB.hydrateVaultBlob(ref.sha256);
        expect(await deviceBStore.isHydrated(ref.sha256), isTrue);

        // Content must match the original.
        final hydratedBytes = await deviceBStore.getBytes(ref.sha256);
        expect(hydratedBytes, equals(_kContent));
      },
    );

    test(
      'hydrateVaultBlob throws StateError when remote object does not exist',
      () async {
        final sha256 = VaultStore.computeSha256ForTest(_kContent);
        await expectLater(
          adapter.hydrateVaultBlob(sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'hydrateVaultBlob throws StateError when remote blob is absent',
      () async {
        // Create a remote manifest without a blob (simulates a stub-only remote).
        final sha256 = VaultStore.computeSha256ForTest(_kContent);
        final crc32c = VaultStore.computeCrc32cForTest(_kContent);
        final prefix = sha256.substring(0, 2);
        final suffix = sha256.substring(2);
        final remoteDir = Directory('${syncRoot.path}/vault/$prefix/$suffix')
          ..createSync(recursive: true);
        File('${remoteDir.path}/manifest.json').writeAsStringSync(
          '{"schemaVersion":1,"sha256":"$sha256","size":${_kContent.length},'
          '"crc32c":"$crc32c","mediaType":"application/octet-stream",'
          '"originalName":"test","createdAt":"0000000000000001"}',
        );
        // No blob file written.

        await expectLater(
          adapter.hydrateVaultBlob(sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    // ── Tombstone sync ────────────────────────────────────────────────────

    test('upload propagates tombstone.json when present locally', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      // Create a local tombstone.
      await localStore.writeTombstone(ref.sha256);

      // Upload: should propagate tombstone.
      await adapter.uploadVaultObject(ref.sha256);

      final sha256 = ref.sha256;
      final prefix = sha256.substring(0, 2);
      final suffix = sha256.substring(2);
      final remoteTombstone = File(
        '${syncRoot.path}/vault/$prefix/$suffix/tombstone.json',
      );
      expect(remoteTombstone.existsSync(), isTrue);
    });

    test(
      'syncVaultMetadata downloads tombstone.json if present remotely',
      () async {
        // Upload with tombstone.
        final ref = await localStore.ingest(
          bytes: _kContent,
          hlcTimestamp: '0000000000000001',
        );
        await localStore.writeTombstone(ref.sha256);
        await adapter.uploadVaultObject(ref.sha256);

        // Device B syncs metadata.
        final deviceBAdapter = MemoryStorageAdapter();
        final deviceBStore = _MemVaultStore(deviceBAdapter, '/device_b_tomb');
        final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
        final adapterB = LocalDirectoryVaultAdapter(
          syncRoot: syncRoot.path,
          localStore: deviceBStore,
          kvStore: deviceBKvStore,
        );
        await adapterB.syncVaultMetadata(ref.sha256);

        // Device B should have the tombstone.
        expect(await deviceBStore.isTombstoned(ref.sha256), isTrue);
      },
    );
  });
}
