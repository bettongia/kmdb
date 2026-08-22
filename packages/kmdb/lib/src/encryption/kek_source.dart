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

import 'biometric_kek_provider.dart';

/// @docImport 'encryption_config.dart';
/// @docImport 'package:kmdb/src/query/kmdb_database.dart';

/// Selects which credential [KmdbDatabase]'s encryption bootstrap uses to
/// derive the Key Encryption Key (KEK) that unwraps the DEK (WI-5, closing
/// SC-1).
///
/// [EncryptionConfig] builds the appropriate [KEKSource] internally from its
/// constructor arguments — most callers never construct one directly:
///
/// - `EncryptionConfig(passphrase: '...')` → [KEKSource.passphrase]
/// - `EncryptionConfig(recoveryCode: '...')` → [KEKSource.recoveryCode]
/// - `EncryptionConfig.biometric(provider)` → [KEKSource.biometric]
///
/// This is a closed (`sealed`) hierarchy: every unlock path the bootstrap
/// supports is represented by exactly one variant, so a new unlock mechanism
/// requires an explicit addition here rather than an ad hoc branch.
sealed class KEKSource {
  const KEKSource();

  /// Unlocks using an Argon2id-derived KEK from a user-supplied passphrase.
  const factory KEKSource.passphrase(String passphrase) = PassphraseKekSource;

  /// Unlocks using an HKDF-derived KEK from a 16-word recovery mnemonic.
  const factory KEKSource.recoveryCode(String recoveryCode) =
      RecoveryCodeKekSource;

  /// Unlocks using a KEK released by a platform biometric authenticator.
  ///
  /// See [BiometricKekProvider] for the idempotent get-or-create contract
  /// [provider] must satisfy.
  const factory KEKSource.biometric(BiometricKekProvider provider) =
      BiometricKekSource;
}

/// A [KEKSource] that derives its KEK from a user-supplied passphrase via
/// Argon2id.
final class PassphraseKekSource extends KEKSource {
  const PassphraseKekSource(this.passphrase);

  /// The passphrase to derive the Argon2id KEK from.
  final String passphrase;
}

/// A [KEKSource] that derives its KEK from a 16-word recovery mnemonic via
/// HKDF-SHA256.
final class RecoveryCodeKekSource extends KEKSource {
  const RecoveryCodeKekSource(this.recoveryCode);

  /// The space-separated 16-word recovery mnemonic.
  final String recoveryCode;
}

/// A [KEKSource] that obtains its KEK from a platform biometric
/// authenticator.
final class BiometricKekSource extends KEKSource {
  const BiometricKekSource(this.provider);

  /// The platform-specific biometric KEK provider.
  final BiometricKekProvider provider;
}
