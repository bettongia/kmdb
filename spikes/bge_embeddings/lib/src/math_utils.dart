// Copyright 2026 The Aurochs KMesh Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:math';

List<double> meanPool(
  List<double> hiddenState,
  List<int> attentionMask, {
  int seqLen = 512,
  int hiddenDim = 384,
}) {
  final result = List<double>.filled(hiddenDim, 0.0);
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

List<double> l2Normalize(List<double> vec) {
  final norm = sqrt(vec.fold(0.0, (s, v) => s + v * v));
  if (norm == 0.0) return vec;
  return vec.map((v) => v / norm).toList();
}

double cosineSimilarity(List<double> a, List<double> b) {
  assert(a.length == b.length);
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}
