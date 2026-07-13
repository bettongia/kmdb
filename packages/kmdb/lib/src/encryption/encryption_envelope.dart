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

import 'dart:typed_data';

import 'encryption_flag.dart';
import 'encryption_provider.dart';

/// Encrypts/decrypts opaque byte payloads that are not `Map<String, dynamic>`
/// shaped and therefore cannot go through [ValueCodec].
///
/// [ValueCodec] (`lib/src/encoding/value_codec.dart`) is `Map`-only — it
/// requires a `Map<String, dynamic>` in and produces one out, because it
/// exists to serve the CBOR document-encoding pipeline (compression + the
/// `[EncryptionFlag][CompressionFlag][payload]` framing). Many values in the
/// system are not maps at all: raw scalars (integers, opaque sentinel
/// strings), fixed-length byte blobs (SQ8 embedding vectors), and generic
/// opaque state blobs (`$meta` entries, index/FTS/Vec persisted state). This
/// class is the byte-oriented sibling of [ValueCodec] for exactly those
/// values.
///
/// This factors out the `[EncryptionFlag byte][nonce‖ciphertext‖tag]` /
/// `[EncryptionFlag.none byte][plaintext]` pattern that
/// `VaultSearchManager.writeExtractArtifact`/`readExtractArtifact` (WI-10)
/// originally inlined for whole-file `extract/` artifacts — both that
/// call site and this plan's KV-value call sites (Gap 1, Gap 3) now share
/// this single implementation, per CLAUDE.md's "prefer existing primitives
/// over re-rolling them."
///
/// ## Wire format
///
/// - `wrap(bytes, null)` (no provider) → `[EncryptionFlag.none (0x00)][bytes]`
///   — flag-prefixed **plaintext**. The flag byte is emitted even when there
///   is no encryption so the two primitives ([EncryptionEnvelope] and
///   [ValueCodec]) are wire-consistent: every value in the store, mapped or
///   scalar, always begins with an [EncryptionFlag] byte.
/// - `wrap(bytes, provider)` →
///   `[EncryptionFlag.aesGcm (0x01)][nonce‖ciphertext‖tag]`.
/// - A zero-length [bytes] payload is valid and round-trips through either
///   branch — the flag byte alone still makes a self-describing 1-byte frame.
/// - [unwrap] of an [EncryptionFlag.aesGcm]-flagged value when [encryption]
///   is `null` throws [StateError] — a database opened without a key must
///   never silently hand back ciphertext as if it were plaintext.
final class EncryptionEnvelope {
  const EncryptionEnvelope._();

  /// Wraps [bytes] with a leading [EncryptionFlag] byte, encrypting with
  /// [encryption] when non-null.
  ///
  /// See the class doc for the exact wire format, including the `null`
  /// (plaintext) and zero-length-payload edge cases.
  static Future<Uint8List> wrap(
    Uint8List bytes,
    EncryptionProvider? encryption,
  ) async {
    if (encryption == null) {
      final out = Uint8List(1 + bytes.length)
        ..[0] = EncryptionFlag.none.byte
        ..setAll(1, bytes);
      return out;
    }
    final ciphertext = await encryption.encrypt(bytes);
    final out = Uint8List(1 + ciphertext.length)
      ..[0] = EncryptionFlag.aesGcm.byte
      ..setAll(1, ciphertext);
    return out;
  }

  /// Reverses [wrap], returning the original plaintext bytes.
  ///
  /// Throws:
  /// - [ArgumentError] if [bytes] is empty (there is no flag byte to parse)
  ///   or the leading byte is not a recognised [EncryptionFlag] (data from a
  ///   future KMDB version, or corruption — see [EncryptionFlag.fromByte]).
  /// - [StateError] if the payload is [EncryptionFlag.aesGcm]-flagged but
  ///   [encryption] is `null` — the database was opened without a key.
  /// - [EncryptionError] if decryption fails (wrong key or tampered/corrupted
  ///   ciphertext).
  static Future<Uint8List> unwrap(
    Uint8List bytes,
    EncryptionProvider? encryption,
  ) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Cannot unwrap empty bytes');
    }
    final flag = EncryptionFlag.fromByte(bytes[0]);
    final body = Uint8List.sublistView(bytes, 1);
    switch (flag) {
      case EncryptionFlag.none:
        return body;
      case EncryptionFlag.aesGcm:
        if (encryption == null) {
          throw StateError(
            'Value is AES-GCM encrypted but no EncryptionProvider is '
            'configured. Open the database with an EncryptionConfig.',
          );
        }
        return encryption.decrypt(body);
    }
  }
}
