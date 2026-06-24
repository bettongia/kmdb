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

/// Query engine for vault content search.
///
/// Implements lexical (BM25), semantic (cosine similarity), and hybrid
/// (Reciprocal Rank Fusion) search over vault blob chunks. Works against the
/// KV namespaces written by [VaultBm25Writer] and [VaultVecWriter].
library;

import 'dart:convert' show json, utf8;
import 'dart:math' show log;
import 'dart:typed_data';

import 'package:betto_lexical/betto_lexical.dart' show createDefaultTokenizer;

import '../../encoding/value_codec.dart';
import '../../search/lexical/fts_manager.dart' show defaultStopwords;
import '../../search/lexical/pipeline.dart' show preprocess;
import '../../search/search_mode.dart';
import '../../search/search_result.dart' show SearchMetadata;
import '../../engine/kvstore/kv_store_impl.dart';
import '../vault_ref.dart';
import '../vault_store.dart';
import 'vault_bm25_writer.dart';
import 'vault_namespaces.dart' show kVaultCorpusSentinelKey, kVaultDocRefPrefix;
import 'vault_search_hit.dart';
import 'vault_search_manager.dart';
import 'vault_vec_writer.dart';

/// Executes [KmdbCollection.searchVault] queries against the vault search index.
///
/// [VaultSearcher] is constructed per-query (stateless apart from the borrowed
/// references it holds). It reads from the `$$vault:fts:`, `$$vault:vec:idx`,
/// `$vault:docref:`, and `$$vault:extract:` namespaces written by
/// [VaultSearchManager].
///
/// ## Search modes
///
/// - **Lexical (BM25):** Per-blob BM25 scoring. Document frequency (DF) is
///   computed dynamically by counting chunk-index keys in the per-term
///   namespace (mirrors [FtsManager], `fts_manager.dart:765`). The blob-level
///   score is the maximum BM25 score across all matching chunks.
/// - **Semantic:** Embeds the query using the database-level [EmbeddingModel]
///   and performs a brute-force dot-product scan over `$$vault:vec:idx` entries.
///   The blob-level score is the maximum cosine similarity across matching chunks.
/// - **Hybrid (RRF):** Runs both legs and combines results using Reciprocal
///   Rank Fusion with `k=60` (matching §23).
///
/// ## Snippet retrieval
///
/// Snippets are the full chunk text, read from `extract/text.txt` using byte
/// offsets stored in `extract/chunks_v1.json`. No additional trimming is
/// applied in v1 (deferred to v2).
///
/// ## Per-blob corpus scope
///
/// Each vault blob is its own BM25 corpus — cross-blob IDF is intentionally
/// not computed. The `n` (chunk count) from the corpus sentinel is the corpus
/// size for IDF computation within that blob.
final class VaultSearcher<T> {
  /// Creates a [VaultSearcher].
  ///
  /// [manager] provides the [KvStoreImpl], [VaultStore], and optional
  /// [EmbeddingModel]. [namespace] is the collection namespace (used to scope
  /// the `$vault:docref:` lookup to blobs referenced by this collection).
  /// [fetchDoc] resolves a document key to [T].
  VaultSearcher({
    required VaultSearchManager manager,
    required String namespace,
    required Future<T?> Function(String id) fetchDoc,
  }) : _kvStore = manager.kvStore,
       _vaultStore = manager.vaultStore,
       _embeddingModel = manager.embeddingModel,
       // _namespace and _fetchDoc stored for future use and documentation.
       // ignore: prefer_initializing_formals
       _namespace = namespace,
       // ignore: prefer_initializing_formals
       _fetchDoc = fetchDoc;

  final KvStoreImpl _kvStore;
  final VaultStore _vaultStore;
  final Object? _embeddingModel; // EmbeddingModel? — kept as Object? to avoid
  // pulling in betto_inferencing's generated type into this file's type graph.
  // Cast is done inline only when calling embed().

  /// The collection namespace. Not used in query logic directly — candidate
  /// sha256 resolution uses [_fetchDoc] to scope results to this collection.
  /// Retained for observability (e.g., future per-namespace query optimisations).
  // ignore: unused_field
  final String _namespace;
  final Future<T?> Function(String id) _fetchDoc;

