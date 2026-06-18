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

/// Distinguishes the class of encryption failure.
///
/// See [EncryptionError] for the exception type that carries these codes.
enum EncryptionErrorCode {
  /// Opening an encrypted database without supplying an [EncryptionConfig].
  ///
  /// Decoding would yield ciphertext-as-CBOR garbage; KMDB fails loudly and
  /// early instead of producing corrupt data.
  databaseIsEncrypted,

  /// Opening a plaintext database with an unlock [EncryptionConfig].
  ///
  /// Silently ignoring a supplied passphrase would be worse than rejecting it,
  /// because the caller would believe encryption is active when it is not.
  databaseIsNotEncrypted,

  /// The passphrase or recovery code does not match the stored wrapped DEK.
  ///
  /// Caused by AES-GCM tag failure on DEK unwrap. The database has not been
  /// modified; the caller should re-prompt for credentials.
  badCredentials,

  /// An [EncryptionConfig.create] config was supplied to a database that
  /// already has user data.
  ///
  /// Provisioning a new DEK on top of existing plaintext data would leave the
  /// existing data un-decryptable (it lacks the new encryption prefix). Only
  /// empty databases can be provisioned.
  cannotProvisionNonEmptyDatabase,

  /// AES-GCM decryption failed for a reason other than a bad key/tag.
  decryptionFailed,

  /// AES-GCM encryption failed.
  encryptionFailed,
}

/// Exception thrown for all encryption-layer failures.
///
/// The [code] field distinguishes the failure class so callers can provide
/// actionable error messages without parsing the [message] string.
///
/// ## Usage
///
/// ```dart
/// try {
///   final db = await KmdbDatabase.open(path: path, adapter: adapter,
///     encryption: EncryptionConfig(passphrase: 'wrong-password'));
/// } on EncryptionError catch (e) {
///   if (e.code == EncryptionErrorCode.badCredentials) {
///     // Re-prompt the user.
///   }
/// }
/// ```
final class EncryptionError implements Exception {
  /// Creates an [EncryptionError] with [code] and [message].
  const EncryptionError(this.code, this.message);

  /// Constructs an [EncryptionError.databaseIsEncrypted] error.
  ///
  /// Thrown when an encrypted database is opened without credentials.
  factory EncryptionError.databaseIsEncrypted() => const EncryptionError(
    EncryptionErrorCode.databaseIsEncrypted,
    'Database is encrypted — supply an EncryptionConfig with a passphrase or '
    'recovery code to open it.',
  );

  /// Constructs an [EncryptionError.databaseIsNotEncrypted] error.
  ///
  /// Thrown when an unlock [EncryptionConfig] is supplied to a plaintext DB.
  factory EncryptionError.databaseIsNotEncrypted() => const EncryptionError(
    EncryptionErrorCode.databaseIsNotEncrypted,
    'Database is not encrypted — do not supply an EncryptionConfig when '
    'opening a plaintext database.',
  );

  /// Constructs an [EncryptionError.badCredentials] error.
  ///
  /// Thrown when the passphrase or recovery code fails to unwrap the DEK.
  factory EncryptionError.badCredentials() => const EncryptionError(
    EncryptionErrorCode.badCredentials,
    'Wrong passphrase or recovery code — DEK unwrap failed.',
  );

  /// Constructs a [EncryptionErrorCode.cannotProvisionNonEmptyDatabase] error.
  ///
  /// Thrown when a `create` config is supplied to a database that already has
  /// user namespaces.
  factory EncryptionError.cannotProvisionNonEmptyDatabase() =>
      const EncryptionError(
        EncryptionErrorCode.cannotProvisionNonEmptyDatabase,
        'Cannot provision encryption on a non-empty database. '
        'Only empty databases can be encrypted at creation time.',
      );

  /// The kind of encryption failure.
  final EncryptionErrorCode code;

  /// Human-readable description of the failure.
  final String message;

  @override
  String toString() => 'EncryptionError(${code.name}): $message';
}
