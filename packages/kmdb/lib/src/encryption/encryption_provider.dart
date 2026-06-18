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

import 'package:cryptography/cryptography.dart';

import 'encryption_error.dart';

/// Abstract interface for value-level encryption used by [ValueCodec].
///
/// An [EncryptionProvider] is stateless from the caller's perspective — it
/// holds the cached DEK internally and presents a simple encrypt/decrypt API.
/// The concrete implementation ([AesGcmEncryptionProvider]) uses AES-256-GCM
/// with a random 96-bit nonce per call.
///
/// Thread safety: all methods are safe to call concurrently from multiple
/// isolates if the concrete implementation is so.
abstract interface class EncryptionProvider {
  /// Encrypts [plaintext] and returns the ciphertext.
  ///
  /// The returned bytes include any nonce / IV and authentication tag needed
  /// for decryption (the format is implementation-defined but
  /// [AesGcmEncryptionProvider] uses `[96-bit nonce][ciphertext][16-byte tag]`).
  ///
  /// Throws [EncryptionError] if encryption fails.
  Future<Uint8List> encrypt(Uint8List plaintext);

  /// Decrypts [ciphertext] previously produced by [encrypt].
  ///
  /// Throws [EncryptionError.badCredentials] if authentication verification
  /// fails (wrong key, tampered ciphertext, or truncated data).
  ///
  /// Throws [EncryptionError] for other failure modes.
  Future<Uint8List> decrypt(Uint8List ciphertext);
}

/// AES-256-GCM implementation of [EncryptionProvider].
///
/// Wire format for encrypted payloads:
/// ```
/// [96-bit nonce (12 bytes)][AES-GCM ciphertext][16-byte GCM tag]
/// ```
///
/// Nonces are 96-bit cryptographically-random values generated fresh per call.
/// This is the standard GCM nonce size (NIST SP 800-38D) and provides
/// negligible collision probability for the expected number of writes per DEK.
///
/// The DEK is a 256-bit (32-byte) symmetric key. It is never stored in
/// plaintext; callers receive this object after the DEK has been derived or
/// unwrapped from its encrypted envelope.
///
/// ## Associated data
///
/// No additional authenticated data (AAD) is used for document values.
/// The GCM tag covers both the ciphertext and the implicit empty AAD, so any
/// modification or truncation of the stored bytes is detected on decrypt.
final class AesGcmEncryptionProvider implements EncryptionProvider {
  /// Creates a provider wrapping the given [_dek].
  ///
  /// [_dek] must be exactly 32 bytes (256 bits).
  AesGcmEncryptionProvider(this._dek) {
    if (_dek.length != 32) {
      throw ArgumentError.value(
        _dek.length,
        'dek.length',
        'DEK must be exactly 32 bytes (256 bits)',
      );
    }
  }

  final Uint8List _dek;

  /// AES-256-GCM instance from the `cryptography` package.
  ///
  /// 16-byte MAC length (GCM tag) is the standard and is non-negotiable for
  /// AES-GCM; the `cryptography` package default is also 16.
  static final _algorithm = AesGcm.with256bits(nonceLength: 12);

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final secretKey = SecretKey(_dek);
    // Generate a fresh random 96-bit nonce for each call.
    // cryptography.AesGcm.newNonce() uses a cryptographically secure RNG.
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // Concatenate: [nonce (12B)] [ciphertext] [mac (16B)]
    // The mac is stored at the end, following the common convention for
    // append-only streams (nonce can be read-ahead).
    final result = Uint8List(
      nonce.length + box.cipherText.length + box.mac.bytes.length,
    );
    var offset = 0;
    result.setAll(offset, nonce);
    offset += nonce.length;
    result.setAll(offset, box.cipherText);
    offset += box.cipherText.length;
    result.setAll(offset, box.mac.bytes);
    return result;
  }

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    // Minimum size: 12 (nonce) + 0 (empty plaintext) + 16 (tag) = 28 bytes.
    const int kNonceLength = 12;
    const int kTagLength = 16;
    const int kMinLength = kNonceLength + kTagLength;

    if (ciphertext.length < kMinLength) {
      throw EncryptionError(
        EncryptionErrorCode.badCredentials,
        'Ciphertext too short to be valid AES-GCM output '
        '(${ciphertext.length} bytes, minimum $kMinLength)',
      );
    }

    final nonce = ciphertext.sublist(0, kNonceLength);
    final tagStart = ciphertext.length - kTagLength;
    final encrypted = ciphertext.sublist(kNonceLength, tagStart);
    final tag = ciphertext.sublist(tagStart);

    final secretKey = SecretKey(_dek);
    final box = SecretBox(encrypted, nonce: nonce, mac: Mac(tag));

    try {
      final plaintext = await _algorithm.decrypt(box, secretKey: secretKey);
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      // GCM authentication tag mismatch — wrong key or tampered ciphertext.
      throw EncryptionError(
        EncryptionErrorCode.badCredentials,
        'AES-GCM authentication failed — wrong key, tampered, or corrupted data',
      );
    } catch (e) {
      throw EncryptionError(
        EncryptionErrorCode.decryptionFailed,
        'AES-GCM decryption failed: $e',
      );
    }
  }

  /// Returns the raw DEK bytes.
  ///
  /// Exposed for key-management operations (re-wrap, change-passphrase) that
  /// need to extract the DEK from an unlocked provider. Must not be stored or
  /// logged.
  Uint8List get dek => Uint8List.fromList(_dek);
}
