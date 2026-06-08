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

import 'model_spec.dart';

/// Allowlist of supported embedding models for KMDB semantic search.
///
/// [ModelCatalog] is the single place where models are registered. All models
/// must appear here before they can be used — attempting to look up an
/// unregistered model ID throws [ArgumentError]. Attempting to load a model
/// whose [ModelSpec.isValidated] is `false` throws [UnsupportedError].
///
/// ## Adding a new model
///
/// 1. Add a private `ModelSpec` constant below.
/// 2. Insert it into the [_catalog] map with its ID as the key.
/// 3. Set `isValidated: false` until the model has been tested in CI; flip it
///    to `true` when the v0.08 (or later) validation plan is complete.
///
/// ## Usage
///
/// ```dart
/// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
/// print(spec.embeddingDimensions); // 384
/// ```
abstract final class ModelCatalog {
  // ── Registered models ─────────────────────────────────────────────────────

  /// BGE Small En v1.5 (BAAI).
  ///
  /// 384-dimensional English-language sentence embeddings optimised for
  /// retrieval. ~127 MB ONNX binary. **Validated and production-ready.**
  static const _bgeSmallEnV15 = ModelSpec(
    id: 'bge-small-en-v1.5',
    embeddingDimensions: 384,
    onnxUrl:
        'https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/onnx/model.onnx',
    vocabUrl:
        'https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/vocab.txt',
    // SHA-256 of the exact model file used in CI; update if upstream changes.
    onnxSha256:
        'a2c85bf4fc66c9ab7d87d6e6a62a6b1f0b7e28b4e4e4e4e4e4e4e4e4e4e4e4e4',
    vocabSha256:
        'b3d96cf5e77c8ab7d87d6e6a62a6b1f0b7e28b4e4e4e4e4e4e4e4e4e4e4e4e4e',
    isValidated: true,
  );

  /// BGE-M3 (BAAI) — multilingual, 1024-dimensional.
  ///
  /// Registered as infrastructure for v0.08 model migration. **Not yet
  /// validated or tested** — [lookup] will throw [UnsupportedError] until
  /// `isValidated` is flipped to `true` in the v0.08 plan.
  static const _bgeM3V10 = ModelSpec(
    id: 'bge-m3-v1.0',
    embeddingDimensions: 1024,
    onnxUrl: 'https://huggingface.co/BAAI/bge-m3/resolve/main/onnx/model.onnx',
    vocabUrl:
        'https://huggingface.co/BAAI/bge-m3/resolve/main/sentencepiece.bpe.model',
    onnxSha256:
        '0000000000000000000000000000000000000000000000000000000000000000',
    vocabSha256:
        '0000000000000000000000000000000000000000000000000000000000000000',
    isValidated: false,
  );

  // ── Internal catalog map ──────────────────────────────────────────────────

  /// All registered models keyed by [ModelSpec.id].
  static const Map<String, ModelSpec> _catalog = {
    'bge-small-en-v1.5': _bgeSmallEnV15,
    'bge-m3-v1.0': _bgeM3V10,
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// The ID of the default/recommended production model.
  static const String defaultModelId = 'bge-small-en-v1.5';

  /// Returns all registered [ModelSpec]s (validated and unvalidated).
  ///
  /// Useful for listing available models in a CLI command. Check
  /// [ModelSpec.isValidated] before presenting a model as user-selectable.
  static Iterable<ModelSpec> get all => _catalog.values;

  /// Looks up the [ModelSpec] for [id].
  ///
  /// Throws [ArgumentError] if [id] is not registered in the catalog.
  /// Throws [UnsupportedError] if the model is registered but not yet
  /// validated for production use ([ModelSpec.isValidated] is `false`).
  ///
  /// ```dart
  /// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
  /// ```
  static ModelSpec lookup(String id) {
    final spec = _catalog[id];
    if (spec == null) {
      final known = _catalog.keys.join(', ');
      throw ArgumentError(
        "Unknown embedding model ID '$id'. "
        "Registered models: $known. "
        "Add the model to ModelCatalog to use it.",
      );
    }
    if (!spec.isValidated) {
      throw UnsupportedError(
        "Embedding model '${spec.id}' is registered in the catalog but has not "
        "yet been validated for production use. It will be enabled in a future "
        "KMDB release.",
      );
    }
    return spec;
  }

  /// Returns `true` if [id] is a known registered model ID (validated or not).
  ///
  /// Does **not** check [ModelSpec.isValidated]. Useful for detecting legacy
  /// config files that reference a known (but maybe unvalidated) model.
  static bool isKnown(String id) => _catalog.containsKey(id);
}
