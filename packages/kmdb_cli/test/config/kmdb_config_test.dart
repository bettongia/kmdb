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

  // ── Index definitions ──────────────────────────────────────────────────────

  group('KmdbConfig — indexes empty', () {
    test('empty() has no indexes', () {
      expect(KmdbConfig.empty().indexes, isEmpty);
    });

    test('load returns empty indexes when key absent', () async {
      // Backwards-compatible: a config file without "indexes" should load fine.
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
      expect(config.indexes, isEmpty);
    });
  });

  group('KmdbConfig — indexes load', () {
    test('round-trips indexes through save/load', () async {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'address.city');
      config.addIndex('contacts', 'tags[]');
      await config.save(tmpDir.path);

      final reloaded = await KmdbConfig.load(tmpDir.path);
      expect(reloaded.indexes, hasLength(2));
      expect(reloaded.indexes[0].collection, equals('contacts'));
      expect(reloaded.indexes[0].path, equals('address.city'));
      expect(reloaded.indexes[1].collection, equals('contacts'));
      expect(reloaded.indexes[1].path, equals('tags[]'));
    });

    test('throws FormatException when indexes is not a list', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      io.File(
        '${tmpDir.path}/local/config.json',
      ).writeAsStringSync(jsonEncode({'indexes': 'oops'}));
      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'indexes' must be a JSON array"),
          ),
        ),
      );
    });

    test(
      'throws FormatException when an index entry is not an object',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
          jsonEncode({
            'indexes': ['not-an-object'],
          }),
        );
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('throws FormatException when collection field is missing', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
        jsonEncode({
          'indexes': [
            {'path': 'city'},
          ],
        }),
      );
      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("missing required string field 'collection'"),
          ),
        ),
      );
    });

    test('throws FormatException when path field is missing', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
        jsonEncode({
          'indexes': [
            {'collection': 'contacts'},
          ],
        }),
      );
      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("missing required string field 'path'"),
          ),
        ),
      );
    });
  });

  group('addIndex', () {
    test('adds an index', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      expect(config.indexes, hasLength(1));
      expect(config.indexes.first.collection, equals('contacts'));
      expect(config.indexes.first.path, equals('city'));
    });

    test('throws on duplicate (collection, path) pair', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      expect(
        () => config.addIndex('contacts', 'city'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains("contacts.city"),
          ),
        ),
      );
    });

    test('allows same path on different collections', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      config.addIndex('items', 'city');
      expect(config.indexes, hasLength(2));
    });

    test('allows different paths on same collection', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      config.addIndex('contacts', 'email');
      expect(config.indexes, hasLength(2));
    });
  });

  group('removeIndex', () {
    test('removes an existing index', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      config.removeIndex('contacts', 'city');
      expect(config.indexes, isEmpty);
    });

    test('throws when the index does not exist', () {
      final config = KmdbConfig.empty();
      expect(
        () => config.removeIndex('contacts', 'city'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains("No index on 'contacts.city' found"),
          ),
        ),
      );
    });

    test('leaves other indexes unaffected', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      config.addIndex('contacts', 'email');
      config.removeIndex('contacts', 'city');
      expect(config.indexes, hasLength(1));
      expect(config.indexes.first.path, equals('email'));
    });
  });

  group('indexesForCollection', () {
    test('returns empty list when no indexes configured', () {
      final config = KmdbConfig.empty();
      expect(config.indexesForCollection('contacts'), isEmpty);
    });

    test('returns only indexes for the requested collection', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      config.addIndex('contacts', 'email');
      config.addIndex('items', 'name');

      final contactIndexes = config.indexesForCollection('contacts');
      expect(contactIndexes, hasLength(2));
      expect(contactIndexes.map((r) => r.path), containsAll(['city', 'email']));
    });

    test('returns empty list for unknown collection', () {
      final config = KmdbConfig.empty();
      config.addIndex('contacts', 'city');
      expect(config.indexesForCollection('unknowncoll'), isEmpty);
    });
  });

  // ── FTS index load error paths ─────────────────────────────────────────────

  group('KmdbConfig — ftsIndexes load', () {
    test('throws FormatException when ftsIndexes is not a list', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      io.File(
        '${tmpDir.path}/local/config.json',
      ).writeAsStringSync(jsonEncode({'ftsIndexes': 'bad'}));
      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("'ftsIndexes' must be a JSON array"),
          ),
        ),
      );
    });

    test(
      'throws FormatException when an ftsIndex entry is not an object',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
          jsonEncode({
            'ftsIndexes': ['not-an-object'],
          }),
        );
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'throws FormatException when ftsIndex entry missing collection',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
          jsonEncode({
            'ftsIndexes': [
              {'field': 'body'},
            ],
          }),
        );
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("missing required string field 'collection'"),
            ),
          ),
        );
      },
    );

    test('throws FormatException when ftsIndex entry missing field', () async {
      final localDir = io.Directory('${tmpDir.path}/local');
      localDir.createSync();
      io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
        jsonEncode({
          'ftsIndexes': [
            {'collection': 'docs'},
          ],
        }),
      );
      expect(
        () => KmdbConfig.load(tmpDir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("missing required string field 'field'"),
          ),
        ),
      );
    });
  });

  // ── embeddingModel load error paths ───────────────────────────────────────

  group('KmdbConfig — embeddingModel load', () {
    test(
      'throws FormatException when embeddingModel is not an object',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File(
          '${tmpDir.path}/local/config.json',
        ).writeAsStringSync(jsonEncode({'embeddingModel': 'bad'}));
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("'embeddingModel' must be a JSON object"),
            ),
          ),
        );
      },
    );

    test(
      'throws FormatException when embeddingModel.type is missing',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
          jsonEncode({
            'embeddingModel': {'modelPath': '/models/bge.onnx'},
          }),
        );
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("'embeddingModel.type'"),
            ),
          ),
        );
      },
    );

    test(
      'throws FormatException when embeddingModel.modelPath is missing',
      () async {
        final localDir = io.Directory('${tmpDir.path}/local');
        localDir.createSync();
        io.File('${tmpDir.path}/local/config.json').writeAsStringSync(
          jsonEncode({
            'embeddingModel': {'type': 'onnx'},
          }),
        );
        expect(
          () => KmdbConfig.load(tmpDir.path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains("'embeddingModel.modelPath'"),
            ),
          ),
        );
      },
    );

    test('round-trips embeddingModel through save/load', () async {
      final config = KmdbConfig.empty();
      config.embeddingModel = (type: 'onnx', modelPath: '/models/bge.onnx');
      await config.save(tmpDir.path);

      final reloaded = await KmdbConfig.load(tmpDir.path);
      expect(reloaded.embeddingModel?.type, 'onnx');
      expect(reloaded.embeddingModel?.modelPath, '/models/bge.onnx');
    });
  });

  // ── addFtsIndex / removeFtsIndex / ftsIndexesForCollection ────────────────

  group('addFtsIndex', () {
    test('adds an FTS index', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      expect(config.ftsIndexes, hasLength(1));
      expect(config.ftsIndexes.first.collection, 'docs');
      expect(config.ftsIndexes.first.field, 'body');
    });

    test('defaults stopWords=false, k1=1.2, b=0.75', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      final idx = config.ftsIndexes.first;
      expect(idx.stopWords, isFalse);
      expect(idx.k1, closeTo(1.2, 0.001));
      expect(idx.b, closeTo(0.75, 0.001));
    });

    test('throws on duplicate (collection, field) pair', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      expect(
        () => config.addFtsIndex('docs', 'body'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('removeFtsIndex', () {
    test('removes an existing FTS index', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.removeFtsIndex('docs', 'body');
      expect(config.ftsIndexes, isEmpty);
    });

    test('throws when FTS index does not exist', () {
      final config = KmdbConfig.empty();
      expect(
        () => config.removeFtsIndex('docs', 'body'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('addFtsIndex/removeFtsIndex round-trip', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'title');
      config.addFtsIndex('docs', 'body');
      config.removeFtsIndex('docs', 'title');
      expect(config.ftsIndexes, hasLength(1));
      expect(config.ftsIndexes.first.field, 'body');
    });
  });

  group('ftsIndexesForCollection', () {
    test('returns empty list when no FTS indexes configured', () {
      expect(KmdbConfig.empty().ftsIndexesForCollection('docs'), isEmpty);
    });

    test('returns only indexes for the requested collection', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      config.addFtsIndex('docs', 'title');
      config.addFtsIndex('notes', 'content');

      final docsIndexes = config.ftsIndexesForCollection('docs');
      expect(docsIndexes, hasLength(2));
      expect(docsIndexes.map((r) => r.field), containsAll(['body', 'title']));
    });

    test('returns empty list for unknown collection', () {
      final config = KmdbConfig.empty();
      config.addFtsIndex('docs', 'body');
      expect(config.ftsIndexesForCollection('notes'), isEmpty);
    });
  });
}
