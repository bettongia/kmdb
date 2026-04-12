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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

/// ONNX Runtime-backed embedding model for KMDB semantic search (stub).
///
/// Implements [EmbeddingModel] using the BGE Small En v1.5 model via the ONNX
/// Runtime C API. This stub is a placeholder — plan 3 (semantic search)
/// replaces it with a full FFI-backed implementation.
///
/// ## Model
///
/// BGE Small En v1.5 produces 384-dimensional float32 embeddings. The model
/// file (`model.onnx`) is tracked in Git LFS at:
/// ```
/// packages/kmdb_inferencing/assets/models/bge-small-en/model.onnx
/// ```
///
/// ## Usage (once implemented)
///
/// ```dart
/// final model = await OnnxEmbeddingModel.load();
/// final (embedding, truncated) = await model.embed('hello world');
/// ```
class OnnxEmbeddingModel implements EmbeddingModel {
  /// Internal constructor — use [load] to create an instance.
  const OnnxEmbeddingModel._();

  /// Loads the BGE Small En v1.5 model and initialises the ONNX Runtime
  /// session (stub).
  ///
  /// Throws [UnimplementedError] in this stub. Plan 3 replaces this with a
  /// real implementation that:
  /// 1. Locates the `model.onnx` file relative to the package root.
  /// 2. Opens an [OrtSession] from the model file.
  /// 3. Returns a fully initialised [OnnxEmbeddingModel].
  static Future<OnnxEmbeddingModel> load() async {
    throw UnimplementedError(
      'OnnxEmbeddingModel.load() is not yet implemented. '
      'The ONNX Runtime FFI bindings and BGE model integration will be '
      'added in plan 3 (semantic search).',
    );
  }

  @override
  Future<(Float32List, bool)> embed(String text) async {
    throw UnimplementedError(
      'OnnxEmbeddingModel.embed() is not yet implemented. '
      'This stub will be replaced in plan 3 (semantic search).',
    );
  }
}
