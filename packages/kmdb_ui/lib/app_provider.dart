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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kmdb/kmdb.dart';

/// Top-level application state provider.
///
/// [AppProvider] owns the open [KmdbDatabase] instance and exposes it to
/// downstream consumers. It replaces the former [DatabaseProvider]'s direct
/// [KvStore] exposure, positioning the UI at the Query Layer boundary
/// (spec §13) rather than bypassing it.
///
/// Key responsibilities:
/// - Opening and closing the [KmdbDatabase].
/// - Maintaining the recent-database list and macOS security-scoped bookmarks.
/// - Exposing the list of user collections with efficient [KmdbCollection.count]
///   calls (not full-scan materialisation).
/// - Tracking selected collection and document for column-based navigation.
/// - Managing the app theme preference.
class AppProvider with ChangeNotifier {
  static const _channel = MethodChannel('com.kmdb.browser/bookmarks');

  final SharedPreferences prefs;
  final List<String> _recentDatabasePaths = [];
  final Map<String, String> _bookmarks = {}; // path -> bookmarkBase64

  String? _selectedDatabasePath;
  KmdbDatabase? _database;
  Map<String, int> _collections = {};
  String? _selectedCollection;
  Map<String, dynamic>? _selectedDocument;
  String? _loadError;
  ThemeMode _themeMode = ThemeMode.system;
  bool _isOpening = false;
  bool _isBusy = false;
  String _busyMessage = '';

  final StorageAdapter _adapter;

  static const String _kRecentDatabasesKey = 'recent_databases';
  static const String _kBookmarksKey = 'bookmarks_map';
  static const String _kThemeModeKey = 'theme_mode';

  /// Creates an [AppProvider].
  ///
  /// [prefs] is used to persist recent database paths and theme preference.
  /// [adapter] defaults to the platform-native adapter; pass a
  /// [MemoryStorageAdapter] in tests.
  AppProvider(this.prefs, {StorageAdapter? adapter})
    : _adapter = adapter ?? StorageAdapterNative() {
    _loadFromPrefs();
  }

  // ── Getters ─────────────────────────────────────────────────────────────────

  /// The list of recently opened database directory paths.
  List<String> get recentDatabasePaths => _recentDatabasePaths;

  /// The absolute path of the currently open database directory, or null.
  String? get selectedDatabasePath => _selectedDatabasePath;

  /// The open [KmdbDatabase] instance, or null if no database is open.
  KmdbDatabase? get database => _database;

  /// The names of all user collections in the open database.
  List<String> get collections => _collections.keys.toList();

  /// Returns the document count for [name] from the cached collection list.
  int getCollectionCount(String name) => _collections[name] ?? 0;

  /// The currently selected collection name, or null.
  String? get selectedCollection => _selectedCollection;

  /// The currently selected document, or null.
  Map<String, dynamic>? get selectedDocument => _selectedDocument;

  /// Any error message from the most recent open operation, or null.
  String? get loadError => _loadError;

  /// The current theme mode.
  ThemeMode get themeMode => _themeMode;

  /// True while a database open is in progress.
  bool get isOpening => _isOpening;

  /// True while a long-running operation is running.
  ///
  /// Used by [AsyncOperationOverlay] to show a modal progress indicator.
  bool get isBusy => _isBusy;

  /// Human-readable label for the currently running operation.
  String get busyMessage => _busyMessage;

  // ── Theme ────────────────────────────────────────────────────────────────────

