// Copyright 2026 The KMDB Authors
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

/// Zstd compression and decompression for Dart.
///
/// This library provides a high-level API for using the Zstandard (Zstd)
/// compression algorithm in Dart applications. It currently supports
/// simple synchronous compression and decompression of byte arrays.
library;

export 'src/zstd_base.dart' show ZstdSimple, minCLevel, maxCLevel;
