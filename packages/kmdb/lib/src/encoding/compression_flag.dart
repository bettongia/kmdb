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

/// Single-byte flag prefixed to every stored value that identifies the
/// compression algorithm applied to the payload.
///
/// The on-disk layout for a stored value is:
/// ```
/// [flag 1B][compressed-or-raw payload]
/// ```
///
/// This flag is written by [ValueCodec.encode] and consumed by
/// [ValueCodec.decode].
enum CompressionFlag {
  /// No compression — payload is raw CBOR bytes.
  none(0x00),

  /// Zstandard compression (native FFI or WASM).
  zstd(0x01),

  /// Deflate compression — fallback when Zstd/WASM is unavailable.
  deflate(0x02);

  const CompressionFlag(this.byte);

  /// The single-byte wire encoding.
  final int byte;

  /// Parses a [CompressionFlag] from its byte value.
  ///
  /// Throws [ArgumentError] for unrecognised bytes.
  static CompressionFlag fromByte(int byte) => switch (byte) {
    0x00 => none,
    0x01 => zstd,
    0x02 => deflate,
    _ => throw ArgumentError.value(
      byte,
      'byte',
      'Unknown CompressionFlag byte',
    ),
  };
}
