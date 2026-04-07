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

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kmdb/kmdb.dart';

class DatabaseProvider with ChangeNotifier {
  static const _channel = MethodChannel('com.kmdb.browser/bookmarks');

  final SharedPreferences prefs;
  final List<String> _recentDatabasePaths = [];
  final Map<String, String> _bookmarks = {}; // path -> bookmarkBase64
  String? _selectedDatabasePath;
  KvStore? _store;
  Map<String, int> _collections = {};
  String? _selectedCollection;
  Map<String, dynamic>? _selectedDocument;
  String? _loadError;
  ThemeMode _themeMode = ThemeMode.system;

  bool _isOpening = false;

  DatabaseProvider(this.prefs) {
    _loadFromPrefs();
  }

  static const String _kRecentDatabasesKey = 'recent_databases';
  static const String _kBookmarksKey = 'bookmarks_map';
  static const String _kThemeModeKey = 'theme_mode';

  void _loadFromPrefs() {
    final list = prefs.getStringList(_kRecentDatabasesKey);
    if (list != null) {
      // Ensure all paths loaded from prefs are absolute
      _recentDatabasePaths.addAll(list.map((p) => File(p).absolute.path));
    }

    final bookmarksJson = prefs.getString(_kBookmarksKey);
    if (bookmarksJson != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(bookmarksJson);
        decoded.forEach((key, value) {
          _bookmarks[key] = value.toString();
        });
      } catch (e) {
        debugPrint('Error loading bookmarks: $e');
      }
    }

    final themeStr = prefs.getString(_kThemeModeKey);
    if (themeStr != null) {
      _themeMode = ThemeMode.values.firstWhere(
        (e) => e.name == themeStr,
        orElse: () => ThemeMode.system,
      );
    }
  }

  Future<void> _saveToPrefs() async {
    await prefs.setStringList(_kRecentDatabasesKey, _recentDatabasePaths);
    await prefs.setString(_kBookmarksKey, jsonEncode(_bookmarks));
  }

  List<String> get recentDatabasePaths => _recentDatabasePaths;
  String? get selectedDatabasePath => _selectedDatabasePath;
  KvStore? get store => _store;
  List<String> get collections => _collections.keys.toList();
  int getCollectionCount(String name) => _collections[name] ?? 0;
  String? get selectedCollection => _selectedCollection;
  Map<String, dynamic>? get selectedDocument => _selectedDocument;
  String? get loadError => _loadError;
  ThemeMode get themeMode => _themeMode;
  bool get isOpening => _isOpening;

  void setThemeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      prefs.setString(_kThemeModeKey, mode.name);
      notifyListeners();
    }
  }

  Future<void> openDatabase() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      await selectDatabase(path);
    }
  }

  Future<void> selectDatabase(String path) async {
    if (_isOpening) return;

    final absolutePath = File(path).absolute.path;
    if (!_recentDatabasePaths.contains(absolutePath)) {
      _recentDatabasePaths.add(absolutePath);
    }

    if (_selectedDatabasePath == absolutePath && _store != null) {
      return;
    }

    _isOpening = true;
    _loadError = null;
    notifyListeners();

    try {
      await _closeCurrentStore();

      // For macOS sandboxing: if we have a bookmark, resolve it first.
      final bookmark = _bookmarks[absolutePath];
      if (bookmark != null && Platform.isMacOS) {
        try {
          await _channel.invokeMethod('startAccessing', {'bookmark': bookmark});
        } catch (e) {
          debugPrint('Error starting access for bookmark: $e');
          // If resolving fails, we'll still try to open (it might work if
          // the app currently has access), but user might need to re-pick.
        }
      }

      _selectedDatabasePath = absolutePath;
      _selectedCollection = null;
      _selectedDocument = null;
      notifyListeners(); // Let the UI show the loading state for the new path

      final adapter = StorageAdapterNative();
      final (store, _) = await KvStoreImpl.open(
        _selectedDatabasePath!,
        adapter,
      );
      _store = store;

      // Upon successful open, request a bookmark if we don't have one (or to update it)
      if (Platform.isMacOS) {
        try {
          final newBookmark = await _channel.invokeMethod<String>(
            'getBookmark',
            {'path': absolutePath},
          );
          if (newBookmark != null) {
            _bookmarks[absolutePath] = newBookmark;
            await _saveToPrefs();
          }
        } catch (e) {
          debugPrint('Error creating bookmark: $e');
        }
      }

      await _loadCollections();
    } catch (e, stack) {
      debugPrint('Error opening database at $absolutePath: $e\n$stack');
      _loadError = e.toString();
      // Keep _selectedDatabasePath so the error can be displayed in the UI
      await _closeCurrentStore();
    } finally {
      _isOpening = false;
      _saveToPrefs();
      notifyListeners();
    }
  }

  Future<void> _closeCurrentStore() async {
    final path = _selectedDatabasePath;
    try {
      if (_store != null) {
        await _store!.close();
      }
    } catch (e) {
      debugPrint('Error closing store: $e');
    } finally {
      _store = null;
      if (path != null && Platform.isMacOS) {
        try {
          await _channel.invokeMethod('stopAccessing', {'path': path});
        } catch (e) {
          debugPrint('Error stopping access: $e');
        }
      }
    }
  }

  void removeDatabase(String path) async {
    final absolutePath = File(path).absolute.path;
    _recentDatabasePaths.remove(absolutePath);
    if (_selectedDatabasePath == absolutePath) {
      await _closeCurrentStore();
      _selectedDatabasePath = null;
      _collections = {};
      _selectedCollection = null;
      _selectedDocument = null;
      _loadError = null;
    }
    _saveToPrefs();
    notifyListeners();
  }

  void selectCollection(String collectionName) {
    if (_selectedDatabasePath != null) {
      _selectedCollection = collectionName;
      _selectedDocument = null;
      notifyListeners();
    }
  }

  void selectDocument(Map<String, dynamic>? doc) {
    _selectedDocument = doc;
    notifyListeners();
  }

  Future<void> _loadCollections() async {
    final store = _store;
    if (store == null) return;

    try {
      final names = await store.listNamespaces();
      final Map<String, int> newCollections = {};
      for (final name in names) {
        if (name.startsWith(r'$')) continue;

        int count = 0;
        await for (final _ in store.scan(name)) {
          count++;
        }
        newCollections[name] = count;
      }
      _collections = newCollections;
      _loadError = null;
    } catch (e) {
      _collections = {};
      _loadError = e.toString();
      debugPrint('Error loading collections: $e');
    }
    // Note: notifyListeners is called in selectDatabase after this
  }

  Future<bool> createCollection(String name) async {
    final store = _store;
    if (store == null) return false;

    try {
      final created = await store.createNamespace(name);
      await _loadCollections();
      notifyListeners();
      return created;
    } catch (e) {
      debugPrint('Error creating collection: $e');
      return false;
    }
  }

  Future<void> refreshCollections() => _loadCollections().then((_) => notifyListeners());

  @override
  void dispose() {
    _closeCurrentStore();
    super.dispose();
  }
}
