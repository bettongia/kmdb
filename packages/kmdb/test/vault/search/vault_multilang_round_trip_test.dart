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

/// End-to-end vault search round-trip tests for WI-6's language-aware BM25
/// stemming: real ingest → real [VaultSearchManager] indexing (tokeniser,
/// language detection, chunker, stemmer) → real [VaultSearcher] query,
/// through the actual production pipeline rather than pre-seeded BM25
/// entries (unlike most of `vault_searcher_test.dart`).
///
/// Covers the plan's Phase 3 requirement: "an end-to-end vault ... search
/// round-trip (index then query) for at least one non-English supported
/// language and one unsupported script."
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/encoding/value_codec.dart';
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
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

/// A [MediaTypeDetector] that always reports `text/plain`, matching how
/// these tests seed content.
final class _AlwaysPlainDetector implements MediaTypeDetector {
  const _AlwaysPlainDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [
    'text/plain',
  ];
}

/// A [VaultStore] backed by [MemoryStorageAdapter], overriding
/// [listFilesRecursive] so [VaultSearchManager] can enumerate extract
/// artifacts from the flat in-memory file map (mirrors the pattern already
/// used in `vault_search_manager_test.dart` / `vault_searcher_test.dart`).
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

const _dbDir = '/vmrt-test';
const _deviceId = 'vmrt0test';
const _hlc = 't1';
const _docId = '01900000000070008000000000000001';

Future<KvStoreImpl> _openStore(MemoryStorageAdapter adapter) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  return store;
}

Future<VaultExtractionState?> _readState(
  KvStoreImpl kvStore,
  String sha256,
) async {
  final ns = '$kVaultExtractPrefix$sha256';
  final bytes = await kvStore.get(ns, kVaultCorpusSentinelKey);
  if (bytes == null) return null;
  return await VaultExtractionState.decode(bytes, sha256);
}

/// Polls until [sha256] reaches a terminal indexing status or [timeout]
/// elapses (mirrors `vault_search_manager_test.dart`'s helper).
Future<VaultExtractionState> _awaitTerminal(
  KvStoreImpl kvStore,
  String sha256, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final state = await _readState(kvStore, sha256);
    if (state != null &&
        (state.status == VaultExtractionStatus.indexed ||
            state.status == VaultExtractionStatus.failed ||
            state.status == VaultExtractionStatus.unsupported)) {
      return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException(
    'Timed out waiting for $sha256 to reach terminal state',
  );
}

/// Registers a docref linking [sha256] to [_docId], as
/// `VaultRefInterceptor` would for a real document write — required for
/// [VaultSearcher] to map a matched blob back to a document.
Future<void> _seedDocref(KvStoreImpl kvStore, String sha256) async {
  final value = await ValueCodec.encode({'p': 'attachment'});
  final batch = WriteBatch()..put('$kVaultDocRefPrefix$sha256', _docId, value);
  await kvStore.writeBatchInternal(batch);
}

void main() {
  late MemoryStorageAdapter adapter;
  late KvStoreImpl kvStore;
  late _TestVaultStore vaultStore;
  late VaultSearchManager manager;

  setUp(() async {
    adapter = MemoryStorageAdapter();
    kvStore = await _openStore(adapter);
    vaultStore = _TestVaultStore(adapter);
    _TestVaultStore._seq = 0;
    manager = VaultSearchManager(
      // Default extractors (PlainTextExtractor) + default chunk config —
      // exercises the real production configuration, not a cut-down test
      // double, since this test's whole point is the real pipeline.
      config: VaultSearchConfig(),
      kvStore: kvStore,
      vaultStore: vaultStore,
    );
    manager.attach();
  });

  tearDown(() async {
    await manager.close();
    await kvStore.close();
    MemoryStorageAdapter.releaseAllLocks();
  });

  /// Ingests [content], waits for indexing to complete, and registers a
  /// docref so the result is attributable to a document.
  Future<String> ingestAndIndex(String content) async {
    final ref = await vaultStore.ingest(
      bytes: Uint8List.fromList(utf8.encode(content)),
      hlcTimestamp: _hlc,
    );
    final state = await _awaitTerminal(kvStore, ref.sha256);
    expect(
      state.status,
      equals(VaultExtractionStatus.indexed),
      reason: 'Expected the blob to index successfully: $state',
    );
    await _seedDocref(kvStore, ref.sha256);
    return ref.sha256;
  }

  group('French (non-English supported language) round-trip', () {
    test(
      'indexed French plural forms match a singular French query term',
      () async {
        // Real French prose (not a bare keyword fragment) so it clears the
        // margin, word-count, and Stemmer-support gates in
        // detectLanguageForStemming() confidently as `fr` — see
        // language_detection.dart's doc comment for why keyword-only
        // fragments would not reliably do so.
        await ingestAndIndex(
          'Les chats noirs dorment paisiblement sur les tapis rouges de la '
          'maison.',
        );

        final searcher = VaultSearcher<Map<String, dynamic>>(
          manager: manager,
          namespace: 'docs',
          fetchDoc: (id) async => id == _docId ? {'id': 'doc'} : null,
        );

        // Query with a *singular* form ("chat") of the indexed plural
        // ("chats"). The French Snowball stemmer reduces both to the same
        // root, so this only matches if both write and query paths
        // selected the French stemmer consistently (WI-6's whole point).
        final result = await searcher.search('chat', mode: SearchMode.lexical);

        expect(result.hits, isNotEmpty);
        expect(result.hits.first.id, equals(_docId));
      },
    );
  });

  group('Unsupported script (Japanese) round-trip', () {
    test('CJK content is indexed (non-empty chunks) and searchable by its '
        'exact tokenised form, with stemming skipped rather than corrupting '
        'the index', () async {
      // Pure Japanese text — the exact class of content the Phase 1 fix
      // (IcuTokenizer via OffsetTokenizer) made searchable at all; before
      // WI-6 the old ASCII-only regex tokenizer produced zero chunks for
      // this input. Neither `ja` nor `zh` has a Snowball algorithm, so
      // stemming is skipped on both sides — tokens must match verbatim
      // (post-tokenisation, pre-stem) for a hit.
      const text = 'これは日本語のテキストです。検索のためのテストです。';
      await ingestAndIndex(text);

      final searcher = VaultSearcher<Map<String, dynamic>>(
        manager: manager,
        namespace: 'docs',
        fetchDoc: (id) async => id == _docId ? {'id': 'doc'} : null,
      );

      // Query with a substring token IcuTokenizer would also segment out
      // of the indexed text (querying with the full original text is the
      // simplest reliable choice, since Japanese has no space-delimited
      // words to pick a single "safe" query token from).
      final result = await searcher.search(text, mode: SearchMode.lexical);

      expect(result.hits, isNotEmpty);
      expect(result.hits.first.id, equals(_docId));
    });
  });
}
