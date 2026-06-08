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

import 'dart:typed_data';

/// Abstract interface for text-to-vector embedding models.
///
/// Allows `VecManager` in `kmdb` to accept an embedding model without taking a
/// dependency on the FFI-heavy `kmdb_inferencing` package. The concrete
/// implementation (`OnnxEmbeddingModel`) lives in `kmdb_inferencing` and
/// implements this interface.
///
/// ## Usage
///
/// Supply an [EmbeddingModel] to [KmdbDatabase.open] when configuring vector
/// indexes:
///
/// ```dart
/// final model = await OnnxEmbeddingModel.load(
///   spec: ModelCatalog.lookup('bge-small-en-v1.5'),
///   cacheDir: '/path/to/cache',
/// );
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
///   embeddingModel: model,
/// );
/// ```
///
/// ## Contract
///
/// - [embed] is called once per document field during indexing and once per
///   query. Implementations must be safe to call from the main isolate.
/// - The returned [Float32List] must have exactly [dimensions] elements.
/// - If [text] is longer than the model's context window, the implementation
///   truncates and sets `truncated = true` in the returned record.
/// - Implementations must not throw on empty [text]; they should return a
///   zero vector and `truncated = false`.
abstract interface class EmbeddingModel {
  /// Stable identifier of the model that produced these embeddings.
  ///
  /// Matches a `ModelCatalog` entry id (e.g. `bge-small-en-v1.5`). Persisted
  /// with each `$vec:` index so a later model swap can be detected and the
  /// index rebuilt.
  ///
  /// Must be non-empty and stable across process restarts. Must not change
  /// after the model is loaded.
  String get modelId;

  /// Embedding vector length produced by this model.
  ///
  /// The single source of truth for SQ8 byte lengths and score-path length
  /// guards in [VecManager]. For example, 384 for BGE Small En v1.5 and 1024
  /// for BGE-M3.
  ///
  /// Must equal `embedding.length` for every [embedding] returned by [embed].
  int get dimensions;

  /// Embeds [text] into a dense float vector.
  ///
  /// Returns a record `(embedding, truncated)` where:
  /// - [embedding] is the float32 embedding vector with exactly [dimensions]
  ///   elements.
  /// - [truncated] is `true` if [text] exceeded the model's context window and
  ///   was silently truncated before embedding.
  Future<(Float32List embedding, bool truncated)> embed(String text);

  /// Releases any native resources held by this model.
  ///
  /// Called by [KmdbDatabase.close] after all other cleanup. Implementations
  /// backed by native libraries (e.g. ONNX Runtime) must release their session
  /// handle here. Pure-Dart implementations may leave this as a no-op.
  ///
  /// After [dispose] is called, [embed] must not be called.
  void dispose();
}
