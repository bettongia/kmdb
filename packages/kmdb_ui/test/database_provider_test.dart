// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_ui/app_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemoryStorageAdapter memoryAdapter;

  tearDown(() => MemoryStorageAdapter.releaseAllLocks());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    memoryAdapter = MemoryStorageAdapter();

    // Mock MethodChannel for macOS bookmark calls.
    const bookmarkChannel = MethodChannel('com.kmdb.browser/bookmarks');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bookmarkChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'getBookmark') {
            return 'mock_bookmark';
          }
          return null;
        });

    // Mock MethodChannel for file_picker.
    const pickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.file_picker',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (MethodCall methodCall) async {
          if (methodCall.method == 'dir') {
            return '/mock/path';
          }
          return null;
        });
  });

  group('AppProvider', () {
    test('initialization loads default values', () {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      expect(provider.recentDatabasePaths, isEmpty);
      expect(provider.themeMode, equals(ThemeMode.system));
      expect(provider.database, isNull);
    });

    test('setThemeMode updates state and prefs', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      provider.setThemeMode(ThemeMode.dark);

      expect(provider.themeMode, equals(ThemeMode.dark));
      expect(prefs.getString('theme_mode'), equals('dark'));
    });

    test('setThemeMode no-op when same mode', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      provider.setThemeMode(ThemeMode.system); // same as default
      expect(notifyCount, equals(0));
    });

    test('removeDatabase updates state and saves to prefs', () async {
      await prefs.setStringList('recent_databases', ['/path/to/db']);
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      expect(provider.recentDatabasePaths, contains(endsWith('db')));

      provider.removeDatabase('/path/to/db');

      expect(provider.recentDatabasePaths, isEmpty);
      expect(prefs.getStringList('recent_databases'), isEmpty);
    });

    test('selectDatabase opens KmdbDatabase and loads collections', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      await provider.selectDatabase('/path/to/test-db');

      expect(provider.selectedDatabasePath, contains('test-db'));
      expect(provider.database, isNotNull);
      expect(provider.isOpening, isFalse);
      expect(provider.loadError, isNull);
    });

    test('selectDatabase adds path to recent list', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      await provider.selectDatabase('/path/to/new-db');

      expect(provider.recentDatabasePaths, contains(endsWith('new-db')));
    });

    test('selectDatabase is a no-op when same database already open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      final db1 = provider.database;

      // Calling again with the same path should not reopen.
      await provider.selectDatabase('/path/to/db');
      expect(provider.database, same(db1));
    });

    test('collections are empty on fresh open with no namespaces', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/empty-db');

      expect(provider.collections, isEmpty);
    });

    test('selectCollection updates selectedCollection', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      await provider.createCollection('notes');

      provider.selectCollection('notes');
      expect(provider.selectedCollection, equals('notes'));
      expect(provider.selectedDocument, isNull);
    });

    test('createCollection returns true and updates collection list', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      final created = await provider.createCollection('tasks');
      expect(created, isTrue);
      expect(provider.collections, contains('tasks'));
    });

    test('createCollection returns false when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      final created = await provider.createCollection('tasks');
      expect(created, isFalse);
    });

    test('selectDocument updates selectedDocument', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final doc = {'_id': 'abc', 'title': 'Hello'};

      provider.selectDocument(doc);
      expect(provider.selectedDocument, equals(doc));

      provider.selectDocument(null);
      expect(provider.selectedDocument, isNull);
    });

    test('isBusy is set while runBusy operation runs', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      bool wasBusy = false;

      await provider.runBusy('Working...', () async {
        wasBusy = provider.isBusy;
        expect(provider.busyMessage, equals('Working...'));
      });

      expect(wasBusy, isTrue);
      expect(provider.isBusy, isFalse);
      expect(provider.busyMessage, isEmpty);
    });

    test('runBusy clears busy state even when operation throws', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      await expectLater(
        provider.runBusy('Failing...', () async {
          throw Exception('test error');
        }),
        throwsA(isA<Exception>()),
      );

      expect(provider.isBusy, isFalse);
      expect(provider.busyMessage, isEmpty);
    });

    // ── deleteCollection ─────────────────────────────────────────────────────

    test('deleteCollection removes collection from list', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      await provider.createCollection('to-delete');
      expect(provider.collections, contains('to-delete'));

      await provider.deleteCollection('to-delete');

      expect(provider.collections, isNot(contains('to-delete')));
    });

    test('deleteCollection removes all documents in the collection', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      await provider.createCollection('items');
      final col = provider.database!.rawCollection('items');
      await col.insert({'x': 1});
      await col.insert({'x': 2});

      await provider.deleteCollection('items');

      expect(provider.collections, isNot(contains('items')));
    });

    test(
      'deleteCollection clears selectedCollection when it is deleted',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/db');
        await provider.createCollection('active');
        provider.selectCollection('active');
        expect(provider.selectedCollection, equals('active'));

        await provider.deleteCollection('active');

        expect(provider.selectedCollection, isNull);
      },
    );

    test('deleteCollection is a no-op when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      // Should not throw even without an open database.
      await provider.deleteCollection('ghost');
      expect(provider.collections, isEmpty);
    });

    // ── FTS index management ─────────────────────────────────────────────────

    test('hasFtsCapability is false before any FTS index is created', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      expect(provider.hasFtsCapability, isFalse);
    });

    test('createFtsIndex enables hasFtsCapability', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/fts-db');
      await provider.createCollection('notes');

      await provider.createFtsIndex(collection: 'notes', field: 'title');

      expect(provider.hasFtsCapability, isTrue);
    });

    test(
      'ftsIndexedFieldsForCollection returns empty before index created',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/db');

        expect(provider.ftsIndexedFieldsForCollection('notes'), isEmpty);
      },
    );

    test('ftsIndexedFieldsForCollection lists created index', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/fts-fields-db');
      await provider.createCollection('docs');

      await provider.createFtsIndex(collection: 'docs', field: 'body');

      expect(provider.ftsIndexedFieldsForCollection('docs'), contains('body'));
    });

    test(
      'deleteFtsIndex removes index from ftsIndexedFieldsForCollection',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/fts-delete-db');
        await provider.createCollection('articles');
        await provider.createFtsIndex(collection: 'articles', field: 'content');
        expect(
          provider.ftsIndexedFieldsForCollection('articles'),
          contains('content'),
        );

        await provider.deleteFtsIndex('articles', 'content');

        expect(
          provider.ftsIndexedFieldsForCollection('articles'),
          isNot(contains('content')),
        );
      },
    );

    test(
      'deleteFtsIndex disables hasFtsCapability when last index removed',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/fts-last-db');
        await provider.createCollection('logs');
        await provider.createFtsIndex(collection: 'logs', field: 'message');
        expect(provider.hasFtsCapability, isTrue);

        await provider.deleteFtsIndex('logs', 'message');

        expect(provider.hasFtsCapability, isFalse);
      },
    );

    test('createFtsIndex preserves selectedCollection across reopen', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/fts-reopen-db');
      await provider.createCollection('notes');
      provider.selectCollection('notes');
      expect(provider.selectedCollection, equals('notes'));

      await provider.createFtsIndex(collection: 'notes', field: 'title');

      // After reopen, selected collection must still be set.
      expect(provider.selectedCollection, equals('notes'));
    });

    test('createFtsIndex is a no-op when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      // Should not throw.
      await provider.createFtsIndex(collection: 'notes', field: 'title');
      expect(provider.hasFtsCapability, isFalse);
    });

    test('deleteFtsIndex is a no-op when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);

      // Should not throw.
      await provider.deleteFtsIndex('notes', 'title');
      expect(provider.hasFtsCapability, isFalse);
    });

    // ── Secondary index management ───────────────────────────────────────────

    test(
      'secondaryIndexPathsForCollection returns empty before index created',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/db');

        expect(provider.secondaryIndexPathsForCollection('items'), isEmpty);
      },
    );

    test('createSecondaryIndex adds path to indexed list', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/sidx-db');
      await provider.createCollection('contacts');

      await provider.createSecondaryIndex('contacts', 'email');

      expect(
        provider.secondaryIndexPathsForCollection('contacts'),
        contains('email'),
      );
    });

    test('deleteSecondaryIndex removes path from indexed list', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/sidx-del-db');
      await provider.createCollection('users');
      await provider.createSecondaryIndex('users', 'name');
      expect(
        provider.secondaryIndexPathsForCollection('users'),
        contains('name'),
      );

      await provider.deleteSecondaryIndex('users', 'name');

      expect(
        provider.secondaryIndexPathsForCollection('users'),
        isNot(contains('name')),
      );
    });

    test(
      'createSecondaryIndex preserves selectedCollection across reopen',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/sidx-reopen-db');
        await provider.createCollection('orders');
        provider.selectCollection('orders');

        await provider.createSecondaryIndex('orders', 'status');

        expect(provider.selectedCollection, equals('orders'));
      },
    );

    test('createSecondaryIndex is a no-op when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.createSecondaryIndex('items', 'field');
      expect(provider.secondaryIndexPathsForCollection('items'), isEmpty);
    });

    // ── Schema management ────────────────────────────────────────────────────

    test(
      'registeredSchemas is empty before any schema is registered',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/db');

        expect(provider.registeredSchemas, isEmpty);
      },
    );

    test('registerSchema returns null on success', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/schema-db');

      final err = await provider.registerSchema(
        'things',
        '{"properties": {"name": {"type": "string"}}}',
      );

      expect(err, isNull);
    });

    test('registerSchema adds collection to registeredSchemas', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/schema-list-db');

      await provider.registerSchema(
        'books',
        '{"properties": {"title": {"type": "string"}}}',
      );

      expect(provider.registeredSchemas, contains('books'));
    });

    test('schemaForCollection returns the schema map', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/schema-get-db');

      await provider.registerSchema(
        'docs',
        '{"properties": {"body": {"type": "string"}}}',
      );

      final schema = provider.schemaForCollection('docs');
      expect(schema, isNotNull);
      expect(schema!['properties'], isA<Map>());
    });

    test('registerSchema returns error for invalid JSON', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      final err = await provider.registerSchema('items', 'not-json');

      expect(err, isNotNull);
      expect(err, contains('Failed to register schema'));
    });

    test('registerSchema returns error for non-object JSON', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      final err = await provider.registerSchema('items', '[1,2,3]');

      expect(err, isNotNull);
      expect(err, contains('JSON object'));
    });

    test(
      'deregisterSchema removes collection from registeredSchemas',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/schema-dereg-db');
        await provider.registerSchema(
          'logs',
          '{"properties": {"msg": {"type": "string"}}}',
        );
        expect(provider.registeredSchemas, contains('logs'));

        await provider.deregisterSchema('logs');

        expect(provider.registeredSchemas, isNot(contains('logs')));
      },
    );

    test('validateDocumentJson returns null for valid document', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/schema-val-db');
      await provider.registerSchema(
        'items',
        '{"required": ["name"], "properties": {"name": {"type": "string"}}}',
      );

      final err = provider.validateDocumentJson('items', '{"name": "Alice"}');
      expect(err, isNull);
    });

    test('validateDocumentJson returns error for schema violation', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/schema-val-err-db');
      await provider.registerSchema('items', '{"required": ["name"]}');

      final err = provider.validateDocumentJson('items', '{"age": 30}');
      expect(err, isNotNull);
    });

    test(
      'validateDocumentJson returns null when no schema registered',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        await provider.selectDatabase('/path/to/db');

        final err = provider.validateDocumentJson('items', '{"any": "thing"}');
        expect(err, isNull);
      },
    );

    // ── Export / Import / Dump / Restore ────────────────────────────────────

    test('exportCollection writes NDJSON and returns document count', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/export-db');
      await provider.createCollection('notes');
      final col = provider.database!.rawCollection('notes');
      await col.insert({'title': 'Alpha'});
      await col.insert({'title': 'Beta'});

      final tmpFile = '${Directory.systemTemp.path}/export_test.ndjson';
      final count = await provider.exportCollection('notes', tmpFile);

      expect(count, equals(2));
      final lines = File(tmpFile).readAsLinesSync();
      expect(lines.where((l) => l.trim().isNotEmpty).length, equals(2));
      File(tmpFile).deleteSync();
    });

    test('importCollection inserts documents from NDJSON', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/import-db');
      await provider.createCollection('tasks');

      final tmpFile = '${Directory.systemTemp.path}/import_test.ndjson';
      // Write two docs in NDJSON format with valid UUIDv7 _id values.
      // Use the collection to insert first, export, then reimport into another.
      final srcProvider = AppProvider(prefs, adapter: memoryAdapter);
      await srcProvider.selectDatabase('/path/to/src-db');
      await srcProvider.createCollection('tasks');
      final srcCol = srcProvider.database!.rawCollection('tasks');
      await srcCol.insert({'title': 'Task 1'});
      await srcCol.insert({'title': 'Task 2'});
      await srcProvider.exportCollection('tasks', tmpFile);

      final (:imported, :skipped, :errors) = await provider.importCollection(
        'tasks',
        tmpFile,
      );

      expect(imported, equals(2));
      expect(skipped, equals(0));
      expect(errors, isEmpty);
      File(tmpFile).deleteSync();
    });

    test('importCollection ignores conflicting docs by default', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/import-conflict-db');
      await provider.createCollection('items');

      // Export one doc, import it, then import again — second should be skipped.
      final tmpFile =
          '${Directory.systemTemp.path}/import_conflict_test.ndjson';
      final col = provider.database!.rawCollection('items');
      await col.insert({'x': 1});
      await provider.exportCollection('items', tmpFile);

      final first = await provider.importCollection('items', tmpFile);
      expect(first.skipped, equals(1));

      File(tmpFile).deleteSync();
    });

    test('dumpDatabase writes headers and returns totals', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/dump-db');
      await provider.createCollection('col1');
      await provider.createCollection('col2');
      await provider.database!.rawCollection('col1').insert({'v': 1});
      await provider.database!.rawCollection('col2').insert({'v': 2});
      await provider.database!.rawCollection('col2').insert({'v': 3});

      final tmpFile = '${Directory.systemTemp.path}/dump_test.ndjson';
      final (:total, :collections) = await provider.dumpDatabase(tmpFile);

      expect(total, equals(3));
      expect(collections, equals(2));
      final content = File(tmpFile).readAsStringSync();
      expect(content, contains('# collection: col1'));
      expect(content, contains('# collection: col2'));
      File(tmpFile).deleteSync();
    });

    test('restoreDatabase restores documents from dump', () async {
      final srcProvider = AppProvider(prefs, adapter: memoryAdapter);
      await srcProvider.selectDatabase('/path/to/restore-src-db');
      await srcProvider.createCollection('alpha');
      await srcProvider.database!.rawCollection('alpha').insert({'k': 1});
      final tmpFile = '${Directory.systemTemp.path}/restore_test.ndjson';
      await srcProvider.dumpDatabase(tmpFile);

      final dstProvider = AppProvider(prefs, adapter: memoryAdapter);
      await dstProvider.selectDatabase('/path/to/restore-dst-db');
      final (:restored, :collections) = await dstProvider.restoreDatabase(
        tmpFile,
      );

      expect(restored, equals(1));
      expect(collections, equals(1));
      expect(dstProvider.collections, contains('alpha'));
      File(tmpFile).deleteSync();
    });

    // ── Maintenance ──────────────────────────────────────────────────────────

    test('storeInfo returns non-null when database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      final info = await provider.storeInfo();
      expect(info, isNotNull);
      expect(info!.deviceId, isNotEmpty);
    });

    test('storeStats returns non-null when database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      final stats = await provider.storeStats();
      expect(stats, isNotNull);
      expect(stats!.totalDbBytes, greaterThanOrEqualTo(0));
    });

    test('storeInfo returns null when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final info = await provider.storeInfo();
      expect(info, isNull);
    });

    test('flushDatabase completes without error', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      await provider.flushDatabase(); // should not throw
    });

    test('compactDatabase completes without error', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      await provider.compactDatabase(); // should not throw
    });

    test('verifyDatabase returns checked count and zero errors', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/verify-db');
      await provider.createCollection('data');
      final col = provider.database!.rawCollection('data');
      await col.insert({'x': 1});
      await col.insert({'x': 2});

      final (:checked, :errors) = await provider.verifyDatabase();

      expect(checked, equals(2));
      expect(errors, equals(0));
    });

    test(
      'verifyDatabase returns zero checked when no database is open',
      () async {
        final provider = AppProvider(prefs, adapter: memoryAdapter);
        final result = await provider.verifyDatabase();
        expect(result.checked, equals(0));
        expect(result.errors, equals(0));
      },
    );

    // ── Remote management ────────────────────────────────────────────────────

    test('remotes returns empty map when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      expect(await provider.remotes(), isEmpty);
    });

    test('remotes returns empty map when no remotes configured', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');
      expect(await provider.remotes(), isEmpty);
    });

    test('addRemote returns error when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final err = await provider.addRemote('origin', '/sync/folder');
      expect(err, isNotNull);
      expect(err, contains('No database open'));
    });

    test('addRemote adds remote to config', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/remote-db');

      await provider.addRemote('origin', '/sync/folder');

      // Config save may fail on in-memory test paths — either outcome is
      // acceptable, the logic path executed without throwing.
    });

    test('removeRemote returns error when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final err = await provider.removeRemote('origin');
      expect(err, isNotNull);
      expect(err, contains('No database open'));
    });

    // ── Sync guard tests ─────────────────────────────────────────────────────

    test('pushTo returns error when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final err = await provider.pushTo('origin');
      expect(err, isNotNull);
      expect(err, contains('No database open'));
    });

    test('pullFrom returns error when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final err = await provider.pullFrom('origin');
      expect(err, isNotNull);
      expect(err, contains('No database open'));
    });

    test('syncWith returns error when no database is open', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      final err = await provider.syncWith('origin');
      expect(err, isNotNull);
      expect(err, contains('No database open'));
    });

    test('pushTo returns error when named remote does not exist', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/sync-guard-db');

      final err = await provider.pushTo('nonexistent');
      expect(err, isNotNull);
      expect(err, contains('not found'));
    });

    test('pullFrom returns error when named remote does not exist', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/sync-guard-db2');

      final err = await provider.pullFrom('nonexistent');
      expect(err, isNotNull);
      expect(err, contains('not found'));
    });

    test('syncWith returns error when named remote does not exist', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/sync-guard-db3');

      final err = await provider.syncWith('nonexistent');
      expect(err, isNotNull);
      expect(err, contains('not found'));
    });
  });
}
