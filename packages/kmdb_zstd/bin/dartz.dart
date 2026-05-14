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

import 'dart:io';
import 'package:kmdb_zstd/zstd.dart';

/// A command-line tool for Zstd compression and decompression.
///
/// Use `dart run bin/dartz.dart <filename>` to compress a file.
/// Use `dart run bin/dartz.dart -d <input.zst> <output>` to decompress a file.
void main(List<String> args) {
  if (args.isEmpty || (args[0] == '-d' && args.length < 3)) {
    _printUsage();
    return;
  }

  final zstd = ZstdSimple();
  final isDecompress = args[0] == '-d';

  try {
    if (isDecompress) {
      final inputPath = args[1];
      final outputPath = args[2];
      _decompress(zstd, inputPath, outputPath);
    } else {
      final inputPath = args[0];
      final outputPath = '$inputPath.zst';
      _compress(zstd, inputPath, outputPath);
    }
  } catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }
}

void _printUsage() {
  print('Usage:');
  print('  Compress:   dart run bin/dartz.dart <filename>');
  print('  Decompress: dart run bin/dartz.dart -d <input.zst> <output>');
}

void _compress(ZstdSimple zstd, String inputPath, String outputPath) {
  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    throw FileSystemException('Input file not found', inputPath);
  }

  print('Compressing $inputPath...');
  final inputBytes = inputFile.readAsBytesSync();
  final compressed = zstd.compress(inputBytes);

  File(outputPath).writeAsBytesSync(compressed);

  print('Success! Created $outputPath');
  print('Original size:   ${inputBytes.length} bytes');
  print('Compressed size: ${compressed.length} bytes');
}

void _decompress(ZstdSimple zstd, String inputPath, String outputPath) {
  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    throw FileSystemException('Input file not found', inputPath);
  }

  print('Decompressing $inputPath...');
  final inputBytes = inputFile.readAsBytesSync();
  final decompressed = zstd.decompress(inputBytes);

  File(outputPath).writeAsBytesSync(decompressed);

  print('Success! Created $outputPath');
  print('Compressed size:   ${inputBytes.length} bytes');
  print('Decompressed size: ${decompressed.length} bytes');
}
