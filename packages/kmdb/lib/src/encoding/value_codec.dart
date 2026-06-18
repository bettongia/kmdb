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

import 'package:cbor/cbor.dart';

import '../encryption/encryption_flag.dart';
import '../encryption/encryption_provider.dart';
import 'compression.dart';
import 'compression_flag.dart';

/// Threshold (in raw CBOR bytes) below which compression is skipped.
///
/// Compressing small payloads rarely saves space and always adds CPU cost.
/// 64 bytes was chosen as a conservative threshold: typical CBOR overhead for
/// a small document is 10–30 bytes, so anything under 64 bytes is unlikely to
/// compress well with either Zstd or Deflate.
const int _kCompressionThreshold = 64;

/// Encodes and decodes document values for storage in the LSM engine.
///
/// The encoding pipeline when encryption is **disabled** (pre-Phase 12):
/// ```
/// [encryption_flag=0x00 1B][compression_flag 1B][payload]
/// ```
///
/// The encoding pipeline when encryption is **enabled** (Phase 12):
/// ```
/// [encryption_flag=0x01 1B][96-bit nonce][AES-GCM ciphertext][16-byte tag]
/// ```
/// where the AES-GCM ciphertext, when decrypted, yields
/// `[compression_flag 1B][compressed-or-raw payload]`.
///
/// ## Wire format detail (§5 extended)
///
/// The outermost byte is always [EncryptionFlag]:
/// - `0x00` (none): the next byte is [CompressionFlag], followed by the
///   (possibly compressed) CBOR payload — the pre-Phase-12 layout.
/// - `0x01` (AES-GCM): the rest of the bytes are a self-describing
///   `[nonce][ciphertext][tag]` blob produced by [AesGcmEncryptionProvider].
///   The plaintext that was encrypted is `[CompressionFlag][payload]`.
///
/// ## Compression strategy
///
/// Compression is only applied when the raw CBOR exceeds
/// [_kCompressionThreshold] bytes. The platform-specific [tryCompress]
/// function selects the algorithm and skips compression entirely if the
/// output would not be smaller than the input.
///
/// When encryption is enabled, the compression flag byte is inside the
/// ciphertext — preventing the cloud provider from learning which compression
/// algorithm was used (a minor confidentiality benefit).
///
/// ## Wire format note
///
/// Phase 12 introduced the two-byte prefix format as a clean break: all values
/// (plaintext and encrypted) now start with an [EncryptionFlag] byte. Values
/// written by pre-Phase-12 builds are not supported — any such database must
/// be migrated (see §31) or re-opened fresh. [decode] requires at least two
/// bytes and will throw [ArgumentError] for single-byte legacy payloads.
///
/// ## Thread safety
///
/// All methods are safe to call concurrently. The async methods return
/// [Future]s and do not mutate shared state.
final class ValueCodec {
  const ValueCodec._();

  // ── Encode ──────────────────────────────────────────────────────────────────

  /// Encodes [value] (a JSON-compatible [Map]) into the Phase 12 storage format.
  ///
  /// Always emits the [EncryptionFlag] outer byte:
  ///
  /// - Plaintext (`encryption == null`): `[0x00][compression_flag][payload]`
  /// - Encrypted (`encryption != null`): `[0x01][nonce+ciphertext+tag]`
  ///
  /// When [encryption] is non-null, the post-compression bytes are encrypted
  /// with AES-256-GCM and the encryption flag byte is `0x01` ([EncryptionFlag.aesGcm]).
  static Future<Uint8List> encode(
    Map<String, dynamic> value, {
    EncryptionProvider? encryption,
  }) async {
    // Step 1: Serialize to CBOR.
    final cborBytes = _toCbor(value);

    // Step 2: Optionally compress.
    final Uint8List compressed;
    if (cborBytes.length < _kCompressionThreshold) {
      compressed = _prependCompression(CompressionFlag.none, cborBytes);
    } else {
      final (flag, payload) = tryCompress(cborBytes);
      compressed = _prependCompression(flag, payload);
    }

    // Step 3: Optionally encrypt.
    if (encryption == null) {
      // No encryption: emit [EncryptionFlag.none][compression_flag][payload].
      return _prependEncryption(EncryptionFlag.none, compressed);
    }

    // Encryption enabled: encrypt the [compression_flag][payload] bytes so
    // the compression algorithm is hidden inside the ciphertext.
    final ciphertext = await encryption.encrypt(compressed);
    return _prependEncryption(EncryptionFlag.aesGcm, ciphertext);
  }

  // ── Decode ──────────────────────────────────────────────────────────────────

