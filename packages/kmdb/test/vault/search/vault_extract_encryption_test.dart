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

/// Toggle-on / mixed-state integration test for WI-10 (`extract/` filesystem
/// artifact encryption).
///
/// Exercises the exact transition the roadmap and §31 describe: a blob
/// indexed before encryption was configured keeps its plaintext
/// (`EncryptionFlag.none`) artifacts; a database that is subsequently
/// reopened with a freshly provisioned [EncryptionProvider] (modelled here by
/// constructing a second [VaultSearchManager] against the same [KvStoreImpl]
/// / [VaultStore] — the same pattern [KmdbDatabase.open] uses to wire a live
/// provider into the manager) writes newly indexed blobs with encrypted
/// (`EncryptionFlag.aesGcm`) artifacts. Both coexist and are individually
/// searchable and correct. [VaultSearchManager.reindexVault] then migrates
/// the still-plaintext blob's artifacts to encrypted, without disturbing the
/// blob that was already encrypted.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/search/search_mode.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_extraction_state.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:kmdb/src/vault/search/vault_search_manager.dart';
import 'package:kmdb/src/vault/search/vault_searcher.dart';
import 'package:kmdb/src/vault/search/vault_text_extractor.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [VaultTextExtractor] that handles `text/plain` blobs via UTF-8 decode.
final class _FixedTextExtractor implements VaultTextExtractor {
  const _FixedTextExtractor();

  @override
  Set<String> get supportedMediaTypes => const {'text/plain'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    if (!supportedMediaTypes.contains(manifest.mediaType)) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Always reports `text/plain`.
final class _AlwaysPlainDetector implements MediaTypeDetector {
  const _AlwaysPlainDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [
    'text/plain',
  ];
}

/// A [VaultStore] backed by [MemoryStorageAdapter], overriding
/// [listFilesRecursive] so [VaultStore.listAllHashes] can discover hash
/// directories from the flat in-memory file map.
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        dbDir: '/db',
        adapter: adapter,
        detector: const _AlwaysPlainDetector(),
        uuidGenerator: _seqUuid,
      );

  final MemoryStorageAdapter _mem;

