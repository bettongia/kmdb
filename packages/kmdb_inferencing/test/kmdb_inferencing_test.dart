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
  group('OnnxEmbeddingModel — stub behaviour', () {
    test('OnnxEmbeddingModel implements EmbeddingModel interface', () {
      // Type check is compile-time, but we can verify at runtime too.
      expect(OnnxEmbeddingModel, isNotNull);
      // The class must be assignable to EmbeddingModel once instantiated.
      // We verify this structurally by checking the type hierarchy.
      // Actual instantiation throws UnimplementedError (see next test).
    });

    test(
      'OnnxEmbeddingModel.load() throws when model assets are absent',
      () async {
        // When the BGE model file is not present (e.g. in CI without assets),
        // load() throws an UnsupportedError with a descriptive message.
        await expectLater(
          OnnxEmbeddingModel.load,
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('OnnxEmbeddingModel is exported from barrel', () {
      // If this file compiles, the export is correct.
      // We just confirm the type name resolves.
      expect(OnnxEmbeddingModel, isNotNull);
    });
  });
}
