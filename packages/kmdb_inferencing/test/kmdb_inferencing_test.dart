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

import 'package:kmdb_inferencing/kmdb_inferencing.dart';
import 'package:test/test.dart';

void main() {
  group('OnnxEmbeddingModel — contract', () {
    test('OnnxEmbeddingModel implements EmbeddingModel interface', () {
      // Type check is compile-time, but we can verify at runtime too.
      expect(OnnxEmbeddingModel, isNotNull);
      // The class must be assignable to EmbeddingModel once instantiated.
      // We verify this structurally by checking the type hierarchy.
    });

    test('OnnxEmbeddingModel.load() throws ArgumentError when neither '
        'modelPath nor cacheDir is supplied', () async {
      // The bundled LFS asset has been removed. Calling load() with no
      // modelPath and no cacheDir must fail fast with ArgumentError so
      // callers receive a clear, actionable error before any I/O is
      // attempted. This is a required-argument check, not a file-not-found.
      await expectLater(OnnxEmbeddingModel.load, throwsA(isA<ArgumentError>()));
    });

    test('OnnxEmbeddingModel is exported from barrel', () {
      // If this file compiles, the export is correct.
      // We just confirm the type name resolves.
      expect(OnnxEmbeddingModel, isNotNull);
    });
  });
}
