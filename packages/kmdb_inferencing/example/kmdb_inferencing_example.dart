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

// ignore_for_file: avoid_print

import 'package:kmdb_inferencing/kmdb_inferencing.dart';

/// Example demonstrating [OnnxEmbeddingModel] usage (once implemented).
///
/// This example will work after plan 3 (semantic search) completes the
/// ONNX Runtime FFI integration. For now, [OnnxEmbeddingModel.load] throws
/// [UnimplementedError].
Future<void> main() async {
  try {
    final model = await OnnxEmbeddingModel.load();
    final (embedding, truncated) = await model.embed('hello world');
    print('Embedding dimensions: ${embedding.length}');
    print('Truncated: $truncated');
  } on UnimplementedError catch (e) {
    print('Not yet implemented: $e');
  }
}
