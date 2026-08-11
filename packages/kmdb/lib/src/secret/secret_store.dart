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

/// Byte-oriented storage abstraction for host-provided secret storage.
///
/// This is the core-package seam that `KmdbDatabase.open`'s unlock-policy
/// bootstrap reads/writes through — the per-device biometric-wrapped DEK and
/// "passphrase last used" re-authentication timestamp (WI-5, closing SC-1;
/// see `dbScopedSecretKey` in `secret_key.dart`) — and that a future
/// `SyncAuthenticator` root key (or any other core-owned secret) can reuse.
/// It is an `abstract interface class` in core, with an in-memory default in
/// this same file ([InMemorySecretStore]), and platform/host-backed
/// implementations supplied from outside the package — e.g. `kmdb_cli`'s
/// `DirectorySecretStore`, a permission-hardened filesystem store rooted at
/// the per-user profile config directory.
///
/// Unlike `kmdb_cli`'s former `CredentialStore` (string-oriented,
/// `write(account, secretJson)`), this interface is byte-oriented: a root
/// key is 32 raw bytes, and round-tripping bytes through a JSON string is
/// the wrong shape for that use case. Callers that need to store structured
/// data (e.g. a JSON credential blob) encode/decode at the call site.
///
/// ## Key format
///
/// [key] is an opaque storage key scoped to whatever the concrete
/// implementation is itself scoped to (e.g. one database directory, one
/// profile config directory). There is no service/account split — a bare
/// key is sufficient because a single [SecretStore] instance never spans
/// multiple unrelated secret namespaces.
///
/// ## OS-native keychain integration
///
/// Native keychain integration (macOS Keychain, Windows Credential Manager,
/// Linux Secret Service) is deferred (see `docs/roadmap/9_99.md`). This
/// interface is the seam a future native backend slots into without
/// reshaping call sites.
abstract interface class SecretStore {
  /// Writes [value] under [key], overwriting any existing value.
  Future<void> write(String key, Uint8List value);

  /// Reads the secret stored under [key].
  ///
  /// Returns `null` if no secret has been written for [key]. May throw
  /// [SecretPermissionException] if the underlying storage is found to be
  /// readable by users other than the owner — see the concrete
  /// implementation's documentation for the exact predicate.
  Future<Uint8List?> read(String key);

  /// Deletes the secret stored under [key].
  ///
  /// A no-op if no secret exists for [key].
  Future<void> delete(String key);

  /// Returns the keys currently held by this store.
  ///
  /// Returns an empty list if the store has never been written to. Used by
  /// callers that need to enumerate and prune orphaned secrets (e.g. `kmdb
  /// credentials prune`).
  Future<List<String>> list();
}

/// Default [SecretStore] that holds secrets in memory for the current
/// process.
///
/// This implementation never writes to disk or any external store. Stored
/// secrets are lost when the process exits (or the [InMemorySecretStore]
/// instance is garbage-collected). Appropriate for tests and any context
/// with no durable secret-storage requirement.
final class InMemorySecretStore implements SecretStore {
  final Map<String, Uint8List> _secrets = {};

  @override
  Future<void> write(String key, Uint8List value) async {
    // Defensive copy: the caller must not be able to mutate the stored
    // value after write() returns.
    _secrets[key] = Uint8List.fromList(value);
  }

  @override
  Future<Uint8List?> read(String key) async {
    final cached = _secrets[key];
    // Defensive copy: the caller must not be able to mutate the cached
    // value by mutating the returned list.
    return cached != null ? Uint8List.fromList(cached) : null;
  }

  @override
  Future<void> delete(String key) async {
    _secrets.remove(key);
  }

  @override
  Future<List<String>> list() async => _secrets.keys.toList();
}

/// Thrown by [SecretStore.read] when the secret's underlying storage is
/// found with looser-than-expected permissions.
///
/// Modelled on OpenSSH's `Permissions 0644 for '...' are too open` refusal:
/// rather than silently reading a secret the store can no longer vouch for,
/// the read is hard-refused with an error naming the exact fix.
final class SecretPermissionException implements Exception {
  /// Creates a [SecretPermissionException] for the offending [path].
  SecretPermissionException({
    required this.path,
    required this.actualMode,
    required this.expectedMode,
  });

  /// The absolute path of the offending file or directory.
  final String path;

  /// The POSIX permission bits actually observed on [path] (low 9 bits of
  /// `FileStat.mode`, as returned by `stat()`).
  final int actualMode;

  /// The POSIX permission bits [path] is expected to have.
  final int expectedMode;

  @override
  String toString() {
    final actual = actualMode.toRadixString(8).padLeft(3, '0');
    final expected = expectedMode.toRadixString(8).padLeft(3, '0');
    return 'Secret at $path is readable by others (mode $actual). '
        'Fix with: chmod $expected $path';
  }
}