  /// Updates the theme mode and persists the choice to shared preferences.
  void setThemeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      prefs.setString(_kThemeModeKey, mode.name);
      notifyListeners();
    }
  }

  // ── Database lifecycle ───────────────────────────────────────────────────────

  /// Opens a directory picker and opens the selected database.
  Future<void> openDatabase() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      await selectDatabase(path);
    }
  }

  /// Opens the database at [path] and loads the collection list.
  ///
  /// If [path] is already open, this is a no-op. Adds [path] to the recent
  /// list and requests a macOS security-scoped bookmark where available.
  Future<void> selectDatabase(String path) async {
    if (_isOpening) return;

    final absolutePath = File(path).absolute.path;
    if (!_recentDatabasePaths.contains(absolutePath)) {
      _recentDatabasePaths.add(absolutePath);
    }

    if (_selectedDatabasePath == absolutePath && _database != null) {
      return;
    }

    _isOpening = true;
    _loadError = null;
    notifyListeners();

    try {
      await _closeCurrentDatabase();

      // For macOS sandboxing: if we have a bookmark, resolve it first so that
      // the security scope is active before KvStoreImpl opens the directory.
      final bookmark = _bookmarks[absolutePath];
      if (bookmark != null && Platform.isMacOS) {
        try {
          await _channel.invokeMethod('startAccessing', {'bookmark': bookmark});
        } catch (e) {
          debugPrint('Error starting access for bookmark: $e');
        }
      }

      _selectedDatabasePath = absolutePath;
      _selectedCollection = null;
      _selectedDocument = null;
      notifyListeners();

      // Open via KmdbDatabase so downstream consumers can use the query layer.
      _database = await KmdbDatabase.open(
        path: _selectedDatabasePath!,
        adapter: _adapter,
      );

      // Request/refresh the macOS security-scoped bookmark for future launches.
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
      await _closeCurrentDatabase();
    } finally {
      _isOpening = false;
      _saveToPrefs();
      notifyListeners();
    }
  }

  /// Removes [path] from the recent database list and closes it if open.
  void removeDatabase(String path) async {
    final absolutePath = File(path).absolute.path;
    _recentDatabasePaths.remove(absolutePath);
    if (_selectedDatabasePath == absolutePath) {
      await _closeCurrentDatabase();
      _selectedDatabasePath = null;
      _collections = {};
      _selectedCollection = null;
      _selectedDocument = null;
      _loadError = null;
    }
    _saveToPrefs();
    notifyListeners();
  }

  // ── Collection management ────────────────────────────────────────────────────

  /// Selects [collectionName] as the active collection.
  void selectCollection(String collectionName) {
    if (_selectedDatabasePath != null) {
      _selectedCollection = collectionName;
      _selectedDocument = null;
      notifyListeners();
    }
  }

  /// Creates a new collection named [name] via the underlying KvStore.
  ///
  /// Returns true if the collection was created, false if it already existed
  /// or if no database is open.
  Future<bool> createCollection(String name) async {
    final db = _database;
    if (db == null) return false;

    try {
      final created = await db.store.createNamespace(name);
      await _loadCollections();
      notifyListeners();
      return created;
    } catch (e) {
      debugPrint('Error creating collection: $e');
      return false;
    }
  }

  /// Reloads the collection list and notifies listeners.
  Future<void> refreshCollections() =>
      _loadCollections().then((_) => notifyListeners());

  // ── Document selection ───────────────────────────────────────────────────────

  /// Sets the currently selected document.
  ///
  /// Pass null to clear the selection.
  void selectDocument(Map<String, dynamic>? doc) {
    _selectedDocument = doc;
    notifyListeners();
  }

  // ── Busy state ───────────────────────────────────────────────────────────────

  /// Wraps [operation] in a busy-state guard, showing [message] in any active
  /// [AsyncOperationOverlay] while the operation runs.
  ///
  /// Sets [isBusy] to true, disables the overlay, runs [operation], then
  /// restores [isBusy] to false regardless of success or failure.
  Future<T> runBusy<T>(String message, Future<T> Function() operation) async {
    _isBusy = true;
    _busyMessage = message;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _isBusy = false;
      _busyMessage = '';
      notifyListeners();
    }
  }

  // ── Internal helpers ─────────────────────────────────────────────────────────

  void _loadFromPrefs() {
    final list = prefs.getStringList(_kRecentDatabasesKey);
    if (list != null) {
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

  /// Loads (or reloads) the collection list.
  ///
  /// Uses [KmdbCollection.count] for each namespace so that the full document
  /// set is never materialised — only the integer count is fetched.
  Future<void> _loadCollections() async {
    final db = _database;
    if (db == null) return;

    try {
      final names = await db.store.listNamespaces();
      final Map<String, int> newCollections = {};
      for (final name in names) {
        // Skip system namespaces ($meta, $index:…, $fts:…, $vec:…, $cache).
        if (name.startsWith(r'$')) continue;

        // Use KmdbCollection.count() rather than streaming every document:
        // this avoids materialising the full collection on every open/refresh.
        final count = await db.rawCollection(name).all().count();
        newCollections[name] = count;
      }
      _collections = newCollections;
      _loadError = null;
    } catch (e) {
      _collections = {};
      _loadError = e.toString();
      debugPrint('Error loading collections: $e');
    }
    // Callers are responsible for calling notifyListeners after this.
  }

  Future<void> _closeCurrentDatabase() async {
    final path = _selectedDatabasePath;
    try {
      if (_database != null) {
        await _database!.close();
      }
    } catch (e) {
      debugPrint('Error closing database: $e');
    } finally {
      _database = null;
      if (path != null && Platform.isMacOS) {
        try {
          await _channel.invokeMethod('stopAccessing', {'path': path});
        } catch (e) {
          debugPrint('Error stopping access: $e');
        }
      }
    }
  }

  @override
  void dispose() {
    _closeCurrentDatabase();
    super.dispose();
  }
}
