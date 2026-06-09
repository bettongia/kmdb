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

/// Produces a sentence-level embedding by averaging the token-level hidden
/// states produced by the ONNX model, weighted by [attentionMask].
///
/// [hiddenState] is the flat list of float32 logits extracted from the
/// [OnnxTensor] returned by [OnnxSession.run] with shape `[seqLen * hiddenDim]`.
///
/// [attentionMask] is the parallel list from [TokenizerOutput], length
/// `seqLen`. Padding positions (mask = 0) are excluded from the average.
///
/// [seqLen] is the number of token positions.
///
/// [hiddenDim] is the embedding dimension (e.g. 384 for BGE Small En v1.5,
/// 1024 for BGE-M3). Sourced from `spec.meta['dimensions'] as int` and
/// must be supplied by the caller — there is no default, as the dimension is
/// model-specific and must not be assumed.
///
/// Returns a float32 list of [hiddenDim] elements. Returns a zero vector if
/// no attention-masked tokens are present (degenerate case).
Float32List meanPool(
  List<double> hiddenState,
  List<int> attentionMask, {
  int seqLen = 512,
  required int hiddenDim,
}) {
  final result = Float32List(hiddenDim);
  var active = 0;
  for (var t = 0; t < seqLen; t++) {
    if (attentionMask[t] != 1) continue;
    final offset = t * hiddenDim;
    for (var d = 0; d < hiddenDim; d++) {
      result[d] += hiddenState[offset + d];
    }
    active++;
  }
  if (active == 0) return result;
  for (var d = 0; d < hiddenDim; d++) {
    result[d] /= active;
  }
  return result;
}

/// L2-normalises [vec] in-place and returns it.
///
/// After normalisation the vector has unit length (norm ≈ 1.0). This is
/// required before SQ8 quantisation (the fixed range [-1, 1] assumes
/// L2-normalised input) and before computing cosine similarity as a dot
/// product.
///
/// If [vec] is a zero vector (norm = 0) it is returned unchanged to avoid
/// division by zero.
Float32List l2Normalize(Float32List vec) {
  var norm = 0.0;
  for (final v in vec) {
    norm += v * v;
  }
  norm = sqrt(norm);
  if (norm == 0.0) return vec;
  for (var i = 0; i < vec.length; i++) {
    vec[i] /= norm;
  }
  return vec;
}

/// Computes the cosine similarity (dot product) of two L2-normalised vectors.
///
/// For unit-norm vectors `a` and `b`, the cosine similarity equals their dot
/// product, which is in the range `[-1.0, 1.0]`. In practice BGE embeddings
/// tend to give scores in `[0.0, 1.0]` for English text.
///
/// [a] and [b] must have the same length.
double cosineSimilarity(Float32List a, Float32List b) {
  assert(a.length == b.length, 'Vectors must have the same length');
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}
