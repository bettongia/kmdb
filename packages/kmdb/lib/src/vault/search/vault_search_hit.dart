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

import '../../search/search_result.dart' show SearchMetadata;
import '../vault_ref.dart';

/// The matching chunk context within a vault blob search result.
///
/// Provides the snippet text, byte offsets in `text.txt`, and the originating
/// document field path so callers can display the hit and navigate to the
/// source field.
final class VaultChunkContext {
  /// Creates a [VaultChunkContext].
  const VaultChunkContext({
    required this.ref,
    required this.chunkIndex,
    required this.totalChunks,
    required this.snippet,
    required this.fieldPath,
  });

  /// The vault blob reference that contains the matching chunk.
  final VaultRef ref;

  /// 0-based position of the matching chunk within its blob's chunk sequence.
  final int chunkIndex;

  /// Total number of chunks in the blob (the full `chunkCount` from the
  /// extraction state).
  final int totalChunks;

  /// The full text of the matching chunk, read from `extract/text.txt` using
  /// the byte offsets in `extract/chunks_v1.json`.
  ///
  /// In v1 this is the complete chunk text (no additional trimming). Callers
  /// may truncate for display as appropriate. A `maxSnippetLength` config
  /// parameter is deferred to v2.
  final String snippet;

  /// Dot-notation field path in the owning document that holds the
  /// [VaultRef] URI for this blob.
  ///
  /// **First-field-path-wins**: When the same blob is referenced from more
  /// than one field in the same document, only the first field path encountered
  /// during the `_scanVaultUrisWithPaths` scan is stored. This is a documented
  /// v1 limitation; a future version may store all paths.
  final String fieldPath;
}

/// A single ranked vault-content match.
///
/// Mirrors the field set of [SearchHit] exactly (`rank, score, fieldScores,
/// id, document`) and adds [chunkContext]. It is a standalone `final class`,
/// NOT a subclass of [SearchHit] — [SearchHit] is `final` and cannot be
/// extended (RQ-2). Keeping the field names identical means callers that
/// already consume [SearchHit] can read a [VaultSearchHit] with no surprises.
///
/// ## Scores
///
/// The meaning of [score] depends on the active [SearchMode]:
///
/// - **Lexical (BM25):** per-chunk BM25 score. The blob-level score is the
///   maximum across all matching chunks.
/// - **Semantic (cosine similarity):** per-chunk dot product of L2-normalised
///   SQ8 vectors. The blob-level score is the maximum cosine similarity across
///   all matching chunks.
/// - **Hybrid (RRF):** Reciprocal Rank Fusion combining the lexical and
///   semantic ranks (k=60, same formula as §23). Not bounded to `[0, 1]`.
///
/// ## Field scores
///
/// [fieldScores] contains per-component scores keyed by `"vault:bm25"` (BM25)
/// and/or `"vault:cosine"` (cosine similarity). Unlike [SearchHit.fieldScores],
/// vault search does not have per-document-field scores — the vault corpus is
/// chunk-based. In hybrid mode both keys are populated.
///
/// ## Example
///
/// ```dart
/// final result = await collection.searchVault('database query');
/// for (final hit in result.hits) {
///   print('${hit.rank}. ${hit.id} (${hit.score.toStringAsFixed(3)})');
///   print('  field: ${hit.chunkContext.fieldPath}');
///   print('  snippet: ${hit.chunkContext.snippet.substring(0, 100)}...');
/// }
/// ```
final class VaultSearchHit<T> {
  /// Creates a [VaultSearchHit].
  const VaultSearchHit({
    required this.rank,
    required this.score,
    required this.fieldScores,
    required this.id,
    required this.document,
    required this.chunkContext,
  });

  /// 1-based position in the result list (1 = highest relevance).
  final int rank;

  /// Overall relevance score. Interpretation matches [SearchHit.score]
  /// (BM25, cosine, or RRF depending on the active [SearchMode]).
  final double score;

  /// Per-component scores, keyed `"vault:bm25"` and/or `"vault:cosine"`.
  ///
  /// The vault corpus is chunk-based, not field-based, so there is no
  /// per-document-field key here (unlike [SearchHit.fieldScores]).
  final Map<String, double> fieldScores;

  /// The owning document key (UUIDv7 hex string).
  final String id;

  /// The fully decoded owning document.
  final T document;

  /// The matching chunk's context: snippet, byte offsets, and originating
  /// document field path.
  final VaultChunkContext chunkContext;
}

/// The result of a [KmdbCollection.searchVault] call.
///
/// Parallel to [SearchResult] but typed for [VaultSearchHit] hits rather than
/// [SearchHit] hits. A separate wrapper type is used because [SearchResult]'s
/// `hits` field is `List<SearchHit<T>>` — [VaultSearchHit] is a standalone
/// `final class` that cannot be placed in that list (RQ-2).
///
/// [SearchMetadata] is reused unchanged.
///
/// ## Example
///
/// ```dart
/// final result = await collection.searchVault('database query');
/// print('Found ${result.metadata.total} results');
/// for (final hit in result.hits) {
///   print('${hit.rank}. ${hit.id}');
/// }
/// ```
final class VaultSearchResult<T> {
  /// Creates a [VaultSearchResult].
  const VaultSearchResult({required this.metadata, required this.hits});

  /// Metadata describing the search query and execution.
  ///
  /// [SearchMetadata.searched] contains `["vault"]` and [SearchMetadata.skipped]
  /// is empty for a successful vault search, or `["vault:semantic"]` when the
  /// query requested semantic mode but no embedding model is configured.
  final SearchMetadata metadata;

  /// Ranked list of vault-content matches, ordered by descending [VaultSearchHit.score].
  final List<VaultSearchHit<T>> hits;
}
