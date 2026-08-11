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

import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

import 'secret_store/directory_secret_store.dart';
import 'sync_auth_key_store.dart';

// Re-export the config types so existing CLI imports of this file continue to
// resolve without change.  New code should import from
// `package:kmdb/kmdb_config.dart` directly.
export 'package:kmdb/kmdb_config.dart'
    show GoogleDriveRemoteConfig, LocalRemoteConfig, RemoteConfig;

// ── Adapter factory ──────────────────────────────────────────────────────────

/// Constructs the [SyncStorageAdapter] appropriate for [remote].
///
/// This CLI-only factory bridges a [RemoteConfig] subtype (defined in
/// `package:kmdb/kmdb_config.dart`) to its concrete [SyncStorageAdapter]
/// constructor.  Non-CLI consumers construct adapters directly.
///
/// The factory is `async` because Google Drive credential load/refresh is
/// asynchronous.  All call sites (sync, push, pull commands) are already
/// `async` and simply `await` this function.
///
/// [dbDir] — the local database directory.  Used to scope the [SecretStore]
/// key the Google Drive credentials are stored under (see
/// [dbScopedSecretKey]) — not to locate a file within [dbDir] itself, unlike
/// the former `{dbDir}/local/`-rooted design.
///
/// [remoteName] — the configured name of [remote] (e.g. `'origin'`), used to
/// scope the sync-authentication [SyncSetKey] (0.10.01 WI-4 T1) this
/// function reads via [loadSyncAuthKey] and wraps the returned adapter with.
/// When `null` — the CLI's `--sync-dir` one-off bypass, which has no saved
/// remote identity to key a [SyncSetKey] by — the returned adapter is
/// **unauthenticated**, exactly matching that flag's pre-existing "bypasses
/// saved remotes" escape-hatch semantics. Every *named* remote is always
/// wrapped: `remote add` mints a key automatically (see
/// [RemoteCommand._add]), so a named remote with no key can only mean it was
/// never fully enrolled (R-4) — this function throws [SyncAuthException]
/// rather than silently syncing unauthenticated in that case.
///
/// [secretStoreOverride] — an injectable [SecretStore], used by tests to
/// avoid exercising the real permission-hardened filesystem store. Defaults
/// to `null`, in which case [DirectorySecretStore.forPlatform] resolves the
/// real store rooted at the per-user profile config directory.
///
/// Throws [StateError] if Google Drive credentials are missing (i.e. the user
/// has not yet run `kmdb <db> remote add --type google-drive`). Throws
/// [SecretPermissionException] if the stored credentials are found with
/// looser-than-expected POSIX permissions. Throws [SyncAuthException] (R-4)
/// if [remoteName] is non-null but no [SyncSetKey] has been enrolled for it.
Future<SyncStorageAdapter> adapterFor(
  RemoteConfig remote, {
  required String dbDir,
  String? remoteName,
  SecretStore? secretStoreOverride,
}) async {
  final SyncStorageAdapter inner;
  switch (remote) {
    case LocalRemoteConfig(:final path):
      inner = LocalDirectoryAdapter(path);

    case GoogleDriveRemoteConfig(:final syncRoot, :final credentialsPath):
      final authClient = await _loadGoogleDriveAuthClient(
        dbDir: dbDir,
        credentialsPath: credentialsPath,
        secretStoreOverride: secretStoreOverride,
      );
      inner = GoogleDriveAdapter(authClient, syncRoot: syncRoot);
  }

  if (remoteName == null) return inner; // --sync-dir one-off: unauthenticated

  final key = await loadSyncAuthKey(
    dbDir: dbDir,
    remoteName: remoteName,
    secretStoreOverride: secretStoreOverride,
  );
  if (key == null) {
    throw SyncAuthException(
      'No sync-authentication key enrolled for remote "$remoteName". '
      "This should not happen for a remote created with 'remote add' "
      '(which mints a key automatically) — if this remote was added on '
      "another device, run 'kmdb <db> remote pair show' there, then "
      "'kmdb <db> remote pair import $remoteName <code>' here.",
    );
  }
  return SyncAuthenticatingAdapter(
    inner,
    DefaultSyncAuthenticator(key.rootKey),
  );
}