  // BM25 hyper-parameters (matching FtsManager defaults).
  static const double _k1 = 1.2;
  static const double _b = 0.75;

  // RRF parameter (matching §23 / HybridManager).
  static const int _rrfK = 60;

  // Key constants for fieldScores map.
  static const String _keyBm25 = 'vault:bm25';
  static const String _keyCosine = 'vault:cosine';

  // ── Public entry point ─────────────────────────────────────────────────────

  /// Searches vault blob content for [query] using [mode].
  ///
  /// Returns [VaultSearchResult] with ranked [VaultSearchHit]s. Results are
  /// limited to blobs that have been downloaded and indexed on this device;
  /// stub blobs produce no hits.
  ///
  /// [limit] and [offset] paginate the ranked hit list.
  Future<VaultSearchResult<T>> search(
    String query, {
    SearchMode mode = SearchMode.auto,
    int limit = 10,
    int offset = 0,
  }) async {
    if (query.trim().isEmpty) {
      return VaultSearchResult<T>(
        metadata: SearchMetadata(
          query: query,
          searched: const [],
          skipped: const ['vault'],
          total: 0,
        ),
        hits: const [],
      );
    }

    // Resolve candidate sha256 hashes for this collection namespace.
    final candidateSha256s = await _candidatesForNamespace();

    if (candidateSha256s.isEmpty) {
      return VaultSearchResult<T>(
        metadata: SearchMetadata(
          query: query,
          searched: const [],
          skipped: const [],
          total: 0,
        ),
        hits: const [],
      );
    }

    // Check whether semantic leg is available.
    final hasModel = _embeddingModel != null;

    // Determine effective mode.
    final effectiveMode = switch (mode) {
      SearchMode.auto => hasModel ? SearchMode.auto : SearchMode.lexical,
      SearchMode.semantic => SearchMode.semantic,
      SearchMode.lexical => SearchMode.lexical,
    };

    final skipped = <String>[];

    switch (effectiveMode) {
      case SearchMode.lexical:
        final lexScores = await _scoreLexical(query, candidateSha256s);
        return _buildResult(
          query: query,
          sha256Scores: lexScores.map(
            (e) => (e.$1, e.$2, <String, double>{_keyBm25: e.$2}),
          ),
          searched: ['vault:lexical'],
          skipped: skipped,
          limit: limit,
          offset: offset,
        );

      case SearchMode.semantic:
        if (!hasModel) {
          // Semantic requested but no model — degrade to lexical.
          skipped.add('vault:semantic');
          final lexScores = await _scoreLexical(query, candidateSha256s);
          return _buildResult(
            query: query,
            sha256Scores: lexScores.map(
              (e) => (e.$1, e.$2, <String, double>{_keyBm25: e.$2}),
            ),
            searched: ['vault:lexical'],
            skipped: skipped,
            limit: limit,
            offset: offset,
          );
        }
        final semScores = await _scoreSemantic(query, candidateSha256s);
        return _buildResult(
          query: query,
          sha256Scores: semScores.map(
            (e) => (e.$1, e.$2, <String, double>{_keyCosine: e.$2}),
          ),
          searched: ['vault:semantic'],
          skipped: skipped,
          limit: limit,
          offset: offset,
        );

      case SearchMode.auto:
        // auto with model → hybrid (RRF).
        final lexScores = await _scoreLexical(query, candidateSha256s);
        final semScores = await _scoreSemantic(query, candidateSha256s);
        final rrfScores = _applyRrf(lexScores, semScores);
        return _buildResult(
          query: query,
          sha256Scores: rrfScores,
          searched: ['vault:lexical', 'vault:semantic'],
          skipped: skipped,
          limit: limit,
          offset: offset,
        );
    }
  }

  // ── Candidate resolution ──────────────────────────────────────────────────

