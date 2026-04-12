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

import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:bge_embeddings/bge_embeddings.dart';

Future<void> main() async {
  final assetDir = p.join(Directory.current.path, 'assets');

  print('Loading model (ORT library downloaded automatically on first run)...');
  final embedder = await BgeEmbedder.load(
    modelPath: p.join(assetDir, 'bge_small.onnx'),
    vocabPath: p.join(assetDir, 'vocab.txt'),
  );
  print('Ready.\n');

  // ── Single embedding ──────────────────────────────────────────────────────
  const query = 'What is the effect of temperature on enzyme activity?';
  final queryEmbedding = embedder.embed(query);
  print('Query: "$query"');
  print('Dims : ${queryEmbedding.length}');
  print(
    'First 6: ${queryEmbedding.take(6).map((v) => v.toStringAsFixed(4)).join(', ')}\n',
  );

  // ── Ranked similarity search ──────────────────────────────────────────────
  final passages = [
    'Enzyme activity generally increases with temperature up to an optimal '
        'point, after which denaturation causes a sharp decline.',
    'The mitochondria is the powerhouse of the cell.',
    'Higher temperatures increase molecular kinetic energy, accelerating '
        'reaction rates until the enzyme structure is disrupted.',
    'Photosynthesis converts light energy into chemical energy stored in glucose.',
  ];

  final passageEmbeddings = embedder.embedAll(passages);
  final scored = List.generate(
    passages.length,
    (i) => (
      score: cosineSimilarity(queryEmbedding, passageEmbeddings[i]),
      passage: passages[i],
    ),
  )..sort((a, b) => b.score.compareTo(a.score));

  print('Results (ranked):');
  for (final r in scored) {
    final preview = r.passage.length > 60
        ? '${r.passage.substring(0, 60)}...'
        : r.passage;
    print('  [${(r.score * 100).toStringAsFixed(1)}%] $preview');
  }

  print('---');
  embedder.dispose();
}
