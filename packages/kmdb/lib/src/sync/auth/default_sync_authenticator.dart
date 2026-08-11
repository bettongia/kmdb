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

import 'sync_artifact_class.dart';
import 'sync_authenticator.dart';

/// The default, pure-Dart [SyncAuthenticator], backed by a raw 256-bit
/// sync-set root key held in Dart-visible memory.
///
/// Suitable for native hosts (the CLI, desktop, mobile) where the root key
/// is read from a [SecretStore] implementation and there is no equivalent of
/// a browser's script-readable heap to defend against. **Not used on web** —
/// see the web-specific `WebSyncAuthenticator`, which keeps the key inside a
/// non-extractable WebCrypto `CryptoKey` instead of a plain [Uint8List]
/// (0.10.01 WI-4 Q4).
///
/// ## Derivation
///
/// Mirrors `AesGcmEncryptionProvider._indexTokenSubKey`
/// (`encryption_provider.dart:279-287`) exactly: for each
/// [SyncArtifactClass], an HKDF-SHA256 sub-key is derived from the root key
/// via `Hkdf(hmac: Hmac(Sha256()), outputLength: 32).deriveKey(secretKey:
/// rootKey, nonce: [], info: artifactClass.hkdfInfo)`, memoized per class so
/// concurrent first-callers for the same class await one in-flight
/// derivation rather than each deriving it independently (HKDF is
/// deterministic, so a duplicate derivation would not be incorrect, just
/// wasteful).
///
/// The MAC itself is HMAC-SHA256 over the caller-supplied message, truncated
/// to the leading 16 bytes (128 bits) — matching `indexToken`'s truncation
/// (`encryption_provider.dart:297`, `mac.bytes.sublist(0, 16)`).
final class DefaultSyncAuthenticator implements SyncAuthenticator {
  /// Creates a [DefaultSyncAuthenticator] from a 256-bit (32-byte) raw
  /// [rootKey].
  ///
  /// Throws [ArgumentError] if [rootKey] is not exactly [kRootKeyLength]
  /// bytes. [rootKey] is defensively copied — the caller may safely mutate
  /// or discard its own reference after construction.
  DefaultSyncAuthenticator(Uint8List rootKey)
    : _rootKey = Uint8List.fromList(rootKey) {
    if (_rootKey.length != kRootKeyLength) {
      throw ArgumentError.value(
        rootKey.length,
        'rootKey.length',
        'Sync-auth root key must be exactly $kRootKeyLength bytes',
      );
    }
  }

  /// The required length, in bytes, of the sync-set root key (256 bits).
  static const int kRootKeyLength = 32;

  /// The MAC length, in bytes (128 bits) — see the class doc comment.
  static const int kMacLength = 16;

  final Uint8List _rootKey;

  /// The HMAC-SHA256 algorithm, used both for HKDF (sub-key derivation) and
  /// for computing the per-message MAC itself — same instance-reuse pattern
  /// as `AesGcmEncryptionProvider._hmacSha256`.
  static final _hmacSha256 = Hmac(Sha256());

  /// Lazily-derived, memoized sub-keys, one per [SyncArtifactClass].
  final Map<SyncArtifactClass, Future<SecretKey>> _subKeys = {};

  Future<SecretKey> _subKeyFor(SyncArtifactClass artifactClass) {
    return _subKeys.putIfAbsent(
      artifactClass,
      () => Hkdf(hmac: _hmacSha256, outputLength: 32).deriveKey(
        secretKey: SecretKey(_rootKey),
        nonce: const <int>[],
        info: artifactClass.hkdfInfo,
      ),
    );
  }

  @override
  Future<Uint8List> mac(
    SyncArtifactClass artifactClass,
    Uint8List message,
  ) async {
    final subKey = await _subKeyFor(artifactClass);
    final mac = await _hmacSha256.calculateMac(message, secretKey: subKey);
    return Uint8List.fromList(mac.bytes.sublist(0, kMacLength));
  }

  @override
  Future<bool> verify(
    SyncArtifactClass artifactClass,
    Uint8List message,
    Uint8List mac,
  ) async {
    final expected = await this.mac(artifactClass, message);
    return _constantTimeEquals(expected, mac);
  }

  /// Compares [a] and [b] in constant time with respect to their content.
  ///
  /// A length mismatch short-circuits (both MACs here are always
  /// [kMacLength] bytes by construction, so this branch is defensive rather
  /// than a real timing channel — an attacker who can vary length is already
  /// not constrained to a fixed-length MAC). Byte comparison always visits
  /// every index of the shorter operand, XOR-accumulating differences rather
  /// than branching or returning early, so total execution time does not
  /// depend on the position of the first mismatching byte.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
