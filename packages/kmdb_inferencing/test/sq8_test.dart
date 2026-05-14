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

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kmdb_inferencing/kmdb_inferencing.dart';
import 'package:test/test.dart';

void main() {
  group('SQ8 quantise / dequantise', () {
    // ── Round-trip accuracy ────────────────────────────────────────────────

    test('round-trip error is ≤ 0.004 for all elements', () {
      // A unit vector spread uniformly across [-1, 1].
      final v = Float32List.fromList(
        List.generate(384, (i) => (i / 191.5) - 1.0),
      );
      final roundTrip = dequantise(quantise(v));
      for (var i = 0; i < v.length; i++) {
        expect(
          (roundTrip[i] - v[i]).abs(),
          lessThanOrEqualTo(0.004),
          reason: 'element $i: original=${v[i]}, roundTrip=${roundTrip[i]}',
        );
      }
    });

    test('round-trip for a 384-element zero vector does not error', () {
      final v = Float32List(384); // all zeros
      expect(() => dequantise(quantise(v)), returnsNormally);
      final result = dequantise(quantise(v));
      expect(result.length, equals(384));
    });

    // ── Boundary values ────────────────────────────────────────────────────

    test('1.0 quantises to 255', () {
      final v = Float32List(384)..fillRange(0, 384, 1.0);
      final q = quantise(v);
      expect(q[0], equals(255));
    });

    test('-1.0 quantises to 0', () {
      final v = Float32List(384)..fillRange(0, 384, -1.0);
      final q = quantise(v);
      expect(q[0], equals(0));
    });

    test('0.0 quantises to 127 or 128', () {
      final v = Float32List(384)..fillRange(0, 384, 0.0);
      final q = quantise(v);
      // round((0.0 + 1.0) / 2.0 * 255) = round(127.5) = 128 (banker's or ceil)
      // Some implementations may give 127; both are acceptable.
      expect(q[0], anyOf(equals(127), equals(128)));
    });

    // ── Clamping ───────────────────────────────────────────────────────────

    test('values slightly above 1.0 are clamped to 255', () {
      final v = Float32List(384)..fillRange(0, 384, 1.0001);
      final q = quantise(v);
      expect(q[0], equals(255));
    });

    test('values slightly below -1.0 are clamped to 0', () {
      final v = Float32List(384)..fillRange(0, 384, -1.0001);
      final q = quantise(v);
      expect(q[0], equals(0));
    });

    // ── Specific formula verification ──────────────────────────────────────

    test(
      'quantise formula: u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)',
      () {
        // Test a known value: f = 0.5
        // (0.5 + 1.0) / 2.0 * 255 = 0.75 * 255 = 191.25 → round = 191
        final v = Float32List(384)..fillRange(0, 384, 0.5);
        final q = quantise(v);
        expect(q[0], equals(191));
      },
    );

    test('dequantise formula: f = u / 255.0 * 2.0 - 1.0', () {
      // u = 191: 191 / 255 * 2 - 1 = 1.498 - 1 = 0.498...
      final bytes = Uint8List(384)..fillRange(0, 384, 191);
      final f = dequantise(bytes);
      expect(f[0], closeTo(191 / 255.0 * 2.0 - 1.0, 1e-6));
    });

    // ── L2-normalised vector preservation ─────────────────────────────────

    test(
      'cosine similarity between two similar L2-normalised vectors is > 0.99 after round-trip',
      () {
        // Construct a unit vector with a slight perturbation, round-trip both.
        final v1 = _randomUnitVector(seed: 42);
        final v1rt = dequantise(quantise(v1));

        double dot = 0.0;
        double norm1 = 0.0;
        double norm2 = 0.0;
        for (var i = 0; i < 384; i++) {
          dot += v1[i] * v1rt[i];
          norm1 += v1[i] * v1[i];
          norm2 += v1rt[i] * v1rt[i];
        }
        final cosine = dot / (math.sqrt(norm1) * math.sqrt(norm2));
        expect(cosine, greaterThan(0.99));
      },
    );

    test(
      'cosine similarity between dissimilar vectors is preserved after round-trip',
      () {
        final v1 = _randomUnitVector(seed: 1);
        final v2 = _randomUnitVector(seed: 99999);

        // Dot product before quantisation.
        double dotBefore = 0.0;
        for (var i = 0; i < 384; i++) {
          dotBefore += v1[i] * v2[i];
        }

        final v1q = dequantise(quantise(v1));
        final v2q = dequantise(quantise(v2));

        double dotAfter = 0.0;
        for (var i = 0; i < 384; i++) {
          dotAfter += v1q[i] * v2q[i];
        }

        // The quantised dot product should be close to the original.
        expect(dotAfter, closeTo(dotBefore, 0.05));
      },
    );
  });
}

/// Generates a deterministic L2-normalised random vector of length 384.
Float32List _randomUnitVector({required int seed}) {
  final rng = math.Random(seed);
  final v = Float32List.fromList(
    List.generate(384, (_) => rng.nextDouble() * 2 - 1),
  );
  var norm = 0.0;
  for (final x in v) {
    norm += x * x;
  }
  norm = math.sqrt(norm);
  for (var i = 0; i < v.length; i++) {
    v[i] /= norm;
  }
  return v;
}
