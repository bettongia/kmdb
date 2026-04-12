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

/// ONNX Runtime session wrapper (stub).
///
/// This class will be implemented in plan 3 (semantic search) to wrap the ONNX
/// Runtime C API via FFI. The stub exists to establish the structural
/// relationship between [OrtSession] and [OnnxEmbeddingModel] without
/// implementing the FFI bindings yet.
///
/// Plan 3 will:
/// - Load the `onnxruntime` shared library appropriate for the platform.
/// - Initialise an `OrtEnv` and `OrtSession` from a `.onnx` model file.
/// - Expose a `run()` method that accepts tokenised input tensors and returns
///   the last-hidden-state float embeddings.
class OrtSession {
  /// Stub constructor — throws [UnimplementedError].
  ///
  /// Plan 3 replaces this with a factory that loads the ONNX Runtime library
  /// and opens the model from [modelPath].
  OrtSession(String modelPath) {
    throw UnimplementedError(
      'OrtSession is not yet implemented. '
      'The ONNX Runtime FFI bindings will be added in plan 3 (semantic search).',
    );
  }
}
