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

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kmdb_inferencing/kmdb_inferencing.dart';
import 'package:test/test.dart';

// ── Mock HTTP infrastructure ─────────────────────────────────────────────────

/// Returns the SHA-256 hex string of [bytes].
String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// A minimal fake HTTP server for testing [ModelDownloader].
///
/// [responses] maps URLs to the raw byte content that should be returned
/// when that URL is requested. Set [statusCode] to a non-2xx value to
/// simulate server errors.
class _FakeHttpServer {
  _FakeHttpServer({this.statusCode = 200, Map<String, List<int>>? responses})
    : _responses = responses ?? {};

  final int statusCode;
  final Map<String, List<int>> _responses;
  final List<String> requestedUrls = [];

  HttpClient get client => _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._server);
  final _FakeHttpServer _server;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _server.requestedUrls.add(url.toString());
    return _FakeHttpClientRequest(_server, url);
  }

  @override
  void close({bool force = false}) {}

  // Unimplemented stubs — only getUrl is used by ModelDownloader.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._server, this._url);
  final _FakeHttpServer _server;
  final Uri _url;

  @override
  Future<HttpClientResponse> close() async {
    final body = _server._responses[_url.toString()] ?? <int>[];
    return _FakeHttpClientResponse(statusCode: _server.statusCode, body: body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse({required this.statusCode, required this._body});

  @override
  final int statusCode;
  final List<int> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final ctrl = StreamController<List<int>>();
    ctrl.add(_body);
    ctrl.close();
    return ctrl.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  HttpHeaders get headers => _FakeHeaders(contentLength: _body.length);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders({required this.contentLength});

  @override
  final int contentLength;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── Helper to build a ModelSpec with specific checksums ────────────────────

ModelSpec _makeSpec({
  required String id,
  required List<int> onnxBytes,
  required List<int> vocabBytes,
}) => ModelSpec(
  id: id,
  embeddingDimensions: 384,
  onnxUrl: 'https://example.com/$id/model.onnx',
  vocabUrl: 'https://example.com/$id/vocab.txt',
  onnxSha256: _sha256Hex(onnxBytes),
  vocabSha256: _sha256Hex(vocabBytes),
);

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('model_downloader_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ModelDownloader', () {
    group('successful download', () {
      test(
        'downloads onnx and vocab files and returns correct paths',
        () async {
          final onnxBytes = [1, 2, 3, 4, 5];
          final vocabBytes = [10, 20, 30];
          final spec = _makeSpec(
            id: 'test-model',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          final server = _FakeHttpServer(
            responses: {spec.onnxUrl: onnxBytes, spec.vocabUrl: vocabBytes},
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          final paths = await downloader.ensure(spec);

          expect(File(paths.onnxPath).existsSync(), isTrue);
          expect(File(paths.vocabPath).existsSync(), isTrue);
          expect(File(paths.onnxPath).readAsBytesSync(), equals(onnxBytes));
          expect(File(paths.vocabPath).readAsBytesSync(), equals(vocabBytes));
        },
      );

      test('creates model subdirectory inside cacheDir', () async {
        final onnxBytes = [1, 2];
        final vocabBytes = [3, 4];
        final spec = _makeSpec(
          id: 'test-model-v2',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        final server = _FakeHttpServer(
          responses: {spec.onnxUrl: onnxBytes, spec.vocabUrl: vocabBytes},
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec);

        // The model files should be in a subdirectory named after the model ID.
        final modelDir = Directory('${tempDir.path}/test-model-v2');
        expect(modelDir.existsSync(), isTrue);
      });

      test(
        'returns ModelPaths with correct onnx and vocab file names',
        () async {
          final onnxBytes = [10, 20, 30];
          final vocabBytes = [40, 50];
          final spec = _makeSpec(
            id: 'check-paths',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          final server = _FakeHttpServer(
            responses: {spec.onnxUrl: onnxBytes, spec.vocabUrl: vocabBytes},
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          final paths = await downloader.ensure(spec);

          expect(paths.onnxPath, endsWith('model.onnx'));
          expect(paths.vocabPath, endsWith('vocab.txt'));
        },
      );

      test('invokes progress callback during download', () async {
        final onnxBytes = List<int>.generate(1000, (i) => i % 256);
        final vocabBytes = List<int>.generate(500, (i) => i % 256);
        final spec = _makeSpec(
          id: 'progress-test',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        final server = _FakeHttpServer(
          responses: {spec.onnxUrl: onnxBytes, spec.vocabUrl: vocabBytes},
        );

        final progressCalls = <({int received, int total})>[];

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(
          spec,
          onProgress: (received, total) {
            progressCalls.add((received: received, total: total));
          },
        );

        // Progress should have been called at least once for each file.
        expect(progressCalls, isNotEmpty);
        // Final call should report all bytes received.
        expect(
          progressCalls.any((c) => c.received == onnxBytes.length),
          isTrue,
        );
      });
    });

    group('short-circuit (already cached)', () {
      test(
        'skips download when files are present with correct checksums',
        () async {
          final onnxBytes = [1, 2, 3];
          final vocabBytes = [4, 5, 6];
          final spec = _makeSpec(
            id: 'cached-model',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          // Pre-populate the cache.
          final modelDir = Directory('${tempDir.path}/cached-model');
          await modelDir.create(recursive: true);
          await File('${modelDir.path}/model.onnx').writeAsBytes(onnxBytes);
          await File('${modelDir.path}/vocab.txt').writeAsBytes(vocabBytes);

          final server = _FakeHttpServer(
            responses: {
              spec.onnxUrl: [99],
              spec.vocabUrl: [99],
            },
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          await downloader.ensure(spec);

          // Neither URL should have been requested.
          expect(server.requestedUrls, isEmpty);
        },
      );

      test('re-downloads only the missing file', () async {
        final onnxBytes = [1, 2, 3];
        final vocabBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'partial-cache',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        // Pre-populate only the onnx file.
        final modelDir = Directory('${tempDir.path}/partial-cache');
        await modelDir.create(recursive: true);
        await File('${modelDir.path}/model.onnx').writeAsBytes(onnxBytes);
        // vocab is absent.

        final server = _FakeHttpServer(
          responses: {
            spec.onnxUrl: [99],
            spec.vocabUrl: vocabBytes,
          },
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec);

        // Only the vocab URL should have been fetched.
        expect(server.requestedUrls, equals([spec.vocabUrl]));
      });

      test('re-downloads file when checksum does not match', () async {
        final onnxBytes = [1, 2, 3];
        final vocabBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'bad-checksum',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        // Pre-populate with wrong bytes (checksum will not match).
        final modelDir = Directory('${tempDir.path}/bad-checksum');
        await modelDir.create(recursive: true);
        await File('${modelDir.path}/model.onnx').writeAsBytes([9, 9, 9]);
        await File('${modelDir.path}/vocab.txt').writeAsBytes(vocabBytes);

        final server = _FakeHttpServer(
          responses: {
            spec.onnxUrl: onnxBytes,
            spec.vocabUrl: [99],
          },
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec);

        // Only the onnx URL should have been re-fetched.
        expect(server.requestedUrls, equals([spec.onnxUrl]));
        // The file should now have the correct content.
        expect(
          File('${modelDir.path}/model.onnx').readAsBytesSync(),
          equals(onnxBytes),
        );
      });
    });

    group('checksum mismatch error', () {
      test(
        'throws StateError when downloaded onnx checksum is wrong',
        () async {
          final onnxBytes = [1, 2, 3];
          final vocabBytes = [4, 5, 6];

          // Spec has correct checksums, but server returns different bytes.
          final spec = _makeSpec(
            id: 'corrupt-onnx',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          final server = _FakeHttpServer(
            responses: {
              spec.onnxUrl: [0, 0, 0], // wrong content
              spec.vocabUrl: vocabBytes,
            },
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          await expectLater(
            downloader.ensure(spec),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('checksum mismatch'),
              ),
            ),
          );
        },
      );

      test(
        'error message includes file path and expected/actual checksums',
        () async {
          final onnxBytes = [1, 2, 3];
          final vocabBytes = [4, 5, 6];
          final spec = _makeSpec(
            id: 'checksum-error-msg',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          final server = _FakeHttpServer(
            responses: {
              spec.onnxUrl: [0xFF, 0xFF], // wrong content
              spec.vocabUrl: vocabBytes,
            },
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          await expectLater(
            downloader.ensure(spec),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf([contains('SHA-256'), contains(spec.onnxSha256)]),
              ),
            ),
          );
        },
      );

      test('deletes temp file after checksum mismatch', () async {
        final onnxBytes = [1, 2, 3];
        final vocabBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'temp-cleanup',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        final server = _FakeHttpServer(
          responses: {
            spec.onnxUrl: [7, 8, 9], // wrong bytes
            spec.vocabUrl: vocabBytes,
          },
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await expectLater(downloader.ensure(spec), throwsA(isA<StateError>()));

        // Verify no .part file was left behind.
        final modelDir = Directory('${tempDir.path}/temp-cleanup');
        final partFiles = modelDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.part'))
            .toList();
        expect(partFiles, isEmpty);
      });
    });

    group('HTTP error handling', () {
      test('throws HttpException on non-2xx response', () async {
        final onnxBytes = [1, 2, 3];
        final vocabBytes = [4, 5, 6];
        final spec = _makeSpec(
          id: 'http-error',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        final server = _FakeHttpServer(
          statusCode: 404,
          responses: {spec.onnxUrl: [], spec.vocabUrl: []},
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await expectLater(
          downloader.ensure(spec),
          throwsA(isA<HttpException>()),
        );
      });

      test(
        'error message for HTTP failure includes the URL and status code',
        () async {
          final onnxBytes = [1, 2, 3];
          final vocabBytes = [4, 5, 6];
          final spec = _makeSpec(
            id: 'http-error-msg',
            onnxBytes: onnxBytes,
            vocabBytes: vocabBytes,
          );

          final server = _FakeHttpServer(
            statusCode: 503,
            responses: {spec.onnxUrl: [], spec.vocabUrl: []},
          );

          final downloader = ModelDownloader(
            cacheDir: tempDir.path,
            httpClientFactory: () => server.client,
          );

          await expectLater(
            downloader.ensure(spec),
            throwsA(
              isA<HttpException>().having(
                (e) => e.message,
                'message',
                allOf([contains('503'), contains(spec.onnxUrl)]),
              ),
            ),
          );
        },
      );
    });

    group('temp-file-then-rename crash safety', () {
      test('final file is only written after checksum passes', () async {
        final onnxBytes = [1, 2, 3, 4];
        final vocabBytes = [5, 6, 7, 8];
        final spec = _makeSpec(
          id: 'atomic-rename',
          onnxBytes: onnxBytes,
          vocabBytes: vocabBytes,
        );

        final server = _FakeHttpServer(
          responses: {spec.onnxUrl: onnxBytes, spec.vocabUrl: vocabBytes},
        );

        final downloader = ModelDownloader(
          cacheDir: tempDir.path,
          httpClientFactory: () => server.client,
        );

        await downloader.ensure(spec);

        // No .part files should remain after a successful download.
        final modelDir = Directory('${tempDir.path}/atomic-rename');
        final partFiles = modelDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.part'))
            .toList();
        expect(partFiles, isEmpty);

        // Final files should be present.
        expect(File('${modelDir.path}/model.onnx').existsSync(), isTrue);
        expect(File('${modelDir.path}/vocab.txt').existsSync(), isTrue);
      });
    });
  });

  group('ModelPaths', () {
    test('stores onnxPath and vocabPath correctly', () {
      const paths = ModelPaths(
        onnxPath: '/cache/model/model.onnx',
        vocabPath: '/cache/model/vocab.txt',
      );
      expect(paths.onnxPath, equals('/cache/model/model.onnx'));
      expect(paths.vocabPath, equals('/cache/model/vocab.txt'));
    });
  });
}
