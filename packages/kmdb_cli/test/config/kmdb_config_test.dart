// Copyright 2026 The KMDB Authors.
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
import 'dart:io' as io;

import 'package:kmdb_cli/src/config/kmdb_config.dart';
import 'package:kmdb_cli/src/config/remote_config.dart';
import 'package:test/test.dart';

void main() {
  late io.Directory tmpDir;

  setUp(() {
    tmpDir = io.Directory.systemTemp.createTempSync('kmdb_config_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('KmdbConfig.empty', () {
    test('has no remotes', () {
      final config = KmdbConfig.empty();
      expect(config.remotes, isEmpty);
    });
  });

  group('KmdbConfig.load', () {
    test('returns empty config when file does not exist', () async {
      final config = await KmdbConfig.load(tmpDir.path);
      expect(config.remotes, isEmpty);
    });

    test('round-trips a local remote', () async {
      // Write a config manually.
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync(
        jsonEncode({
          'remotes': {
            'origin': {'type': 'local', 'path': '/mnt/nas/sync'},
          },
        }),
      );

      final config = await KmdbConfig.load(tmpDir.path);
      expect(config.remotes, hasLength(1));
      expect(config.remotes['origin'], isA<LocalRemoteConfig>());
      expect(
        (config.remotes['origin'] as LocalRemoteConfig).path,
        '/mnt/nas/sync',
      );
    });

    test('round-trips multiple remotes', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync(
        jsonEncode({
          'remotes': {
            'origin': {'type': 'local', 'path': '/mnt/nas/sync'},
            'dropbox': {
              'type': 'local',
              'path': '/Users/me/Dropbox/myapp-sync',
            },
          },
        }),
      );

      final config = await KmdbConfig.load(tmpDir.path);
      expect(config.remotes, hasLength(2));
      expect(
        (config.remotes['dropbox'] as LocalRemoteConfig).path,
        '/Users/me/Dropbox/myapp-sync',
      );
    });

    test('throws FormatException for invalid JSON', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync('{ not json }');

      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Corrupt config.json'),
          ),
        ),
      );
    });

    test('throws FormatException when root is not a JSON object', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync('[1, 2, 3]');

      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('expected a JSON object'),
          ),
        ),
      );
    });

    test('throws FormatException when remotes is not a JSON object', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync(jsonEncode({'remotes': 'oops'}));

      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException for unknown remote type', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync(
        jsonEncode({
          'remotes': {
            'origin': {'type': 'google_drive', 'folderId': 'abc'},
          },
        }),
      );

      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("Unknown remote type 'google_drive'"),
          ),
        ),
      );
    });

    test('throws FormatException when local remote is missing path', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      final file = io.File('${tmpDir.path}/local/config.json');
      file.writeAsStringSync(
        jsonEncode({
          'remotes': {
            'origin': {'type': 'local'},
          },
        }),
      );

      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'throws FormatException when a remote entry is not a JSON object',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        final file = io.File('${tmpDir.path}/local/config.json');
        file.writeAsStringSync(
          jsonEncode({
            'remotes': {'origin': 'bad'},
          }),
        );

        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('KmdbConfig.save', () {
    test('creates local/ directory lazily and writes config', () async {
      final config = KmdbConfig.empty();
      config.addRemote('origin', LocalRemoteConfig(path: '/tmp/sync'));
      await config.save(tmpDir.path);

      final file = io.File('${tmpDir.path}/local/config.json');
      expect(await file.exists(), isTrue);

      final reloaded = await KmdbConfig.load(tmpDir.path);
      expect(reloaded.remotes, hasLength(1));
      expect(
        (reloaded.remotes['origin'] as LocalRemoteConfig).path,
        '/tmp/sync',
      );
    });

    test('overwrites existing config atomically', () async {
      // Write initial state.
      final config1 = KmdbConfig.empty();
      config1.addRemote('origin', LocalRemoteConfig(path: '/path/a'));
      await config1.save(tmpDir.path);

      // Overwrite.
      final config2 = await KmdbConfig.load(tmpDir.path);
      config2.addRemote(
        'origin',
        LocalRemoteConfig(path: '/path/b'),
        force: true,
      );
      await config2.save(tmpDir.path);

      final reloaded = await KmdbConfig.load(tmpDir.path);
      expect((reloaded.remotes['origin'] as LocalRemoteConfig).path, '/path/b');
    });
  });

  group('addRemote', () {
    test('adds a remote', () {
      final config = KmdbConfig.empty();
      config.addRemote('origin', LocalRemoteConfig(path: '/tmp/sync'));
      expect(config.remotes, hasLength(1));
    });

    test('throws on duplicate name without force', () {
      final config = KmdbConfig.empty();
      config.addRemote('origin', LocalRemoteConfig(path: '/tmp/sync'));
      expect(
        () => config.addRemote('origin', LocalRemoteConfig(path: '/other')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains("remote named 'origin' already exists"),
          ),
        ),
      );
    });

    test('overwrites with force: true', () {
      final config = KmdbConfig.empty();
      config.addRemote('origin', LocalRemoteConfig(path: '/path/a'));
      config.addRemote(
        'origin',
        LocalRemoteConfig(path: '/path/b'),
        force: true,
      );
      expect((config.remotes['origin'] as LocalRemoteConfig).path, '/path/b');
    });
  });

  group('removeRemote', () {
    test('removes an existing remote', () {
      final config = KmdbConfig.empty();
      config.addRemote('origin', LocalRemoteConfig(path: '/tmp/sync'));
      config.removeRemote('origin');
      expect(config.remotes, isEmpty);
    });

    test('throws on non-existent name', () {
      final config = KmdbConfig.empty();
      expect(
        () => config.removeRemote('nosuchremote'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains("No remote named 'nosuchremote' found"),
          ),
        ),
      );
    });
  });

  group('RemoteConfig.fromJson', () {
    test('throws FormatException when type is missing', () {
      expect(
        () => RemoteConfig.fromJson({'path': '/tmp'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("missing required field 'type'"),
          ),
        ),
      );
    });

    test('throws FormatException when type is not a string', () {
      expect(
        () => RemoteConfig.fromJson({'type': 42}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('adapterFor', () {
    test('returns LocalDirectoryAdapter for LocalRemoteConfig', () {
      // We just verify it does not throw — the adapter type is not exported.
      expect(
        () => adapterFor(LocalRemoteConfig(path: '/tmp/sync')),
        returnsNormally,
      );
    });
  });
}
