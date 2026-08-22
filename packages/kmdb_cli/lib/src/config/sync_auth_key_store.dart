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

/// CLI persistence for the per-remote `SyncSetKey` (0.10.01 WI-4 T1).
///
/// Each named sync remote holds its own `SyncSetKey`, scoped by both the
/// database directory and the remote name via
/// `dbScopedSecretKey(dbDir, 'sync-auth:$remoteName')` — the same
/// `SecretStore`-key-naming pattern the Google Drive OAuth credentials use
/// (see `remote_config.dart`'s `_loadGoogleDriveAuthClient`), extended with
/// a `sync-auth:` prefix so the two secret classes never collide under the
/// same `dbDir`/name combination. `remote add` mints a fresh key
/// ([mintSyncAuthKey]); `remote pair import` overwrites it with a key
/// shared from another device ([importSyncAuthKey]); `remote pair show`
/// and `adapterFor` read it ([loadSyncAuthKey]); `remote remove` deletes it
/// ([deleteSyncAuthKey]) — mirroring the existing Google-Drive-credentials
/// cleanup so removing a remote never leaves an orphaned secret behind.
///
/// @docImport '../commands/remote_command.dart';
/// @docImport 'remote_config.dart';
library;

import 'package:kmdb/kmdb.dart' show SecretStore, SyncSetKey, dbScopedSecretKey;

import 'secret_store/directory_secret_store.dart';

/// Returns the [SecretStore] key under which [remoteName]'s [SyncSetKey] is
/// stored, scoped to [dbDir].
String syncAuthSecretKey(String dbDir, String remoteName) =>
    dbScopedSecretKey(dbDir, 'sync-auth:$remoteName');

/// Generates a fresh [SyncSetKey] and persists it for [remoteName], scoped
/// to [dbDir].
///
/// Called once, at `remote add` time — every remote gets its own key,
/// regardless of adapter type (Q-C: one key per remote). Overwrites any
/// existing key already stored for this `(dbDir, remoteName)` pair; callers
/// that need to preserve an existing key (e.g. re-running `remote add
/// --force`) must check [loadSyncAuthKey] first.
///
/// [secretStoreOverride] — an injectable [SecretStore], used by tests to
/// avoid exercising the real permission-hardened filesystem store. Defaults
/// to `null`, in which case [DirectorySecretStore.forPlatform] resolves the
/// real store.
Future<SyncSetKey> mintSyncAuthKey({
  required String dbDir,
  required String remoteName,
  SecretStore? secretStoreOverride,
}) async {
  final key = SyncSetKey.generate();
  await importSyncAuthKey(
    dbDir: dbDir,
    remoteName: remoteName,
    key: key,
    secretStoreOverride: secretStoreOverride,
  );
  return key;
}

/// Persists [key] as the [SyncSetKey] for [remoteName], overwriting any
/// existing key.
///
/// Used both by [mintSyncAuthKey] (a freshly-generated key) and by `remote
/// pair import` (a key decoded from a pairing code shared by another
/// device — the two share this single write path since both are "install
/// this exact key material").
Future<void> importSyncAuthKey({
  required String dbDir,
  required String remoteName,
  required SyncSetKey key,
  SecretStore? secretStoreOverride,
}) async {
  final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
  await store.write(syncAuthSecretKey(dbDir, remoteName), key.encode());
}

/// Loads the [SyncSetKey] previously stored for [remoteName], or `null` if
/// none has been minted or imported yet (R-4: a remote-configured-but-
/// unenrolled database).
///
/// Throws [FormatException] if the stored bytes are corrupt (should not
/// happen in practice — only [mintSyncAuthKey]/[importSyncAuthKey] ever
/// write this key, both via `SyncSetKey.encode`).
Future<SyncSetKey?> loadSyncAuthKey({
  required String dbDir,
  required String remoteName,
  SecretStore? secretStoreOverride,
}) async {
  final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
  final bytes = await store.read(syncAuthSecretKey(dbDir, remoteName));
  if (bytes == null) return null;
  return SyncSetKey.decode(bytes);
}

/// Deletes the [SyncSetKey] stored for [remoteName], if any.
///
/// Called by `remote remove` so removing a remote never leaves an orphaned
/// secret behind — mirrors the existing Google Drive credentials cleanup in
/// `RemoteCommand._remove`.
Future<void> deleteSyncAuthKey({
  required String dbDir,
  required String remoteName,
  SecretStore? secretStoreOverride,
}) async {
  final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
  await store.delete(syncAuthSecretKey(dbDir, remoteName));
}
