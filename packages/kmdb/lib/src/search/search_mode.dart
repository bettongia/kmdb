// Copyright 2026 The KMDB Authors
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

/// Controls which search index is used when calling
/// [KmdbCollection.search].
///
/// KMDB supports three search strategies:
///
/// - **Lexical** — BM25 inverted index over tokenised document fields.
///   Fast and exact; requires `ftsIndexes` to be configured at open time.
/// - **Semantic** — vector similarity search using BGE Small En v1.5
///   embeddings with SQ8 quantisation. Understands paraphrase and synonymy;
///   requires `vecIndexes` and an `embeddingModel` at open time.
/// - **Auto (hybrid)** — automatically selects lexical if only an FTS index
///   is available, semantic if only a vector index is available, and combines
///   both using Reciprocal Rank Fusion (RRF) when both indexes are present.
///
/// Hybrid search is not a separate value — it activates automatically under
/// `auto` when both indexes are available for the queried fields.
enum SearchMode {
  /// Automatically select the best available search strategy.
  ///
  /// Behaviour:
  /// - Both FTS and vector indexes available → hybrid (RRF combination).
  /// - Only FTS index available → lexical BM25.
  /// - Only vector index available → semantic cosine similarity.
  /// - No index available → returns an empty result with the field listed in
  ///   `SearchMetadata.skipped`.
  auto,

  /// Force lexical (BM25) search only.
  ///
  /// Returns an empty result if no FTS index is configured for the requested
  /// field, with the field listed in `SearchMetadata.skipped`.
  lexical,

  /// Force semantic (vector cosine similarity) search only.
  ///
  /// Returns an empty result if no vector index is configured for the
  /// requested field, with the field listed in `SearchMetadata.skipped`.
  semantic,
}
