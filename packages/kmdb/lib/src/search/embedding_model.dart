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
/// final model = await OnnxEmbeddingModel.load();
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
/// - The returned [Float32List] must have a fixed, model-specific length (e.g.
///   384 dimensions for BGE Small En v1.5).
/// - If [text] is longer than the model's context window, the implementation
///   truncates and sets `truncated = true` in the returned record.
/// - Implementations must not throw on empty [text]; they should return a
///   zero vector and `truncated = false`.
abstract interface class EmbeddingModel {
  /// Embeds [text] into a dense float vector.
  ///
  /// Returns a record `(embedding, truncated)` where:
  /// - [embedding] is the float32 embedding vector.
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
