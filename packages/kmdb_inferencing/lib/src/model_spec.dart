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

/// Specification for a downloadable embedding model.
///
/// A [ModelSpec] is the single source of truth for all properties of a
/// supported embedding model: its stable identifier, embedding dimension,
/// download URLs, and SHA-256 checksums for integrity verification.
///
/// Model specs are stored in [ModelCatalog] and referenced by [id] throughout
/// the system. The [id] is persisted in [VecIndexState] so that a model change
/// can be detected and stale indexes rebuilt.
///
/// ## Example
///
/// ```dart
/// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
/// print(spec.embeddingDimensions); // 384
/// ```
final class ModelSpec {
  /// Creates a [ModelSpec].
  const ModelSpec({
    required this.id,
    required this.embeddingDimensions,
    required this.onnxUrl,
    required this.vocabUrl,
    required this.onnxSha256,
    required this.vocabSha256,
    this.isValidated = true,
  });

  /// Stable identifier for this model.
  ///
  /// Referenced throughout the system (persisted in [VecIndexState], used in
  /// [EmbeddingModel.modelId], and stored in `local/config.json`). Must match
  /// the corresponding [ModelCatalog] key.
  ///
  /// Examples: `bge-small-en-v1.5`, `bge-m3-v1.0`
  final String id;

  /// Number of dimensions in the embedding vector produced by this model.
  ///
  /// This is the single source of truth for SQ8 byte lengths and score-path
  /// length guards. For example, BGE Small En v1.5 produces 384-dimensional
  /// vectors; BGE-M3 produces 1024-dimensional vectors.
  ///
  /// The SQ8-encoded byte length equals this value (1 byte per component).
  final int embeddingDimensions;

  /// HTTPS URL for the ONNX model binary (`.onnx` file).
  ///
  /// Downloaded by [ModelDownloader] when the model is not already cached.
  /// The SHA-256 checksum [onnxSha256] is verified after download.
  final String onnxUrl;

  /// HTTPS URL for the vocabulary file (`vocab.txt`).
  ///
  /// Required by [BertTokenizer]. Downloaded alongside the ONNX binary.
  /// The SHA-256 checksum [vocabSha256] is verified after download.
  final String vocabUrl;

  /// Lowercase hex SHA-256 digest of the ONNX binary at [onnxUrl].
  ///
  /// Used by [ModelDownloader] to verify download integrity. A mismatch
  /// triggers a delete-and-retry.
  final String onnxSha256;

  /// Lowercase hex SHA-256 digest of the vocabulary file at [vocabUrl].
  ///
  /// Used by [ModelDownloader] to verify download integrity. A mismatch
  /// triggers a delete-and-retry.
  final String vocabSha256;

  /// Whether this model is fully tested and safe to use in production.
  ///
  /// Models registered in [ModelCatalog] but not yet validated
  /// (e.g. BGE-M3 in v0.07) have `isValidated = false`. Attempting to load an
  /// unvalidated model throws [UnsupportedError] via [ModelCatalog.lookup].
  final bool isValidated;
}
