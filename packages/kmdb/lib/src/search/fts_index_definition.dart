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

/// Defines a full-text search (FTS) index over a single document field within
/// a named collection.
///
/// FTS indexes use the BM25 ranking function over a tokenised inverted index
/// stored in `$$fts:{collection}:{field}` system namespaces. These are
/// local-only namespaces — never uploaded to the sync folder.
///
/// ## BM25 tuning
///
/// BM25 has two tuning parameters:
///
/// - [k1] controls term-frequency saturation. Higher values give more weight
///   to term frequency; lower values produce near-binary term weighting.
///   Default: `1.2` (widely used baseline).
/// - [b] controls document-length normalisation. `0.0` disables length
///   normalisation; `1.0` fully normalises by document length.
///   Default: `0.75` (widely used baseline).
///
/// ## Example
///
/// ```dart
/// // Index the 'body' field of the 'articles' collection with default BM25
/// // settings and English stop word removal enabled.
/// final def = FtsIndexDefinition(
///   collection: 'articles',
///   field: 'body',
///   stopWords: true,
/// );
/// ```
final class FtsIndexDefinition {
  /// Creates an FTS index definition.
  ///
  /// [collection] is the name of the collection to index. Must be a valid
  /// KMDB collection name (no `$` prefix).
  ///
  /// [field] is the document field path to index. Supports dot-notation for
  /// nested fields (e.g. `'meta.description'`).
  ///
  /// [lazy] controls when the index is initially built. When `false` (the
  /// default) the index is built the first time a search query is issued
  /// against this field. When `true` the index build is deferred until the
  /// first write is received.
  ///
  /// [k1] and [b] are BM25 tuning parameters (see class-level docs).
  ///
  /// [stopWords] when `true`, applies the Stopwords ISO `en` list during
  /// Stage 3 of the indexing pipeline, removing common English words (e.g.
  /// "the", "is", "at") before the BM25 calculation. Reduces index size and
  /// noise at the cost of not being able to search for stop words.
  const FtsIndexDefinition({
    required this.collection,
    required this.field,
    this.lazy = false,
    this.k1 = 1.2,
    this.b = 0.75,
    this.stopWords = false,
  });

  /// The collection name whose documents this index covers.
  final String collection;

  /// The document field path (dot-notation) to index.
  final String field;

  /// Whether the initial index build is deferred until the first write.
  ///
  /// When `false` (default), the index is built lazily on the first query.
  final bool lazy;

  /// BM25 term-frequency saturation parameter. Default: `1.2`.
  ///
  /// Typical range: `[1.2, 2.0]`. Lower values approach binary term weighting.
  final double k1;

  /// BM25 document-length normalisation parameter. Default: `0.75`.
  ///
  /// Range: `[0.0, 1.0]`. Use `0.0` to disable length normalisation.
  final double b;

  /// Whether to apply English stop word removal during preprocessing.
  ///
  /// Uses the Stopwords ISO `en` list (Stage 3 of the pipeline). Defaults to
  /// `false` to preserve all terms.
  final bool stopWords;
}
