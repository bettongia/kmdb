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

// coverage:ignore-file
// Web compression implementation.
//
// Web stores values uncompressed (CompressionFlag.none). Deflate has been
// removed as a clean break — the project is pre-release. Zstd decompression
// on web is deferred; an UnsupportedError is thrown to surface the gap
// clearly if a value compressed on native is read on web.

import 'dart:typed_data';

import 'compression_flag.dart';

/// Returns [data] uncompressed — web stores values with no compression.
///
/// Always returns `(CompressionFlag.none, data)`.
(CompressionFlag, Uint8List) tryCompress(Uint8List data) {
  return (CompressionFlag.none, data);
}

/// Decompresses [data] according to [flag].
///
/// Throws [UnsupportedError] for [CompressionFlag.zstd] — Zstd decompression
/// on web is deferred pending a WASM implementation.
Uint8List decompress(CompressionFlag flag, Uint8List data) => switch (flag) {
  CompressionFlag.none => data,
  CompressionFlag.zstd => throw UnsupportedError(
    'Zstd decompression is not supported on web. '
    'This value was encoded on a native platform.',
  ),
};
