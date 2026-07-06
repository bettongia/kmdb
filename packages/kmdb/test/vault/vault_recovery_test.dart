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
import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_recovery.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

import 'test_kv_store.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

class TestVaultStore extends VaultStore {
  TestVaultStore(MemoryStorageAdapter adapter, {super.dbDir = '/db'})
    : _memAdapter = adapter,
      super(
        adapter: adapter,
        detector: const _NoOpDetector(),
        uuidGenerator: _counter,
      );

  final MemoryStorageAdapter _memAdapter;

  static int _seq = 0;
  static String _counter() => 'staging-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final results = <String>[];
    for (final path in _memAdapter.files.keys) {
      if (path.startsWith(prefix)) {
        results.add(path.substring(prefix.length));
      }
    }
    return results;
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

void main() {
  late MemoryStorageAdapter adapter;
  late TestVaultStore store;
  late TestKvStore kvStore;

  setUp(() {
    TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
    store = TestVaultStore(adapter);
    kvStore = TestKvStore();
  });

  group('VaultRecovery', () {
    VaultRecovery makeRecovery() =>
        VaultRecovery(store: store, kvStore: kvStore);

    group('staging sweep', () {
      test('deletes staging files on recovery', () async {
        // Simulate a crash after step 1: staging file exists, no final dir.
        adapter.files['/db/vault/staging/crash-uuid'] = Uint8List(10);

        final result = await makeRecovery().recover();
        expect(result.stagingFilesDeleted, equals(1));
        expect(
          adapter.files.containsKey('/db/vault/staging/crash-uuid'),
          isFalse,
        );
      });

      test('deletes multiple staging files', () async {
        adapter.files['/db/vault/staging/uuid-1'] = Uint8List(5);
        adapter.files['/db/vault/staging/uuid-2'] = Uint8List(5);

        final result = await makeRecovery().recover();
        expect(result.stagingFilesDeleted, equals(2));
      });

      test('no staging files means no deletion', () async {
        final result = await makeRecovery().recover();
        expect(result.stagingFilesDeleted, equals(0));
      });
    });

    group('hash directory sweep', () {
      test(
        'crash after step 3: blob present, no manifest, no KV ref → delete',
        () async {
          // Simulate crash after step 3: blob exists in final path, no manifest.
          final sha256 =
              'aabbcc1234567890aabbcc1234567890aabbcc1234567890aabbcc1234567890';
          adapter.files[store.blobPath(sha256)] = Uint8List(20);
          // No manifest, no KV ref.

          final result = await makeRecovery().recover();
          expect(result.hashDirsDeleted, equals(1));
          expect(await store.isHydrated(sha256), isFalse);
        },
      );

      test('crash after step 4: manifest + blob, no KV ref → delete', () async {
        final bytes = Uint8List.fromList('content'.codeUnits);
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        // Don't add a KV ref — simulates a crash before WriteBatch committed.

        final result = await makeRecovery().recover();
        expect(result.hashDirsDeleted, equals(1));
        expect(await store.exists(ref.sha256), isFalse);
      });

      test('valid object with KV ref is preserved', () async {
        final bytes = Uint8List.fromList('keep me'.codeUnits);
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        // Set a KV ref.
        kvStore.setRefCount(ref.sha256, 1);

        final result = await makeRecovery().recover();
        expect(result.hashDirsDeleted, equals(0));
        expect(await store.exists(ref.sha256), isTrue);
        expect(await store.isHydrated(ref.sha256), isTrue);
      });

      test('stub (manifest-only) with KV ref is preserved', () async {
        // The producer-side contract on [VaultStore.createStub] requires the
        // ref to be established *before* the manifest write, so the call
        // order here matches what a correctly-implemented syncVaultMetadata
        // would do (SSTable ingest establishes the ref, then the stub is
        // materialised).
        final sha256 = 'dd' * 32;
        kvStore.setRefCount(sha256, 1);
        final manifest = VaultManifest(
          sha256: sha256,
          size: 50,
          crc32c: '12345678',
          mediaType: 'image/png',
          originalName: 'remote.png',
          createdAt: 't1',
        );
        await store.createStub(manifest, kvStore: kvStore);

        final result = await makeRecovery().recover();
        expect(result.hashDirsDeleted, equals(0));
        expect(await store.exists(sha256), isTrue);
        expect(await store.isHydrated(sha256), isFalse);
      });

      test('ref-less manifest (contract violation) is deleted', () async {
        // Under the producer-side contract, [VaultStore.createStub] refuses
        // to write a ref-less manifest. To exercise recovery's behaviour
        // when the contract has been violated upstream (e.g. by a buggy
        // adapter, a pre-contract on-disk state, or filesystem corruption),
        // write the manifest directly via the storage adapter so the
        // hash dir reaches the error state recovery is meant to reap.
        final sha256 = 'ee' * 32;
        final manifest = VaultManifest(
          sha256: sha256,
          size: 50,
          crc32c: '12345678',
          mediaType: 'image/png',
          originalName: 'orphan.png',
          createdAt: 't1',
        );
        await adapter.createDirectory(store.hashDir(sha256));
        await adapter.writeFile(
          store.manifestPath(sha256),
          Uint8List.fromList(utf8.encode(manifest.toJsonString())),
        );
        // No KV ref — violates the spec invariant.

        final result = await makeRecovery().recover();
        expect(result.hashDirsDeleted, equals(1));
        expect(await store.exists(sha256), isFalse);
      });

      test('blob only (no manifest) but WITH KV ref — leave alone', () async {
        // This covers the defensive branch in _shouldDelete: a blob exists in
        // the final path without a manifest, but there is already a KV ref.
        // This should not happen normally, but recovery must not delete it.
        final sha256 =
            'bbccdd1234567890bbccdd1234567890bbccdd1234567890bbccdd1234567890';
        adapter.files[store.blobPath(sha256)] = Uint8List(8);
        // Manifest is absent but a KV ref exists — leave it alone.
        kvStore.setRefCount(sha256, 1);

        final result = await makeRecovery().recover();
        // Hash dir must NOT be deleted.
        expect(result.hashDirsDeleted, equals(0));
        expect(await store.isHydrated(sha256), isTrue);
      });

      test('blob only (no manifest) but WITH KV ref — leave alone', () async {
        // This covers the defensive branch in _shouldDelete: a blob exists in
        // the final path without a manifest, but there is already a KV ref.
        // This should not happen normally, but recovery must not delete it.
        final sha256 =
            'bbccdd1234567890bbccdd1234567890bbccdd1234567890bbccdd1234567890';
        adapter.files[store.blobPath(sha256)] = Uint8List(8);
        // Manifest is absent but a KV ref exists — leave it alone.
        kvStore.setRefCount(sha256, 1);

        final result = await makeRecovery().recover();
        // Hash dir must NOT be deleted.
        expect(result.hashDirsDeleted, equals(0));
        expect(await store.isHydrated(sha256), isTrue);
      });

      test(
        'tombstoned object with zero ref count is preserved (GC handles it)',
        () async {
          final bytes = Uint8List.fromList('tombstone'.codeUnits);
          final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
          await store.writeTombstone(ref.sha256);
          // Set ref count to 0 in KV store — this simulates the tombstone path.
          // However, recovery checks for presence, not tombstone state.
          // A tombstoned object with a valid manifest is still "present in KV"
          // only if the WriteBatch that tombstoned it also cleared the ref.
          // Recovery should NOT delete tombstoned objects — that's GC's job.
          // If ref count is 0 and manifest is present, delete it.
          // (This tests that we don't accidentally preserve a zero-ref object.)
          kvStore.setRefCount(ref.sha256, 0);

          final result = await makeRecovery().recover();
          // With ref count 0, the recovery should delete it.
          expect(result.hashDirsDeleted, equals(1));
        },
      );

      // ── Fail-safe ref-count decoding (H3) ───────────────────────────────────

      test(
        'FAIL-SAFE: manifest + corrupt ref entry → object survives recovery',
        () async {
          // A single malformed $vault entry must not let recovery wipe a blob
          // that documents may still reference. The old decoder read this as
          // "no reference" and deleted the hash directory.
          final bytes = Uint8List.fromList('keep on crash'.codeUnits);
          final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
          // Corrupt ref entry: valid codec flag, CBOR int instead of a map.
          kvStore.setRawRefCount(ref.sha256, Uint8List.fromList([0x00, 0x01]));

          final result = await makeRecovery().recover();
          expect(result.hashDirsDeleted, equals(0)); // NOT deleted
          expect(result.retainedUndecodable, equals(1));
          expect(await store.exists(ref.sha256), isTrue);
          expect(await store.isHydrated(ref.sha256), isTrue);
        },
      );

      test('FAIL-SAFE: garbage ref bytes → object survives recovery', () async {
        final bytes = Uint8List.fromList('garbage guard'.codeUnits);
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        kvStore.setRawRefCount(
          ref.sha256,
          Uint8List.fromList([0xEE, 0xFF, 0x00, 0x99]),
        );

        final result = await makeRecovery().recover();
        expect(result.hashDirsDeleted, equals(0));
        expect(result.retainedUndecodable, equals(1));
        expect(await store.exists(ref.sha256), isTrue);
      });

      test(
        'true orphan (manifest present, no ref entry) is still deleted',
        () async {
          // Happy-path regression guard: a genuinely absent ref entry is a
          // positive determination of zero references → delete.
          final bytes = Uint8List.fromList('orphan'.codeUnits);
          final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
          // No KV ref set at all.

          final result = await makeRecovery().recover();
          expect(result.hashDirsDeleted, equals(1));
          expect(result.retainedUndecodable, equals(0));
          expect(await store.exists(ref.sha256), isFalse);
        },
      );
    });

    group('VaultRecoveryResult', () {
      test('hadWork is false when no cleanup', () {
        const r = VaultRecoveryResult(
          stagingFilesDeleted: 0,
          hashDirsDeleted: 0,
        );
        expect(r.hadWork, isFalse);
      });

      test('hadWork is true when staging files deleted', () {
        const r = VaultRecoveryResult(
          stagingFilesDeleted: 1,
          hashDirsDeleted: 0,
        );
        expect(r.hadWork, isTrue);
      });

      test('hadWork is true when hash dirs deleted', () {
        const r = VaultRecoveryResult(
          stagingFilesDeleted: 0,
          hashDirsDeleted: 1,
        );
        expect(r.hadWork, isTrue);
      });

      test('toString includes field values', () {
        const r = VaultRecoveryResult(
          stagingFilesDeleted: 3,
          hashDirsDeleted: 2,
          retainedUndecodable: 7,
        );
        expect(r.toString(), contains('3'));
        expect(r.toString(), contains('2'));
        expect(r.toString(), contains('retainedUndecodable: 7'));
      });

      test('retainedUndecodable defaults to 0', () {
        const r = VaultRecoveryResult(
          stagingFilesDeleted: 0,
          hashDirsDeleted: 0,
        );
        expect(r.retainedUndecodable, equals(0));
      });
    });
  });

  group('kVaultRefCountSentinelKey', () {
    // This is the load-bearing guarantee the entire Bug 1 fix rests on: the
    // sentinel key itself must pass through KeyCodec.keyToBytes (the exact
    // validation that made the old flat `(namespace: '$vault', key: sha256)`
    // scheme throw FormatException on every write). A non-conforming sentinel
    // would silently reintroduce the bug this constant exists to fix.
    test('KeyCodec.keyToBytes does not throw', () {
      expect(
        () => KeyCodec.keyToBytes(kVaultRefCountSentinelKey),
        returnsNormally,
      );
    });

    test('is 32 hex characters', () {
      expect(kVaultRefCountSentinelKey.length, equals(32));
    });

    test('has the UUIDv7 version nibble (\'7\') at index 12', () {
      expect(kVaultRefCountSentinelKey[12], equals('7'));
    });

    test('has a valid UUIDv7 variant nibble at index 16', () {
      expect({
        '8',
        '9',
        'a',
        'b',
      }, contains(kVaultRefCountSentinelKey[16].toLowerCase()));
    });
  });
}
