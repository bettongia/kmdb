// Copyright 2026 The KMDB Authors
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
    print('Tokenising Utility');
    print('---------------------');
    print('Usage:');
    print('  dart bin/tokens.dart "<text>"');
    print('  dart bin/tokens.dart <file_path>');
    print('  echo "text" | dart bin/tokens.dart');
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
  final vocabPath = p.join(assetDir, 'vocab.txt');

  if (!File(vocabPath).existsSync()) {
    stderr.writeln('Error: Assets not found in $assetDir.');
    stderr.writeln(
      'Ensure bge_small.onnx and vocab.txt exist in the assets/ directory.',
    );
    exit(1);
  }

  final tokenizer = await BertTokenizer.load(vocabPath, maxLength: 512);
  final tokens = tokenizer.encode(input);

  final tokenCount = tokens.attentionMask.where((m) => m == 1).length;
  final inputIds = tokens.inputIds.take(tokenCount).toList();
  final decoded = tokenizer.decode(inputIds);

  print('Count : ${decoded.length}');
  print('Tokens: ${jsonEncode(decoded)}');
}
