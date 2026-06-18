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

import 'dek_cache.dart';
import 'encryption_provider.dart';
import 'key_derivation.dart';
import 'recovery_code.dart';

/// Configures how an existing encrypted database is unlocked, or how a new
/// encrypted database is provisioned.
///
/// ## Opening an existing encrypted database
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: path,
///   adapter: adapter,
///   encryptionConfig: EncryptionConfig(passphrase: 'my-passphrase'),
/// );
/// ```
///
/// Or with a recovery code (16-word mnemonic):
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: path,
///   adapter: adapter,
///   encryptionConfig: EncryptionConfig(
///     recoveryCode: 'able acid aged also apex arch area army ...',
///   ),
/// );
/// ```
///
/// ## Creating a new encrypted database
///
/// ```dart
/// final result = await EncryptionConfig.createResult(passphrase: '...');
/// final db = await KmdbDatabase.open(
///   path: path,
///   adapter: adapter,
///   encryptionConfig: result.config,
/// );
/// // Show result.recoveryCode to the user exactly once — it cannot be
/// // recovered if lost.
/// print('Recovery code: ${result.recoveryCode}');
/// ```
///
/// ## DEK caching
///
/// By default the [dekCache] is an [InMemoryDekCache] (the DEK is held for the
/// current process lifetime only). On Flutter mobile/desktop, inject a
/// `FlutterSecureDekCache` from the `kmdb_flutter` add-on package to persist
/// the DEK across app restarts without re-prompting the user.
final class EncryptionConfig {
  /// Creates an unlock config for an existing encrypted database.
  ///
  /// Exactly one of [passphrase] or [recoveryCode] must be supplied.
  ///
  /// [dekCache] is the session DEK cache. Defaults to [InMemoryDekCache].
  /// Inject a `FlutterSecureDekCache` on Flutter mobile/desktop apps.
  EncryptionConfig({
    String? passphrase,
    String? recoveryCode,
    DekCache? dekCache,
  }) : _passphrase = passphrase,
       _recoveryCode = recoveryCode,
       _provisioning = false,
       _provisioningDek = null,
       _provisioningSalt = null,
       _provisioningRecoveryEntropy = null,
       dekCache = dekCache ?? InMemoryDekCache() {
    if (passphrase == null && recoveryCode == null) {
      throw ArgumentError(
        'Exactly one of passphrase or recoveryCode must be supplied to '
        'EncryptionConfig. To create a new encrypted database, use '
        'EncryptionConfig.createResult().',
      );
    }
    if (passphrase != null && recoveryCode != null) {
      throw ArgumentError(
        'Only one of passphrase or recoveryCode may be supplied, not both.',
      );
    }
  }

  /// Creates a provisioning config that creates a new encrypted database.
  ///
  /// This constructor is private; callers use [createResult] which returns
  /// both the config and the one-time recovery code mnemonic.
  EncryptionConfig._provision({
    required String this._passphrase,
    required Uint8List dek,
    required Uint8List salt,
    required Uint8List recoveryEntropy,
    DekCache? dekCache,
  }) : _recoveryCode = null,
       _provisioning = true,
       _provisioningDek = dek,
       _provisioningSalt = salt,
       _provisioningRecoveryEntropy = recoveryEntropy,
       dekCache = dekCache ?? InMemoryDekCache();

