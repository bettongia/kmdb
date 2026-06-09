// Copyright 2026 The Authors.
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

import 'dart:io';
import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_lexical/lexical.dart' show Tokenizer;
import 'package:path/path.dart' as p;

import 'bert_tokenizer.dart';
import 'math_utils.dart';
import 'model_catalog.dart';

/// ONNX Runtime-backed embedding model for KMDB semantic search.
///
/// Implements [EmbeddingModel] using a model from [ModelCatalog] via the
/// `betto_onnxrt` [OnnxRuntime] and [OnnxSession] API. Produces L2-normalised
/// float32 embeddings suitable for cosine similarity search.
///
/// ## Model identity
///
/// [modelId] returns the stable [ModelSpec.id] of the loaded model (e.g.
/// `bge-small-en-v1.5`). This is persisted in `$meta` with each `$vec:` index
/// so that a model change can be detected and the index rebuilt.
///
/// ## Loading with download-on-demand
///
/// The preferred approach is to supply a [ModelSpec] and a [cacheDir]. If the
/// model files are already cached and their SHA-256 checksums match, they are
/// used immediately. Otherwise [ModelDownloader] fetches the files before
/// opening the ORT session:
///
/// ```dart
/// final spec = ModelCatalog.lookup('bge-small-en-v1.5');
/// final model = await OnnxEmbeddingModel.load(
///   spec: spec,
///   cacheDir: '/path/to/cache',
///   onProgress: (received, total) {
///     stderr.writeln('Downloading: $received / $total bytes');
///   },
/// );
/// ```
///
/// ## Loading from an explicit path (legacy / LFS assets)
///
/// The [modelPath] parameter loads a model from a specific filesystem path,
/// bypassing the catalog and downloader. This is retained for backward
/// compatibility with the Git LFS asset layout. Specifying [modelPath] without
/// [spec] uses [ModelCatalog.defaultModelId] for the identity.
///
/// ```dart
/// // Legacy / LFS-bundled model path:
/// final model = await OnnxEmbeddingModel.load(
///   modelPath: '<executableDir>/assets/models/bge-small-en/bge_small.onnx',
/// );
/// ```
///
/// ## Lifecycle
///
/// [load] opens the native ORT session via [OnnxRuntime.load]. [embed] runs
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
  OnnxEmbeddingModel._(
    this._runtime,
    this._session,
    this._tokenizer,
    this._spec,
  );

  final OnnxRuntime _runtime;
  final OnnxSession _session;
  final BertTokenizer _tokenizer;

  /// The [ModelSpec] of the loaded model.
  ///
  /// Provides [modelId] and [dimensions] for the [EmbeddingModel] interface.
  final ModelSpec _spec;

  // ── EmbeddingModel interface ───────────────────────────────────────────────

  /// Stable identifier of the loaded model, matching a [ModelCatalog] entry.
  ///
  /// Persisted with each `$vec:` index so a later model swap can be detected
  /// and the index rebuilt. Example: `bge-small-en-v1.5`.
  @override
  String get modelId => _spec.id;

  /// Embedding vector length produced by this model.
  ///
  /// Sourced from `spec.meta['dimensions']`. This is the single source of
  /// truth for SQ8 byte lengths and score-path length guards.
  /// Example: 384 for BGE Small En v1.5.
  @override
  int get dimensions => _spec.meta['dimensions'] as int;

  // ── Factory ────────────────────────────────────────────────────────────────

  /// Loads an embedding model and returns an [OnnxEmbeddingModel].
  ///
  /// ## Download-on-demand path (preferred)
  ///
  /// When [spec] and [cacheDir] are provided the [ModelDownloader] is invoked
  /// to ensure the model files are present and checksummed before opening the
  /// ORT session. Files already in the cache are reused without downloading.
  ///
  /// [onProgress] is forwarded to [ModelDownloader.ensure] and receives
  /// incremental download progress. It is not called when files are cached.
  ///
  /// ## Legacy explicit-path
  ///
  /// When [modelPath] is provided (and [spec] is `null`), the file at that
  /// path is loaded directly (no download, no checksum). The model identity
  /// is set to [ModelCatalog.defaultModelId]. This supports the Git LFS
  /// bundle layout used in development and the existing test suite.
  ///
  /// If [modelPath] is `null` and [spec] is `null`, the model is looked up
  /// from the default assets directory relative to the compiled executable:
  /// `<executableDir>/assets/models/bge-small-en/bge_small.onnx`.
  ///
  /// [tokenizer] overrides the word-segmentation step inside [BertTokenizer].
  /// Defaults to [RegExpTokenizer]. Supply `IcuTokenizer()` from
  /// `package:betto_icu` for superior Unicode coverage.
  ///
  /// Throws [UnsupportedError] if the model file does not exist on disk.
  /// Throws [Exception] if the ORT library cannot be loaded or the model is
  /// corrupt.
  static Future<OnnxEmbeddingModel> load({
    ModelSpec? spec,
    String? cacheDir,
    String? modelPath,
    Tokenizer? tokenizer,
    DownloadProgress? onProgress,
  }) async {
    // Resolve the model spec. When no spec is given, use the default model.
    // When a raw modelPath is supplied without a spec, we still need an id for
    // model identity tracking — use the default catalog ID.
    final resolvedSpec =
        spec ?? ModelCatalog.lookup(ModelCatalog.defaultModelId);

    final String resolvedModelPath;
    final String resolvedVocabPath;

    if (modelPath != null) {
      // Explicit path — bypass catalog and downloader.
      resolvedModelPath = modelPath;
      resolvedVocabPath = p.join(p.dirname(modelPath), 'vocab.txt');
    } else if (cacheDir != null) {
      // Download-on-demand path: let ModelDownloader ensure the files are
      // present and their checksums match before opening the ORT session.
      // The ModelCatalog allowlist gates which models may be downloaded.
      final downloader = ModelDownloader(allowlist: ModelCatalog());
      final resolved = await downloader.ensure(
        resolvedSpec,
        cacheDir: cacheDir,
        onProgress: onProgress,
      );
      // File names in ResolvedModel.filePaths match the keys in ModelSpec.files:
      // 'onnx' → absolute path to the .onnx model, 'vocab' → vocab.txt.
      resolvedModelPath = resolved.filePaths['onnx']!;
      resolvedVocabPath = resolved.filePaths['vocab']!;
    } else {
      // Default asset path (LFS bundle layout used in development).
      resolvedModelPath = _defaultModelPath();
      resolvedVocabPath = p.join(p.dirname(resolvedModelPath), 'vocab.txt');
    }

    _assertFileExists(resolvedModelPath, 'model file');
    _assertFileExists(resolvedVocabPath, 'vocab.txt');

    // Load the ORT runtime via the betto_onnxrt native-assets build hook.
    // This replaces the old ort_library.dart runtime download mechanism.
    final runtime = await OnnxRuntime.load();
    final session = runtime.createSessionFromFile(resolvedModelPath);
    final tok = await BertTokenizer.load(
      resolvedVocabPath,
      tokenizer: tokenizer,
    );
    return OnnxEmbeddingModel._(runtime, session, tok, resolvedSpec);
  }

  // ── EmbeddingModel.embed ──────────────────────────────────────────────────

  /// Embeds [text] into an L2-normalised float32 vector of [dimensions] elements.
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
  /// - [embedding] — [dimensions]-element [Float32List] with unit L2 norm.
  /// - [truncated] — `true` if [text] exceeded 510 usable BERT tokens and
  ///   was silently cut before embedding.
  @override
  Future<(Float32List, bool)> embed(String text) async {
    final tokens = _tokenizer.encode(text);
    final seqLen = tokens.inputIds.length;
    final hiddenDim = dimensions; // sourced from spec.meta['dimensions']

    // Build int64 input tensors shaped [1, seqLen].
    // The BGE model requires three inputs: input_ids, attention_mask,
    // and token_type_ids — all shaped [1, seqLen] with int64 elements.
    final shape = [1, seqLen];
    final inputIds = OnnxTensor.fromInt64(shape, tokens.inputIds);
    final attentionMask = OnnxTensor.fromInt64(shape, tokens.attentionMask);
    final tokenTypeIds = OnnxTensor.fromInt64(shape, tokens.tokenTypeIds);

    // Run ONNX inference. The output 'last_hidden_state' has shape
    // [1, seqLen, hiddenDim]. We rely on OnnxSession.run() populating
    // the shape from the native OrtValue via the output-shape-readback
    // slots (31/32/33) added in the generic betto_onnxrt API.
    final outputs = _session.run(
      inputs: {
        'input_ids': inputIds,
        'attention_mask': attentionMask,
        'token_type_ids': tokenTypeIds,
      },
      outputNames: ['last_hidden_state'],
    );
    final outputTensor = outputs.first;

    // Extract the flat float32 output. The tensor shape is [1, seqLen, D].
    // asFloat32() throws StateError if the output element type is not float32,
    // which would indicate a mismatched model.
    final raw = outputTensor.asFloat32().toList();

    // Mean-pool over non-padding token positions, then L2-normalise.
    final pooled = meanPool(
      raw,
      tokens.attentionMask.toList(),
      seqLen: seqLen,
      hiddenDim: hiddenDim,
    );
    final embedding = l2Normalize(pooled);

    return (embedding, tokens.truncated);
  }

  /// Releases the native ORT session and runtime resources.
  ///
  /// Must be called exactly once when the model is no longer needed.
  /// After [dispose], [embed] must not be called.
  @override
  void dispose() {
    _session.dispose();
    _runtime.dispose();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Returns the default model path relative to the compiled executable.
  ///
  /// Used when no [modelPath] is supplied and no [cacheDir] is provided. This
  /// corresponds to the Git LFS asset layout used in development.
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

  static void _assertFileExists(String path, String label) {
    if (!File(path).existsSync()) {
      throw UnsupportedError(
        '$label not found at: $path\n'
        'Ensure model assets are present or configure a cacheDir for '
        'download-on-demand. See ModelCatalog and ModelDownloader.',
      );
    }
  }
}
