// Copyright 2026 The KMDB Authors
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

    test('ftsIndexedFieldsForCollection returns empty before index created',
        () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/db');

      expect(provider.ftsIndexedFieldsForCollection('notes'), isEmpty);
    });

    test('ftsIndexedFieldsForCollection lists created index', () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/fts-fields-db');
      await provider.createCollection('docs');

      await provider.createFtsIndex(collection: 'docs', field: 'body');

      expect(
        provider.ftsIndexedFieldsForCollection('docs'),
        contains('body'),
      );
    });

    test('deleteFtsIndex removes index from ftsIndexedFieldsForCollection',
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
    });

    test('deleteFtsIndex disables hasFtsCapability when last index removed',
        () async {
      final provider = AppProvider(prefs, adapter: memoryAdapter);
      await provider.selectDatabase('/path/to/fts-last-db');
      await provider.createCollection('logs');
      await provider.createFtsIndex(collection: 'logs', field: 'message');
      expect(provider.hasFtsCapability, isTrue);

      await provider.deleteFtsIndex('logs', 'message');

      expect(provider.hasFtsCapability, isFalse);
    });

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
  });
}
