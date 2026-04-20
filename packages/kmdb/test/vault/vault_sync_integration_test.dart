// Copyright 2026 The KMDB Authors
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

// Two-device vault sync integration tests using [LocalDirectoryVaultAdapter].
//
// These tests simulate device A ingesting a file, uploading to the sync vault,
// device B receiving a stub via [syncVaultMetadata], and then hydrating the
// blob on demand via [hydrateVaultBlob].

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/local_directory_vault_adapter.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

import 'package:kmdb/src/vault/media_type_detector.dart';

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

/// A [VaultStore] backed by [MemoryStorageAdapter] for device A (ingestion).
class _DeviceVaultStore extends VaultStore {
  _DeviceVaultStore(MemoryStorageAdapter adapter, String dbPath)
    : _mem = adapter,
      super(adapter: adapter, dbDir: dbPath, detector: const _NoOpDetector());

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

void main() {
  group('VaultSync integration (two-device)', () {
    late Directory syncRoot;
    late MemoryStorageAdapter deviceAAdapter;
    late _DeviceVaultStore deviceAStore;
    late LocalDirectoryVaultAdapter deviceAAdapter2;

    late MemoryStorageAdapter deviceBMemAdapter;
    late _DeviceVaultStore deviceBStore;
    late LocalDirectoryVaultAdapter deviceBAdapter;

    /// Small content bytes.
    final content = Uint8List.fromList(utf8.encode('sync-integration-test'));

    setUp(() {
      syncRoot = Directory.systemTemp.createTempSync('kmdb_sync_int_');

      // Device A: in-memory vault store + local directory sync adapter.
      deviceAAdapter = MemoryStorageAdapter();
      deviceAStore = _DeviceVaultStore(deviceAAdapter, '/device_a');
      deviceAAdapter2 = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceAStore,
      );

      // Device B: separate in-memory vault store + local directory sync adapter.
      deviceBMemAdapter = MemoryStorageAdapter();
      deviceBStore = _DeviceVaultStore(deviceBMemAdapter, '/device_b');
      deviceBAdapter = LocalDirectoryVaultAdapter(
        syncRoot: syncRoot.path,
        localStore: deviceBStore,
      );
    });

    tearDown(() {
      try {
        syncRoot.deleteSync(recursive: true);
      } catch (_) {}
    });

    // ── Full sync lifecycle ───────────────────────────────────────────────

    test(
      'device A ingests → uploads → device B stubs → device B hydrates',
      () async {
        // Step 1: Device A ingests the file.
        final ref = await deviceAStore.ingest(
          bytes: content,
          hlcTimestamp: '0000000000000001',
          originalName: 'photo.jpg',
        );
        final sha256 = ref.sha256;

        // Device A is fully hydrated.
        expect(await deviceAStore.isHydrated(sha256), isTrue);

        // Step 2: Device A uploads to the sync vault.
        await deviceAAdapter2.uploadVaultObject(sha256);
        expect(await deviceAAdapter2.vaultObjectExists(sha256), isTrue);

        // Step 3: Device B syncs metadata (creates a stub).
        await deviceBAdapter.syncVaultMetadata(sha256);
        expect(await deviceBStore.exists(sha256), isTrue);
        expect(await deviceBStore.isHydrated(sha256), isFalse, reason: 'stub');

        // Step 4: Device B requests the blob (on-demand hydration).
        await deviceBAdapter.hydrateVaultBlob(sha256);
        expect(await deviceBStore.isHydrated(sha256), isTrue);

        // The bytes on device B must match the original content.
        final hydratedBytes = await deviceBStore.getBytes(sha256);
        expect(hydratedBytes, equals(content));
      },
    );

    // ── VaultStore.syncAdapter wiring ─────────────────────────────────────

    test('stub.getBytes auto-hydrates when syncAdapter is set', () async {
      // Ingest on device A and upload.
      final ref = await deviceAStore.ingest(
        bytes: content,
        hlcTimestamp: '0000000000000001',
      );
      await deviceAAdapter2.uploadVaultObject(ref.sha256);

      // Device B syncs metadata → stub.
      await deviceBAdapter.syncVaultMetadata(ref.sha256);
      expect(await deviceBStore.isHydrated(ref.sha256), isFalse);

      // Wire the sync adapter on device B's vault store.
      deviceBStore.syncAdapter = deviceBAdapter;

      // Calling getBytes should auto-hydrate.
      final bytes = await deviceBStore.getBytes(ref.sha256);
      expect(bytes, equals(content));
      expect(await deviceBStore.isHydrated(ref.sha256), isTrue);
    });

    test(
      'getBytes on stub throws StateError when no syncAdapter wired',
      () async {
        // Ingest and upload from device A.
        final ref = await deviceAStore.ingest(
          bytes: content,
          hlcTimestamp: '0000000000000001',
        );
        await deviceAAdapter2.uploadVaultObject(ref.sha256);

        // Device B syncs metadata → stub (no syncAdapter wired).
        await deviceBAdapter.syncVaultMetadata(ref.sha256);
        expect(await deviceBStore.isHydrated(ref.sha256), isFalse);
        expect(deviceBStore.syncAdapter, isNull);

        // getBytes must throw StateError.
        await expectLater(
          deviceBStore.getBytes(ref.sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    // ── Idempotency ────────────────────────────────────────────────────────

    test('uploading the same object twice is idempotent', () async {
      final ref = await deviceAStore.ingest(
        bytes: content,
        hlcTimestamp: '0000000000000001',
      );

      // Two uploads should not throw.
      await deviceAAdapter2.uploadVaultObject(ref.sha256);
      await deviceAAdapter2.uploadVaultObject(ref.sha256);

      expect(await deviceAAdapter2.vaultObjectExists(ref.sha256), isTrue);
    });

    test('syncing metadata twice is idempotent', () async {
      final ref = await deviceAStore.ingest(
        bytes: content,
        hlcTimestamp: '0000000000000001',
      );
      await deviceAAdapter2.uploadVaultObject(ref.sha256);

      // Two syncVaultMetadata calls should not throw.
      await deviceBAdapter.syncVaultMetadata(ref.sha256);
      await deviceBAdapter.syncVaultMetadata(ref.sha256);

      expect(await deviceBStore.exists(ref.sha256), isTrue);
    });

    // ── Tombstone propagation ──────────────────────────────────────────────

    test(
      'tombstone uploaded by device A appears on device B after sync',
      () async {
        final ref = await deviceAStore.ingest(
          bytes: content,
          hlcTimestamp: '0000000000000001',
        );
        // Mark as tombstoned locally on device A.
        await deviceAStore.writeTombstone(ref.sha256);
        // Upload with tombstone.
        await deviceAAdapter2.uploadVaultObject(ref.sha256);

        // Device B syncs metadata → should receive tombstone.
        await deviceBAdapter.syncVaultMetadata(ref.sha256);
        expect(await deviceBStore.isTombstoned(ref.sha256), isTrue);
      },
    );

    // ── Non-existent object ────────────────────────────────────────────────

    test(
      'vaultObjectExists returns false for SHA-256 not in sync vault',
      () async {
        final sha256 = VaultStore.computeSha256ForTest(
          Uint8List.fromList(utf8.encode('not-uploaded')),
        );
        expect(await deviceAAdapter2.vaultObjectExists(sha256), isFalse);
      },
    );

    test('syncVaultMetadata throws for SHA-256 not in sync vault', () async {
      final sha256 = VaultStore.computeSha256ForTest(
        Uint8List.fromList(utf8.encode('not-in-sync')),
      );
      await expectLater(
        deviceBAdapter.syncVaultMetadata(sha256),
        throwsA(isA<StateError>()),
      );
    });
  });
}
