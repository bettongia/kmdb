// Copyright 2026 The Authors
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

// coverage:ignore-file
// Web/WASM stub for `EmbeddingModel`/`EmbeddingKind`.
//
// This file exists purely so kmdb's `lib/` graph (in particular
// `VecManager`, which is present but dead code on web — see
// `KmdbDatabase.open`'s `vecIndexes`/`kSemanticSearchAvailable` guard) has a
// name to type-check against. Nothing on web ever constructs an
// [EmbeddingModel]: no concrete implementation of this interface is
// registered for web, and `KmdbDatabase.open` throws `UnsupportedError`
// before any caller-supplied instance could reach [VecManager]. Every
// member below is copied verbatim (signature-for-signature) from
// `package:betto_inferencing`'s `lib/src/embedding_model.dart` — the two
// must stay in lockstep or `VecManager` fails to compile on one platform
// or the other (guarded by the wasm barrel-compile smoke in `make
// cicd_web`).

import 'dart:typed_data';

/// Distinguishes indexing-time ("document") text from query-time ("query")
/// text passed to [EmbeddingModel.embed].
///
/// See `package:betto_inferencing`'s `EmbeddingKind` (the native
/// counterpart to this stub) for the full rationale.
enum EmbeddingKind {
  /// Text being indexed (inserted or updated) into a vector index.
  document,

  /// Text used to query a vector index for nearest neighbours.
  query,
}

/// Abstract interface for text-to-vector embedding models (web stub).
///
/// Structurally identical to `package:betto_inferencing`'s `EmbeddingModel`
/// but declared locally so this file never imports that package (which
/// transitively pulls in `dart:ffi` via `betto_onnxrt` — unavailable on
/// web/WASM). No concrete implementation of this interface is registered
/// for web in kmdb 0.1.0.
abstract interface class EmbeddingModel {
  /// Stable identifier of the model that produced these embeddings.
  String get modelId;

  /// Embedding vector length produced by this model.
  int get dimensions;

  /// Embeds [text] into a dense float vector.
  ///
  /// See `package:betto_inferencing`'s `EmbeddingModel.embed` for the full
  /// contract this signature mirrors.
  Future<(Float32List embedding, bool truncated)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  });

  /// Releases any native resources held by this model.
  void dispose();
}

/// Whether a concrete [EmbeddingModel] can be constructed on this platform.
///
/// Always `false` on web/WASM — see `embedding_model_native.dart`'s doc
/// comment for the native counterpart (`true`) and how
/// `KmdbDatabase.open` uses this flag.
const bool kSemanticSearchAvailable = false;
