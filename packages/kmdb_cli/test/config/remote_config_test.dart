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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_cli/src/config/remote_config.dart';
import 'package:test/test.dart';

void main() {
  group('RemoteConfig.fromJson', () {
    test('throws FormatException when type field is missing', () {
      expect(
        () => RemoteConfig.fromJson({'path': '/some/path'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'type'"),
          ),
        ),
      );
    });

    test('throws FormatException when type field is not a string', () {
      expect(
        () => RemoteConfig.fromJson({'type': 42}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'type' must be a string"),
          ),
        ),
      );
    });

    test('throws FormatException for unknown type', () {
      expect(
        () => RemoteConfig.fromJson({'type': 'cloud'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("Unknown remote type 'cloud'"),
          ),
        ),
      );
    });

    test('returns LocalRemoteConfig for type=local', () {
      final config = RemoteConfig.fromJson({
        'type': 'local',
        'path': '/mnt/sync',
      });
      expect(config, isA<LocalRemoteConfig>());
      expect((config as LocalRemoteConfig).path, '/mnt/sync');
    });

    test('returns GoogleDriveRemoteConfig for type=google-drive', () {
      final config = RemoteConfig.fromJson({
        'type': 'google-drive',
        'syncRoot': 'kmdb-sync',
      });
      expect(config, isA<GoogleDriveRemoteConfig>());
      expect((config as GoogleDriveRemoteConfig).syncRoot, 'kmdb-sync');
    });
  });

  group('LocalRemoteConfig.fromJson', () {
    test('throws FormatException when path field is missing', () {
      expect(
        () => LocalRemoteConfig.fromJson({'type': 'local'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'path'"),
          ),
        ),
      );
    });

    test('throws FormatException when path field is not a string', () {
      expect(
        () => LocalRemoteConfig.fromJson({'type': 'local', 'path': 123}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'path' must be a string"),
          ),
        ),
      );
    });

    test('round-trips through fromJson and toJson', () {
      final original = LocalRemoteConfig(path: '/mnt/nas/sync');
      final roundTripped = LocalRemoteConfig.fromJson(original.toJson());
      expect(roundTripped.path, original.path);
      expect(roundTripped.type, 'local');
    });
  });

  group('LocalRemoteConfig equality and hashCode', () {
    test('equal when paths match', () {
      final a = LocalRemoteConfig(path: '/mnt/sync');
      final b = LocalRemoteConfig(path: '/mnt/sync');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('not equal when paths differ', () {
      final a = LocalRemoteConfig(path: '/mnt/sync');
      final b = LocalRemoteConfig(path: '/other');
      expect(a, isNot(equals(b)));
    });

    test('equal to itself', () {
      final a = LocalRemoteConfig(path: '/mnt/sync');
      expect(a, equals(a));
    });
  });

  group('GoogleDriveRemoteConfig.fromJson', () {
    test('throws FormatException when syncRoot is missing', () {
      expect(
        () => GoogleDriveRemoteConfig.fromJson({'type': 'google-drive'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'syncRoot'"),
          ),
        ),
      );
    });

    test(
      'round-trips through fromJson and toJson (default credentialsPath)',
      () {
        final original = GoogleDriveRemoteConfig(syncRoot: 'my-kmdb-sync');
        final rt = GoogleDriveRemoteConfig.fromJson(original.toJson());
        expect(rt.syncRoot, 'my-kmdb-sync');
        expect(rt.credentialsPath, 'google_credentials.json');
        expect(rt.type, 'google-drive');
      },
    );

    test(
      'round-trips through fromJson and toJson (custom credentialsPath)',
      () {
        final original = GoogleDriveRemoteConfig(
          syncRoot: 'sync-folder',
          credentialsPath: 'creds.json',
        );
        final rt = GoogleDriveRemoteConfig.fromJson(original.toJson());
        expect(rt.credentialsPath, 'creds.json');
      },
    );
  });

  group('GoogleDriveRemoteConfig equality and hashCode', () {
    test('equal when syncRoot and credentialsPath match', () {
      final a = GoogleDriveRemoteConfig(syncRoot: 'sync');
      final b = GoogleDriveRemoteConfig(syncRoot: 'sync');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('not equal when syncRoot differs', () {
      final a = GoogleDriveRemoteConfig(syncRoot: 'sync-a');
      final b = GoogleDriveRemoteConfig(syncRoot: 'sync-b');
      expect(a, isNot(equals(b)));
    });
  });

  group('adapterFor', () {
    test('returns LocalDirectoryAdapter for LocalRemoteConfig', () async {
      final config = LocalRemoteConfig(path: '/mnt/sync');
      final adapter = await adapterFor(config, dbDir: '/tmp/test-db');
      expect(adapter, isA<LocalDirectoryAdapter>());
    });

    test(
      'throws StateError for GoogleDriveRemoteConfig without credentials',
      () async {
        final config = GoogleDriveRemoteConfig(syncRoot: 'kmdb-sync');
        // No credentials file exists under /tmp/nonexistent-db/local/ so a
        // StateError is expected.
        await expectLater(
          adapterFor(config, dbDir: '/tmp/nonexistent-db'),
          throwsStateError,
        );
      },
    );
  });
}
