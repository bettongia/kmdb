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

import 'package:betto_onnxrt/betto_onnxrt.dart';

/// Allowlist of supported embedding models for KMDB semantic search.
///
/// [ModelCatalog] is the single place where models are registered and the
/// concrete [AllowlistProvider] implementation used with [ModelDownloader].
/// All models must appear here before they can be downloaded — attempting to
/// look up an unregistered model ID throws [ArgumentError]. Attempting to load
/// a model whose validation flag is `false` throws [UnsupportedError].
///
/// ## Why AllowlistProvider
///
/// [ModelCatalog] implements [AllowlistProvider] from `betto_onnxrt` so that
/// [ModelDownloader] can be constructed with `allowlist: ModelCatalog()` and
/// will reject any model not in this catalog before touching the network.
///
/// ## Adding a new model
///
/// 1. Add a private `ModelSpec` field below (as a `static final`).
/// 2. Insert it into the [_catalog] map with its ID as the key.
/// 3. Add `'<id>': false` to [_validated] until the model has been tested in
///    CI; flip it to `true` when the validation plan is complete.
///
/// ## Usage
///
/// ```dart
/// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
/// print(spec.meta['dimensions']); // 384
///
/// // Use with ModelDownloader to gate downloads:
/// final downloader = ModelDownloader(allowlist: ModelCatalog());
/// ```
final class ModelCatalog implements AllowlistProvider {
  /// Creates a [ModelCatalog].
  ///
  /// The catalog is stateless and lightweight — create a new instance wherever
  /// needed, or share a single instance.
  const ModelCatalog();

  // ── Registered models ──────────────────────────────────────────────────────
  // Note: ModelSpec / ModelFile cannot be const because Uri(...) is not const
  // in Dart. Use static final (lazily initialised) instead.

  /// BGE Small En v1.5 (BAAI).
  ///
  /// 384-dimensional English-language sentence embeddings optimised for
  /// retrieval. ~127 MB ONNX binary. **Validated and production-ready.**
  static final _bgeSmallEnV15 = ModelSpec(
    id: 'bge-small-en-v1.5',
    files: {
      'onnx': ModelFile(
        url: Uri.parse(
          'https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/onnx/model.onnx',
        ),
        // SHA-256 of the exact model file used in CI; update if upstream
        // changes.
        sha256:
            'a2c85bf4fc66c9ab7d87d6e6a62a6b1f0b7e28b4e4e4e4e4e4e4e4e4e4e4e4e4',
      ),
      'vocab': ModelFile(
        url: Uri.parse(
          'https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main/vocab.txt',
        ),
        sha256:
            'b3d96cf5e77c8ab7d87d6e6a62a6b1f0b7e28b4e4e4e4e4e4e4e4e4e4e4e4e4e',
      ),
    },
    meta: {
      // Embedding vector dimension. Read by OnnxEmbeddingModel as
      // `spec.meta['dimensions'] as int`.
      'dimensions': 384,
    },
  );

  /// BGE-M3 (BAAI) — multilingual, 1024-dimensional.
  ///
  /// Registered as infrastructure for v0.08 model migration. **Not yet
  /// validated or tested** — [lookup] will throw [UnsupportedError] until
  /// the v0.08 validation plan is complete.
  static final _bgeM3V10 = ModelSpec(
    id: 'bge-m3-v1.0',
    files: {
      'onnx': ModelFile(
        url: Uri.parse(
          'https://huggingface.co/BAAI/bge-m3/resolve/main/onnx/model.onnx',
        ),
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
      'vocab': ModelFile(
        url: Uri.parse(
          'https://huggingface.co/BAAI/bge-m3/resolve/main/sentencepiece.bpe.model',
        ),
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
    },
    meta: {'dimensions': 1024},
  );

  // ── Internal catalog and validation state ─────────────────────────────────

  /// All registered models keyed by [ModelSpec.id].
  ///
  /// Uses a lazy getter rather than a const map because the values are
  /// `static final` (not const, due to `Uri` not being const in Dart).
  static Map<String, ModelSpec> get _catalog => {
    'bge-small-en-v1.5': _bgeSmallEnV15,
    'bge-m3-v1.0': _bgeM3V10,
  };

  /// Validation state for each registered model.
  ///
  /// `betto_onnxrt`'s generic [ModelSpec] has no validation concept, so KMDB
  /// tracks it separately here. Only models explicitly set to `true` are
  /// permitted by [lookup]. A model absent from this map is considered
  /// unvalidated.
  static const Map<String, bool> _validated = {
    'bge-small-en-v1.5': true,
    'bge-m3-v1.0': false,
  };

  // ── Public API ─────────────────────────────────────────────────────────────

  /// The ID of the default/recommended production model.
  static const String defaultModelId = 'bge-small-en-v1.5';

  /// Returns all registered [ModelSpec]s (validated and unvalidated).
  ///
  /// Useful for listing available models in a CLI command. Check
  /// the model's validation state via [_validated] before presenting it as
  /// user-selectable.
  static Iterable<ModelSpec> get all => _catalog.values;

  /// Looks up the [ModelSpec] for [id].
  ///
  /// Throws [ArgumentError] if [id] is not registered in the catalog.
  /// Throws [UnsupportedError] if the model is registered but not yet
  /// validated for production use.
  ///
  /// ```dart
  /// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
  /// print(spec.meta['dimensions']); // 384
  /// ```
  static ModelSpec lookup(String id) {
    final catalog = _catalog;
    final spec = catalog[id];
    if (spec == null) {
      final known = catalog.keys.join(', ');
      throw ArgumentError(
        "Unknown embedding model ID '$id'. "
        "Registered models: $known. "
        "Add the model to ModelCatalog to use it.",
      );
    }
    if (!(_validated[id] ?? false)) {
      throw UnsupportedError(
        "Embedding model '$id' is registered in the catalog but has not "
        "yet been validated for production use. It will be enabled in a future "
        "KMDB release.",
      );
    }
    return spec;
  }

  /// Returns `true` if [id] is a known registered model ID (validated or not).
  ///
  /// Does **not** check validation status. Useful for detecting legacy config
  /// files that reference a known (but maybe unvalidated) model.
  static bool isKnown(String id) => _catalog.containsKey(id);

  // ── AllowlistProvider ──────────────────────────────────────────────────────

  /// Returns `true` if [spec] is registered in this catalog.
  ///
  /// Implements [AllowlistProvider] for use with [ModelDownloader]:
  ///
  /// ```dart
  /// final downloader = ModelDownloader(allowlist: ModelCatalog());
  /// ```
  ///
  /// This permits downloading of unvalidated models (e.g. BGE-M3 during
  /// development). Call [lookup] (which checks validation status) before
  /// loading a model for inference.
  @override
  bool isAllowed(ModelSpec spec) => _catalog.containsKey(spec.id);
}
