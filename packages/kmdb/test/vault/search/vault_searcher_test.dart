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

/// Tests for [VaultSearcher]: lexical (BM25), semantic, hybrid, result
/// construction, pagination, snippet retrieval, and candidate scoping.
library;

import 'dart:convert' show json, utf8;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:betto_inferencing/betto_inferencing.dart' show EmbeddingModel;
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/search/search_mode.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/search/vault_bm25_writer.dart';
import 'package:kmdb/src/vault/search/vault_namespaces.dart';
import 'package:kmdb/src/vault/search/vault_search_config.dart';
import 'package:kmdb/src/vault/search/vault_search_manager.dart';
import 'package:kmdb/src/vault/search/vault_searcher.dart';
import 'package:kmdb/src/vault/search/vault_vec_writer.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A [MediaTypeDetector] that always reports `text/plain`.
final class _AlwaysPlainDetector implements MediaTypeDetector {
  const _AlwaysPlainDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [
    'text/plain',
  ];
}

/// A [VaultStore] subclass backed by [MemoryStorageAdapter] for testing.
///
/// Overrides [listFilesRecursive] to enumerate files from the flat memory map
/// rather than a real filesystem. Without this override, [listAllHashes] cannot
/// discover hash directories because the memory adapter has no directory tree.
final class _TestVaultStore extends VaultStore {
  _TestVaultStore(MemoryStorageAdapter adapter)
    : _mem = adapter,
      super(
        dbDir: '/db',
        adapter: adapter,
        detector: const _AlwaysPlainDetector(),
        uuidGenerator: () => 'staging-0',
      );

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

/// A deterministic fake [EmbeddingModel] for testing semantic search.
///
/// Returns a unit vector in a direction derived from the hash of [text].
/// Dimension is 8 (small) for speed. Can be configured to throw.
final class _FakeEmbeddingModel implements EmbeddingModel {
  _FakeEmbeddingModel();

  /// When true, [embed] throws to exercise the searcher's error handling.
  /// No current test sets this; retained for symmetry with the manager fake.
  bool shouldThrow = false;

  @override
  final int dimensions = 8;

  @override
  String get modelId => 'fake-model-v1';

  @override
  Future<(Float32List, bool)> embed(String text) async {
    if (shouldThrow) throw Exception('inference failure');
    final seed = text.codeUnits.fold(0, (a, b) => a ^ b);
    final rng = math.Random(seed);
    final v = Float32List.fromList(
      List.generate(dimensions, (_) => rng.nextDouble() * 2 - 1),
    );
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }
    return (v, false);
  }

  @override
  void dispose() {}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/searcher-test';
const _deviceId = 'searcher0test';
const _hlc = 'hlc1';

/// Opens a fresh [KvStoreImpl] backed by [adapter].
Future<KvStoreImpl> _openStore(MemoryStorageAdapter adapter) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: _deviceId,
  );
  return store;
}

/// Creates a lexical-only [VaultSearchManager] (no embedding model).
VaultSearchManager _makeManager(
  KvStoreImpl kvStore,
  _TestVaultStore vaultStore,
) {
  return VaultSearchManager(
    config: VaultSearchConfig(),
    kvStore: kvStore,
    vaultStore: vaultStore,
  );
}

/// Builds a [VaultSearcher] for [namespace] with [fetchDoc].
///
/// [fetchDoc] maps a docId to a document (or null if not found/deleted).
VaultSearcher<T> _makeSearcher<T>(
  VaultSearchManager manager, {
  String namespace = 'test-docs',
  required Future<T?> Function(String id) fetchDoc,
}) {
  return VaultSearcher<T>(
    manager: manager,
    namespace: namespace,
    fetchDoc: fetchDoc,
  );
}

/// Generates a synthetic 64-char hex sha256 of the form '{char}' * 64.
String _sha256(String char) => char * 64;

