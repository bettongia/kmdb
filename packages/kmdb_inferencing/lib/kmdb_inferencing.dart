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

/// ONNX Runtime inference for KMDB semantic search.
///
/// Provides [OnnxEmbeddingModel], which implements the [EmbeddingModel]
/// interface using the BGE Small En v1.5 model via the ONNX Runtime C API.
///
/// This package is a scaffold — plan 3 (semantic search) adds the full FFI
/// implementation. For now, constructing [OnnxEmbeddingModel] throws
/// [UnimplementedError].
///
/// ## Platform support
///
/// This package is native-only. It must not be used on the web platform.
///
/// ## FFI dependency
///
/// The ONNX Runtime shared library must be available on the target platform.
/// Plan 3 will add the native build hooks and bundling configuration.
library;

export 'src/embedding_model.dart' show OnnxEmbeddingModel;
