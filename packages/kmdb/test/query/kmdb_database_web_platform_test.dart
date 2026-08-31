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

// Web-only platform-exclusion test (0.10.01 WI-9 Phase C, release-blocker
// #1). Semantic search (vector indexes) requires ONNX Runtime, which is
// unavailable on web/WASM — `KmdbDatabase.open` must fail fast with a clear
// `UnsupportedError` rather than let a web caller discover the gap via some
// other, less legible failure further down the open() sequence. This test
// only makes sense on web: on native, `kSemanticSearchAvailable` is `true`
// and non-empty `vecIndexes` is a perfectly valid (and separately tested —
// see test/search/semantic/vec_manager_test.dart) configuration.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  test(
    'open() throws UnsupportedError on web when vecIndexes is non-empty',
    () async {
      // MemoryStorageAdapter is used because the UnsupportedError check
      // fires before any storage I/O occurs — no real (SAHPool) adapter is
      // needed to exercise this path.
      final adapter = MemoryStorageAdapter();
      await expectLater(
        KmdbDatabase.open(
          path: '/db',
          adapter: adapter,
          vecIndexes: const [
            VecIndexDefinition(collection: 'articles', field: 'body'),
          ],
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('open() throws UnsupportedError on web even when a hand-rolled '
      'EmbeddingModel is supplied — semantic search is a platform exclusion, '
      'not merely an unmet embeddingModel requirement', () async {
    final adapter = MemoryStorageAdapter();
    await expectLater(
      KmdbDatabase.open(
        path: '/db',
        adapter: adapter,
        vecIndexes: const [
          VecIndexDefinition(collection: 'articles', field: 'body'),
        ],
        embeddingModel: _WebFakeEmbeddingModel(),
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });
}

/// A trivial [EmbeddingModel] a determined web caller could hand-roll
/// against the web stub interface (no ONNX Runtime involved at all). Proves
/// the `UnsupportedError` guard in `KmdbDatabase.open` fires unconditionally
/// on web, not merely when `embeddingModel` is omitted.
final class _WebFakeEmbeddingModel implements EmbeddingModel {
  @override
  String get modelId => 'web-fake-v1';

  @override
  int get dimensions => 1;

  @override
  Future<(Float32List, bool)> embed(
    String text, {
    EmbeddingKind kind = EmbeddingKind.document,
  }) async =>
      throw UnsupportedError('never called — open() rejects before this');

  @override
  void dispose() {}
}
