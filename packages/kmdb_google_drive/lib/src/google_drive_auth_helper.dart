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

import 'package:googleapis/drive/v3.dart' show DriveApi;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

/// The Drive scope that grants access to files created or opened by this app.
///
/// `drive.file` is the narrowest scope sufficient for KMDB sync: the adapter
/// creates its own folder hierarchy and only ever reads/writes files it owns.
/// Using the broader `drive` scope is unnecessary and would surface more
/// of the user's Drive contents than needed.
const kDriveFileScope = DriveApi.driveFileScope;

/// Static factory methods for obtaining a Google OAuth2 [AuthClient].
///
/// The adapter ([GoogleDriveAdapter]) is auth-agnostic: it accepts any
/// [AuthClient].  Callers that need help constructing one can use this helper.
/// Two reference integrations are provided:
///
/// - [fromServiceAccount] — for server-side / testing use.
/// - [fromUserConsent] — local-server redirect flow (CLI / desktop).
///
/// **Platform note.** Both factory methods use `dart:io` (file I/O for the
/// credentials cache, and a local HTTP server for the redirect flow).  They
/// are therefore **native-only** — they must not be called from a web or
/// WASM context.  Flutter web callers should use `google_sign_in` +
/// `extension_google_sign_in_as_googleapis_auth` to produce an [AuthClient]
/// from the platform SSO flow and pass it directly to [GoogleDriveAdapter].
abstract final class GoogleDriveAuthHelper {
  GoogleDriveAuthHelper._();

  /// Obtains an [AuthClient] from a service account key JSON file.
  ///
  /// Loads [serviceAccountJson] (the content of a Google Cloud service
  /// account key file, as a JSON string or parsed map), requests [scopes]
  /// (defaults to [kDriveFileScope]), and returns an [AutoRefreshingAuthClient].
  ///
  /// Useful for server-side and automated test scenarios.
  ///
  /// Example:
  /// ```dart
  /// final client = await GoogleDriveAuthHelper.fromServiceAccount(
  ///   File('service_account.json').readAsStringSync(),
  /// );
  /// ```
  static Future<AutoRefreshingAuthClient> fromServiceAccount(
    Object serviceAccountJson, {
    List<String> scopes = const [kDriveFileScope],
    http.Client? baseClient,
  }) async {
    final credentials = ServiceAccountCredentials.fromJson(serviceAccountJson);
    return clientViaServiceAccount(credentials, scopes, baseClient: baseClient);
  }

  /// Obtains an [AuthClient] via an interactive browser OAuth2 consent flow
  /// (local-server redirect, suitable for CLI / native desktop).
  ///
  /// [clientId] is the OAuth client ID (from the Google Cloud Console for a
  /// "Desktop" application type).  [scopes] defaults to [kDriveFileScope].
  ///
  /// When [credentialsCachePath] is provided, the returned credentials are
  /// serialised to that file path.  On subsequent calls the cached credentials
  /// are loaded and refreshed if expired, so the user does not need to
  /// re-authorise.
  ///
  /// The function opens the user's browser to the Google consent page and
  /// starts a transient HTTP server on `localhost` to capture the redirect.
  ///
  /// **Dart I/O only.** Not available in browser or WASM contexts.
  ///
  /// Example:
  /// ```dart
  /// final client = await GoogleDriveAuthHelper.fromUserConsent(
  ///   ClientId('YOUR_CLIENT_ID.apps.googleusercontent.com', 'YOUR_SECRET'),
  ///   credentialsCachePath: '/home/user/.config/myapp/drive_credentials.json',
  /// );
  /// ```
  static Future<AuthClient> fromUserConsent(
    ClientId clientId, {
    List<String> scopes = const [kDriveFileScope],
    String? credentialsCachePath,
    http.Client? baseClient,
  }) async {
    // Attempt to load cached credentials.
    if (credentialsCachePath != null) {
      final cached = await _loadCachedCredentials(
        credentialsCachePath,
        clientId,
        scopes,
        baseClient: baseClient,
      );
      if (cached != null) return cached;
    }

    // Run the interactive consent flow.
    final client = await clientViaUserConsent(
      clientId,
      scopes,
      _promptUser,
      baseClient: baseClient,
    );

    // Persist the credentials for future use.
    if (credentialsCachePath != null) {
      await _saveCredentials(credentialsCachePath, client.credentials);
    }

    return client;
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  /// Tries to load credentials from [path], refreshing if expired.
  ///
  /// Returns `null` if the file does not exist or is invalid.
  static Future<AuthClient?> _loadCachedCredentials(
    String path,
    ClientId clientId,
    List<String> scopes, {
    http.Client? baseClient,
  }) async {
    final file = File(path);
    if (!await file.exists()) return null;

    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final credentials = AccessCredentials.fromJson(json);

      // Refresh if expired.
      final base = baseClient ?? http.Client();
      final refreshed = await refreshCredentials(clientId, credentials, base);

      // Persist the refreshed token.
      await _saveCredentials(path, refreshed);

      // authenticatedClient wraps the base client with the refreshed token.
      return authenticatedClient(base, refreshed);
    } catch (_) {
      // Treat any load/parse/refresh failure as a cache miss.
      return null;
    }
  }

  /// Serialises [credentials] to [path], creating parent directories if needed.
  static Future<void> _saveCredentials(
    String path,
    AccessCredentials credentials,
  ) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(credentials.toJson()));
  }

  /// Default user-prompt function: prints the authorisation URL to stdout and
  /// asks the user to visit it.
  ///
  /// [clientViaUserConsent] opens a browser automatically on most platforms;
  /// this callback is invoked as a fallback prompt.
  static void _promptUser(String url) {
    stdout
      ..writeln()
      ..writeln('Please visit the following URL to authorise KMDB:')
      ..writeln()
      ..writeln('  $url')
      ..writeln();
  }
}