  static int _seq = 0;
  static String _seqUuid() => 'staging-${_seq++}';

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return [
      for (final path in _mem.files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/vee-test';
const _deviceId = 'vee0test000';
const _hlc = 't1';

/// Polls until [sha256] reaches a terminal indexing status or [timeout] elapses.
Future<VaultExtractionState> _awaitTerminal(
  KvStoreImpl kvStore,
  String sha256, {
  Duration timeout = const Duration(seconds: 5),
  EncryptionProvider? encryption,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final ns = '$kVaultExtractPrefix$sha256';
    final bytes = await kvStore.get(ns, kVaultCorpusSentinelKey);
    if (bytes != null) {
      final state = await VaultExtractionState.decode(
        bytes,
        sha256,
        encryption: encryption,
      );
      if (state.status == VaultExtractionStatus.indexed ||
          state.status == VaultExtractionStatus.failed ||
          state.status == VaultExtractionStatus.unsupported) {
        return state;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException(
    'Timed out waiting for $sha256 to reach terminal state',
  );
}

/// Writes a `$vault:docref:{sha256}` entry linking [sha256] to [docId] —
/// simulates the write [VaultRefInterceptor] performs at the collection
/// layer, which [VaultSearchManager] does not perform itself.
Future<void> _seedDocref(
  KvStoreImpl kvStore,
  String sha256,
  String docId,
) async {
  final batch = WriteBatch()
    ..put('$kVaultDocRefPrefix$sha256', docId, Uint8List(0));
  await kvStore.writeBatchInternal(batch);
}

void main() {
  test('toggle-on / mixed-state: pre-existing plaintext blob and newly '
      'encrypted blob coexist and are both correctly searchable; '
      'reindexVault() migrates the plaintext blob to encrypted', () async {
    final adapter = MemoryStorageAdapter();
    final (kvStore, _) = await KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );
    addTearDown(() => kvStore.close());
    final vaultStore = _TestVaultStore(adapter);
    addTearDown(MemoryStorageAdapter.releaseAllLocks);

    // ── Phase 1: index blob 1 with NO encryption configured. ──────────────
    final managerNoEnc = VaultSearchManager(
      config: VaultSearchConfig(
        chunkSize: 50,
        chunkOverlap: 5,
        extractors: [_FixedTextExtractor()],
      ),
      kvStore: kvStore,
      vaultStore: vaultStore,
    );

    const blob1Text = 'alpha document about mountains and rivers';
    final ref1 = await vaultStore.ingest(
      bytes: Uint8List.fromList(utf8.encode(blob1Text)),
      hlcTimestamp: _hlc,
    );
    final sha1 = ref1.sha256;
    await managerNoEnc.queueBlob(sha1, 'text/plain');
    await _awaitTerminal(kvStore, sha1);
    await managerNoEnc.close();

    // Verify blob 1's text.txt is plaintext (EncryptionFlag.none).
    final extractDir1 = '${vaultStore.hashDir(sha1)}/extract';
    final rawText1 = adapter.files['$extractDir1/text.txt']!;
    expect(
      rawText1[0],
      equals(EncryptionFlag.none.byte),
      reason:
          'Blob indexed before encryption was configured must be '
          'plaintext',
    );

    // ── Phase 2: "reopen" with a freshly provisioned EncryptionConfig — a
    // second VaultSearchManager over the SAME KvStoreImpl/VaultStore, with
    // an EncryptionProvider configured. This mirrors what
    // KmdbDatabase.open() does when it re-constructs VaultSearchManager
    // after the encryption bootstrap runs. ────────────────────────────────
    final dek = await KeyDerivation.generateDek();
    final provider = AesGcmEncryptionProvider(dek);
    final managerEnc = VaultSearchManager(
      config: VaultSearchConfig(
        chunkSize: 50,
        chunkOverlap: 5,
        extractors: [_FixedTextExtractor()],
      ),
      kvStore: kvStore,
      vaultStore: vaultStore,
      encryption: provider,
    );
    addTearDown(managerEnc.close);

    const blob2Text = 'beta document about oceans and deserts';
    final ref2 = await vaultStore.ingest(
      bytes: Uint8List.fromList(utf8.encode(blob2Text)),
      hlcTimestamp: _hlc,
    );
    final sha2 = ref2.sha256;
    await managerEnc.queueBlob(sha2, 'text/plain');
    await _awaitTerminal(kvStore, sha2, encryption: provider);

    // Verify blob 2's text.txt is encrypted (EncryptionFlag.aesGcm).
    final extractDir2 = '${vaultStore.hashDir(sha2)}/extract';
    final rawText2 = adapter.files['$extractDir2/text.txt']!;
    expect(
      rawText2[0],
      equals(EncryptionFlag.aesGcm.byte),
      reason:
          'Blob indexed after encryption was configured must be '
          'encrypted',
    );
    expect(
      utf8.decode(rawText2, allowMalformed: true),
      isNot(contains(blob2Text)),
      reason: 'Encrypted artifact must not leak plaintext on disk',
    );

    // ── Phase 3: both blobs must be simultaneously, correctly searchable
    // via the encrypted-mode manager (which can read both the plaintext
    // and the encrypted artifact, since each file is self-describing). ───
    final docId1 = '01900000000070008000000000000001';
    final docId2 = '01900000000070008000000000000002';
    await _seedDocref(kvStore, sha1, docId1);
    await _seedDocref(kvStore, sha2, docId2);

    final docs = {
      docId1: {'id': 'doc1'},
      docId2: {'id': 'doc2'},
    };
    final searcher = VaultSearcher<Map<String, dynamic>>(
      manager: managerEnc,
      namespace: 'test-docs',
      fetchDoc: (id) async => docs[id],
    );

    final result1 = await searcher.search(
      'mountains',
      mode: SearchMode.lexical,
    );
    expect(result1.hits, hasLength(1));
    expect(result1.hits.first.id, equals(docId1));
    expect(result1.hits.first.chunkContext.snippet, equals(blob1Text));

    final result2 = await searcher.search('oceans', mode: SearchMode.lexical);
    expect(result2.hits, hasLength(1));
    expect(result2.hits.first.id, equals(docId2));
    expect(result2.hits.first.chunkContext.snippet, equals(blob2Text));

    // ── Phase 4: reindexVault() migrates blob 1's artifacts from
    // plaintext to encrypted, without disturbing blob 2. ──────────────────
    final resetCount = await managerEnc.reindexVault();
    expect(resetCount, equals(2)); // both indexed blobs are reset.

    // Both blobs are re-processed through managerEnc during reindexVault(),
    // so their extraction state is now encrypted regardless of which
    // manager originally wrote it.
    await _awaitTerminal(kvStore, sha1, encryption: provider);
    await _awaitTerminal(kvStore, sha2, encryption: provider);

    final rawText1AfterReindex = adapter.files['$extractDir1/text.txt']!;
    expect(
      rawText1AfterReindex[0],
      equals(EncryptionFlag.aesGcm.byte),
      reason:
          'reindexVault() must migrate the plaintext blob to '
          'encrypted once a provider is configured',
    );

    // Both blobs remain correct and searchable after the migration.
    final result1AfterReindex = await searcher.search(
      'mountains',
      mode: SearchMode.lexical,
    );
    expect(result1AfterReindex.hits, hasLength(1));
    expect(
      result1AfterReindex.hits.first.chunkContext.snippet,
      equals(blob1Text),
    );

    final result2AfterReindex = await searcher.search(
      'oceans',
      mode: SearchMode.lexical,
    );
    expect(result2AfterReindex.hits, hasLength(1));
    expect(
      result2AfterReindex.hits.first.chunkContext.snippet,
      equals(blob2Text),
    );
  });
}
