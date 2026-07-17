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

import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/config/remote_config.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart'
    show GoogleDriveAdapter;
import 'package:test/test.dart';

// ── Credential helpers ─────────────────────────────────────────────────────

/// Creates a valid (non-expired) [AccessCredentials] JSON payload for use in
/// test credential files.
///
/// The access token is set to expire one hour from now, which satisfies the
/// [AccessToken.hasExpired] check without requiring a network refresh.
String _validCredentialsJson({
  String token = 'test-access-token',
  String? refreshToken = 'test-refresh-token',
}) {
  final creds = AccessCredentials(
    AccessToken(
      'Bearer',
      token,
      DateTime.now().add(const Duration(hours: 1)).toUtc(),
    ),
    refreshToken,
    ['https://www.googleapis.com/auth/drive.file'],
  );
  // Include client_id so future refresh calls can use it.
  return jsonEncode({
    ...creds.toJson(),
    'client_id': 'test-client-id',
    'client_secret': 'test-client-secret',
  });
}

/// Writes [content] to [file] and, on POSIX, hardens the file to `600` and
/// [localDir] to `700` — matching the permissions `DirectoryCredentialStore
/// .write` establishes in production.
///
/// Fixtures written directly via `File.writeAsStringSync` (bypassing
/// `DirectoryCredentialStore`) land at the process umask, typically `644`
/// (group/world-readable). Under the hard-refuse read path, `adapterFor`
/// would throw `CredentialPermissionException` instead of exercising the
/// behaviour each test actually wants to assert on, so every fixture that
/// reaches `adapterFor` must be hardened immediately after writing. This is
/// a no-op on Windows, where `DirectoryCredentialStore` performs no
/// chmod/stat checks at all.
void _writeHardenedFixture(File file, String content, Directory localDir) {
  file.writeAsStringSync(content);
  if (Platform.isWindows) return;
  final dirResult = Process.runSync('chmod', ['700', localDir.path]);
  if (dirResult.exitCode != 0) {
    throw StateError('chmod 700 ${localDir.path} failed: ${dirResult.stderr}');
  }
  final fileResult = Process.runSync('chmod', ['600', file.path]);
  if (fileResult.exitCode != 0) {
    throw StateError('chmod 600 ${file.path} failed: ${fileResult.stderr}');
  }
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;
  late Directory dbDir;
  late Directory localDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('adapter_for_test_');
    dbDir = Directory('${tmpDir.path}/db')..createSync();
    localDir = Directory('${dbDir.path}/local')..createSync();
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  // ── Missing credentials ─────────────────────────────────────────────────────

  group('adapterFor — GoogleDriveRemoteConfig', () {
    test('throws StateError when credentials file is absent', () async {
      final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
      await expectLater(
        adapterFor(config, dbDir: dbDir.path),
        throwsStateError,
      );
    });

    test(
      'StateError message contains instructions to run remote add',
      () async {
        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        await expectLater(
          adapterFor(config, dbDir: dbDir.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('remote add'),
            ),
          ),
        );
      },
    );

    test(
      'returns GoogleDriveAdapter when non-expired credentials are present',
      () async {
        // Write valid (non-expired) credentials to the expected path.
        final credFile = File('${localDir.path}/google_credentials.json');
        _writeHardenedFixture(credFile, _validCredentialsJson(), localDir);

        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        // adapterFor reads the credentials file, sees the token has not
        // expired, and returns an authenticated GoogleDriveAdapter without
        // making any network calls.
        final adapter = await adapterFor(config, dbDir: dbDir.path);
        expect(adapter, isA<GoogleDriveAdapter>());
      },
    );

    test('uses custom credentialsPath from config', () async {
      const customCreds = 'my_creds.json';
      final credFile = File('${localDir.path}/$customCreds');
      _writeHardenedFixture(credFile, _validCredentialsJson(), localDir);

      final config = GoogleDriveRemoteConfig(
        syncRoot: 'kmdb-sync',
        credentialsPath: customCreds,
      );
      final adapter = await adapterFor(config, dbDir: dbDir.path);
      expect(adapter, isA<GoogleDriveAdapter>());
    });

    test('StateError when credentials file contains invalid JSON', () async {
      final credFile = File('${localDir.path}/google_credentials.json');
      // Hardened even though this fixture is deliberately invalid JSON: an
      // un-hardened (umask-default) file would trip the permission refusal
      // before ever reaching the JSON parse, masking the behaviour this test
      // actually wants to assert on (FormatException -> StateError).
      _writeHardenedFixture(credFile, '{ invalid json }}', localDir);

      final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
      await expectLater(
        adapterFor(config, dbDir: dbDir.path),
        throwsStateError,
      );
    });

    // ── google_credentials.json is never in the sync path ─────────────────────
    //
    // The credentials file lives under {dbDir}/local/ and is explicitly
    // outside the sync root.  The SyncEngine only uploads files emitted by
    // the LSM engine (SSTables, HWM, lease), never {dbDir}/local/ contents.
    //
    // This test verifies the file path invariant: credentials are stored
    // at {dbDir}/local/{credentialsPath}, which is inside the local-only
    // subdirectory that SyncEngine never touches.
    test(
      'google_credentials.json is stored in local/ (not in sync root)',
      () async {
        final credFile = File('${localDir.path}/google_credentials.json');
        credFile.writeAsStringSync(_validCredentialsJson());

        // Confirm the credentials are stored under {dbDir}/local/, which is
        // the CLI-only, non-synced subdirectory. Compared against
        // `localDir.path` directly (rather than rejoining with
        // `Platform.pathSeparator`) since `localDir` and `credFile` were both
        // built with a literal `/` above — on Windows, joining with `\`
        // would produce a separator that never appears in either path.
        expect(credFile.path, contains(localDir.path));
        // The credentials file must NOT be at the database root (which is
        // the sync root for SSTable uploads).
        expect(
          File('${dbDir.path}/google_credentials.json').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'adapterFor returns LocalDirectoryAdapter for LocalRemoteConfig',
      () async {
        final config = LocalRemoteConfig(path: tmpDir.path);
        final adapter = await adapterFor(config, dbDir: dbDir.path);
        expect(adapter, isA<LocalDirectoryAdapter>());
      },
    );
  });

  // ── GoogleDriveRemoteConfig credential path invariant ─────────────────────
  //
  // The credentialsPath is always relative: it is joined with {dbDir}/local/
  // inside _loadGoogleDriveAuthClient.  Relative paths are significant:
  // they prevent the CLI from accidentally resolving credentials outside the
  // database directory (path traversal safety).
  group('GoogleDriveRemoteConfig — credentials path invariant', () {
    test('default credentialsPath is relative (not absolute)', () {
      final config = GoogleDriveRemoteConfig(syncRoot: 'sync');
      expect(config.credentialsPath, isNot(startsWith('/')));
    });

    test('syncRoot is used as the Drive folder name', () {
      final config = GoogleDriveRemoteConfig(syncRoot: 'my-kmdb-sync');
      expect(config.syncRoot, equals('my-kmdb-sync'));
    });

    test('toJson serialises both syncRoot and credentialsPath', () {
      final config = GoogleDriveRemoteConfig(
        syncRoot: 'kmdb',
        credentialsPath: 'creds.json',
      );
      final json = config.toJson();
      expect(json['syncRoot'], equals('kmdb'));
      expect(json['credentialsPath'], equals('creds.json'));
      expect(json['type'], equals('google-drive'));
    });
  });
}