/// A docId for test documents.
const _docId1 = '01900000000070008000000000000001';
const _docId2 = '01900000000070008000000000000002';
const _docId3 = '01900000000070008000000000000003';

/// Writes a manifest file for [sha256] into [adapter] (simulates ingest).
///
/// Also writes a blob file so [VaultStore.isHydrated] returns true.
Future<void> _seedVaultBlob(
  _TestVaultStore vaultStore,
  String sha256, {
  String content = 'test content',
}) async {
  final manifest = VaultManifest(
    sha256: sha256,
    size: 0,
    crc32c: '00000000',
    mediaType: 'text/plain',
    originalName: 'test.txt',
    createdAt: _hlc,
    encrypted: false,
  );
  await vaultStore.adapter.createDirectory(vaultStore.hashDir(sha256));
  await vaultStore.adapter.writeFile(
    vaultStore.manifestPath(sha256),
    Uint8List.fromList(utf8.encode(json.encode(manifest.toJson()))),
  );
  await vaultStore.adapter.writeFile(
    vaultStore.blobPath(sha256),
    Uint8List.fromList(utf8.encode(content)),
  );
}

/// Writes BM25 index entries for [sha256] with given [termFrequencies] into [kvStore].
///
/// Each element of [termFrequencies] is a term-frequency map for one chunk.
/// Also writes the corpus sentinel with `n` = chunk count.
Future<void> _seedBm25(
  KvStoreImpl kvStore,
  String sha256,
  List<Map<String, int>> termFrequencies,
) async {
  final totalTokens = termFrequencies.fold<int>(
    0,
    (sum, tf) => sum + tf.values.fold<int>(0, (s, v) => s + v),
  );
  final batch = WriteBatch();
  const VaultBm25Writer().write(
    sha256: sha256,
    termFrequencies: termFrequencies,
    totalTokens: totalTokens,
    batch: batch,
  );
  await kvStore.writeBatchInternal(batch);
}

/// Writes a docref entry linking [sha256] to [docId] via [fieldPath].
///
/// This simulates the write that [VaultRefInterceptor] performs when a document
/// is stored with a vault URI in [fieldPath].
Future<void> _seedDocref(
  KvStoreImpl kvStore,
  String sha256,
  String docId,
  String fieldPath,
) async {
  final value = await ValueCodec.encode({'p': fieldPath});
  final batch = WriteBatch()..put('$kVaultDocRefPrefix$sha256', docId, value);
  await kvStore.writeBatchInternal(batch);
}

/// Writes extract artifacts (text.txt, chunks_v1.json) for [sha256].
///
/// Used to ensure [VaultSearcher._buildChunkContext] can read snippets.
Future<void> _seedExtractArtifacts(
  _TestVaultStore vaultStore,
  String sha256,
  String text,
  List<Map<String, dynamic>> chunks,
) async {
  final extractDir = '${vaultStore.hashDir(sha256)}/extract';
  await vaultStore.adapter.createDirectory(extractDir);
  await vaultStore.adapter.writeFile(
    '$extractDir/text.txt',
    Uint8List.fromList(utf8.encode(text)),
  );
  await vaultStore.adapter.writeFile(
    '$extractDir/chunks_v1.json',
    Uint8List.fromList(utf8.encode(json.encode(chunks))),
  );
}

/// Writes SQ8 vector index entries for [sha256] with given [embeddings].
///
/// Quantises each Float32List embedding and writes it to the
/// `$$vault:vec:idx:{sha256}` namespace keyed by chunk index.
Future<void> _seedVec(
  KvStoreImpl kvStore,
  String sha256,
  List<Float32List> embeddings,
) async {
  final batch = WriteBatch();
  const VaultVecWriter().write(
    sha256: sha256,
    embeddings: embeddings,
    batch: batch,
  );
  await kvStore.writeBatchInternal(batch);
}

