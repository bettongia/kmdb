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
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_ui/database_provider.dart';

class MockKvStore extends Mock implements KvStore {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late MemoryStorageAdapter memoryAdapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    memoryAdapter = MemoryStorageAdapter();

    // Mock MethodChannel for bookmarks
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

    // Mock MethodChannel for file_picker
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

  group('DatabaseProvider', () {
    test('initialization loads default values', () {
      final provider = DatabaseProvider(prefs, adapter: memoryAdapter);
      expect(provider.recentDatabasePaths, isEmpty);
      expect(provider.themeMode, equals(ThemeMode.system));
    });

    test('setThemeMode updates state and prefs', () async {
      final provider = DatabaseProvider(prefs, adapter: memoryAdapter);
      provider.setThemeMode(ThemeMode.dark);

      expect(provider.themeMode, equals(ThemeMode.dark));
      expect(prefs.getString('theme_mode'), equals('dark'));
    });

    test('removeDatabase updates state and saves to prefs', () async {
      await prefs.setStringList('recent_databases', ['/path/to/db']);
      final provider = DatabaseProvider(prefs, adapter: memoryAdapter);

      expect(provider.recentDatabasePaths, contains(endsWith('db')));

      provider.removeDatabase('/path/to/db');

      expect(provider.recentDatabasePaths, isEmpty);
      expect(prefs.getStringList('recent_databases'), isEmpty);
    });

    test('selectDatabase opens store and loads collections', () async {
      final provider = DatabaseProvider(prefs, adapter: memoryAdapter);

      // selectDatabase will try to open the database.
      // MemoryStorageAdapter will work fine in test environment.
      await provider.selectDatabase('/path/to/test-db');

      expect(provider.selectedDatabasePath, contains('test-db'));
      expect(provider.store, isNotNull);
      expect(provider.isOpening, isFalse);
    });
  });
}