  /// Finds all sha256 hashes referenced by documents in [_namespace].
  ///
  /// Reads `$vault:docref:{sha256}` entries and returns sha256 values for which
  /// any document in this collection references that blob.
  ///
  /// ## Why not listNamespaces()
  ///
  /// `$vault:docref:{sha256}` namespaces are written via [writeBatchInternal],
  /// which does not register `$`-prefixed namespaces in the KV namespace
  /// registry. [KvStore.listNamespaces] therefore never returns them. Instead,
  /// we iterate over all known blobs from the vault filesystem and probe each
  /// `$vault:docref:{sha256}` namespace directly — [KvStore.scan] reads from
  /// the LSM engine without requiring namespace registration.
  Future<Set<String>> _candidatesForNamespace() async {
    // Use the vault filesystem as the authoritative list of known blobs.
    // For each, probe its docref namespace to see if any document in this
    // collection references it.
    final knownHashes = await _vaultStore.listAllHashes();
    if (knownHashes.isEmpty) return const {};

    final result = <String>{};

    for (final sha256 in knownHashes) {
      final docRefNs = '$kVaultDocRefPrefix$sha256';
      await for (final entry in _kvStore.scan(docRefNs)) {
        final docId = entry.key;
        final doc = await _fetchDoc(docId);
        if (doc != null) {
          result.add(sha256);
          break; // Found at least one reference in this collection.
        }
      }
    }

    return result;
  }

  // ── Lexical (BM25) scoring ───────────────────────────────────────────────

