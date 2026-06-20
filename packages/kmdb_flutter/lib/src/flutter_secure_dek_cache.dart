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

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kmdb/kmdb.dart';

/// A persistent [DekCache] backed by [FlutterSecureStorage].
///
/// Stores the unwrapped Data Encryption Key (DEK) in platform-secure storage
/// so that the user is not prompted for their passphrase on every app launch:
///
/// - **iOS / macOS:** Apple Keychain, restricted to
///   [KeychainAccessibility.first_unlock_this_device] so the DEK is available
///   after the first unlock following a reboot, but is **never synced to iCloud
///   Keychain** (the "this device" variant keeps the key local).
/// - **Android:** Keystore-backed AES-GCM encryption via [AndroidOptions]
///   default (AES/GCM/NoPadding with RSA-OAEP key wrapping — API 23+).
///
/// ## Storage key derivation
///
/// The `dbId` passed to [store], [read], and [clear] is the database directory
/// path — as passed to `KmdbDatabase.open(path:)`. Because raw paths can
/// contain characters that are invalid or awkward in Keychain / Keystore key
/// names (`/`, spaces), the path is encoded as:
///
/// ```
/// kmdb_dek_<base64Url(utf8(dbId))>   (no padding)
/// ```
///
/// The base64url encoding is reversible, collision-free, and produces a key
/// that is valid on all platforms. No hash function is used because the key
/// only needs to be storage-safe, not opaque.
///
/// ## Path-stability caveat
///
/// The cache hit depends on the database path being **byte-identical** across
/// app launches. On iOS, the app sandbox container path can change after an OS
/// restore or device migration. If it does, [read] returns `null` and the user
/// is prompted to re-enter their passphrase — a graceful degradation, **not**
/// data loss. The roadmap 0.07 `PlatformIdStore` is designed to provide a
/// stable cross-path device identifier that will subsume this limitation; this
/// package is intended to be its first consumer.
///
/// ## Usage
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   encryptionConfig: EncryptionConfig(
///     passphrase: 'my-passphrase',
///     dekCache: FlutterSecureDekCache(),
///   ),
/// );
/// ```
///
/// To tighten security further (e.g., require biometric authentication),
/// supply custom options:
///
/// ```dart
/// FlutterSecureDekCache(
///   iosOptions: IOSOptions(
///     accessibility: KeychainAccessibility.first_unlock_this_device,
///     accessControlFlags: [AccessControlFlag.biometryAny],
///   ),
/// )
/// ```
final class FlutterSecureDekCache implements DekCache {
  /// Prefix used for all DEK storage keys, providing namespace isolation.
  static const _keyPrefix = 'kmdb_dek_';

  /// The underlying secure storage instance.
  final FlutterSecureStorage _storage;

  /// Platform-specific options applied when reading/writing the DEK on iOS.
  final IOSOptions _iosOptions;

  /// Platform-specific options applied when reading/writing the DEK on macOS.
  final MacOsOptions _macosOptions;

  /// Platform-specific options applied when reading/writing the DEK on Android.
  final AndroidOptions _androidOptions;

  /// Creates a [FlutterSecureDekCache] with secure-by-default platform options.
  ///
  /// The defaults are:
  ///
  /// - **iOS / macOS:** [KeychainAccessibility.first_unlock_this_device] —
  ///   the DEK is accessible after the first unlock following a reboot and is
  ///   never synced to iCloud Keychain.
  /// - **Android:** default [AndroidOptions] — AES/GCM/NoPadding data
  ///   encryption with RSA-OAEP key wrapping via Android Keystore (API 23+).
  ///
  /// Supply [iosOptions], [macosOptions], or [androidOptions] to override the
  /// defaults, for example to add biometric-gated access.
  FlutterSecureDekCache({
    IOSOptions? iosOptions,
    MacOsOptions? macosOptions,
    AndroidOptions? androidOptions,
  }) : _iosOptions =
           iosOptions ??
           const IOSOptions(
             // Accessible after first unlock — survives reboot without
             // requiring an immediate unlock. The "this_device" variant
             // ensures the key is NEVER synced to iCloud Keychain.
             accessibility: KeychainAccessibility.first_unlock_this_device,
           ),
       _macosOptions =
           macosOptions ??
           const MacOsOptions(
             // Same policy as iOS: available post-first-unlock, never
             // migrated via iCloud Keychain.
             accessibility: KeychainAccessibility.first_unlock_this_device,
           ),
       _androidOptions = androidOptions ?? const AndroidOptions(),
       _storage = const FlutterSecureStorage();

  /// Derives the Keychain/Keystore storage key for the given [dbId].
  ///
  /// The key is `kmdb_dek_<base64Url(utf8(dbId))>` without padding.
  /// base64url is used (rather than raw base64) because the standard alphabet
  /// avoids `+` and `/`, which may be problematic in some Keystore backends.
  static String _storageKey(String dbId) {
    // Encode the dbId as UTF-8 bytes, then base64url without padding.
    final encoded = base64Url.encode(utf8.encode(dbId));
    // Remove `=` padding characters for a cleaner key.
    final noPadding = encoded.replaceAll('=', '');
    return '$_keyPrefix$noPadding';
  }

  @override
  Future<void> store(String dbId, Uint8List dek) async {
    final key = _storageKey(dbId);
    // Encode the DEK bytes as base64url (no padding) for string storage.
    // base64url avoids characters that could cause issues across platforms.
    final value = base64Url.encode(dek).replaceAll('=', '');
    await _storage.write(
      key: key,
      value: value,
      iOptions: _iosOptions,
      mOptions: _macosOptions,
      aOptions: _androidOptions,
    );
  }

  @override
  Future<Uint8List?> read(String dbId) async {
    final key = _storageKey(dbId);
    final value = await _storage.read(
      key: key,
      iOptions: _iosOptions,
      mOptions: _macosOptions,
      aOptions: _androidOptions,
    );
    if (value == null) return null;

    // Decode the base64url-encoded DEK. Add padding if needed for decoding.
    final padded = _addBase64Padding(value);
    final decoded = base64Url.decode(padded);

    // Return a defensive copy so the caller cannot mutate the decoded bytes
    // and inadvertently corrupt a cached reference.
    return Uint8List.fromList(decoded);
  }

  @override
  Future<void> clear(String dbId) async {
    final key = _storageKey(dbId);
    await _storage.delete(
      key: key,
      iOptions: _iosOptions,
      mOptions: _macosOptions,
      aOptions: _androidOptions,
    );
  }

  /// Adds the necessary `=` padding characters to a base64url string so that
  /// the Dart [base64Url] codec can decode it.
  ///
  /// base64 strings must have a length that is a multiple of 4; padding
  /// ensures this invariant when we stripped it before storing.
  static String _addBase64Padding(String s) {
    final remainder = s.length % 4;
    if (remainder == 0) return s;
    return s.padRight(s.length + (4 - remainder), '=');
  }
}
