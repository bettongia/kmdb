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
import 'package:kmdb/src/sync/auth/default_sync_authenticator.dart';
import 'package:kmdb/src/sync/auth/sync_artifact_class.dart';
import 'package:kmdb/src/sync/auth/sync_auth_envelope.dart';
import 'package:kmdb/src/sync/auth/sync_auth_exception.dart';
import 'package:kmdb/src/sync/auth/sync_authenticator.dart';
import 'package:kmdb/src/vault/local_directory_vault_adapter.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

import 'test_kv_store.dart';

/// A fixed 32-byte sync-authentication root key shared by every
/// [LocalDirectoryVaultAdapter] in this file — simulating multiple devices
/// enrolled in the same sync-set (0.10.01 WI-4 T1). All adapters must share
/// one [SyncAuthenticator] instance keyed from this so that device-A writes
/// verify under device-B's reads.
final Uint8List _kTestRootKey = Uint8List.fromList(List.generate(32, (i) => i));

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
    late SyncAuthenticator authenticator;

    setUp(() async {
      // Create fresh temp directories for each test.
      syncRoot = Directory.systemTemp.createTempSync('kmdb_vault_sync_');
      localDbDir = Directory.systemTemp.createTempSync('kmdb_vault_local_');

      // Local store uses the native filesystem adapter via MemoryStorageAdapter
      // for simplicity in tests.
      final memAdapter = MemoryStorageAdapter();
      localStore = _MemVaultStore(memAdapter, localDbDir.path);
      localKvStore = TestKvStore();
      authenticator = DefaultSyncAuthenticator(_kTestRootKey);

      adapter = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: localStore,
        kvStore: localKvStore,
        authenticator: authenticator,
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
      final sha256 = VaultStore.computeSha256(_kContent);
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

    test('syncVaultMetadata creates a stub (manifest, no blob) locally', () async {
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
        authenticator: authenticator,
      );

      // Sync metadata to device B.
      await adapterB.syncVaultMetadata(ref.sha256);

      // Device B should have manifest.json but no blob → stub.
      expect(await deviceBStore.exists(ref.sha256), isTrue);
      expect(await deviceBStore.isHydrated(ref.sha256), isFalse);
    });

    test(
      'syncVaultMetadata throws StateError when remote manifest missing',
      () async {
        final sha256 = VaultStore.computeSha256(_kContent);
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
          authenticator: authenticator,
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

    test('hydrateVaultBlob rejects a substituted remote blob (S-4) — content '
        'that does not hash to the requested address is never written to the '
        'local final blob path', () async {
      // Upload legitimate content from device A.
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);

      // Attacker substitutes the remote blob's bytes in place — simulating
      // a malicious peer (T3) who legitimately holds the sync-set key (a
      // shared-key MAC cannot distinguish a malicious key-holder from a
      // legitimate one — see the plan's Non-goals) but writes mismatched
      // content. This is the residual attacker S-4 defends against once
      // sync authentication (0.10.01 WI-4 T1) is in place: T1 (a compromised
      // provider *without* the key) can no longer even produce a
      // validly-enveloped substitution at all — that weaker case is covered
      // by sync_auth_envelope_test.dart, not here. The manifest (sha256,
      // crc32c) is left untouched, so this is exactly the "whatever the
      // sync folder holds becomes the local blob for that address" scenario
      // the review's S-4 finding describes.
      final prefix = ref.sha256.substring(0, 2);
      final suffix = ref.sha256.substring(2);
      // Prefixed with EncryptionFlag.none (0x00) so the substituted bytes
      // parse as a well-formed (unencrypted) EncryptionEnvelope, then
      // wrapped in a *validly-authenticated* sync-auth envelope (matching
      // the malicious-key-holder threat model above) — this test is
      // specifically about the SHA-256 content-address check surviving
      // *underneath* a passing sync-auth check, not envelope parsing.
      final substituted = Uint8List.fromList([
        0x00,
        ...utf8.encode('attacker-substituted-content'),
      ]);
      final enveloped = await SyncAuthEnvelope.wrap(
        substituted,
        authenticator,
        artifactClass: SyncArtifactClass.vaultBlob,
        relativePath: 'vault/$prefix/$suffix/blob',
      );
      final remoteBlobPath = '${syncRoot.path}/vault/$prefix/$suffix/blob';
      await File(remoteBlobPath).writeAsBytes(enveloped);

      // Device B syncs metadata (stub) then attempts hydration.
      final deviceBAdapter = MemoryStorageAdapter();
      final deviceBStore = _MemVaultStore(
        deviceBAdapter,
        '/device_b_substitution',
      );
      final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
      final adapterB = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceBStore,
        kvStore: deviceBKvStore,
        authenticator: authenticator,
      );
      await adapterB.syncVaultMetadata(ref.sha256);

      await expectLater(
        adapterB.hydrateVaultBlob(ref.sha256),
        throwsA(isA<VaultContentMismatchException>()),
      );

      // The substituted content must never have reached the local final
      // blob path — the object must still read as a stub, not a hydrated
      // (and now-poisoned) local blob.
      expect(await deviceBStore.isHydrated(ref.sha256), isFalse);
    });

    test(
      'hydrateVaultBlob throws StateError when remote object does not exist',
      () async {
        final sha256 = VaultStore.computeSha256(_kContent);
        await expectLater(
          adapter.hydrateVaultBlob(sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('hydrateVaultBlob throws StateError when remote blob is absent', () async {
      // Create a remote manifest without a blob (simulates a stub-only remote).
      final sha256 = VaultStore.computeSha256(_kContent);
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
    });

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
          authenticator: authenticator,
        );
        await adapterB.syncVaultMetadata(ref.sha256);

        // Device B should have the tombstone.
        expect(await deviceBStore.isTombstoned(ref.sha256), isTrue);
      },
    );

    // ── Sync authentication (0.10.01 WI-4 T1, Phase 4 forged-artefact matrix) ──

    test('syncVaultMetadata rejects a forged (raw, un-enveloped) remote '
        'manifest.json', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);

      // Attacker (or a legacy pre-sync-auth remote, R-5) overwrites the
      // manifest with raw, un-enveloped bytes.
      final prefix = ref.sha256.substring(0, 2);
      final suffix = ref.sha256.substring(2);
      final remoteManifestPath =
          '${syncRoot.path}/vault/$prefix/$suffix/manifest.json';
      await File(remoteManifestPath)
          .writeAsBytes(utf8.encode('{"forged": true}'));

      final deviceBAdapter = MemoryStorageAdapter();
      final deviceBStore = _MemVaultStore(
        deviceBAdapter,
        '/device_b_forged_manifest',
      );
      final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
      final adapterB = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceBStore,
        kvStore: deviceBKvStore,
        authenticator: authenticator,
      );

      await expectLater(
        adapterB.syncVaultMetadata(ref.sha256),
        throwsA(isA<SyncAuthException>()),
      );
      // The forged manifest must never have been accepted as a stub.
      expect(await deviceBStore.exists(ref.sha256), isFalse);
    });

    test('syncVaultMetadata rejects a forged (raw, un-enveloped) remote '
        'tombstone.json', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await localStore.writeTombstone(ref.sha256);
      await adapter.uploadVaultObject(ref.sha256);

      // Attacker overwrites the tombstone with raw, un-enveloped bytes —
      // a forged tombstone is a deletion-triggering artefact, so this
      // must be rejected just as strictly as a forged manifest.
      final prefix = ref.sha256.substring(0, 2);
      final suffix = ref.sha256.substring(2);
      final remoteTombstonePath =
          '${syncRoot.path}/vault/$prefix/$suffix/tombstone.json';
      await File(remoteTombstonePath)
          .writeAsBytes(utf8.encode('{"forged": true}'));

      final deviceBAdapter = MemoryStorageAdapter();
      final deviceBStore = _MemVaultStore(
        deviceBAdapter,
        '/device_b_forged_tombstone',
      );
      final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
      final adapterB = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceBStore,
        kvStore: deviceBKvStore,
        authenticator: authenticator,
      );

      await expectLater(
        adapterB.syncVaultMetadata(ref.sha256),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('hydrateVaultBlob rejects a forged (raw, un-enveloped) remote blob '
        'before ever reaching the EncryptionEnvelope/sha256 checks', () async {
      final ref = await localStore.ingest(
        bytes: _kContent,
        hlcTimestamp: '0000000000000001',
      );
      await adapter.uploadVaultObject(ref.sha256);

      final prefix = ref.sha256.substring(0, 2);
      final suffix = ref.sha256.substring(2);
      final remoteBlobPath = '${syncRoot.path}/vault/$prefix/$suffix/blob';
      // Raw bytes, no sync-auth envelope at all (distinct from the S-4
      // test above, which uses a *validly-enveloped* substitution to
      // isolate the sha256 check specifically).
      await File(remoteBlobPath)
          .writeAsBytes([0x00, ...utf8.encode('forged-no-envelope')]);

      final deviceBAdapter = MemoryStorageAdapter();
      final deviceBStore = _MemVaultStore(
        deviceBAdapter,
        '/device_b_forged_blob',
      );
      final deviceBKvStore = TestKvStore()..setRefCount(ref.sha256, 1);
      final adapterB = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceBStore,
        kvStore: deviceBKvStore,
        authenticator: authenticator,
      );
      await adapterB.syncVaultMetadata(ref.sha256);

      await expectLater(
        adapterB.hydrateVaultBlob(ref.sha256),
        throwsA(isA<SyncAuthException>()),
      );
      expect(await deviceBStore.isHydrated(ref.sha256), isFalse);
    });
  });
}
