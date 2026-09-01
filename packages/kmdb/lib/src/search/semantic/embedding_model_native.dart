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

/// Native `EmbeddingModel`/`EmbeddingKind` surface — a **re-export** (not a
/// redeclaration) of `package:betto_inferencing`'s types.
///
/// This must stay a re-export: preserving type *identity* is the single most
/// important correctness constraint of the `embedding_model.dart` seam. A
/// concrete implementation such as `OnnxEmbeddingModel` implements
/// `betto_inferencing`'s `EmbeddingModel`; if this file redeclared a new
/// `EmbeddingModel` type instead of re-exporting the original, an
/// `OnnxEmbeddingModel` instance would no longer satisfy
/// `KmdbDatabase.open(embeddingModel: ...)`'s signature on native — a
/// silent, compile-time-invisible break (see the dedicated type-identity
/// regression test in `test/query/embedding_model_seam_test.dart`).
library;

export 'package:betto_inferencing/betto_inferencing.dart'
    show EmbeddingModel, EmbeddingKind;

/// Whether a concrete [EmbeddingModel] can be constructed on this platform.
///
/// `true` here (native, backed by ONNX Runtime via FFI). The web
/// counterpart (`embedding_model_stub.dart`) sets this `false`: semantic
/// search is compiled out on web (see `docs/spec/22_semantic_search.md`),
/// and `KmdbDatabase.open` uses this flag to fail fast and explicitly (an
/// `UnsupportedError`) rather than silently permitting an unreachable
/// vector-index configuration.
const bool kSemanticSearchAvailable = true;