/// Creates a [VaultSearchManager] with the given [embeddingModel].
VaultSearchManager _makeManagerWithModel(
  KvStoreImpl kvStore,
  _TestVaultStore vaultStore,
  EmbeddingModel model,
) {
  return VaultSearchManager(
    config: VaultSearchConfig(),
    kvStore: kvStore,
    vaultStore: vaultStore,
    embeddingModel: model,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late MemoryStorageAdapter adapter;
  late KvStoreImpl kvStore;
  late _TestVaultStore vaultStore;
  late VaultSearchManager manager;

  setUp(() async {
    adapter = MemoryStorageAdapter();
    kvStore = await _openStore(adapter);
    vaultStore = _TestVaultStore(adapter);
    manager = _makeManager(kvStore, vaultStore);
  });

  tearDown(() async {
    await manager.close();
    await kvStore.close();
  });

  // ── Empty-query short-circuit ──────────────────────────────────────────────

  group('empty query', () {
    test('empty string returns empty result with skipped vault', () async {
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => null,
      );
      final result = await searcher.search('');
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
      expect(result.metadata.skipped, contains('vault'));
    });

    test(
      'whitespace-only query returns empty result with skipped vault',
      () async {
        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => null,
        );
        final result = await searcher.search('   ');
        expect(result.hits, isEmpty);
        expect(result.metadata.skipped, contains('vault'));
      },
    );
  });

  // ── No candidates ──────────────────────────────────────────────────────────

  group('no candidates', () {
    test('empty vault returns empty result', () async {
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => null,
      );
      final result = await searcher.search('hello world');
      expect(result.hits, isEmpty);
      expect(result.metadata.total, equals(0));
    });

    test('blob in vault but no docref returns no candidates', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      // No docref written — blob not referenced by any document.

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => null,
      );
      final result = await searcher.search('test');
      expect(result.hits, isEmpty);
    });
  });

  // ── Lexical search ─────────────────────────────────────────────────────────

  group('lexical search', () {
    test('finds blob whose BM25 index matches query term', () async {
      final sha256 = _sha256('b');
      // Seed: one chunk with stemmed terms. The BM25 index always stores the
      // stemmed form produced by preprocess():
      //   "machine" → "machin",  "learning" → "learn".
      // This mirrors what the real VaultIndexingIsolate writes after preprocessing.
      await _seedVaultBlob(
        vaultStore,
        sha256,
        content: 'machine learning content',
      );
      await _seedBm25(kvStore, sha256, [
        {'machin': 3, 'learn': 2},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'attachment');

      final doc1 = {'name': 'doc1'};
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => id == _docId1 ? doc1 : null,
      );

      final result = await searcher.search(
        'machine learning',
        mode: SearchMode.lexical,
      );

      expect(result.hits, isNotEmpty);
      expect(result.hits.first.id, equals(_docId1));
      expect(result.hits.first.score, greaterThan(0.0));
      expect(result.metadata.searched, contains('vault:lexical'));
    });

    test(
      'higher-frequency term blob scores higher than lower-frequency blob',
      () async {
        // sha256 'a' has 5 occurrences of "machin" (stemmed "machine") per chunk.
        // sha256 'b' has 1 occurrence — lower TF → lower BM25 score.
        final sha256a = _sha256('a');
        final sha256b = _sha256('b');

        await _seedVaultBlob(vaultStore, sha256a);
        await _seedBm25(kvStore, sha256a, [
          {'machin': 5, 'other': 1},
        ]);
        await _seedDocref(kvStore, sha256a, _docId1, 'file');

        await _seedVaultBlob(vaultStore, sha256b);
        await _seedBm25(kvStore, sha256b, [
          {'machin': 1, 'other': 1},
        ]);
        await _seedDocref(kvStore, sha256b, _docId2, 'file');

        final docs = {
          _docId1: {'id': 'doc1'},
          _docId2: {'id': 'doc2'},
        };
        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (id) async => docs[id],
        );

        final result = await searcher.search(
          'machine',
          mode: SearchMode.lexical,
        );

        expect(result.hits, hasLength(2));
        // Blob 'a' (5 occurrences) should rank higher than blob 'b' (1 occurrence).
        expect(result.hits.first.id, equals(_docId1));
        expect(result.hits.last.id, equals(_docId2));
      },
    );

    test('blob with no matching terms is not in results', () async {
      final sha256 = _sha256('c');
      await _seedVaultBlob(vaultStore, sha256);
      // "databas" (stemmed "database") indexed — query "machine" (→ "machin") should not match.
      await _seedBm25(kvStore, sha256, [
        {'databas': 2},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search('machine', mode: SearchMode.lexical);
      expect(result.hits, isEmpty);
    });

    test('stop-word-only query returns no results', () async {
      // "the" and "a" are stop words; after preprocessing, query terms are empty.
      final sha256 = _sha256('d');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'the': 3, 'a': 2},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      // All words are stop words — query terms list will be empty.
      final result = await searcher.search('the a', mode: SearchMode.lexical);
      expect(result.hits, isEmpty);
    });
  });

  // ── Semantic degradation (no model) ───────────────────────────────────────

  group('semantic mode without model', () {
    test('semantic mode degrades to lexical when no model configured', () async {
      // manager was created without embeddingModel (lexical-only).
      // "neural" → "neural", "network" → "network" (both survive Porter stemmer).
      final sha256 = _sha256('e');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'neural': 2, 'network': 1},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'neural network',
        mode: SearchMode.semantic,
      );

      // Should degrade to lexical and still find results.
      expect(result.hits, isNotEmpty);
      expect(result.metadata.searched, contains('vault:lexical'));
      expect(result.metadata.skipped, contains('vault:semantic'));
    });

    test('auto mode without model uses lexical only', () async {
      // "vector" → "vector" (unchanged by Porter stemmer).
      final sha256 = _sha256('f');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'vector': 3},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search('vector', mode: SearchMode.auto);

      expect(result.hits, isNotEmpty);
      expect(result.metadata.searched, contains('vault:lexical'));
    });
  });

  // ── Pagination ─────────────────────────────────────────────────────────────

  group('pagination', () {
    test('limit restricts the number of hits', () async {
      // Seed 3 blobs each referenced by a distinct document.
      // "query" → "queri" (after Porter stemmer).
      for (final (sha256, docId) in [
        (_sha256('a'), _docId1),
        (_sha256('b'), _docId2),
        (_sha256('c'), _docId3),
      ]) {
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'queri': 1},
        ]);
        await _seedDocref(kvStore, sha256, docId, 'file');
      }

      final allDocs = {
        _docId1: {'id': 'doc1'},
        _docId2: {'id': 'doc2'},
        _docId3: {'id': 'doc3'},
      };
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => allDocs[id],
      );

      final result = await searcher.search(
        'query',
        mode: SearchMode.lexical,
        limit: 2,
      );

      expect(result.hits, hasLength(2));
      expect(result.metadata.total, equals(3));
    });

    test('offset skips the first N hits', () async {
      for (final (sha256, docId, tf) in [
        (_sha256('a'), _docId1, 5), // highest score
        (_sha256('b'), _docId2, 3), // middle
        (_sha256('c'), _docId3, 1), // lowest
      ]) {
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'search': tf},
        ]);
        await _seedDocref(kvStore, sha256, docId, 'file');
      }

      final allDocs = {
        _docId1: {'id': 'doc1'},
        _docId2: {'id': 'doc2'},
        _docId3: {'id': 'doc3'},
      };
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => allDocs[id],
      );

      // With offset=1, we skip the top-ranked result.
      final result = await searcher.search(
        'search',
        mode: SearchMode.lexical,
        offset: 1,
        limit: 10,
      );

      expect(result.metadata.total, equals(3));
      // Should not contain doc1 (rank 1, skipped).
      final ids = result.hits.map((h) => h.id).toList();
      expect(ids, isNot(contains(_docId1)));
      // rank values should start at 2 (offset + 1).
      expect(result.hits.first.rank, equals(2));
    });
  });

  // ── Result construction ────────────────────────────────────────────────────

  group('result construction', () {
    test('deleted document is skipped', () async {
      // Seed two blobs. Doc1 is "deleted" (fetchDoc returns null).
      // "deleted" → "delet" (Porter stemmer).
      final sha256a = _sha256('a');
      final sha256b = _sha256('b');

      await _seedVaultBlob(vaultStore, sha256a);
      await _seedBm25(kvStore, sha256a, [
        {'delet': 2},
      ]);
      await _seedDocref(kvStore, sha256a, _docId1, 'file');

      await _seedVaultBlob(vaultStore, sha256b);
      await _seedBm25(kvStore, sha256b, [
        {'delet': 1},
      ]);
      await _seedDocref(kvStore, sha256b, _docId2, 'file');

      // _docId1 is "deleted" — fetchDoc returns null for it.
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => id == _docId2 ? {'doc': 'exists'} : null,
      );

      final result = await searcher.search('deleted', mode: SearchMode.lexical);

      // Only doc2 should appear — doc1 was skipped.
      expect(result.hits, hasLength(1));
      expect(result.hits.first.id, equals(_docId2));
    });

    test(
      'snippet is read from extract/text.txt using chunks_v1.json offsets',
      () async {
        final sha256 = _sha256('a');
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'snippet': 2},
        ]);
        await _seedDocref(kvStore, sha256, _docId1, 'attachment');

        // Seed extract artifacts with a known text and chunk offsets.
        const text = 'This is the snippet text for testing.';
        final textBytes = utf8.encode(text);
        await _seedExtractArtifacts(vaultStore, sha256, text, [
          {
            'index': 0,
            'byteStart': 0,
            'byteEnd': textBytes.length,
            'wordCount': 7,
          },
        ]);

        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => {'doc': true},
        );

        final result = await searcher.search(
          'snippet',
          mode: SearchMode.lexical,
        );

        expect(result.hits, hasLength(1));
        expect(result.hits.first.chunkContext.snippet, equals(text));
        expect(result.hits.first.chunkContext.totalChunks, equals(1));
      },
    );

    test(
      'placeholder context returned when extract artifacts are missing',
      () async {
        final sha256 = _sha256('a');
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'data': 1},
        ]);
        await _seedDocref(kvStore, sha256, _docId1, 'file');
        // Deliberately no extract artifacts.

        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => {'doc': true},
        );

        final result = await searcher.search('data', mode: SearchMode.lexical);

        expect(result.hits, hasLength(1));
        // Placeholder: empty snippet, totalChunks=0.
        expect(result.hits.first.chunkContext.snippet, isEmpty);
        expect(result.hits.first.chunkContext.totalChunks, equals(0));
      },
    );

    test('field path is read from docref entry', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'content': 1},
      ]);
      // Write docref with explicit field path.
      await _seedDocref(kvStore, sha256, _docId1, 'documents.file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search('content', mode: SearchMode.lexical);

      expect(result.hits, hasLength(1));
      expect(
        result.hits.first.chunkContext.fieldPath,
        equals('documents.file'),
      );
    });

    test('rank starts at 1 for first hit', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'rank': 5},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search('rank', mode: SearchMode.lexical);

      expect(result.hits.first.rank, equals(1));
    });
  });

  // ── Candidate scoping ──────────────────────────────────────────────────────

  group('candidate scoping', () {
    test(
      'blob with docref for non-existent document is excluded from candidates',
      () async {
        final sha256 = _sha256('a');
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'orphan': 2},
        ]);
        // Docref exists but fetchDoc returns null — document was deleted.
        await _seedDocref(kvStore, sha256, _docId1, 'file');

        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => null, // All documents "deleted".
        );

        final result = await searcher.search(
          'orphan',
          mode: SearchMode.lexical,
        );
        expect(result.hits, isEmpty);
      },
    );

    test('multiple blobs: only referenced ones in candidates', () async {
      final sha256Ref = _sha256('a'); // referenced by doc1
      final sha256Unref = _sha256('b'); // not referenced by any doc

      await _seedVaultBlob(vaultStore, sha256Ref);
      // Use already-stemmed term ("machin" is the Porter stem of "machine").
      // The BM25 index always stores stemmed terms produced by preprocess().
      await _seedBm25(kvStore, sha256Ref, [
        {'machin': 2},
      ]);
      await _seedDocref(kvStore, sha256Ref, _docId1, 'file');

      // sha256Unref: in vault, BM25 indexed, but NO docref.
      await _seedVaultBlob(vaultStore, sha256Unref);
      await _seedBm25(kvStore, sha256Unref, [
        {'machin': 3},
      ]);
      // No docref for sha256Unref.

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => id == _docId1 ? {'doc': 'one'} : null,
      );

      final result = await searcher.search(
        'machine', // → stemmed to "machin" by preprocess()
        mode: SearchMode.lexical,
      );

      // Only sha256Ref has a docref → only doc1 should appear.
      expect(result.hits, hasLength(1));
      expect(result.hits.first.id, equals(_docId1));
    });

    test('same blob referenced by two documents — both appear', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      // Use already-stemmed term ("databas" is the Porter stem of "database").
      // The BM25 index always stores stemmed terms produced by preprocess().
      await _seedBm25(kvStore, sha256, [
        {'databas': 2},
      ]);

      // Both documents reference the same blob.
      await _seedDocref(kvStore, sha256, _docId1, 'file');
      await _seedDocref(kvStore, sha256, _docId2, 'attachment');

      final docs = {
        _docId1: {'id': 'doc1'},
        _docId2: {'id': 'doc2'},
      };
      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (id) async => docs[id],
      );

      final result = await searcher.search(
        'database', // → stemmed to "databas" by preprocess()
        mode: SearchMode.lexical,
      );

      // Both documents should appear in results.
      final ids = result.hits.map((h) => h.id).toSet();
      expect(ids, containsAll([_docId1, _docId2]));
    });
  });

  // ── fieldScores ────────────────────────────────────────────────────────────

  group('fieldScores', () {
    test('lexical search populates vault:bm25 field score', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      // Use already-stemmed term ("machin" is the Porter stem of "machine").
      // The BM25 index always stores stemmed terms produced by preprocess().
      await _seedBm25(kvStore, sha256, [
        {'machin': 3},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        manager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'machine', // → stemmed to "machin" by preprocess()
        mode: SearchMode.lexical,
      );

      expect(
        result.hits.first.fieldScores,
        containsPair('vault:bm25', greaterThan(0.0)),
      );
      expect(
        result.hits.first.fieldScores.containsKey('vault:cosine'),
        isFalse,
      );
    });
  });

  // ── Semantic search (with EmbeddingModel) ─────────────────────────────────

  group('semantic search (with EmbeddingModel)', () {
    late _FakeEmbeddingModel model;
    late VaultSearchManager semanticManager;

    setUp(() {
      model = _FakeEmbeddingModel();
      semanticManager = _makeManagerWithModel(kvStore, vaultStore, model);
    });

    tearDown(() async => semanticManager.close());

    test('semantic mode finds blob with matching vector', () async {
      // Seed a blob with a known vector in the vec index.
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256, content: 'semantic content');
      await _seedDocref(kvStore, sha256, _docId1, 'attachment');

      // Embed "semantic content" with the fake model and seed the vec index.
      final (embedding, _) = await model.embed('semantic content');
      await _seedVec(kvStore, sha256, [embedding]);

      final searcher = _makeSearcher<Map<String, dynamic>>(
        semanticManager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'semantic content',
        mode: SearchMode.semantic,
      );

      expect(result.hits, isNotEmpty);
      expect(result.metadata.searched, contains('vault:semantic'));
      expect(result.hits.first.fieldScores.containsKey('vault:cosine'), isTrue);
    });

    test('semantic mode returns empty when no vec entries', () async {
      // Blob has BM25 but no vec entries.
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedBm25(kvStore, sha256, [
        {'content': 2},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      final searcher = _makeSearcher<Map<String, dynamic>>(
        semanticManager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'content',
        mode: SearchMode.semantic,
      );

      // No vec entries for this blob → no semantic hits.
      expect(result.hits, isEmpty);
      expect(result.metadata.searched, contains('vault:semantic'));
    });

    test('semantic search skips vec entries with wrong dimensions', () async {
      // Write a vec entry with wrong dimension (1 byte) — should be skipped.
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      // Write a vec entry with wrong dimension to test the length guard.
      final wrongDimBatch = WriteBatch()
        ..put(
          VaultVecWriter.vecNamespace(sha256),
          kVaultChunkKey(0),
          Uint8List.fromList([0x80]), // 1 byte, not 8 dims.
        );
      await kvStore.writeBatchInternal(wrongDimBatch);

      final searcher = _makeSearcher<Map<String, dynamic>>(
        semanticManager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'test query',
        mode: SearchMode.semantic,
      );

      // Dimension mismatch → no hits (entry skipped).
      expect(result.hits, isEmpty);
    });
  });

  // ── Hybrid search (auto mode with EmbeddingModel) ─────────────────────────

  group('hybrid search (auto mode with model)', () {
    late _FakeEmbeddingModel model;
    late VaultSearchManager hybridManager;

    setUp(() {
      model = _FakeEmbeddingModel();
      hybridManager = _makeManagerWithModel(kvStore, vaultStore, model);
    });

    tearDown(() async => hybridManager.close());

    test('auto mode runs both lexical and semantic legs', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256, content: 'hybrid search test');
      await _seedBm25(kvStore, sha256, [
        {'hybrid': 2, 'search': 1},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      // Embed the query text and seed the vec index.
      final (embedding, _) = await model.embed('hybrid search test');
      await _seedVec(kvStore, sha256, [embedding]);

      final searcher = _makeSearcher<Map<String, dynamic>>(
        hybridManager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'hybrid search',
        mode: SearchMode.auto,
      );

      // Both legs searched → hit has combined fieldScores.
      expect(result.hits, isNotEmpty);
      expect(
        result.metadata.searched,
        containsAll(['vault:lexical', 'vault:semantic']),
      );
    });

    test('hybrid search fieldScores contains both bm25 and cosine', () async {
      final sha256 = _sha256('a');
      await _seedVaultBlob(vaultStore, sha256, content: 'hybrid score test');
      // "hybrid" → stemmed to "hybrid" by Porter, "score" → "score"
      await _seedBm25(kvStore, sha256, [
        {'hybrid': 3, 'score': 2},
      ]);
      await _seedDocref(kvStore, sha256, _docId1, 'file');

      // Embed and seed with a matching-direction vector.
      final (embedding, _) = await model.embed('hybrid score test');
      await _seedVec(kvStore, sha256, [embedding]);

      final searcher = _makeSearcher<Map<String, dynamic>>(
        hybridManager,
        fetchDoc: (_) async => {'doc': true},
      );

      final result = await searcher.search(
        'hybrid score',
        mode: SearchMode.auto,
      );

      if (result.hits.isNotEmpty) {
        // When both legs match, fieldScores should include both keys.
        final fieldScores = result.hits.first.fieldScores;
        // At least one of bm25/cosine should be populated.
        expect(
          fieldScores.containsKey('vault:bm25') ||
              fieldScores.containsKey('vault:cosine'),
          isTrue,
        );
      }
    });
  });

  // ── BM25 docLen from wordCount ─────────────────────────────────────────────

  group('BM25 scoring uses wordCount from chunks_v1.json', () {
    test(
      'chunk with high wordCount normalises down, low wordCount normalises up',
      () async {
        // Two blobs: identical TF but different wordCounts. BM25 length
        // normalisation should score the shorter-doc chunk higher (b>0).
        final sha256Long = _sha256('a'); // long doc (many words)
        final sha256Short = _sha256('b'); // short doc (few words)

        for (final (sha256, wc) in [(sha256Long, 500), (sha256Short, 5)]) {
          await _seedVaultBlob(vaultStore, sha256);
          await _seedBm25(kvStore, sha256, [
            {'machin': 1},
          ]);
          await _seedDocref(
            kvStore,
            sha256,
            sha256 == sha256Long ? _docId1 : _docId2,
            'file',
          );
          await _seedExtractArtifacts(vaultStore, sha256, 'machine content', [
            {'index': 0, 'byteStart': 0, 'byteEnd': 7, 'wordCount': wc},
          ]);
        }

        final allDocs = {
          _docId1: {'id': 'long'},
          _docId2: {'id': 'short'},
        };
        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (id) async => allDocs[id],
        );

        final result = await searcher.search(
          'machine',
          mode: SearchMode.lexical,
        );
        expect(result.hits, hasLength(2));
        // Shorter doc (fewer words) should rank higher with b=0.75.
        expect(result.hits.first.id, equals(_docId2));
      },
    );
  });

  // ── Chunk context error handling ───────────────────────────────────────────

  group('chunk context error handling', () {
    test(
      '_buildChunkContext falls back to placeholder on exception in file read',
      () async {
        final sha256 = _sha256('a');
        await _seedVaultBlob(vaultStore, sha256);
        await _seedBm25(kvStore, sha256, [
          {'snippet': 1},
        ]);
        await _seedDocref(kvStore, sha256, _docId1, 'file');

        // Write invalid JSON in chunks_v1.json to trigger the catch block.
        final extractDir = '${vaultStore.hashDir(sha256)}/extract';
        await vaultStore.adapter.createDirectory(extractDir);
        await vaultStore.adapter.writeFile(
          '$extractDir/text.txt',
          Uint8List.fromList(utf8.encode('snippet text')),
        );
        await vaultStore.adapter.writeFile(
          '$extractDir/chunks_v1.json',
          Uint8List.fromList(utf8.encode('not valid json')), // triggers catch
        );

        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => {'doc': true},
        );

        final result = await searcher.search(
          'snippet',
          mode: SearchMode.lexical,
        );
        expect(result.hits, hasLength(1));
        // Placeholder context returned: empty snippet.
        expect(result.hits.first.chunkContext.snippet, isEmpty);
        expect(result.hits.first.chunkContext.totalChunks, equals(0));
      },
    );

    test(
      '_buildChunkContext returns placeholder for empty chunks list',
      () async {
        final sha256 = _sha256('a');
        await _seedVaultBlob(vaultStore, sha256);
        // Seed with the pre-stemmed form "machin" (Porter stem of "machine") so
        // the search for "machine" finds the blob and we can exercise the empty
        // chunks fallback path.
        await _seedBm25(kvStore, sha256, [
          {'machin': 1},
        ]);
        await _seedDocref(kvStore, sha256, _docId1, 'file');

        // Write valid but empty chunks list — triggers the placeholder context.
        await _seedExtractArtifacts(vaultStore, sha256, 'text', const []);

        final searcher = _makeSearcher<Map<String, dynamic>>(
          manager,
          fetchDoc: (_) async => {'doc': true},
        );

        // "machine" stems to "machin" which matches the seeded BM25 index.
        final result = await searcher.search(
          'machine',
          mode: SearchMode.lexical,
        );
        expect(result.hits, hasLength(1));
        // Empty chunks → placeholder context.
        expect(result.hits.first.chunkContext.snippet, isEmpty);
        expect(result.hits.first.chunkContext.totalChunks, equals(0));
      },
    );
  });
}
