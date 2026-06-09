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

/// ONNX Runtime inference for KMDB semantic search.
///
/// Provides [OnnxEmbeddingModel] (implements [EmbeddingModel]) backed by the
/// BGE Small En v1.5 model via the `betto_onnxrt` [OnnxRuntime] API, a
/// [BertTokenizer] for BERT WordPiece tokenisation, [quantise]/[dequantise]
/// helpers for SQ8 vector quantisation, and a [ModelCatalog] of supported
/// models with download-on-demand via [ModelDownloader] from `betto_onnxrt`.
///
/// ## Platform support
///
/// This package is **native-only** (macOS, Linux, Windows, Android). It must
/// not be imported on the web platform.
///
/// ## ORT binary acquisition
///
/// The ONNX Runtime shared library is staged at build time by the
/// `betto_onnxrt` native-assets build hook (`hook/build.dart` in the
/// `betto_onnxrt` package). The hook downloads and SHA-256-verifies the
/// platform-appropriate ORT binary from the official Microsoft ORT GitHub
/// Releases. On Android the `.so` is bundled by the build system.
///
/// This replaces the old runtime-download approach in `ort_library.dart`.
library;

// Re-export betto_onnxrt types that callers of kmdb_inferencing need directly.
// ModelSpec, ModelFile, ModelDownloader, ResolvedModel, and DownloadProgress
// are part of the stable public surface of this package.
export 'package:betto_onnxrt/betto_onnxrt.dart'
    show DownloadProgress, ModelDownloader, ModelFile, ModelSpec, ResolvedModel;

export 'src/bert_tokenizer.dart' show BertTokenizer, TokenizerOutput;
export 'src/embedding_model.dart' show OnnxEmbeddingModel;
export 'src/model_catalog.dart' show ModelCatalog;
export 'src/sq8.dart' show quantise, dequantise;
