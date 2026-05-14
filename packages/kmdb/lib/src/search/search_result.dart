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

/// The result of a [KmdbCollection.search] call.
///
/// Contains an ordered list of [hits] (ranked by relevance) and [metadata]
/// describing the search execution.
///
/// ## Type parameter
///
/// [T] is the document type returned by the collection's codec. Each [SearchHit]
/// carries the fully decoded document so callers do not need to issue a
/// separate point-lookup.
///
/// ## Example
///
/// ```dart
/// final result = await collection.search('flutter database');
/// print('Found ${result.metadata.total} results');
/// for (final hit in result.hits) {
///   print('${hit.rank}. [${hit.score.toStringAsFixed(3)}] ${hit.id}');
/// }
/// ```
final class SearchResult<T> {
  /// Creates a [SearchResult] with the given [metadata] and [hits].
  const SearchResult({required this.metadata, required this.hits});

  /// Metadata describing the search query and how it was executed.
  final SearchMetadata metadata;

  /// Ranked list of matching documents, ordered by descending [SearchHit.score].
  final List<SearchHit<T>> hits;
}

/// Metadata attached to every [SearchResult].
///
/// Provides observability into how the query was processed, including which
/// fields were actually searched and which were skipped due to missing indexes.
final class SearchMetadata {
  /// Creates a [SearchMetadata] instance.
  const SearchMetadata({
    required this.query,
    required this.searched,
    required this.skipped,
    required this.total,
  });

  /// The original query string as supplied by the caller.
  final String query;

  /// The field names that were successfully searched (at least one index was
  /// available and the field was not excluded by the query's [Filter]).
  final List<String> searched;

  /// The field names that were requested but skipped because no matching index
  /// was configured, or because the selected [SearchMode] is incompatible with
  /// the available index type.
  ///
  /// A non-empty [skipped] list does not indicate an error — it is informational.
  /// The result will still contain hits from any [searched] fields.
  final List<String> skipped;

  /// The total number of matching documents before [KmdbQuery.limit] is applied.
  ///
  /// May be larger than `hits.length` when a `limit` parameter was supplied.
  final int total;
}

/// A single ranked document in a [SearchResult].
///
/// Carries the decoded document, its relevance score, and per-field scores
/// for transparency in hybrid mode.
///
/// ## Scores
///
/// The meaning of [score] depends on the active [SearchMode]:
///
/// - **Lexical (BM25):** normalised BM25 score in `[0, 1]`. Higher is more
///   relevant.
/// - **Semantic (cosine similarity):** cosine similarity in `[-1, 1]`, where
///   1 means identical vector directions. In practice scores are in `[0, 1]`
///   for the BGE model.
/// - **Hybrid (RRF):** Reciprocal Rank Fusion score combining lexical and
///   semantic ranks. Formula: `1/(k + rank_lexical) + 1/(k + rank_semantic)`,
///   where `k = 60`. Not bounded to `[0, 1]`.
///
/// ## Field scores
///
/// [fieldScores] contains per-field component scores keyed by
/// `"{fieldName}:bm25"` for the BM25 component and `"{fieldName}:cosine"` for
/// the cosine component. In single-mode operation, only the relevant key is
/// populated.
///
/// ```dart
/// final bm25 = hit.fieldScores['title:bm25']; // null in semantic mode
/// final cosine = hit.fieldScores['title:cosine']; // null in lexical mode
/// ```
final class SearchHit<T> {
  /// Creates a [SearchHit].
  const SearchHit({
    required this.rank,
    required this.score,
    required this.fieldScores,
    required this.id,
    required this.document,
  });

  /// 1-based position in the result list (1 = highest relevance).
  final int rank;

  /// Overall relevance score for this hit. See class-level docs for
  /// mode-specific interpretation.
  final double score;

  /// Per-field component scores, keyed by `"{field}:bm25"` or
  /// `"{field}:cosine"`. Empty in stub mode.
  final Map<String, double> fieldScores;

  /// The document key (UUIDv7 hex string).
  final String id;

  /// The fully decoded document.
  final T document;
}
