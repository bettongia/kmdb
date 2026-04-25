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

import 'dart:math';
import 'dart:typed_data';

import 'package:kmdb_inferencing/src/math_utils.dart';
import 'package:test/test.dart';

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  // meanPool
  // ──────────────────────────────────────────────────────────────────────────

  group('meanPool', () {
    const hiddenDim = 4; // small dim for easy manual verification
    const seqLen = 3;

    test('averages all active token embeddings', () {
      // Hidden state: 3 tokens × 4 dims.
      // token 0: [1, 0, 0, 0]
      // token 1: [0, 2, 0, 0]
      // token 2: [0, 0, 3, 0]
      // mask = [1, 1, 1] → average = [1/3, 2/3, 1, 0]
      final hidden = <double>[
        1, 0, 0, 0, //
        0, 2, 0, 0, //
        0, 0, 3, 0, //
      ];
      final mask = [1, 1, 1];
      final result = meanPool(
        hidden,
        mask,
        seqLen: seqLen,
        hiddenDim: hiddenDim,
      );
      expect(result[0], closeTo(1 / 3, 1e-6));
      expect(result[1], closeTo(2 / 3, 1e-6));
      expect(result[2], closeTo(1.0, 1e-6));
      expect(result[3], closeTo(0.0, 1e-6));
    });

    test('excludes padding positions (mask = 0)', () {
      // token 0: [4, 0, 0, 0] active
      // token 1: [0, 9, 9, 9] padding — excluded
      // token 2: [2, 0, 0, 0] active
      // average of active = [(4+2)/2, 0, 0, 0] = [3, 0, 0, 0]
      final hidden = <double>[
        4, 0, 0, 0, //
        0, 9, 9, 9, //
        2, 0, 0, 0, //
      ];
      final mask = [1, 0, 1];
      final result = meanPool(
        hidden,
        mask,
        seqLen: seqLen,
        hiddenDim: hiddenDim,
      );
      expect(result[0], closeTo(3.0, 1e-6));
      expect(result[1], closeTo(0.0, 1e-6));
    });

    test('returns zero vector when no tokens are active', () {
      final hidden = List<double>.filled(seqLen * hiddenDim, 1.0);
      final mask = [0, 0, 0];
      final result = meanPool(
        hidden,
        mask,
        seqLen: seqLen,
        hiddenDim: hiddenDim,
      );
      expect(result, everyElement(closeTo(0.0, 1e-9)));
    });

    test('single active token returns that token unchanged', () {
      final hidden = <double>[
        0, 0, 0, 0, //
        3, 1, 4, 1, //
        0, 0, 0, 0, //
      ];
      final mask = [0, 1, 0];
      final result = meanPool(
        hidden,
        mask,
        seqLen: seqLen,
        hiddenDim: hiddenDim,
      );
      expect(result[0], closeTo(3.0, 1e-6));
      expect(result[1], closeTo(1.0, 1e-6));
      expect(result[2], closeTo(4.0, 1e-6));
      expect(result[3], closeTo(1.0, 1e-6));
    });

    test('returns Float32List', () {
      final hidden = List<double>.filled(seqLen * hiddenDim, 0.0);
      final mask = [1, 0, 0];
      expect(meanPool(hidden, mask, seqLen: seqLen, hiddenDim: hiddenDim), isA<Float32List>());
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // l2Normalize
  // ──────────────────────────────────────────────────────────────────────────

  group('l2Normalize', () {
    test('unit-norm after normalisation', () {
      final vec = Float32List.fromList([3.0, 4.0]); // norm = 5
      final result = l2Normalize(vec);
      final norm = sqrt(result[0] * result[0] + result[1] * result[1]);
      expect(norm, closeTo(1.0, 1e-6));
    });

    test('returns the same Float32List object (in-place)', () {
      final vec = Float32List.fromList([1.0, 0.0]);
      final result = l2Normalize(vec);
      expect(identical(result, vec), isTrue);
    });

    test('zero vector is returned unchanged', () {
      final vec = Float32List.fromList([0.0, 0.0, 0.0]);
      final result = l2Normalize(vec);
      expect(result, everyElement(closeTo(0.0, 1e-9)));
    });

    test('already unit-norm vector is unchanged', () {
      final vec = Float32List.fromList([1.0, 0.0, 0.0]);
      l2Normalize(vec);
      expect(vec[0], closeTo(1.0, 1e-6));
      expect(vec[1], closeTo(0.0, 1e-6));
    });

    test('negative components normalise correctly', () {
      final vec = Float32List.fromList([-3.0, -4.0]); // norm = 5
      l2Normalize(vec);
      expect(vec[0], closeTo(-0.6, 1e-6));
      expect(vec[1], closeTo(-0.8, 1e-6));
    });

    test('single-element vector normalises to ±1', () {
      final pos = Float32List.fromList([7.0]);
      l2Normalize(pos);
      expect(pos[0], closeTo(1.0, 1e-6));

      final neg = Float32List.fromList([-5.0]);
      l2Normalize(neg);
      expect(neg[0], closeTo(-1.0, 1e-6));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // cosineSimilarity
  // ──────────────────────────────────────────────────────────────────────────

  group('cosineSimilarity', () {
    test('identical unit vectors give similarity 1.0', () {
      final a = Float32List.fromList([1.0, 0.0, 0.0]);
      final b = Float32List.fromList([1.0, 0.0, 0.0]);
      expect(cosineSimilarity(a, b), closeTo(1.0, 1e-6));
    });

    test('orthogonal unit vectors give similarity 0.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([0.0, 1.0]);
      expect(cosineSimilarity(a, b), closeTo(0.0, 1e-6));
    });

    test('opposite unit vectors give similarity -1.0', () {
      final a = Float32List.fromList([1.0, 0.0]);
      final b = Float32List.fromList([-1.0, 0.0]);
      expect(cosineSimilarity(a, b), closeTo(-1.0, 1e-6));
    });

    test('known 2-D vectors', () {
      // a = (3/5, 4/5), b = (4/5, 3/5) → dot = 12/25 + 12/25 = 24/25
      final a = Float32List.fromList([3 / 5, 4 / 5]);
      final b = Float32List.fromList([4 / 5, 3 / 5]);
      expect(cosineSimilarity(a, b), closeTo(24 / 25, 1e-5));
    });

    test('result is in range [-1, 1] for arbitrary unit vectors', () {
      final rng = Random(0);
      for (var i = 0; i < 20; i++) {
        final raw = Float32List.fromList(
          List.generate(8, (_) => rng.nextDouble() * 2 - 1),
        );
        final a = l2Normalize(Float32List.fromList(raw));
        final raw2 = Float32List.fromList(
          List.generate(8, (_) => rng.nextDouble() * 2 - 1),
        );
        final b = l2Normalize(raw2);
        final sim = cosineSimilarity(a, b);
        expect(sim, greaterThanOrEqualTo(-1.0 - 1e-5));
        expect(sim, lessThanOrEqualTo(1.0 + 1e-5));
      }
    });
  });
}
