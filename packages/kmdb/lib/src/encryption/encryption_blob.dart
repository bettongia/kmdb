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

/// The persisted encryption metadata blob stored in `$meta` under `enc:blob`.
///
/// This blob is written once at database-creation time and replaced atomically
/// on passphrase change. It is stored as **plaintext CBOR** via
/// `MetaStore.getRawByName`/`putRawByName` — the blob must be readable before
/// the DEK is available (bootstrap is non-circular by design).
///
/// The wrapped DEK values inside the blob are AES-GCM ciphertext, so an
/// attacker with the blob still needs the passphrase or recovery entropy to
/// recover the DEK. The blob is not itself sensitive.
///
/// ## Wire format (CBOR map)
///
/// ```
/// {
///   'v':     1,                  // schema version (forward compatibility)
///   'salt':  <bytes>,            // 32-byte Argon2id salt
///   'wdekP': <bytes>,            // wrapped DEK (passphrase path)
///   'wdekR': <bytes>,            // wrapped DEK (recovery path)
///   'm':     65536,              // Argon2id memory cost (KiB) — informational
///   't':     3,                  // Argon2id iteration count — informational
///   'p':     1,                  // Argon2id parallelism — informational
/// }
/// ```
///
/// The `m`/`t`/`p` fields are informational (useful for diagnostic output);
/// the actual KDF parameters are hardcoded in [KeyDerivation] and are not
/// varied at runtime. They are stored so future versions can detect parameter
/// changes introduced by newer builds.
final class EncryptionBlob {
  /// Creates an [EncryptionBlob].
  const EncryptionBlob({
    required this.argon2Salt,
    required this.wrappedDekPassphrase,
    required this.wrappedDekRecovery,
    this.argon2Memory = 65536,
    this.argon2Iterations = 3,
    this.argon2Parallelism = 1,
  });

  /// Current CBOR map schema version.
  static const int kVersion = 1;

  /// 32-byte Argon2id salt used to derive the passphrase KEK.
  final Uint8List argon2Salt;

  /// AES-GCM-wrapped DEK (passphrase path).
  /// Format: `[12-byte nonce][32-byte ct][16-byte tag]` = 60 bytes.
  final Uint8List wrappedDekPassphrase;

  /// AES-GCM-wrapped DEK (recovery-code path).
  /// Format: `[12-byte nonce][32-byte ct][16-byte tag]` = 60 bytes.
  final Uint8List wrappedDekRecovery;

  /// Argon2id memory cost in KiB (informational — stored for diagnostic use).
  final int argon2Memory;

  /// Argon2id iteration count (informational).
  final int argon2Iterations;

  /// Argon2id parallelism (informational).
  final int argon2Parallelism;

  // ── Serialisation ──────────────────────────────────────────────────────────

  /// Encodes this blob to CBOR bytes for storage in `$meta` via
  /// `MetaStore.putRawByName('enc:blob', ...)`.
  Uint8List encode() {
    final map = CborMap({
      CborString('v'): CborSmallInt(kVersion),
      CborString('salt'): CborBytes(argon2Salt),
      CborString('wdekP'): CborBytes(wrappedDekPassphrase),
      CborString('wdekR'): CborBytes(wrappedDekRecovery),
      CborString('m'): CborSmallInt(argon2Memory),
      CborString('t'): CborSmallInt(argon2Iterations),
      CborString('p'): CborSmallInt(argon2Parallelism),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  /// Decodes an [EncryptionBlob] from [bytes] previously produced by [encode].
  ///
  /// Throws [FormatException] if the bytes are not valid CBOR or required
  /// fields are missing / have wrong types.
  factory EncryptionBlob.decode(Uint8List bytes) {
    final CborValue decoded;
    try {
      decoded = cbor.decode(bytes);
    } catch (e) {
      throw FormatException('Invalid encryption blob CBOR: $e');
    }
    if (decoded is! CborMap) {
      throw FormatException(
        'Encryption blob must be a CBOR map, got ${decoded.runtimeType}',
      );
    }

    // Use toObject() to get a plain Dart map, consistent with the rest of the
    // codebase (see IndexManager._decodeState, FtsManager, etc.).
    final map = decoded.toObject() as Map<dynamic, dynamic>;

    Uint8List getBytes(String key) {
      final v = map[key];
      if (v is! List) {
        throw FormatException(
          'Missing or invalid field "$key" in enc:blob: expected bytes, got ${v?.runtimeType}',
        );
      }
      return Uint8List.fromList(List<int>.from(v));
    }

    int getInt(String key) {
      final v = map[key];
      if (v is! int) {
        throw FormatException(
          'Missing or invalid int field "$key" in enc:blob: got ${v?.runtimeType}',
        );
      }
      return v;
    }

    return EncryptionBlob(
      argon2Salt: getBytes('salt'),
      wrappedDekPassphrase: getBytes('wdekP'),
      wrappedDekRecovery: getBytes('wdekR'),
      argon2Memory: getInt('m'),
      argon2Iterations: getInt('t'),
      argon2Parallelism: getInt('p'),
    );
  }
}
