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

import 'dart:math';
import 'dart:typed_data';

/// Quantises a float32 embedding vector to unsigned 8-bit integers (SQ8).
///
/// Uses a **fixed symmetric range** suitable for L2-normalised vectors whose
/// components lie in `[-1.0, 1.0]`:
///
/// ```
/// u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)
/// ```
///
/// This maps `-1.0` → `0`, `0.0` → `127` (or `128`), `1.0` → `255`.
///
/// ## Assumptions
///
/// - Input must be an L2-normalised vector (all components in `[-1.0, 1.0]`).
///   Values marginally outside the range (e.g. due to float rounding) are
///   clamped rather than panicked.
/// - No per-vector calibration is required; the fixed range provides adequate
///   accuracy for cosine similarity ranking.
/// - [vector] may have any positive length (384 for BGE Small En v1.5, 1024
///   for BGE-M3, etc.). A debug-mode assertion fires for empty vectors.
///
/// The quantisation error is bounded by `2.0 / 255 ≈ 0.00784` per component
/// (one quantisation step). In practice, round-trip error is ≤ 0.004 per
/// element.
Uint8List quantise(Float32List vector) {
  assert(
    vector.isNotEmpty,
    'Embedding vector must be non-empty, got length ${vector.length}',
  );
  final out = Uint8List(vector.length);
  for (var i = 0; i < vector.length; i++) {
    final f = vector[i];
    // Map [-1, 1] → [0, 255] and clamp to guard against float rounding.
    final u = ((f + 1.0) / 2.0 * 255.0).roundToDouble();
    out[i] = min(255, max(0, u.toInt()));
  }
  return out;
}

/// Dequantises an SQ8-encoded vector back to float32.
///
/// Inverse of [quantise]:
///
/// ```
/// f = u / 255.0 * 2.0 - 1.0
/// ```
///
/// The reconstructed values are in `[-1.0, 1.0]` but are no longer
/// L2-normalised (the quantisation error means the norm is slightly off 1.0).
/// For cosine similarity via dot product this is acceptable — the ranking
/// order is preserved.
///
/// [vector] may have any positive length. A debug-mode assertion fires for
/// empty vectors.
Float32List dequantise(Uint8List vector) {
  assert(
    vector.isNotEmpty,
    'SQ8 vector must be non-empty, got length ${vector.length}',
  );
  final out = Float32List(vector.length);
  for (var i = 0; i < vector.length; i++) {
    out[i] = vector[i] / 255.0 * 2.0 - 1.0;
  }
  return out;
}
