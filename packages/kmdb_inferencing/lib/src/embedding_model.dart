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

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_lexical/lexical.dart' show Tokenizer;
import 'package:path/path.dart' as p;

import 'bert_tokenizer.dart';
import 'math_utils.dart';
import 'ort_library.dart';
import 'ort_session.dart';

/// ONNX Runtime-backed embedding model for KMDB semantic search.
///
/// Implements [EmbeddingModel] using the **BGE Small En v1.5** model via the
/// ONNX Runtime C API. Produces 384-dimensional L2-normalised float32
/// embeddings suitable for cosine similarity search.
///
/// ## Model file
///
/// The model binary (`bge_small.onnx`, ~127 MB) and vocabulary (`vocab.txt`)
/// are bundled in `packages/kmdb_inferencing/assets/models/bge-small-en/`
/// and tracked via Git LFS. They must be present on disk before calling
/// [load]; the method throws [UnsupportedError] if the file is absent.
///
/// ## Usage
///
/// ```dart
/// final model = await OnnxEmbeddingModel.load();
/// try {
///   final (embedding, truncated) = await model.embed('semantic search');
///   // embedding is a 384-element Float32List
/// } finally {
///   model.dispose();
/// }
/// ```
///
/// ## Lifecycle
///
/// [load] opens the native ORT session (~127 MB cold load). [embed] runs
/// synchronously on the calling isolate — do **not** call from the UI thread
/// in Flutter without isolate offloading. [dispose] releases native resources;
/// always call it (use `try/finally`).
///
/// ## Thread safety
///
/// ORT sessions are thread-affine. All [embed] and [dispose] calls must come
/// from the same isolate that called [load].
class OnnxEmbeddingModel implements EmbeddingModel {
  /// Internal constructor — use [load].
  OnnxEmbeddingModel._(this._session, this._tokenizer);

  final OrtInferenceSession _session;
  final BertTokenizer _tokenizer;

  /// Loads the BGE Small En v1.5 model from [modelPath].
  ///
  /// If [modelPath] is `null`, the model is looked up from the default assets
  /// directory relative to the compiled executable:
  /// `<executableDir>/assets/models/bge-small-en/bge_small.onnx`.
  ///
  /// [tokenizer] overrides the word-segmentation step inside
  /// [BertTokenizer]. Defaults to [RegExpTokenizer]. Supply `IcuTokenizer()`
  /// from `package:kmdb_tokenizer_icu` for superior Unicode coverage.
  ///
  /// Throws [UnsupportedError] if [modelPath] (or the default path) does not
  /// exist on disk.
  ///
  /// Throws [Exception] if the ONNX Runtime library cannot be loaded or the
  /// model file is corrupt.
  static Future<OnnxEmbeddingModel> load({
    String? modelPath,
    Tokenizer? tokenizer,
  }) async {
    final resolvedModelPath = modelPath ?? _defaultModelPath();
    _assertModelExists(resolvedModelPath);

    final vocabPath = p.join(p.dirname(resolvedModelPath), 'vocab.txt');
    _assertFileExists(vocabPath, 'vocab.txt');

    final lib = await openOrtLibrary();
    final session = OrtInferenceSession.create(lib, resolvedModelPath);
    final tok = await BertTokenizer.load(vocabPath, tokenizer: tokenizer);
    return OnnxEmbeddingModel._(session, tok);
  }

  /// Embeds [text] into a 384-dimensional L2-normalised float32 vector.
  ///
  /// Runs synchronously on the calling isolate. For large batches or UI
  /// applications, wrap calls in [Isolate.run] — but note that ORT sessions
  /// are thread-affine, so the session must be created inside the same isolate
  /// that calls [embed].
  ///
  /// An empty or whitespace-only [text] produces a `[CLS][SEP]`-only
  /// embedding (two real tokens) and returns `truncated = false`.
  ///
  /// Returns `(embedding, truncated)`:
  /// - [embedding] — 384-element [Float32List] with unit L2 norm.
  /// - [truncated] — `true` if [text] exceeded 510 usable BERT tokens and
  ///   was silently cut before embedding.
  @override
  Future<(Float32List, bool)> embed(String text) async {
    final tokens = _tokenizer.encode(text);
    final seqLen = tokens.inputIds.length;

    // Run ONNX inference. Output shape: [1, seqLen, 384].
    final raw = _session.run(
      inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
      inputData: [tokens.inputIds, tokens.attentionMask, tokens.tokenTypeIds],
      inputShape: [1, seqLen],
      outputName: 'last_hidden_state',
    );

    // Mean-pool over non-padding token positions, then L2-normalise.
    final pooled = meanPool(raw, tokens.attentionMask.toList(), seqLen: seqLen);
    final embedding = l2Normalize(pooled);

    return (embedding, tokens.truncated);
  }

  /// Releases the native ORT session and associated resources.
  ///
  /// Must be called exactly once when the model is no longer needed.
  /// After [dispose], [embed] must not be called.
  @override
  void dispose() => _session.dispose();

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Returns the default model path relative to the compiled executable.
  static String _defaultModelPath() {
    final execDir = File(Platform.resolvedExecutable).parent.path;
    return p.join(
      execDir,
      'assets',
      'models',
      'bge-small-en',
      'bge_small.onnx',
    );
  }

  static void _assertModelExists(String path) {
    if (!File(path).existsSync()) {
      throw UnsupportedError(
        'BGE model file not found at: $path\n'
        'Ensure the model assets are bundled with your application. '
        'See packages/kmdb_inferencing/assets/models/bge-small-en/',
      );
    }
  }

  static void _assertFileExists(String path, String label) {
    if (!File(path).existsSync()) {
      throw UnsupportedError(
        '$label not found at: $path\n'
        'Ensure all model assets are present in the bge-small-en/ directory.',
      );
    }
  }
}
