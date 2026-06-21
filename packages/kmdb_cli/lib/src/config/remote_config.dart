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
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

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
/// [dbDir] — the local database directory.  Used to locate the Google Drive
/// credentials file at `{dbDir}/local/{credentialsPath}`.
///
/// Throws [StateError] if Google Drive credentials are missing (i.e. the user
/// has not yet run `kmdb <db> remote add --type google-drive`).
Future<SyncStorageAdapter> adapterFor(
  RemoteConfig remote, {
  required String dbDir,
}) async {
  switch (remote) {
    case LocalRemoteConfig(:final path):
      return LocalDirectoryAdapter(path);

    case GoogleDriveRemoteConfig(:final syncRoot, :final credentialsPath):
      final authClient = await _loadGoogleDriveAuthClient(
        dbDir: dbDir,
        credentialsPath: credentialsPath,
      );
      return GoogleDriveAdapter(authClient, syncRoot: syncRoot);
  }
}

// ── Google Drive credential helpers ──────────────────────────────────────────

/// Loads and (if expired) refreshes Google Drive OAuth credentials from
/// `{dbDir}/local/{credentialsPath}`.
///
/// The credentials file is created by `kmdb remote add --type google-drive`
/// after a successful OAuth consent flow.  The format is the JSON returned by
/// [AccessCredentials.toJson].
///
/// Throws [StateError] if the credentials file is absent.
Future<AuthClient> _loadGoogleDriveAuthClient({
  required String dbDir,
  required String credentialsPath,
}) async {
  final fullPath = [
    dbDir,
    'local',
    credentialsPath,
  ].join(Platform.pathSeparator);
  final file = File(fullPath);

  if (!await file.exists()) {
    throw StateError(
      'Google Drive credentials not found at $fullPath.\n'
      "Run 'kmdb <db> remote add --type google-drive <name> --folder <name> "
      "--client-id <id> --client-secret <secret>' to authorise.",
    );
  }

  try {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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

      // Persist the refreshed token so future runs skip the refresh round-trip.
      await File(fullPath).writeAsString(
        jsonEncode({...refreshed.toJson(), ..._clientIdJson(clientId)}),
      );

      return authenticatedClient(base, refreshed);
      // coverage:ignore-end
    }

    return authenticatedClient(base, credentials);
  } on FormatException catch (e) {
    throw StateError(
      'Failed to parse Google Drive credentials at $fullPath: $e\n'
      "Run 'kmdb <db> remote add --type google-drive <name> ...' to re-authorise.",
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
