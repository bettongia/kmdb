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

import 'credential_store/directory_credential_store.dart';

/// Storage abstraction for CLI-managed cloud sync credentials (currently:
/// the Google Drive OAuth blob written by `kmdb remote add --type
/// google-drive`).
///
/// This is a *per-machine, non-synced, CLI-only* secret store — it never
/// touches the `kmdb` core database, `EncryptionProvider`, or any synced
/// surface. See `docs/spec/` (CLI credential store section, §31 gap 9) for
/// the full design rationale.
///
/// The only implementation shipped today is [DirectoryCredentialStore],
/// which hardens `{dbDir}/local/` with POSIX permissions (`chmod 700`
/// directory, `chmod 600` file) rather than integrating with an OS-native
/// keychain — see [DirectoryCredentialStore]'s doc comment for the full
/// permission model. OS-native keychain integration (macOS Keychain,
/// Windows Credential Manager, Linux Secret Service) is deferred; see
/// `docs/roadmap/9_99.md`.
///
/// This interface exists as an injection seam even though only one
/// implementation ships: it costs nothing extra now, gives tests a seam to
/// avoid ever touching real credential storage, and gives a future
/// native-backend pickup somewhere to slot in without reshaping call sites.
abstract interface class CredentialStore {
  /// Writes [secretJson] under [account], overwriting any existing value.
  ///
  /// [account] is used directly as the storage key — for
  /// [DirectoryCredentialStore], the filename within `{dbDir}/local/`. There
  /// is no separate service/account split: a store is already scoped to one
  /// database directory, so a bare filename cannot collide across databases.
  Future<void> write(String account, String secretJson);

  /// Reads the secret stored under [account].
  ///
  /// Returns `null` if no secret has been written for [account] (callers
  /// typically convert this to a "run remote add" style error). Returns the
  /// secret JSON string on success.
  ///
  /// May throw [CredentialPermissionException] if the underlying storage is
  /// found to be readable by users other than the owner — see
  /// [DirectoryCredentialStore] for the exact predicate.
  Future<String?> read(String account);

  /// Deletes the secret stored under [account].
  ///
  /// A no-op if no secret exists for [account].
  Future<void> delete(String account);

  /// Returns the [CredentialStore] appropriate for the current platform.
  ///
  /// Synchronous — unlike an OS-native-keychain design, there is no native
  /// store to probe asynchronously in v1; this always resolves to a
  /// [DirectoryCredentialStore] rooted at [dbDir].
  factory CredentialStore.forPlatform({required String dbDir}) =>
      DirectoryCredentialStore(dbDir: dbDir);
}

/// Thrown by [CredentialStore.read] when the credential file or its parent
/// directory is found with looser-than-expected POSIX permissions.
///
/// Modelled on OpenSSH's `Permissions 0644 for '...' are too open` refusal:
/// rather than silently reading a secret the store can no longer vouch for,
/// the read is hard-refused with an error naming the exact `chmod` command
/// that fixes it.
final class CredentialPermissionException implements Exception {
  /// Creates a [CredentialPermissionException] for the offending [path].
  CredentialPermissionException({
    required this.path,
    required this.actualMode,
    required this.expectedMode,
  });

  /// The absolute path of the offending file or directory.
  final String path;

  /// The POSIX permission bits actually observed on [path] (low 9 bits of
  /// `FileStat.mode`, as returned by `stat()`).
  final int actualMode;

  /// The POSIX permission bits [path] is expected to have (`0o600` for
  /// credential files, `0o700` for the containing `local/` directory).
  final int expectedMode;

  @override
  String toString() {
    final actual = actualMode.toRadixString(8).padLeft(3, '0');
    final expected = expectedMode.toRadixString(8).padLeft(3, '0');
    return 'Credentials at $path are readable by others (mode $actual). '
        'Fix with: chmod $expected $path';
  }
}
