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

// coverage:ignore-file
// Stub compression implementation used when neither dart:io nor
// dart:js_interop is available. Stores all values uncompressed.

import 'dart:typed_data';

import 'compression_flag.dart';

/// Returns the data uncompressed — no compression available in this
/// build configuration.
(CompressionFlag, Uint8List) tryCompress(Uint8List data) =>
    (CompressionFlag.none, data);

/// Returns [data] unchanged for [CompressionFlag.none]; throws
/// [UnsupportedError] for any compressed flag.
Uint8List decompress(CompressionFlag flag, Uint8List data) => switch (flag) {
  CompressionFlag.none => data,
  _ => throw UnsupportedError(
    'Compression flag $flag is not supported in this build configuration.',
  ),
};
