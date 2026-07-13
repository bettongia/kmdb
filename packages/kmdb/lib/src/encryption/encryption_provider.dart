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

import 'dart:convert' show utf8;
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

  /// Derives a deterministic, keyed namespace token for [message] (Gap 2 of
  /// the Encryption confidentiality reconciliation plan, Q4).
  ///
  /// Used to replace the plaintext hex encoding of FTS terms and secondary
  /// index values in KvStore namespace names (e.g. `$$fts:{ns}:{field}:
  /// {hexTerm}`) with an HMAC-SHA256 token that does not reveal the
  /// underlying term/value to anyone without the database's DEK. Callers
  /// must pass an already domain-separated [message] so that the same term
  /// or value in different fields/namespaces never collides:
  /// `"{ns}:{field}:{term}"` for FTS, `"{ns}:{path}:{hexEncodedValue}"` for a
  /// secondary index, `"{sha256}:{term}"` for vault FTS.
  ///
  /// The `:`-join is a plain concatenation, not a length-prefixed encoding,
  /// so it is not fully collision-proof in the abstract: a collection
  /// namespace or field/path containing a literal `:` could in theory shift
  /// the split point and collide with a different (ns, field, term) triple
  /// that concatenates to the same string (e.g. `ns="a", field="b:c"` vs.
  /// `ns="a", field="b", term` starting with `"c:"`). The vault-FTS domain
  /// (`"{sha256}:{term}"`) is immune — `sha256` is always exactly 64 hex
  /// characters, so the split point is fixed regardless of `term`'s content
  /// — and the secondary-index domain's final component is always
  /// hex-encoded (`{hexEncodedValue}`), so it cannot itself introduce a
  /// `:`. The FTS domain's `ns`/`field` (and the secondary-index domain's
  /// `ns`/`path`) are drawn from application-chosen collection/field names,
  /// not attacker-controlled input in this threat model, and are not
  /// currently escaped against embedded `:` — a theoretical gap, not
  /// exploitable via untrusted data, and left unfixed as out of scope for
  /// this plan (Gap 2 exists to hide term/value *content*, not to defend
  /// against a database schema deliberately designed to produce colliding
  /// tokens).
  ///
  /// The token is computed from a sub-key **derived from, but distinct from,
  /// the DEK** via HKDF-SHA256 (`info = "kmdb-index-token"`) — never the raw
  /// DEK directly — so that a compromised index token cannot be used to
  /// derive the DEK itself. The sub-key is derived once (lazily, on first
  /// call) and cached for the lifetime of this provider.
  ///
  /// Returns a 32-character lowercase hex string (a 16-byte / 128-bit
  /// truncation of the full 32-byte HMAC-SHA256 output — ample forgery/
  /// collision resistance for a local-disk namespace token while keeping
  /// namespace names compact; see `namespace_codec.dart`'s 255-byte cap).
  ///
  /// Deterministic and reproducible across process restarts for a given DEK:
  /// the same [message] always produces the same token as long as the
  /// database's DEK is unchanged. Passphrase/recovery-code rotation re-wraps
  /// the DEK but does not change it, so tokens survive rotation — see §31's
  /// "DEK rotation and index tokens" note. A future "change the DEK" feature
  /// would invalidate every token and require a full index rebuild.
  Future<String> indexToken(String message);
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

  // ── Namespace token derivation (Gap 2, Q4) ─────────────────────────────────

  /// HKDF info string for [indexToken]'s sub-key: `kmdb-index-token`.
  ///
  /// Domain-separates this HKDF output from every other HKDF use in KMDB
  /// (currently only the recovery-KEK derivation in `key_derivation.dart`,
  /// whose info string is `kmdb-recovery-kek-v1`), so the two derivations can
  /// never collide even though both start from key material tied to the same
  /// database.
  static const List<int> _kIndexTokenInfo = [
    // b'kmdb-index-token'
    0x6b, 0x6d, 0x64, 0x62, 0x2d, 0x69, 0x6e, 0x64,
    0x65, 0x78, 0x2d, 0x74, 0x6f, 0x6b, 0x65, 0x6e,
  ];

  /// The HMAC-SHA256 algorithm used both for HKDF (sub-key derivation) and
  /// for computing the per-message token itself.
  static final _hmacSha256 = Hmac(Sha256());

  /// Lazily-derived, cached sub-key used by [indexToken].
  ///
  /// Memoized as a `Future` (not the resolved bytes) so that concurrent
  /// callers racing to compute the very first token all await the same
  /// in-flight derivation rather than each independently deriving it — HKDF
  /// is deterministic, so a duplicate derivation would not be incorrect, just
  /// wasteful.
  Future<SecretKey>? _indexTokenSubKeyFuture;

  Future<SecretKey> _indexTokenSubKey() {
    return _indexTokenSubKeyFuture ??= Hkdf(hmac: _hmacSha256, outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(_dek),
          nonce: const <int>[],
          info: _kIndexTokenInfo,
        );
  }

  @override
  Future<String> indexToken(String message) async {
    final subKey = await _indexTokenSubKey();
    final mac = await _hmacSha256.calculateMac(
      utf8.encode(message),
      secretKey: subKey,
    );
    // Truncate the 32-byte HMAC-SHA256 output to 16 bytes (128 bits) — see
    // the [EncryptionProvider.indexToken] doc comment for the rationale.
    final truncated = mac.bytes.sublist(0, 16);
    return truncated.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
