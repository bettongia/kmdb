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

// Fault-injection and default-coverage tests for VaultGc.sweep() and
// VaultRecovery.recover() against a *real*, non-overridden VaultStore.
//
// Every other vault_gc_test.dart / vault_recovery_test.dart test uses
// TestVaultStore, which overrides VaultStore.listFilesRecursive with its own
// prefix-scan implementation — so those tests exercise VaultGc/VaultRecovery's
// logic but never actually drive the production
// `VaultStore.listFilesRecursive` → `StorageAdapter.listFilesRecursive`
// delegation this plan fixes (previously a stub that always returned []).
//
// This file constructs a bare `VaultStore` directly (no subclass override)
// against both MemoryStorageAdapter and FaultyStorageAdapter, so a regression
// in the real default (e.g. a leading path separator reintroduced by a future
// change) would be caught here even though ~30 other test doubles in the
// suite would stay green.

import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_recovery.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';
import 'test_kv_store.dart';

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('VaultGc.sweep — real VaultStore.listFilesRecursive delegation', () {
    test(
      'MemoryStorageAdapter: tombstoned, zero-ref blob is deleted',
      () async {
        final adapter = MemoryStorageAdapter();
        final store = VaultStore(
          dbDir: '/db',
          adapter: adapter,
          detector: const _NoOpDetector(),
        );
        final kvStore = TestKvStore();
        final gc = VaultGc(store: store, kvStore: kvStore);

        final ref = await store.ingest(
          bytes: _bytes('gc-me'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(ref.sha256); // tombstone, ref count absent (zero)

        final result = await gc.sweep();
        expect(result.examined, equals(1));
        expect(result.deleted, equals(1));
        expect(await store.exists(ref.sha256), isFalse);
      },
    );

    test(
      'MemoryStorageAdapter: referenced blob survives sweep, unreferenced '
      'blob does not — proves enumeration finds exactly the right hashes',
      () async {
        final adapter = MemoryStorageAdapter();
        final store = VaultStore(
          dbDir: '/db',
          adapter: adapter,
          detector: const _NoOpDetector(),
        );
        final kvStore = TestKvStore();
        final gc = VaultGc(store: store, kvStore: kvStore);

        final kept = await store.ingest(
          bytes: _bytes('keep-me'),
          hlcTimestamp: 't1',
        );
        kvStore.setRefCount(kept.sha256, 1);

        final gone = await store.ingest(
          bytes: _bytes('lose-me'),
          hlcTimestamp: 't1',
        );
        await gc.onZeroRefs(gone.sha256);

        final result = await gc.sweep();
        expect(result.deleted, equals(1));
        expect(await store.exists(kept.sha256), isTrue);
        expect(await store.exists(gone.sha256), isFalse);
      },
    );

    test('FaultyStorageAdapter (fault-injection harness): tombstoned, '
        'zero-ref blob is deleted', () async {
      final adapter = FaultyStorageAdapter();
      final store = VaultStore(
        dbDir: '/db',
        adapter: adapter,
        detector: const _NoOpDetector(),
      );
      final kvStore = TestKvStore();
      final gc = VaultGc(store: store, kvStore: kvStore);

      final ref = await store.ingest(
        bytes: _bytes('gc-me'),
        hlcTimestamp: 't1',
      );
      await gc.onZeroRefs(ref.sha256);

      final result = await gc.sweep();
      expect(result.examined, equals(1));
      expect(result.deleted, equals(1));
      expect(await store.exists(ref.sha256), isFalse);
    });

    test('FaultyStorageAdapter: referenced blob survives sweep, unreferenced '
        'blob does not', () async {
      final adapter = FaultyStorageAdapter();
      final store = VaultStore(
        dbDir: '/db',
        adapter: adapter,
        detector: const _NoOpDetector(),
      );
      final kvStore = TestKvStore();
      final gc = VaultGc(store: store, kvStore: kvStore);

      final kept = await store.ingest(
        bytes: _bytes('keep-me'),
        hlcTimestamp: 't1',
      );
      kvStore.setRefCount(kept.sha256, 1);

      final gone = await store.ingest(
        bytes: _bytes('lose-me'),
        hlcTimestamp: 't1',
      );
      await gc.onZeroRefs(gone.sha256);

      final result = await gc.sweep();
      expect(result.deleted, equals(1));
      expect(await store.exists(kept.sha256), isTrue);
      expect(await store.exists(gone.sha256), isFalse);
    });
  });

  group(
    'VaultRecovery.recover — real VaultStore.listFilesRecursive delegation',
    () {
      test(
        'MemoryStorageAdapter: manifest + blob, no KV ref → orphan deleted',
        () async {
          final adapter = MemoryStorageAdapter();
          final store = VaultStore(
            dbDir: '/db',
            adapter: adapter,
            detector: const _NoOpDetector(),
          );
          final kvStore = TestKvStore();
          final recovery = VaultRecovery(store: store, kvStore: kvStore);

          // Simulates a crash after the vault write path completed but before
          // the WriteBatch (ref-count increment) committed.
          final ref = await store.ingest(
            bytes: _bytes('orphan'),
            hlcTimestamp: 't1',
          );

          final result = await recovery.recover();
          expect(result.hashDirsDeleted, equals(1));
          expect(await store.exists(ref.sha256), isFalse);
        },
      );

      test(
        'MemoryStorageAdapter: manifest + blob, with KV ref → preserved',
        () async {
          final adapter = MemoryStorageAdapter();
          final store = VaultStore(
            dbDir: '/db',
            adapter: adapter,
            detector: const _NoOpDetector(),
          );
          final kvStore = TestKvStore();
          final recovery = VaultRecovery(store: store, kvStore: kvStore);

          final ref = await store.ingest(
            bytes: _bytes('keep'),
            hlcTimestamp: 't1',
          );
          kvStore.setRefCount(ref.sha256, 1);

          final result = await recovery.recover();
          expect(result.hashDirsDeleted, equals(0));
          expect(await store.exists(ref.sha256), isTrue);
        },
      );

      test('FaultyStorageAdapter (fault-injection harness): manifest + blob, '
          'no KV ref → orphan deleted', () async {
        final adapter = FaultyStorageAdapter();
        final store = VaultStore(
          dbDir: '/db',
          adapter: adapter,
          detector: const _NoOpDetector(),
        );
        final kvStore = TestKvStore();
        final recovery = VaultRecovery(store: store, kvStore: kvStore);

        final ref = await store.ingest(
          bytes: _bytes('orphan'),
          hlcTimestamp: 't1',
        );

        final result = await recovery.recover();
        expect(result.hashDirsDeleted, equals(1));
        expect(await store.exists(ref.sha256), isFalse);
      });

      test(
        'FaultyStorageAdapter: manifest + blob, with KV ref → preserved',
        () async {
          final adapter = FaultyStorageAdapter();
          final store = VaultStore(
            dbDir: '/db',
            adapter: adapter,
            detector: const _NoOpDetector(),
          );
          final kvStore = TestKvStore();
          final recovery = VaultRecovery(store: store, kvStore: kvStore);

          final ref = await store.ingest(
            bytes: _bytes('keep'),
            hlcTimestamp: 't1',
          );
          kvStore.setRefCount(ref.sha256, 1);

          final result = await recovery.recover();
          expect(result.hashDirsDeleted, equals(0));
          expect(await store.exists(ref.sha256), isTrue);
        },
      );

      test('FaultyStorageAdapter: staging file present, un-synced content '
          'still visible to the live-view sweep', () async {
        // The staging sweep operates on the adapter's live view (matching
        // production semantics: recovery runs before any crash-discarded
        // writes are relevant — the LOCK guarantees no concurrent writer).
        final adapter = FaultyStorageAdapter();
        final store = VaultStore(
          dbDir: '/db',
          adapter: adapter,
          detector: const _NoOpDetector(),
        );
        final kvStore = TestKvStore();
        final recovery = VaultRecovery(store: store, kvStore: kvStore);

        await adapter.writeFile(
          '${store.stagingDir}/crash-uuid',
          _bytes('incomplete'),
        );

        final result = await recovery.recover();
        expect(result.stagingFilesDeleted, equals(1));
        expect(
          await adapter.fileExists('${store.stagingDir}/crash-uuid'),
          isFalse,
        );
      });
    },
  );
}