  /// Decodes a stored value produced by [encode].
  ///
  /// Expects the Phase 12 two-byte prefix format:
  /// `[EncryptionFlag 1B][CompressionFlag 1B][payload]` for plaintext, or
  /// `[EncryptionFlag.aesGcm 1B][nonce+ciphertext+tag]` for encrypted values.
  ///
  /// When [encryption] is non-null, decrypts AES-GCM ciphertext before
  /// decompressing. If the stored value was encrypted with a different key,
  /// or the ciphertext is tampered, throws [EncryptionError.badCredentials].
  ///
  /// Throws [FormatException] if the byte sequence is malformed or the CBOR
  /// payload cannot be decoded as a [Map].
  ///
  /// Throws [ArgumentError] if [bytes] is empty, too short, or carries an
  /// unknown flag.
  ///
  /// Throws [UnsupportedError] if the flag identifies a compression algorithm
  /// not available on the current platform (e.g. Zstd on web).
  static Future<Map<String, dynamic>> decode(
    Uint8List bytes, {
    EncryptionProvider? encryption,
  }) async {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Cannot decode empty bytes');
    }

    // Read the outer encryption flag byte.
    // All values use the Phase 12 two-byte prefix format:
    //   [EncryptionFlag 1B][CompressionFlag 1B][payload]  — plaintext
    //   [EncryptionFlag.aesGcm 1B][nonce+ciphertext+tag]  — encrypted
    // EncryptionFlag.none (0x00) and EncryptionFlag.aesGcm (0x01) are the
    // only defined values; anything else throws via fromByte().
    final encFlag = EncryptionFlag.fromByte(bytes[0]);

    if (encFlag == EncryptionFlag.aesGcm) {
      // Phase 12 encrypted value. Decrypt to get [compression_flag][payload].
      if (encryption == null) {
        // Encrypted value in a database opened without a key — fail loudly.
        throw ArgumentError.value(
          bytes[0],
          'bytes[0]',
          'Value is AES-GCM encrypted but no EncryptionProvider was supplied. '
              'Open the database with an EncryptionConfig.',
        );
      }
      final ciphertext = bytes.sublist(1);
      final plaintext = await encryption.decrypt(ciphertext);
      // plaintext = [compression_flag][compressed-or-raw payload]
      if (plaintext.isEmpty) {
        throw const FormatException('Decrypted payload is empty');
      }
      final compressionFlag = CompressionFlag.fromByte(plaintext[0]);
      final payload = plaintext.sublist(1);
      final cborBytes = decompress(compressionFlag, payload);
      return _fromCbor(cborBytes);
    }

    // EncryptionFlag.none (0x00): Phase 12 unencrypted two-byte prefix format.
    // bytes[0] = EncryptionFlag.none, bytes[1] = CompressionFlag, bytes[2..] = payload.
    //
    // Phase 12 uses the two-byte prefix format for all values regardless of
    // whether encryption is active. Every encode() call now emits an
    // EncryptionFlag byte first, so decode always expects at least 2 bytes.
    if (bytes.length < 2) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'Value too short: expected [enc_flag][comp_flag][payload], got ${bytes.length} byte(s)',
      );
    }
    final compressionFlag = CompressionFlag.fromByte(bytes[1]);
    final payload = bytes.sublist(2);
    final cborBytes = decompress(compressionFlag, payload);
    return _fromCbor(cborBytes);
  }

  // ── CBOR helpers ────────────────────────────────────────────────────────────

  static Uint8List _toCbor(Map<String, dynamic> value) {
    final encoded = cbor.encode(CborValue(value));
    return Uint8List.fromList(encoded);
  }

  static Map<String, dynamic> _fromCbor(Uint8List bytes) {
    final decoded = cbor.decode(bytes);
    if (decoded is! CborMap) {
      throw FormatException('Expected CBOR map, got ${decoded.runtimeType}');
    }
    // toObject() returns Map<dynamic, dynamic> even for nested maps. Deep-cast
    // to Map<String, dynamic> so that FieldPath.resolve() can traverse nested
    // objects without hitting the Map<String, dynamic> type guard.
    final obj = decoded.toObject() as Map<dynamic, dynamic>;
    return _deepCastMap(obj);
  }

  static Map<String, dynamic> _deepCastMap(Map<dynamic, dynamic> m) {
    return m.map((k, v) => MapEntry(k as String, _deepCastValue(v)));
  }

  static dynamic _deepCastValue(dynamic v) {
    if (v is Map<dynamic, dynamic>) return _deepCastMap(v);
    if (v is List) return v.map(_deepCastValue).toList();
    return v;
  }

  // ── Utility ─────────────────────────────────────────────────────────────────

  /// Prepends the [CompressionFlag] byte to [payload].
  static Uint8List _prependCompression(
    CompressionFlag flag,
    Uint8List payload,
  ) {
    final out = Uint8List(1 + payload.length);
    out[0] = flag.byte;
    out.setAll(1, payload);
    return out;
  }

  /// Prepends the [EncryptionFlag] byte to [payload].
  static Uint8List _prependEncryption(EncryptionFlag flag, Uint8List payload) {
    final out = Uint8List(1 + payload.length);
    out[0] = flag.byte;
    out.setAll(1, payload);
    return out;
  }
}
