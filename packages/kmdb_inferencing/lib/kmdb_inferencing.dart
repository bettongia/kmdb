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
/// BGE Small En v1.5 model via the ONNX Runtime C API, a [BertTokenizer]
/// for BERT WordPiece tokenisation, [quantise]/[dequantise] helpers for
/// SQ8 vector quantisation, and a [ModelCatalog] of supported models
/// with their [ModelSpec]s and download-on-demand via [ModelDownloader].
///
/// ## Platform support
///
/// This package is **native-only** (macOS, Linux, Windows, Android). It must
/// not be imported on the web platform.
///
/// ## FFI dependency
///
/// The ONNX Runtime shared library is downloaded automatically on first use
/// by [openOrtLibrary] and cached next to the compiled executable. On Android
/// the `.so` is bundled by Gradle.
library;

export 'src/bert_tokenizer.dart' show BertTokenizer, TokenizerOutput;
export 'src/embedding_model.dart' show OnnxEmbeddingModel;
export 'src/model_catalog.dart' show ModelCatalog;
export 'src/model_downloader.dart'
    show ModelDownloader, ModelPaths, DownloadProgressCallback;
export 'src/model_spec.dart' show ModelSpec;
export 'src/sq8.dart' show quantise, dequantise;
