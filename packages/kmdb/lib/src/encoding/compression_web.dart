// Copyright 2026 The KMDB Authors.
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

// Web compression implementation.
//
// Uses Deflate (via package:archive) for encoding. Zstd decompression on web
// is deferred — values written with flag 0x01 by a native client cannot yet
// be decoded here; an UnsupportedError is thrown to surface the gap clearly.

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'compression_flag.dart';

/// Attempts to compress [data] with Deflate.
///
/// Returns `(CompressionFlag.deflate, compressed)` when the compressed output
/// is smaller than the input, or `(CompressionFlag.none, data)` otherwise.
(CompressionFlag, Uint8List) tryCompress(Uint8List data) {
  final compressed = Uint8List.fromList(ZLibEncoder().encode(data));
  if (compressed.length < data.length) {
    return (CompressionFlag.deflate, compressed);
  }
  return (CompressionFlag.none, data);
}

/// Decompresses [data] according to [flag].
///
/// Throws [UnsupportedError] for [CompressionFlag.zstd] — Zstd decompression
/// on web is deferred pending a WASM implementation.
Uint8List decompress(CompressionFlag flag, Uint8List data) => switch (flag) {
      CompressionFlag.none => data,
      CompressionFlag.deflate =>
        Uint8List.fromList(ZLibDecoder().decodeBytes(data)),
      CompressionFlag.zstd => throw UnsupportedError(
          'Zstd decompression is not supported on web. '
          'This value was encoded on a native platform.',
        ),
    };
