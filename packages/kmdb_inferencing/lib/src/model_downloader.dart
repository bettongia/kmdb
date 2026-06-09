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

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model_spec.dart';

/// Callback invoked during file downloads to report progress.
///
/// [received] is the number of bytes downloaded so far.
/// [total] is the expected total size in bytes (`-1` if the server did not
/// provide a `Content-Length` header and the total is unknown).
typedef DownloadProgressCallback = void Function(int received, int total);

/// Downloads and verifies embedding model files for a [ModelSpec].
///
/// [ModelDownloader] manages a local cache directory. For each required file
/// it:
///
/// 1. Checks whether the file is already present and its SHA-256 checksum
///    matches the [ModelSpec]. If so, the download is skipped (fast path).
/// 2. Downloads the file from the HTTPS URL to a temporary path in the same
///    directory (e.g. `{name}.onnx.part`).
/// 3. Verifies the SHA-256 checksum of the downloaded data against the
///    [ModelSpec]. If the checksum does not match, the partial file is deleted
///    and [StateError] is thrown.
/// 4. Atomically renames the verified temporary file to the final path.
///
/// ## Crash safety
///
/// Writes go through a temp-file + atomic rename so a partial or interrupted
/// download never passes the existence-and-checksum check on a later run. A
/// leftover `.part` file is silently overwritten on the next download attempt.
///
/// ## Concurrency
///
/// For concurrent CLI invocations sharing the same `~/.kmdb_cache` directory,
/// **no locking is needed**: last-writer-wins on the atomic rename is
/// acceptable because both writers produce byte-identical, checksum-verified
/// output.
///
/// ## Platform
///
/// This class is **native-only** (`dart:io`). Web callers must not use it;
/// semantic search is excluded from the web browser by design (see §20).
///
/// ## Usage
///
/// ```dart
/// final downloader = ModelDownloader(cacheDir: '/path/to/cache');
/// final paths = await downloader.ensure(
///   spec: ModelCatalog.lookup('bge-small-en-v1.5'),
///   onProgress: (received, total) {
///     stderr.writeln('Downloading: $received / $total bytes');
///   },
/// );
/// final model = await OnnxEmbeddingModel.load(
///   modelPath: paths.onnxPath,
///   vocabPath: paths.vocabPath,
/// );
/// ```
final class ModelDownloader {
  /// Creates a [ModelDownloader] that caches files under [_cacheDir].
  ///
  /// [_cacheDir] is created lazily on the first download. Subsequent calls
  /// that find all files present and checksummed skip the directory creation.
  ///
  /// [httpClientFactory] is an optional override for the [HttpClient] used
  /// during downloads. Defaults to `HttpClient()`. Inject a custom factory in
  /// tests to return a mock HTTP client without hitting the network.
  ModelDownloader({
    required this._cacheDir,
    HttpClient Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final String _cacheDir;
  final HttpClient Function() _httpClientFactory;

  /// Ensures the model files for [spec] are present and valid in the cache.
  ///
  /// Returns [ModelPaths] pointing to the local ONNX and vocab files once they
  /// are verified. If either file is absent or fails checksum verification, the
  /// downloader fetches it from its URL in [spec].
  ///
  /// [onProgress] is called with incremental byte counts during each file
  /// download. It is not called for files that were already cached.
  ///
  /// Throws [StateError] if a downloaded file fails SHA-256 verification.
  /// Throws [HttpException] if the server returns a non-2xx status for either
  /// file URL.
  Future<ModelPaths> ensure(
    ModelSpec spec, {
    DownloadProgressCallback? onProgress,
  }) async {
    // Create the model-specific subdirectory inside the cache dir.
    // Using the model ID as the subdirectory name keeps each model isolated.
    final modelDir = Directory(p.join(_cacheDir, spec.id));

    final onnxFile = File(p.join(modelDir.path, 'model.onnx'));
    final vocabFile = File(p.join(modelDir.path, 'vocab.txt'));

    // Download each file only if absent or checksum-invalid.
    if (!_isValid(onnxFile, spec.onnxSha256)) {
      await modelDir.create(recursive: true);
      await _download(
        url: spec.onnxUrl,
        dest: onnxFile,
        expectedSha256: spec.onnxSha256,
        onProgress: onProgress,
      );
    }

    if (!_isValid(vocabFile, spec.vocabSha256)) {
      await modelDir.create(recursive: true);
      await _download(
        url: spec.vocabUrl,
        dest: vocabFile,
        expectedSha256: spec.vocabSha256,
        onProgress: onProgress,
      );
    }

    return ModelPaths(onnxPath: onnxFile.path, vocabPath: vocabFile.path);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Returns `true` if [file] exists and its SHA-256 digest matches
  /// [expectedHex].
  bool _isValid(File file, String expectedHex) {
    if (!file.existsSync()) return false;
    try {
      final bytes = file.readAsBytesSync();
      final digest = sha256.convert(bytes);
      return digest.toString() == expectedHex;
    } catch (_) {
      return false;
    }
  }

  /// Downloads [url] to a temp file alongside [dest], verifies the SHA-256,
  /// and atomically renames the temp file to [dest] on success.
  ///
  /// The temp file has a `.part` suffix. If a `.part` file is left from a
  /// prior interrupted download it is overwritten silently.
  ///
  /// Throws [StateError] if the downloaded data does not match
  /// [expectedSha256]. Throws [HttpException] on non-2xx responses.
  Future<void> _download({
    required String url,
    required File dest,
    required String expectedSha256,
    DownloadProgressCallback? onProgress,
  }) async {
    // Use a .part suffix so a partial download never passes the existence+
    // checksum check. If a leftover .part exists it is simply overwritten.
    final tempFile = File('${dest.path}.part');

    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}: $url',
          uri: uri,
        );
      }

      // Stream the response body to the temp file, computing SHA-256 on the
      // fly so we only need a single read pass over the data.
      final totalBytes = response.headers.contentLength < 0
          ? -1
          : response.headers.contentLength;
      var receivedBytes = 0;

      final sink = tempFile.openWrite();
      final accumulator = BytesBuilder(copy: false);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          accumulator.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // Verify checksum of the downloaded data (in memory).
      final allBytes = accumulator.toBytes();
      final digest = sha256.convert(allBytes);
      if (digest.toString() != expectedSha256) {
        // Delete the corrupt temp file and abort.
        // Ignore deletion errors — the file may already be absent.
        await tempFile.delete().catchError((_) => tempFile);
        throw StateError(
          'SHA-256 checksum mismatch for ${dest.path}.\n'
          '  Expected : $expectedSha256\n'
          '  Got      : ${digest.toString()}\n'
          'The download may be corrupt. Please retry.',
        );
      }

      // Checksum verified — atomically rename the temp file to the final path.
      await tempFile.rename(dest.path);
    } finally {
      client.close();
    }
  }
}

/// Resolved local file paths for a downloaded embedding model.
///
/// Returned by [ModelDownloader.ensure] once all model files are present and
/// verified. Pass [onnxPath] and [vocabPath] to [OnnxEmbeddingModel.load].
final class ModelPaths {
  /// Creates a [ModelPaths] record.
  const ModelPaths({required this.onnxPath, required this.vocabPath});

  /// Absolute path to the ONNX model binary (`.onnx`).
  final String onnxPath;

  /// Absolute path to the vocabulary file (`vocab.txt`).
  final String vocabPath;
}
