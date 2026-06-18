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

/// Conditional export that selects the platform-appropriate compression
/// implementation at compile time.
///
/// - Native (`dart:io`): Zstd via `betto_zstd` (FFI bindings compiled from
///   source via `native_toolchain_c`).
/// - Web (`dart:js_interop`): Zstd via `betto_zstd` WASM build.
/// - Stub (neither): no-op; values are stored uncompressed.
///
/// Each implementation exposes two top-level functions with identical
/// signatures:
/// - [tryCompress] — compresses [data] and returns the flag+bytes pair.
/// - [decompress]  — decompresses [data] according to the given flag.
library;

export 'compression_stub.dart'
    if (dart.library.io) 'compression_io.dart'
    if (dart.library.js_interop) 'compression_web.dart';
