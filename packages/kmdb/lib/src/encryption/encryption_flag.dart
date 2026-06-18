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

/// Single-byte flag that is the outermost prefix of every stored value,
/// identifying whether the payload is encrypted.
///
/// The on-disk wire format for a stored value is:
/// ```
/// [encryption_flag 1B][compression_flag 1B][compressed-or-raw payload]
/// ```
///
/// When [EncryptionFlag.aesGcm] is set the structure is:
/// ```
/// [aesGcm 1B][96-bit nonce][AES-256-GCM ciphertext][16-byte GCM tag]
/// ```
/// where the ciphertext, when decrypted, yields `[compression_flag][payload]`.
/// The compression flag is therefore *inside* the ciphertext, preventing the
/// cloud from learning which compression algorithm was used.
///
/// This flag is a separate byte from [CompressionFlag] (spec §5): encryption
/// and compression are independently evolvable dimensions — a bitmask would
/// force combinatorial handling as either axis grows.
///
/// ## Forward-compatibility
///
/// Unknown flag bytes throw [ArgumentError] — the same posture as
/// [CompressionFlag.fromByte]. An old build that reads a value encrypted with a
/// future algorithm gets a clean, attributable error rather than attempting to
/// decompress ciphertext.
enum EncryptionFlag {
  /// Payload is not encrypted. The next byte is the compression flag.
  none(0x00),

  /// Payload is encrypted with AES-256-GCM.
  ///
  /// After stripping this byte, the remaining bytes are:
  /// `[96-bit nonce][AES-GCM ciphertext][16-byte tag]`
  /// The decrypted plaintext is `[compression_flag][compressed-or-raw payload]`.
  aesGcm(0x01);

  const EncryptionFlag(this.byte);

  /// The single-byte wire encoding.
  final int byte;

  /// Parses an [EncryptionFlag] from its byte value.
  ///
  /// Throws [ArgumentError] for unrecognised bytes — unknown flags indicate
  /// data written by a future version of KMDB or silent corruption.
  static EncryptionFlag fromByte(int byte) => switch (byte) {
    0x00 => none,
    0x01 => aesGcm,
    _ => throw ArgumentError.value(
      byte,
      'byte',
      'Unknown EncryptionFlag byte — data may be from a newer KMDB version '
          'or is corrupted',
    ),
  };
}
