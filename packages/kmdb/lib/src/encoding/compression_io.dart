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

// Native compression implementation.
//
// Uses Zstd (via es_compression's prebuilt FFI bindings) for encoding.
// Deflate decode is retained so that values written by older builds or web
// clients (flag 0x02) can still be read on native.

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:es_compression/zstd.dart';

import 'compression_flag.dart';

/// Attempts to compress [data] with Zstd (level 3).
///
/// Returns `(CompressionFlag.zstd, compressed)` when the compressed output is
/// smaller than the input, or `(CompressionFlag.none, data)` otherwise.
(CompressionFlag, Uint8List) tryCompress(Uint8List data) {
  final compressed = Uint8List.fromList(ZstdCodec(level: 3).encode(data));
  if (compressed.length < data.length) {
    return (CompressionFlag.zstd, compressed);
  }
  return (CompressionFlag.none, data);
}

/// Decompresses [data] according to [flag].
///
/// Handles all three flags so that values written with any algorithm —
/// including Deflate from web clients — can be decoded on native.
///
/// Throws [UnsupportedError] for unrecognised flags (guarded upstream by
/// [CompressionFlag.fromByte]).
Uint8List decompress(CompressionFlag flag, Uint8List data) => switch (flag) {
  CompressionFlag.none => data,
  CompressionFlag.zstd => Uint8List.fromList(ZstdCodec().decode(data)),
  CompressionFlag.deflate => Uint8List.fromList(
    ZLibDecoder().decodeBytes(data),
  ),
};