  /// Creates a new [EncryptionConfig] that provisions encryption on a new
  /// database and returns it alongside the one-time recovery code.
  ///
  /// The [recoveryCode] field of the returned [EncryptionSetupResult] is the
  /// **only** time the recovery mnemonic is presented. It must be shown to the
  /// user and kept in a safe place; it cannot be recovered from the database.
  ///
  /// ```dart
  /// final result = await EncryptionConfig.createResult(passphrase: 'my-passphrase');
  /// final db = await KmdbDatabase.open(
  ///   path: path, adapter: adapter,
  ///   encryptionConfig: result.config,
  /// );
  /// // Show result.recoveryCode to the user.
  /// ```
  static Future<EncryptionSetupResult> createResult({
    required String passphrase,
    DekCache? dekCache,
  }) async {
    // Generate fresh DEK, Argon2id salt, and recovery entropy.
    final dek = await KeyDerivation.generateDek();
    final salt = await KeyDerivation.generateSalt();
    final recoveryEntropy = await KeyDerivation.generateRecoveryEntropy();
    final recoveryCode = RecoveryCode.encode(recoveryEntropy);

    final config = EncryptionConfig._provision(
      passphrase: passphrase,
      dek: dek,
      salt: salt,
      recoveryEntropy: recoveryEntropy,
      dekCache: dekCache,
    );
    return EncryptionSetupResult(config: config, recoveryCode: recoveryCode);
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  final String? _passphrase;
  final String? _recoveryCode;

  /// Whether this config was created via [_provision] (creates a new DB).
  final bool _provisioning;

  // Pre-generated values supplied only when [_provisioning] is true.
  final Uint8List? _provisioningDek;
  final Uint8List? _provisioningSalt;
  final Uint8List? _provisioningRecoveryEntropy;

  /// The DEK session cache. Stores the unwrapped DEK after the first unlock so
  /// the user is not re-prompted for their passphrase each session.
  final DekCache dekCache;

  /// Whether this config will provision a new encrypted database.
  ///
  /// `true` → this is a [createResult] config; a new DEK is generated and
  ///          stored. Fails if the database already has user data.
  /// `false` → this is an unlock config; the existing wrapped DEK is
  ///           unwrapped with the supplied credentials.
  bool get isProvisioning => _provisioning;

  // ── Internal bootstrap API ─────────────────────────────────────────────────

  /// Returns the pre-generated DEK (only valid when [isProvisioning] is true).
  Uint8List get provisioningDek {
    assert(
      _provisioning,
      'provisioningDek only valid for provisioning configs',
    );
    return _provisioningDek!;
  }

  /// Returns the pre-generated Argon2id salt (provisioning only).
  Uint8List get provisioningSalt {
    assert(
      _provisioning,
      'provisioningSalt only valid for provisioning configs',
    );
    return _provisioningSalt!;
  }

  /// Returns the pre-generated recovery entropy (provisioning only).
  Uint8List get provisioningRecoveryEntropy {
    assert(
      _provisioning,
      'provisioningRecoveryEntropy only valid for provisioning configs',
    );
    return _provisioningRecoveryEntropy!;
  }

  /// Derives the KEK from the supplied passphrase and [salt].
  ///
  /// Returns `null` if this config uses a recovery code (not a passphrase).
  Future<Uint8List?> derivePassphraseKek(Uint8List salt) async {
    final pp = _passphrase;
    if (pp == null) return null;
    return KeyDerivation.deriveKekFromPassphrase(pp, salt);
  }

  /// Derives the KEK from the supplied recovery code.
  ///
  /// Returns `null` if this config uses a passphrase (not a recovery code).
  Future<Uint8List?> deriveRecoveryKek() async {
    final rc = _recoveryCode;
    if (rc == null) return null;
    // Decode the 16-word mnemonic back to 128-bit entropy.
    final entropy = RecoveryCode.decode(rc);
    return KeyDerivation.deriveKekFromRecoveryEntropy(entropy);
  }

  /// Unwraps [wrappedDek] using the passphrase KEK derived from [salt].
  ///
  /// Returns `null` if decryption fails (wrong passphrase or no passphrase).
  Future<Uint8List?> tryUnwrapWithPassphrase(
    Uint8List wrappedDek,
    Uint8List salt,
  ) async {
    final kek = await derivePassphraseKek(salt);
    if (kek == null) return null;
    return KeyDerivation.unwrapDek(wrappedDek, kek);
  }

  /// Unwraps [wrappedDek] using the recovery KEK.
  ///
  /// Returns `null` if decryption fails (wrong recovery code or no recovery
  /// code).
  Future<Uint8List?> tryUnwrapWithRecovery(Uint8List wrappedDek) async {
    final kek = await deriveRecoveryKek();
    if (kek == null) return null;
    return KeyDerivation.unwrapDek(wrappedDek, kek);
  }

  /// Wraps [dek] under the passphrase KEK derived from [salt].
  ///
  /// Used during provisioning and passphrase change.
  Future<Uint8List> wrapDekWithPassphrase(Uint8List dek, Uint8List salt) async {
    final kek = await KeyDerivation.deriveKekFromPassphrase(_passphrase!, salt);
    return KeyDerivation.wrapDek(dek, kek);
  }

  /// Wraps [dek] under the recovery KEK derived from [recoveryEntropy].
  ///
  /// Used during provisioning to store the recovery-wrapped DEK.
  Future<Uint8List> wrapDekWithRecovery(
    Uint8List dek,
    Uint8List recoveryEntropy,
  ) async {
    final kek = await KeyDerivation.deriveKekFromRecoveryEntropy(
      recoveryEntropy,
    );
    return KeyDerivation.wrapDek(dek, kek);
  }

  /// Builds an [AesGcmEncryptionProvider] from [dek].
  EncryptionProvider buildProvider(Uint8List dek) =>
      AesGcmEncryptionProvider(dek);
}

/// Returned by [EncryptionConfig.createResult] when provisioning a new
/// encrypted database.
///
/// [config] is the provisioning [EncryptionConfig] to pass to
/// `KmdbDatabase.open`. [recoveryCode] is the one-time 16-word mnemonic that
/// must be shown to the user and stored safely — it is the only way to recover
/// the database if the passphrase is forgotten.
final class EncryptionSetupResult {
  /// Creates an [EncryptionSetupResult].
  const EncryptionSetupResult({
    required this.config,
    required this.recoveryCode,
  });

  /// The provisioning config to pass to [KmdbDatabase.open].
  final EncryptionConfig config;

  /// The 16-word space-separated recovery mnemonic.
  ///
  /// **Show this to the user exactly once.** It cannot be regenerated from the
  /// database. Losing both the passphrase and the recovery code means the data
  /// is unrecoverable.
  final String recoveryCode;
}
