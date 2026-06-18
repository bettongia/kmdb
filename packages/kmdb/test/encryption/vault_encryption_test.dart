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

import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_gc.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

import '../vault/test_kv_store.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter, {super.encryption})
    : _memAdapter = adapter,
      super(
        dbDir: '/db',
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
    return [
      for (final path in _memAdapter.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

// ── Helpers ──────────────────────────────────────────────────────────────────

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

const _hlc = '0000000000000001-0001';

void main() {
  late MemoryStorageAdapter adapter;

  setUp(() {
    _TestVaultStore._seq = 0;
    adapter = MemoryStorageAdapter();
  });

  // ── Plaintext vault (no encryption) ──────────────────────────────────────────

  group('VaultStore without encryption', () {
    test('ingest then getBytes round-trips', () async {
      final store = _TestVaultStore(adapter);
      final data = _bytes('hello world');
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
      final recovered = await store.getBytes(ref.sha256);
      expect(recovered, equals(data));
    });

    test('manifest does not set encrypted flag for plaintext', () async {
      final store = _TestVaultStore(adapter);
      final data = _bytes('plaintext data');
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
      final manifest = await store.getManifest(ref.sha256);
      expect(manifest.encrypted, isFalse);
    });
  });

  // ── Encrypted vault ───────────────────────────────────────────────────────────

  group('VaultStore with AES-GCM encryption', () {
    late Uint8List dek;
    late AesGcmEncryptionProvider provider;

    setUpAll(() async {
      dek = await KeyDerivation.generateDek();
    });

    setUp(() {
      provider = AesGcmEncryptionProvider(dek);
    });

    test('ingest stores ciphertext on disk (not plaintext)', () async {
      final store = _TestVaultStore(adapter, encryption: provider);

      const plaintext = 'this-is-secret-data';
      final data = _bytes(plaintext);
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);

      // Read the raw bytes on disk and verify the plaintext is not visible.
      final blobPath = store.blobPath(ref.sha256);
      final rawOnDisk = adapter.files[blobPath]!;
      final plaintextBytes = data;

      bool foundPlaintext = false;
      outer:
      for (var i = 0; i <= rawOnDisk.length - plaintextBytes.length; i++) {
        for (var j = 0; j < plaintextBytes.length; j++) {
          if (rawOnDisk[i + j] != plaintextBytes[j]) continue outer;
        }
        foundPlaintext = true;
        break;
      }
      expect(
        foundPlaintext,
        isFalse,
        reason:
            'Plaintext was found in the stored blob — encryption not applied',
      );
    });

    test('getBytes decrypts and returns plaintext', () async {
      final store = _TestVaultStore(adapter, encryption: provider);

      final data = _bytes('secret content');
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
      final recovered = await store.getBytes(ref.sha256);
      expect(recovered, equals(data));
    });

    test('manifest sets encrypted: true when encryption is active', () async {
      final store = _TestVaultStore(adapter, encryption: provider);

      final data = _bytes('blob data');
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
      final manifest = await store.getManifest(ref.sha256);
      expect(manifest.encrypted, isTrue);
    });

    test(
      'SHA-256 content address is computed over plaintext (not ciphertext)',
      () async {
        final store = _TestVaultStore(adapter, encryption: provider);

        final data = _bytes('content for hash check');
        final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);

        // Compute the expected hash over the PLAINTEXT.
        final expectedSha256 = VaultStore.computeSha256ForTest(data);
        expect(ref.sha256, equals(expectedSha256));

        // Also verify the stored blob is NOT the data itself (it's ciphertext).
        final blobPath = store.blobPath(ref.sha256);
        final rawOnDisk = adapter.files[blobPath]!;
        expect(rawOnDisk, isNot(equals(data)));
      },
    );

    test(
      'deduplication: two ingests of same plaintext return the same ref',
      () async {
        final store = _TestVaultStore(adapter, encryption: provider);

        final data = _bytes('deduplicated content');
        final ref1 = await store.ingest(bytes: data, hlcTimestamp: _hlc);
        final ref2 = await store.ingest(bytes: data, hlcTimestamp: _hlc);
        expect(ref1.sha256, equals(ref2.sha256));
      },
    );

    test(
      'getBytes throws StateError when blob is encrypted but no provider',
      () async {
        // Ingest with encryption.
        final storeWithEnc = _TestVaultStore(adapter, encryption: provider);
        final data = _bytes('encrypted content');
        final ref = await storeWithEnc.ingest(bytes: data, hlcTimestamp: _hlc);

        // Open the same adapter with a store that has no encryption provider.
        final storeNoEnc = _TestVaultStore(adapter);
        expect(
          () async => storeNoEnc.getBytes(ref.sha256),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('large blob round-trips encrypted', () async {
      final store = _TestVaultStore(adapter, encryption: provider);

      final data = Uint8List.fromList(List.generate(100000, (i) => i % 256));
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
      final recovered = await store.getBytes(ref.sha256);
      expect(recovered, equals(data));
    });
  });

  // ── Vault recovery with encryption ────────────────────────────────────────────

  group('VaultStore encrypted manifest parsing', () {
    test('encrypted: true round-trips through manifest JSON', () async {
      final dek2 = await KeyDerivation.generateDek();
      final prov = AesGcmEncryptionProvider(dek2);
      final store = _TestVaultStore(adapter, encryption: prov);

      final data = _bytes('manifest test');
      final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);

      // Read the manifest and verify the encrypted field.
      final manifest = await store.getManifest(ref.sha256);
      expect(manifest.encrypted, isTrue);
      expect(manifest.sha256, equals(ref.sha256));
    });
  });

  // ── VaultGc sweep with encryption ────────────────────────────────────────────

  group('VaultGc sweep with encrypted ref counts', () {
    // These tests exercise the blocking bug reported in Q6: $vault ref count
    // entries are encrypted, but the three read sites (VaultGc.sweep,
    // VaultStore.createStub, VaultRecovery._classify) were not passing the
    // EncryptionProvider to VaultRefCount.read. Without the provider the
    // 0x01 encryption flag byte causes a FormatException, which
    // VaultRefCount.read catches and returns RefCountUndecodable — the
    // fail-safe retains the blob instead of GC'ing it.

    late Uint8List dek;
    late AesGcmEncryptionProvider provider;
    late TestKvStore kvStore;

    setUpAll(() async {
      dek = await KeyDerivation.generateDek();
    });

    setUp(() {
      provider = AesGcmEncryptionProvider(dek);
      kvStore = TestKvStore();
    });

    test(
      'full GC cycle: ingest → ref count written encrypted → delete → sweep reclaims blob',
      () async {
        final store = _TestVaultStore(adapter, encryption: provider);
        final gc = VaultGc(
          store: store,
          kvStore: kvStore,
          encryption: provider,
        );

        // Step 1: Ingest a blob (simulates the write path).
        final data = _bytes('gc-cycle-secret');
        final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
        final sha256 = ref.sha256;

        // Step 2: Seed an encrypted ref count entry (simulates what
        // VaultRefInterceptor writes when a document referencing this blob is
        // created). The entry is a ValueCodec-encoded map with the provider.
        final encryptedRefCountBytes = await ValueCodec.encode({
          'refCount': 1,
        }, encryption: provider);
        kvStore.setRawRefCount(sha256, encryptedRefCountBytes);

        // Blob should be present and the ref count readable when the correct
        // provider is supplied.
        expect(await store.isHydrated(sha256), isTrue);

        // Step 3: Decrement to zero — write a tombstone (simulates document
        // deletion). Use a zero ref count entry and tombstone to mimic what
        // VaultRefInterceptor.decrement does: it deletes the entry and calls
        // gc.onZeroRefs. Here we clear the ref and create the tombstone directly.
        kvStore.clearRefCount(sha256);
        await gc.onZeroRefs(sha256);

        // Tombstone should now be present.
        expect(await store.isTombstoned(sha256), isTrue);

        // Step 4: Run the GC sweep. With the encryption provider threaded
        // through, VaultRefCount.read can decode the (now absent) entry, which
        // is treated as RefCountAbsent → zero refs → safe to delete.
        final result = await gc.sweep();

        // The blob must have been reclaimed.
        expect(result.deleted, equals(1));
        expect(result.retainedUndecodable, equals(0));
        expect(
          await store.exists(sha256),
          isFalse,
          reason: 'blob should have been GC\'d',
        );
      },
    );

    test(
      'sweep retains blob when ref count is encrypted and no provider is given',
      () async {
        // Regression guard: without the fix, a missing provider caused
        // RefCountUndecodable, which the fail-safe correctly retained.
        // After the fix, callers must supply the provider. This test confirms
        // that the pre-fix behaviour (retain on undecodable) still applies
        // if someone constructs VaultGc with the wrong/no provider.
        final store = _TestVaultStore(adapter, encryption: provider);

        // VaultGc with NO encryption provider.
        final gcNoEnc = VaultGc(store: store, kvStore: kvStore);

        final data = _bytes('should-be-retained');
        final ref = await store.ingest(bytes: data, hlcTimestamp: _hlc);
        final sha256 = ref.sha256;

        // Store an encrypted ref count entry (non-zero) — GC without provider
        // cannot decode it.
        final encryptedRefCountBytes = await ValueCodec.encode({
          'refCount': 1,
        }, encryption: provider);
        kvStore.setRawRefCount(sha256, encryptedRefCountBytes);

        // Tombstone the object.
        await gcNoEnc.onZeroRefs(sha256);

        // Sweep without provider: the encrypted entry is undecodable, so the
        // fail-safe retains the blob.
        final result = await gcNoEnc.sweep();
        expect(result.retainedUndecodable, equals(1));
        expect(result.deleted, equals(0));
        expect(
          await store.exists(sha256),
          isTrue,
          reason: 'fail-safe must retain blob when ref count is undecodable',
        );
      },
    );
  });
}
