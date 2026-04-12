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

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:bge_embeddings/bge_embeddings.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty && stdin.hasTerminal) {
    print('BGE Embedding Utility');
    print('---------------------');
    print('Usage:');
    print('  dart bin/embed.dart "<text>"');
    print('  dart bin/embed.dart <file_path>');
    print('  echo "text" | dart bin/embed.dart');
    return;
  }

  String input;
  if (args.isNotEmpty) {
    final filePath = args[0];
    if (File(filePath).existsSync()) {
      input = await File(filePath).readAsString();
    } else {
      input = args.join(' ');
    }
  } else {
    // Read from stdin (e.g. piped input)
    input = await stdin.transform(utf8.decoder).join();
  }

  if (input.trim().isEmpty) return;

  // Resolve assets path relative to the current working directory.
  final assetDir = p.join(Directory.current.path, 'assets');
  final modelPath = p.join(assetDir, 'bge_small.onnx');
  final vocabPath = p.join(assetDir, 'vocab.txt');

  if (!File(modelPath).existsSync() || !File(vocabPath).existsSync()) {
    stderr.writeln('Error: Assets not found in $assetDir.');
    stderr.writeln('Ensure bge_small.onnx and vocab.txt exist in the assets/ directory.');
    exit(1);
  }

  // Load the model
  final embedder = await BgeEmbedder.load(
    modelPath: modelPath,
    vocabPath: vocabPath,
  );

  try {
    final embedding = embedder.embed(input);
    // Output the vector as a JSON array of doubles.
    stdout.writeln(jsonEncode(embedding));
  } finally {
    embedder.dispose();
  }
}
