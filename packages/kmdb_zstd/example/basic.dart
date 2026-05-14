// Copyright 2026 The Authors
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
import 'dart:typed_data';
import 'package:kmdb_zstd/zstd.dart';

void main() {
  // Create a ZstdSimple instance with a specific compression level (default is 3)
  final zstd = ZstdSimple(level: 3);

  // Data to compress
  final data = Uint8List.fromList([1, 2, 3, 4, 5, 1, 2, 3, 4, 5]);

  // Compress
  final compressed = zstd.compress(data);
  print('Compressed size: ${compressed.length}');

  // Decompress
  final decompressed = zstd.decompress(compressed);
  print('Decompressed size: ${decompressed.length}');
}