  /// Scores [candidateSha256s] using BM25 against [query].
  ///
  /// For each query term, scans `$$vault:fts:{sha256}:{hexTerm}` to get chunk
  /// TF values and counts DF (number of chunks containing the term). The
  /// per-blob corpus sentinel provides `n` (chunk count) and `totalTokens`.
  ///
  /// Per-chunk document length (`|d|` in BM25) is read from
  /// `extract/chunks_v1.json` ([VaultChunk.wordCount]). This is the correct
  /// value for length normalisation — not the term frequency, which was the
  /// prior bug (docLen: tf).
  ///
  /// Returns a list of `(sha256, score)` pairs sorted by descending score.
  Future<List<(String, double)>> _scoreLexical(
    String query,
    Set<String> candidateSha256s,
  ) async {
    // Tokenise the query using the same pipeline as indexing (preprocess
    // applies: tokenise → normalise → stop-word filter → stem). This ensures
    // query terms are directly comparable to indexed terms.
    final queryTerms = preprocess(
      query,
      createDefaultTokenizer(),
      stopWords: defaultStopwords.listing,
    ).toSet().toList();

    if (queryTerms.isEmpty) return [];

    final scores = <String, double>{};

    for (final sha256 in candidateSha256s) {
      // Read corpus sentinel for this blob.
      final corpusNs = VaultBm25Writer.corpusNamespace(sha256);
      final corpusBytes = await _kvStore.get(corpusNs, kVaultCorpusSentinelKey);
      final corpus = VaultBm25Writer.decodeCorpus(corpusBytes);
      if (corpus == null || corpus.n == 0) continue;

      final n = corpus.n; // total chunks in this blob.
      final totalTokens = corpus.totalTokens;
      final avgdl = totalTokens > 0 ? totalTokens / n : 1.0;

      // Load per-chunk word counts from chunks_v1.json for BM25 length
      // normalisation. Falls back to avgdl for chunks whose metadata is absent
      // (e.g. extract artifact not yet written or a legacy index).
      final chunkWordCounts = await _loadChunkWordCounts(sha256);

      // For each query term, collect per-chunk TF and count DF.
      var blobScore = 0.0;

      for (final term in queryTerms) {
        final termNs = VaultBm25Writer.termNamespace(sha256, term);
        final chunkTfs = <int, int>{}; // chunkIndex → tf

        await for (final entry in _kvStore.scan(termNs)) {
          final tf = VaultBm25Writer.decodeTf(entry.value);
          if (tf > 0) {
            // kVaultChunkKey format: 17-char fixed prefix + 15-char hex index.
            // Extract the last 15 chars as the chunk index.
            final key = entry.key;
            if (key.length == 32) {
              final chunkIdx = int.tryParse(key.substring(17), radix: 16) ?? -1;
              if (chunkIdx >= 0) chunkTfs[chunkIdx] = tf;
            }
          }
        }

        if (chunkTfs.isEmpty) continue;
        final df = chunkTfs.length; // number of chunks containing this term.

        // BM25: use max chunk score as the blob score contribution.
        // Each chunk is treated as a "document" within the blob corpus.
        var maxChunkScore = 0.0;
        for (final entry in chunkTfs.entries) {
          // Use the actual wordCount for this chunk as the document length.
          // Falls back to avgdl (cast to int) when chunk metadata is absent,
          // which makes length normalisation neutral for that chunk.
          final chunkIdx = entry.key;
          final tf = entry.value;
          final docLen =
              chunkWordCounts[chunkIdx] ?? avgdl.round().clamp(1, 1 << 30);
          final chunkScore = _bm25Score(
            tf: tf,
            df: df,
            n: n,
            docLen: docLen,
            avgdl: avgdl,
            k1: _k1,
            b: _b,
          );
          if (chunkScore > maxChunkScore) maxChunkScore = chunkScore;
        }
        blobScore += maxChunkScore;
      }

      if (blobScore > 0) scores[sha256] = blobScore;
    }

    return scores.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Loads per-chunk word counts from `extract/chunks_v1.json` for [sha256].
  ///
  /// Returns a map from chunk index to word count. Returns an empty map if
  /// the file does not exist or cannot be parsed (graceful degradation — the
  /// caller falls back to avgdl for any missing entry).
  Future<Map<int, int>> _loadChunkWordCounts(String sha256) async {
    final extractDir = '${_vaultStore.hashDir(sha256)}/extract';
    final chunksPath = '$extractDir/chunks_v1.json';
    try {
      final adapter = _vaultStore.adapter;
      if (!await adapter.fileExists(chunksPath)) return {};
      final bytes = await adapter.readFile(chunksPath);
      final list = json.decode(utf8.decode(bytes)) as List;
      return {
        for (final entry in list.cast<Map<String, dynamic>>())
          (entry['index'] as num).toInt():
              (entry['wordCount'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {};
    }
  }

  // ── Semantic (cosine) scoring ─────────────────────────────────────────────

  /// Scores [candidateSha256s] using cosine similarity against [query].
  ///
  /// Embeds [query] on the main isolate using the database-level model, then
  /// scans `$$vault:vec:idx:{sha256}` per-blob namespaces for [candidateSha256s],
  /// dequantises SQ8 vectors, and computes dot-product cosine similarity.
  ///
  /// Returns a list of `(sha256, score)` pairs sorted by descending score.
  Future<List<(String, double)>> _scoreSemantic(
    String query,
    Set<String> candidateSha256s,
  ) async {
    if (_embeddingModel == null) return [];

    // Embed query on main isolate (ORT session is thread-affine — RQ-5).
    // Cast is safe: the constructor receives EmbeddingModel? from the manager.
    final model = _embeddingModel as dynamic;
    final (Float32List queryVec, _) = await (model.embed(query) as Future);

    final scores = <String, double>{};

    // Scan each candidate blob's per-blob vector namespace separately.
    // Namespace = $$vault:vec:idx:{sha256}; key = kVaultChunkKey(chunkIndex).
    for (final sha256 in candidateSha256s) {
      final ns = VaultVecWriter.vecNamespace(sha256);
      await for (final entry in _kvStore.scan(ns)) {
        final chunkVec = VaultVecWriter.dequantise(entry.value);
        if (chunkVec.length != queryVec.length) continue;

        final similarity = _dotProduct(queryVec, chunkVec);
        // Keep max similarity per blob.
        final current = scores[sha256] ?? double.negativeInfinity;
        if (similarity > current) scores[sha256] = similarity;
      }
    }

    return scores.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  // ── RRF merge ────────────────────────────────────────────────────────────

  /// Merges [lexScores] and [semScores] using Reciprocal Rank Fusion.
  ///
  /// RRF formula: `score = Σ 1 / (k + rank)` where k=[_rrfK]=60 (§23).
  /// Returns `(sha256, rrfScore, fieldScores)` sorted by descending RRF score.
  Iterable<(String, double, Map<String, double>)> _applyRrf(
    List<(String, double)> lexScores,
    List<(String, double)> semScores,
  ) {
    final rrfScores = <String, double>{};
    final bm25Component = <String, double>{};
    final cosineComponent = <String, double>{};

    // Record raw component scores for fieldScores.
    for (final (sha256, score) in lexScores) {
      bm25Component[sha256] = score;
    }
    for (final (sha256, score) in semScores) {
      cosineComponent[sha256] = score;
    }

    // Lexical leg RRF contribution.
    for (var rank = 0; rank < lexScores.length; rank++) {
      final sha256 = lexScores[rank].$1;
      rrfScores[sha256] = (rrfScores[sha256] ?? 0.0) + 1.0 / (_rrfK + rank + 1);
    }

    // Semantic leg RRF contribution.
    for (var rank = 0; rank < semScores.length; rank++) {
      final sha256 = semScores[rank].$1;
      rrfScores[sha256] = (rrfScores[sha256] ?? 0.0) + 1.0 / (_rrfK + rank + 1);
    }

    final sorted = rrfScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted.map((e) {
      final sha256 = e.key;
      final components = <String, double>{};
      if (bm25Component.containsKey(sha256)) {
        components[_keyBm25] = bm25Component[sha256]!;
      }
      if (cosineComponent.containsKey(sha256)) {
        components[_keyCosine] = cosineComponent[sha256]!;
      }
      return (sha256, e.value, components);
    });
  }

  // ── Result construction ───────────────────────────────────────────────────

  /// Builds a paginated [VaultSearchResult] from scored sha256 entries.
  ///
  /// Fetches documents, reads snippets from `extract/` artifacts, and
  /// constructs [VaultSearchHit]s. Entries where the document cannot be
  /// fetched are silently skipped (document deleted after indexing).
  Future<VaultSearchResult<T>> _buildResult({
    required String query,
    required Iterable<(String, double, Map<String, double>)> sha256Scores,
    required List<String> searched,
    required List<String> skipped,
    required int limit,
    required int offset,
  }) async {
    // Resolve docId → fieldPath for all scored sha256s, then fetch documents.
    // We want to deduplicate to document level (highest-scoring sha256 per doc).
    final docBestScore = <String, (double, Map<String, double>, String)>{};
    // docId → (score, fieldScores, sha256)

    for (final (sha256, score, fieldScores) in sha256Scores) {
      // Scan docref entries for this sha256.
      final docRefNs = '$kVaultDocRefPrefix$sha256';
      await for (final entry in _kvStore.scan(docRefNs)) {
        final docId = entry.key;
        final current = docBestScore[docId];
        if (current == null || score > current.$1) {
          docBestScore[docId] = (score, fieldScores, sha256);
        }
      }
    }

    if (docBestScore.isEmpty) {
      return VaultSearchResult<T>(
        metadata: SearchMetadata(
          query: query,
          searched: searched,
          skipped: skipped,
          total: 0,
        ),
        hits: const [],
      );
    }

    // Sort document entries by descending score.
    final sorted = docBestScore.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));

    final total = sorted.length;
    final page = sorted.skip(offset).take(limit).toList();

    final hits = <VaultSearchHit<T>>[];
    var rank = offset + 1;

    for (final entry in page) {
      final docId = entry.key;
      final (score, fieldScores, sha256) = entry.value;

      // Fetch the document.
      final doc = await _fetchDoc(docId);
      if (doc == null) {
        rank++;
        continue; // Document was deleted after indexing.
      }

      // Read field path from docref.
      // Value is stored as ValueCodec-encoded map {'p': fieldPath} (see
      // VaultRefInterceptor.interceptWrite). Decode via ValueCodec to handle
      // encryption and CBOR decoding uniformly.
      final docRefNs = '$kVaultDocRefPrefix$sha256';
      final fieldPathBytes = await _kvStore.get(docRefNs, docId);
      String fieldPath = '';
      if (fieldPathBytes != null) {
        try {
          final decoded = await ValueCodec.decode(fieldPathBytes);
          fieldPath = (decoded['p'] as String?) ?? '';
        } catch (_) {
          // Undecodable — use empty path.
        }
      }

      // Read chunk context: pick the best-matching chunk (first one for now).
      final chunkCtx = await _buildChunkContext(sha256, fieldPath);

      hits.add(
        VaultSearchHit<T>(
          rank: rank,
          score: score,
          fieldScores: fieldScores,
          id: docId,
          document: doc,
          chunkContext: chunkCtx,
        ),
      );
      rank++;
    }

    return VaultSearchResult<T>(
      metadata: SearchMetadata(
        query: query,
        searched: searched,
        skipped: skipped,
        total: total,
      ),
      hits: hits,
    );
  }

  /// Reads the first chunk context for [sha256] to populate [VaultSearchHit.chunkContext].
  ///
  /// Reads `extract/chunks_v1.json` for byte offsets and `extract/text.txt` for
  /// the snippet text. Returns a [VaultChunkContext] with `chunkIndex: 0` and
  /// the full text of the first chunk.
  ///
  /// Returns a placeholder context if the extract artifacts are missing.
  Future<VaultChunkContext> _buildChunkContext(
    String sha256,
    String fieldPath,
  ) async {
    final extractDir = '${_vaultStore.hashDir(sha256)}/extract';
    final chunksPath = '$extractDir/chunks_v1.json';
    final textPath = '$extractDir/text.txt';

    try {
      final adapter = _vaultStore.adapter;
      if (!await adapter.fileExists(chunksPath) ||
          !await adapter.fileExists(textPath)) {
        return _placeholderContext(sha256, fieldPath);
      }

      final chunksBytes = await adapter.readFile(chunksPath);
      final chunksList = json.decode(utf8.decode(chunksBytes)) as List;

      if (chunksList.isEmpty) {
        return _placeholderContext(sha256, fieldPath);
      }

      // Build a VaultRef for this sha256 and wire it to the store so callers
      // can access blob bytes and metadata through the ref.
      final ref = VaultRef('kmdb-vault://sha256/$sha256')..wire(_vaultStore);

      // Read the first chunk's text.
      final firstChunk = chunksList.first as Map<String, dynamic>;
      final byteStart = (firstChunk['byteStart'] as int?) ?? 0;
      final byteEnd = (firstChunk['byteEnd'] as int?) ?? 0;

      final textBytes = await adapter.readFile(textPath);
      // clamp returns num; calling toInt() ensures we get a proper int for
      // Uint8List.sublistView which requires int arguments.
      final safeEnd = byteEnd.clamp(0, textBytes.length).toInt();
      final safeStart = byteStart.clamp(0, safeEnd).toInt();

      final snippetBytes = Uint8List.sublistView(textBytes, safeStart, safeEnd);
      final snippet = utf8.decode(snippetBytes, allowMalformed: true);

      return VaultChunkContext(
        ref: ref,
        chunkIndex: 0,
        totalChunks: chunksList.length,
        snippet: snippet,
        fieldPath: fieldPath,
      );
    } catch (_) {
      return _placeholderContext(sha256, fieldPath);
    }
  }

  /// Returns a minimal [VaultChunkContext] when extract artifacts are unavailable.
  Future<VaultChunkContext> _placeholderContext(
    String sha256,
    String fieldPath,
  ) async {
    // Construct a VaultRef from the sha256 and wire it to the store.
    // Even if the manifest is missing, the VaultRef can still be constructed
    // — callers that try to access blob bytes will get an appropriate error.
    final ref = VaultRef('kmdb-vault://sha256/$sha256')..wire(_vaultStore);
    return VaultChunkContext(
      ref: ref,
      chunkIndex: 0,
      totalChunks: 0,
      snippet: '',
      fieldPath: fieldPath,
    );
  }

  // ── Scoring helpers ───────────────────────────────────────────────────────

  /// BM25 scoring formula (matches [FtsManager._bm25Score]).
  ///
  /// ```
  /// IDF(t) = ln((N − df(t) + 0.5) / (df(t) + 0.5) + 1)
  /// TF_norm = tf × (k1 + 1) / (tf + k1 × (1 − b + b × |d| / avgdl))
  /// BM25(t, d) = IDF(t) × TF_norm
  /// ```
  static double _bm25Score({
    required int tf,
    required int df,
    required int n,
    required int docLen,
    required double avgdl,
    required double k1,
    required double b,
  }) {
    if (df <= 0 || n <= 0 || docLen <= 0 || avgdl <= 0) return 0.0;
    final idf = log((n - df + 0.5) / (df + 0.5) + 1);
    if (idf <= 0) return 0.0;
    final tfNorm = tf * (k1 + 1) / (tf + k1 * (1 - b + b * docLen / avgdl));
    return idf * tfNorm;
  }

  /// Dot product of two float32 vectors (cosine similarity for L2-normalised
  /// vectors).
  static double _dotProduct(Float32List a, Float32List b) {
    var sum = 0.0;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}