// ── Google Drive credential helpers ──────────────────────────────────────────

/// Loads and (if expired) refreshes Google Drive OAuth credentials from the
/// permission-hardened [SecretStore], under the key
/// `dbScopedSecretKey(dbDir, credentialsPath)`.
///
/// The credentials are written by `kmdb remote add --type google-drive` after
/// a successful OAuth consent flow.  The format is the JSON returned by
/// [AccessCredentials.toJson].
///
/// [secretStoreOverride] — an injectable [SecretStore]; defaults to `null`,
/// in which case [DirectorySecretStore.forPlatform] resolves the real store
/// rooted at the per-user profile config directory.
///
/// Throws [StateError] if the credentials are absent. Throws
/// [SecretPermissionException] if the stored credentials are found with
/// looser-than-expected POSIX permissions.
Future<AuthClient> _loadGoogleDriveAuthClient({
  required String dbDir,
  required String credentialsPath,
  SecretStore? secretStoreOverride,
}) async {
  final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
  final key = dbScopedSecretKey(dbDir, credentialsPath);

  // read() returns null when the credentials are absent, distinct from
  // permission failures (which throw SecretPermissionException) or
  // successful reads (which return the secret bytes).
  final secretBytes = await store.read(key);
  if (secretBytes == null) {
    throw StateError(
      'Google Drive credentials not found for this database.\n'
      "Re-run 'kmdb <db> remote add --type google-drive <name> --folder "
      "<name> --client-id <id> --client-secret <secret>' to authorise.",
    );
  }

  try {
    final secretJson = utf8.decode(secretBytes);
    final json = jsonDecode(secretJson) as Map<String, dynamic>;
    final credentials = AccessCredentials.fromJson(json);
    final base = http.Client();

    // Refresh if the access token has expired.
    if (credentials.accessToken.hasExpired) {
      // coverage:ignore-start
      // A ClientId is required by the refresh API, even though it is also
      // embedded in the refresh token.  We extract it from the stored
      // credentials if available; otherwise fall back to empty.
      final clientId = _clientIdFromCredentials(json) ?? ClientId('', '');
      final refreshed = await refreshCredentials(clientId, credentials, base);

      // Persist the refreshed token through the same store used to read it,
      // so the rewritten secret re-asserts the store's permission model
      // (chmod 600) rather than relying on the filesystem preserving the
      // existing mode. In practice the mode is preserved on overwrite, so
      // this is belt-and-braces, but routing through `store.write` keeps a
      // single source of truth for the invariant.
      await store.write(
        key,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({...refreshed.toJson(), ..._clientIdJson(clientId)}),
          ),
        ),
      );

      return authenticatedClient(base, refreshed);
      // coverage:ignore-end
    }

    return authenticatedClient(base, credentials);
  } on FormatException catch (e) {
    throw StateError(
      'Failed to parse Google Drive credentials for this database: $e\n'
      "Re-run 'kmdb <db> remote add --type google-drive <name> ...' to "
      're-authorise.',
    );
  }
}

/// Extracts the [ClientId] stored alongside the credentials, if present.
///
/// During `remote add`, the CLI writes `client_id` and `client_secret` into
/// the credentials JSON so they are available for future refresh calls.
// coverage:ignore-start
ClientId? _clientIdFromCredentials(Map<String, dynamic> json) {
  final id = json['client_id'] as String?;
  final secret = json['client_secret'] as String?;
  if (id == null || id.isEmpty) return null;
  return ClientId(id, secret ?? '');
}

/// Returns the [ClientId] fields as a JSON map for persistence.
Map<String, dynamic> _clientIdJson(ClientId clientId) => {
  'client_id': clientId.identifier,
  'client_secret': clientId.secret,
};
// coverage:ignore-end
