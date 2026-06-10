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

/// Defines a vector (semantic) search index over a single document field
/// within a named collection.
///
/// Vector indexes store SQ8-quantised BGE Small En v1.5 embeddings in
/// `$vec:{collection}:{field}` system namespaces. These namespaces are
/// excluded from sync and cache.
///
/// An [EmbeddingModel] must be supplied to [KmdbDatabase.open] when any
/// [VecIndexDefinition] is provided. Omitting the model causes `open()` to
/// throw [ArgumentError].
///
/// ## Example
///
/// ```dart
/// // Index the 'body' field of the 'articles' collection for semantic search.
/// final def = VecIndexDefinition(collection: 'articles', field: 'body');
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vecIndexes: [def],
///   embeddingModel: await OnnxEmbeddingModel.load(cacheDir: cacheDir),
/// );
/// ```
final class VecIndexDefinition {
  /// Creates a vector index definition.
  ///
  /// [collection] is the name of the collection to index. Must be a valid
  /// KMDB collection name (no `$` prefix).
  ///
  /// [field] is the document field path to index. Supports dot-notation for
  /// nested fields (e.g. `'meta.description'`).
  ///
  /// [lazy] controls when the index is initially built. When `false` (the
  /// default) the index is built the first time a search query is issued
  /// against this field.
  const VecIndexDefinition({
    required this.collection,
    required this.field,
    this.lazy = false,
  });

  /// The collection name whose documents this index covers.
  final String collection;

  /// The document field path (dot-notation) to index.
  final String field;

  /// Whether the initial index build is deferred until the first write.
  ///
  /// When `false` (default), the index is built lazily on the first query.
  final bool lazy;
}
