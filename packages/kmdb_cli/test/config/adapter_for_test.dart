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
import 'dart:typed_data';

import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/config/remote_config.dart';
import 'package:kmdb_cli/src/config/secret_store/directory_secret_store.dart';
import 'package:kmdb_cli/src/config/secret_store/secret_key.dart';
import 'package:kmdb_cli/src/config/sync_auth_key_store.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart'
    show GoogleDriveAdapter;
import 'package:test/test.dart';

import '../support/fake_secret_store.dart';

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

/// Seeds [store] with [content] under the key `adapterFor` will look up for
/// [dbDir] + [credentialsPath] — i.e. `dbScopedSecretKey(dbDir,
/// credentialsPath)`. Mirrors what `RemoteCommand._authoriseGoogleDrive`
/// writes in production, minus the real OAuth flow.
void _seedCredential(
  FakeSecretStore store,
  String dbDir,
  String credentialsPath,
  String content,
) {
  store.secrets[dbScopedSecretKey(dbDir, credentialsPath)] = Uint8List.fromList(
    utf8.encode(content),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;
  late Directory dbDir;
  late FakeSecretStore secretStore;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('adapter_for_test_');
    dbDir = Directory('${tmpDir.path}/db')..createSync();
    secretStore = FakeSecretStore();
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  // ── Missing credentials ─────────────────────────────────────────────────────

  group('adapterFor — GoogleDriveRemoteConfig', () {
    test('throws StateError when credentials are absent', () async {
      final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
      await expectLater(
        adapterFor(config, dbDir: dbDir.path, secretStoreOverride: secretStore),
        throwsStateError,
      );
    });

    test(
      'StateError message contains instructions to re-run remote add',
      () async {
        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        await expectLater(
          adapterFor(
            config,
            dbDir: dbDir.path,
            secretStoreOverride: secretStore,
          ),
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
        _seedCredential(
          secretStore,
          dbDir.path,
          'google_credentials.json',
          _validCredentialsJson(),
        );

        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        // adapterFor reads the credentials, sees the token has not expired,
        // and returns an authenticated GoogleDriveAdapter without making any
        // network calls.
        final adapter = await adapterFor(
          config,
          dbDir: dbDir.path,
          secretStoreOverride: secretStore,
        );
        expect(adapter, isA<GoogleDriveAdapter>());
      },
    );

    test('uses custom credentialsPath from config', () async {
      const customCreds = 'my_creds.json';
      _seedCredential(
        secretStore,
        dbDir.path,
        customCreds,
        _validCredentialsJson(),
      );

      final config = GoogleDriveRemoteConfig(
        syncRoot: 'kmdb-sync',
        credentialsPath: customCreds,
      );
      final adapter = await adapterFor(
        config,
        dbDir: dbDir.path,
        secretStoreOverride: secretStore,
      );
      expect(adapter, isA<GoogleDriveAdapter>());
    });

    test('StateError when credentials contain invalid JSON', () async {
      _seedCredential(
        secretStore,
        dbDir.path,
        'google_credentials.json',
        '{ invalid json }}',
      );

      final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
      await expectLater(
        adapterFor(config, dbDir: dbDir.path, secretStoreOverride: secretStore),
        throwsStateError,
      );
    });

    // ── Credentials are stored outside dbDir entirely ─────────────────────────
    //
    // This is the whole point of the profile-dir move that closes review
    // finding C-1: unlike the former {dbDir}/local/-rooted design, no
    // credential file is ever written anywhere under dbDir — the real
    // DirectorySecretStore is rooted at the per-user profile config
    // directory, entirely outside any database's own directory tree (and
    // therefore also outside the sync root, which SyncEngine only ever
    // populates from LSM-emitted files).
    test('credentials are never written anywhere under dbDir', () async {
      final secretRoot = Directory('${tmpDir.path}/secret-root');
      final realStore = DirectorySecretStore(root: secretRoot.path);
      await realStore.write(
        dbScopedSecretKey(dbDir.path, 'google_credentials.json'),
        Uint8List.fromList(utf8.encode(_validCredentialsJson())),
      );

      // dbDir was created empty in setUp and is never touched by the secret
      // store — its directory tree stays empty.
      expect(dbDir.listSync(recursive: true), isEmpty);
      // The secret does live somewhere — just not under dbDir.
      expect(secretRoot.listSync(), isNotEmpty);
    });

    test(
      'adapterFor returns LocalDirectoryAdapter for LocalRemoteConfig',
      () async {
        final config = LocalRemoteConfig(path: tmpDir.path);
        final adapter = await adapterFor(config, dbDir: dbDir.path);
        expect(adapter, isA<LocalDirectoryAdapter>());
      },
    );

    // ── Default store resolution (no override) ────────────────────────────────
    //
    // Exercises `secretStoreOverride ?? DirectorySecretStore.forPlatform()`
    // for real — the one call site every other test in this file
    // deliberately avoids to keep isolation from the real machine profile
    // directory. Safe here because dbDir is a freshly-generated temp
    // directory, so its scoped key cannot already exist in the real store,
    // and this is a pure *read* (adapterFor never writes on the
    // missing-credentials path) — nothing is ever written to the real
    // ~/.config/kmdb (or %APPDATA%\kmdb) directory by this test.
    test(
      'without an override, adapterFor resolves the real '
      'DirectorySecretStore.forPlatform() default (read-only, no fixture)',
      () async {
        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        await expectLater(
          adapterFor(config, dbDir: dbDir.path),
          throwsStateError,
        );
      },
    );
  });

  // ── GoogleDriveRemoteConfig credential path invariant ─────────────────────
  //
  // The credentialsPath is always relative: it is combined with dbDir inside
  // dbScopedSecretKey. Relative paths are significant: they prevent the CLI
  // from accidentally resolving credentials outside the intended scope.
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

  // ── Sync authentication (0.10.01 WI-4 T1) ─────────────────────────────────────

  group('adapterFor — sync authentication (remoteName)', () {
    test('remoteName omitted returns an unwrapped, unauthenticated adapter '
        '(the --sync-dir one-off bypass)', () async {
      final config = LocalRemoteConfig(path: tmpDir.path);
      final adapter = await adapterFor(
        config,
        dbDir: dbDir.path,
        secretStoreOverride: secretStore,
      );
      // Not wrapped: an exact LocalDirectoryAdapter, not a decorator.
      expect(adapter, isA<LocalDirectoryAdapter>());
      expect(adapter, isNot(isA<SyncAuthenticatingAdapter>()));
    });

    test('remoteName provided but no key enrolled throws SyncAuthException '
        '(R-4)', () async {
      final config = LocalRemoteConfig(path: tmpDir.path);
      await expectLater(
        adapterFor(
          config,
          dbDir: dbDir.path,
          remoteName: 'origin',
          secretStoreOverride: secretStore,
        ),
        throwsA(
          isA<SyncAuthException>().having(
            (e) => e.message,
            'message',
            allOf(contains('origin'), contains('remote pair')),
          ),
        ),
      );
    });

    test('remoteName provided with an enrolled key returns a '
        'SyncAuthenticatingAdapter whose uploads are enveloped', () async {
      await mintSyncAuthKey(
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: secretStore,
      );

      final remoteDir = Directory('${tmpDir.path}/remote')..createSync();
      final config = LocalRemoteConfig(path: remoteDir.path);
      final adapter = await adapterFor(
        config,
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: secretStore,
      );
      expect(adapter, isA<SyncAuthenticatingAdapter>());

      final payload = Uint8List.fromList(utf8.encode('sstable-bytes'));
      await adapter.upload('sstables/a-0-1.sst', payload);

      // The bytes on disk must be enveloped (larger than, and different
      // from, the raw payload) — reading through the raw
      // LocalDirectoryAdapter proves the envelope was actually applied at
      // the storage layer, not merely accepted/no-op'd by the decorator.
      final raw = await LocalDirectoryAdapter(
        remoteDir.path,
      ).download('sstables/a-0-1.sst');
      expect(raw, isNotNull);
      expect(raw, isNot(equals(payload)));
      expect(raw!.length, greaterThan(payload.length));

      // And it round-trips back through the same authenticated adapter.
      final downloaded = await adapter.download('sstables/a-0-1.sst');
      expect(downloaded, equals(payload));
    });

    test('two adapterFor calls for the same remoteName share the same key, so '
        'artefacts written by one round-trip through the other', () async {
      await mintSyncAuthKey(
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: secretStore,
      );
      final remoteDir = Directory('${tmpDir.path}/remote')..createSync();
      final config = LocalRemoteConfig(path: remoteDir.path);

      final writer = await adapterFor(
        config,
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: secretStore,
      );
      final reader = await adapterFor(
        config,
        dbDir: dbDir.path,
        remoteName: 'origin',
        secretStoreOverride: secretStore,
      );

      final payload = Uint8List.fromList(utf8.encode('shared-key'));
      await writer.upload('highwater/a1b2c3d4.hwm', payload);
      final downloaded = await reader.download('highwater/a1b2c3d4.hwm');
      expect(downloaded, equals(payload));
    });
  });
}
