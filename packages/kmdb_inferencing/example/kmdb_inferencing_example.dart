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

import 'dart:io';

import 'package:kmdb_inferencing/kmdb_inferencing.dart';

/// Example demonstrating [OnnxEmbeddingModel] usage with download-on-demand.
///
/// [OnnxEmbeddingModel.load] requires either a [modelPath] or a [cacheDir].
/// The preferred approach is to supply [cacheDir], which triggers the
/// [ModelDownloader] to fetch the BGE Small En v1.5 model on first use. On
/// subsequent runs the cached files are verified by SHA-256 and reused.
///
/// Run this example with a writable cache directory, e.g.:
///   dart run example/kmdb_inferencing_example.dart
Future<void> main() async {
  // Use a local cache directory for model files. In a real application this
  // would be a persistent app-specific directory (e.g. from path_provider).
  final cacheDir = Directory.systemTemp.createTempSync('kmdb_model_cache').path;

  try {
    // Download-on-demand: ModelDownloader fetches the model on first use and
    // caches it in cacheDir. Subsequent calls reuse the cached files.
    final model = await OnnxEmbeddingModel.load(
      cacheDir: cacheDir,
      onProgress: (received, total) {
        final pct = total > 0 ? (received * 100 ~/ total) : 0;
        print('Downloading model: $pct% ($received / $total bytes)');
      },
    );

    try {
      final (embedding, truncated) = await model.embed('hello world');
      print('Embedding dimensions: ${embedding.length}');
      print('Truncated: $truncated');
    } finally {
      model.dispose();
    }
  } on UnsupportedError catch (e) {
    // ORT is not available in this environment (e.g. iOS, or JIT without
    // native-assets build). See docs/spec/22_semantic_search.md for platform
    // support details.
    print('ORT not available: $e');
  }
}
