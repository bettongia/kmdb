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

// Web compression implementation.
//
// Uses Zstd via betto_zstd's WASM build (self-built Emscripten, frame-compatible
// with the native FFI path by construction). The WASM module must be initialised
// before any call to tryCompress or decompress — call ZstdSimple.init() once in
// KmdbDatabase.open() before any I/O begins.

import 'dart:typed_data';

import 'package:betto_zstd/betto_zstd.dart' show ZstdSimple;

import 'compression_flag.dart';

/// Attempts to compress [data] with Zstd (level 3) on web.
///
/// Returns `(CompressionFlag.zstd, compressed)` when the compressed output is
/// smaller than the input, or `(CompressionFlag.none, data)` otherwise.
///
/// The WASM module must have been initialised via [ZstdSimple.init] before
/// calling this function (guaranteed by [KmdbDatabase.open]).
(CompressionFlag, Uint8List) tryCompress(Uint8List data) {
  final compressed = ZstdSimple(level: 3).compress(data);
  if (compressed.length < data.length) {
    return (CompressionFlag.zstd, compressed);
  }
  return (CompressionFlag.none, data);
}

/// Decompresses [data] according to [flag] on web.
///
/// The WASM module must have been initialised via [ZstdSimple.init] before
/// calling this function (guaranteed by [KmdbDatabase.open]).
///
/// Throws [UnsupportedError] for unrecognised flags (guarded upstream by
/// [CompressionFlag.fromByte]).
Uint8List decompress(CompressionFlag flag, Uint8List data) => switch (flag) {
  CompressionFlag.none => data,
  CompressionFlag.zstd => ZstdSimple().decompress(data),
};
