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

/// Unit tests for [VaultSearchManager.writeExtractArtifact] and
/// [VaultSearchManager.readExtractArtifact] — the flag-byte codec used to
/// (optionally) encrypt `extract/` filesystem artifacts (WI-10, §31).
///
/// These tests exercise the codec directly (no full indexing pipeline
/// required): a manager is constructed against a bare [MemoryStorageAdapter]
/// -backed [VaultStore] and the two methods are called directly with
/// synthetic paths.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:kmdb/src/vault/search/vault_search_manager.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [MediaTypeDetector] stub — media-type detection is irrelevant here.
final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/veac-test';
const _deviceId = 'veac0test0';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Bundles the pieces needed to construct and tear down a
/// [VaultSearchManager] backed by a fresh [MemoryStorageAdapter].
final class _Fixture {
  _Fixture(this.adapter, this.kvStore, this.vaultStore, this.manager);

  final MemoryStorageAdapter adapter;
  final KvStoreImpl kvStore;
  final VaultStore vaultStore;
  final VaultSearchManager manager;

  Future<void> dispose() async {
    await manager.close();
    await kvStore.close();
  }
}

/// Builds a [_Fixture] against a fresh in-memory store, optionally with
/// [encryption] configured on the manager.
Future<_Fixture> _makeFixture({EncryptionProvider? encryption}) async {
  final adapter = MemoryStorageAdapter();
  final (kvStore, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  final vaultStore = VaultStore(
    dbDir: '/db',
    adapter: adapter,
    detector: const _NoOpDetector(),
  );
  final manager = VaultSearchManager(
    config: VaultSearchConfig(chunkSize: 50, chunkOverlap: 5),
    kvStore: kvStore,
    vaultStore: vaultStore,
    encryption: encryption,
  );
  return _Fixture(adapter, kvStore, vaultStore, manager);
}

void main() {
  group('writeExtractArtifact / readExtractArtifact', () {
    test(
      'plaintext round-trip when no EncryptionProvider is configured',
      () async {
        final fx = await _makeFixture();
        addTearDown(fx.dispose);

        const path = '/db/vault/aa/extract/text.txt';
        final plaintext = _bytes('hello plaintext extract artifact');

        await fx.manager.writeExtractArtifact(path, plaintext);
        final roundTripped = await fx.manager.readExtractArtifact(path);

        expect(roundTripped, equals(plaintext));
      },
    );

    test(
      'plaintext artifact is prefixed with EncryptionFlag.none (0x00) on disk',
      () async {
        final fx = await _makeFixture();
        addTearDown(fx.dispose);

        const path = '/db/vault/aa/extract/text.txt';
        final plaintext = _bytes('plain');
        await fx.manager.writeExtractArtifact(path, plaintext);

        final raw = await fx.adapter.readFile(path);
        expect(raw[0], equals(EncryptionFlag.none.byte));
        expect(raw.sublist(1), equals(plaintext));
      },
    );

    test(
      'encrypted round-trip when an EncryptionProvider is configured',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final fx = await _makeFixture(encryption: provider);
        addTearDown(fx.dispose);

        const path = '/db/vault/bb/extract/chunks_v1.json';
        final plaintext = _bytes('[{"index":0,"byteStart":0,"byteEnd":5}]');

        await fx.manager.writeExtractArtifact(path, plaintext);
        final roundTripped = await fx.manager.readExtractArtifact(path);

        expect(roundTripped, equals(plaintext));
      },
    );

    test(
      'encrypted artifact is prefixed with EncryptionFlag.aesGcm (0x01) on disk',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final fx = await _makeFixture(encryption: provider);
        addTearDown(fx.dispose);

        const path = '/db/vault/bb/extract/text.txt';
        final plaintext = _bytes('secret text content');
        await fx.manager.writeExtractArtifact(path, plaintext);

        final raw = await fx.adapter.readFile(path);
        expect(raw[0], equals(EncryptionFlag.aesGcm.byte));
        // Ciphertext body must not contain the plaintext verbatim.
        expect(
          utf8.decode(raw, allowMalformed: true),
          isNot(contains('secret text content')),
        );
      },
    );

    test('empty artifact file throws FormatException on read', () async {
      final fx = await _makeFixture();
      addTearDown(fx.dispose);

      const path = '/db/vault/cc/extract/text.txt';
      await fx.adapter.writeFile(path, Uint8List(0));

      await expectLater(
        fx.manager.readExtractArtifact(path),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'corrupted ciphertext throws EncryptionError.badCredentials',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final fx = await _makeFixture(encryption: provider);
        addTearDown(fx.dispose);

        const path = '/db/vault/dd/extract/text.txt';
        await fx.manager.writeExtractArtifact(path, _bytes('secret text'));

        // Corrupt the ciphertext in place (flip the last byte of the GCM tag).
        final raw = await fx.adapter.readFile(path);
        final corrupted = Uint8List.fromList(raw);
        corrupted[corrupted.length - 1] ^= 0xFF;
        await fx.adapter.writeFile(path, corrupted);

        await expectLater(
          fx.manager.readExtractArtifact(path),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.badCredentials,
            ),
          ),
        );
      },
    );

    test('unknown flag byte throws ArgumentError', () async {
      final fx = await _makeFixture();
      addTearDown(fx.dispose);

      const path = '/db/vault/ee/extract/text.txt';
      // 0xFF is not a recognised EncryptionFlag byte.
      await fx.adapter.writeFile(
        path,
        Uint8List.fromList([0xFF, ...utf8.encode('body')]),
      );

      await expectLater(
        fx.manager.readExtractArtifact(path),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'encrypted artifact read with no provider configured throws StateError',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);

        // Write with encryption configured.
        final fx = await _makeFixture(encryption: provider);
        addTearDown(fx.dispose);

        const path = '/db/vault/ff/extract/text.txt';
        await fx.manager.writeExtractArtifact(path, _bytes('secret'));

        // Read with a second manager over the same adapter/filesystem, but
        // with no EncryptionProvider configured.
        final noEncManager = VaultSearchManager(
          config: VaultSearchConfig(chunkSize: 50, chunkOverlap: 5),
          kvStore: fx.kvStore,
          vaultStore: fx.vaultStore,
        );
        addTearDown(noEncManager.close);

        await expectLater(
          noEncManager.readExtractArtifact(path),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
