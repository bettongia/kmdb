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
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';

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
/// - Managing FTS index definitions: loading from [KmdbConfig], passing to
///   [KmdbDatabase.open], and creating/deleting via [createFtsIndex] /
///   [deleteFtsIndex] (which reopen the database to apply the change).
/// - Managing secondary index definitions: same pattern as FTS.
/// - Schema management: register/deregister JSON schemas and validate documents.
/// - Export/import single collections and dump/restore the whole database as
///   NDJSON files (matching the CLI export/import/dump/restore format).
/// - Database maintenance: flush, compact, verify, and device-ID rotation.
/// - Managing the app theme preference.
class AppProvider with ChangeNotifier {
  static const _channel = MethodChannel('com.kmdb.browser/bookmarks');

  final SharedPreferences prefs;
  final List<String> _recentDatabasePaths = [];
  final Map<String, String> _bookmarks = {}; // path -> bookmarkBase64

  String? _selectedDatabasePath;
  KmdbDatabase? _database;

  /// FTS index definitions active for the open database.
  ///
  /// Loaded from [KmdbConfig] when the database is opened and kept in sync
  /// with [createFtsIndex] / [deleteFtsIndex]. Always passed to
  /// [KmdbDatabase.open] so the FTS manager is wired at open time.
  List<FtsIndexDefinition> _ftsIndexDefs = [];

  /// Secondary index definitions active for the open database.
  ///
  /// Loaded from [KmdbConfig] when the database is opened and kept in sync
  /// with [createSecondaryIndex] / [deleteSecondaryIndex]. Always passed to
  /// [KmdbDatabase.open] so the index manager is wired at open time.
  List<IndexDefinition> _secondaryIndexDefs = [];

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

  // ── FTS capabilities ─────────────────────────────────────────────────────────

  /// True when the open database has an active [FtsManager] (i.e. at least one
  /// FTS index definition was passed at open time).
  bool get hasFtsCapability => _database?.ftsManager != null;

  /// True when the open database has an active [VecManager].
  ///
  /// Semantic search requires an embedding model backed by ONNX Runtime, which
  /// is only available on macOS. This guard prevents the search panel from
  /// showing the semantic mode selector on unsupported platforms.
  bool get hasVecCapability => _database?.vecManager != null;

  /// The fields with an active FTS index for [collection].
  List<String> ftsIndexedFieldsForCollection(String collection) => _ftsIndexDefs
      .where((d) => d.collection == collection)
      .map((d) => d.field)
      .toList();

  // ── Secondary index capabilities ──────────────────────────────────────────────

  /// The field paths with a secondary index configured for [collection].
  List<String> secondaryIndexPathsForCollection(String collection) =>
      _secondaryIndexDefs
          .where((d) => d.namespace == collection)
          .map((d) => d.path)
          .toList();

  // ── Schema capabilities ────────────────────────────────────────────────────────

  /// The names of all collections that have a registered JSON schema.
  List<String> get registeredSchemas =>
      _database?.schemaManager.registeredCollections ?? [];

  /// The raw JSON schema map for [collection], or null if none is registered.
  Map<String, dynamic>? schemaForCollection(String collection) =>
      _database?.schemaManager.getSchema(collection);

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

      // Load FTS and secondary index definitions from config so the respective
      // managers are wired at open time. Errors are non-fatal.
      _ftsIndexDefs = await _loadFtsDefsFromConfig(absolutePath);
      _secondaryIndexDefs = await _loadSecondaryIndexDefsFromConfig(
        absolutePath,
      );

      // Open via KmdbDatabase so downstream consumers can use the query layer.
      _database = await KmdbDatabase.open(
        path: _selectedDatabasePath!,
        adapter: _adapter,
        ftsIndexes: _ftsIndexDefs,
        indexes: _secondaryIndexDefs,
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

  /// Clears the collection and document selection without closing the database.
  ///
  /// Used for narrow-layout back navigation from the document content column to
  /// the collection list column.
  void clearCollectionSelection() {
    _selectedCollection = null;
    _selectedDocument = null;
    notifyListeners();
  }

  /// Closes the current database and clears the path selection.
  ///
  /// Unlike [removeDatabase], this keeps the path in [recentDatabasePaths] so
  /// the user can reopen it by tapping it. Used for narrow-layout back
  /// navigation from the collection list column to the database history column.
  Future<void> deselectDatabase() async {
    await _closeCurrentDatabase();
    _selectedDatabasePath = null;
    _selectedCollection = null;
    _selectedDocument = null;
    _collections = {};
    notifyListeners();
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

  /// Deletes the collection named [name] and all its documents, secondary
  /// indexes, and FTS/vector index data.
  ///
  /// After deletion the selected collection and document are cleared if they
  /// pointed at [name]. The collection list is refreshed automatically.
  Future<void> deleteCollection(String name) async {
    final db = _database;
    final dbPath = _selectedDatabasePath;
    if (db == null || dbPath == null) return;

    // 1. Delete all documents in batches of 200 via the query layer so that
    //    write events fire and any active watch() streams are notified.
    const batchSize = 200;
    var batch = WriteBatch();
    var count = 0;
    final col = db.rawCollection(name);
    await for (final doc in col.all().stream()) {
      final id = doc['_id'] as String;
      batch.delete(name, id);
      count++;
      if (count >= batchSize) {
        await db.store.writeBatch(batch);
        batch = WriteBatch();
        count = 0;
      }
    }
    if (!batch.isEmpty) await db.store.writeBatch(batch);

    // 2. Remove secondary index definitions from config and drop index data.
    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      final records = config.indexesForCollection(name).toList();
      for (final record in records) {
        await db.indexManager.removeIndex(name, record.path);
        config.removeIndex(name, record.path);
      }
      if (records.isNotEmpty) await config.save();
    } catch (e) {
      debugPrint('Error cleaning up indexes for collection $name: $e');
    }

    // 3. Unregister the namespace so it no longer appears in collections list.
    await db.store.unregisterNamespace(name);

    if (_selectedCollection == name) {
      _selectedCollection = null;
      _selectedDocument = null;
    }
    await _loadCollections();
    notifyListeners();
  }

  /// Reloads the collection list and notifies listeners.
  Future<void> refreshCollections() =>
      _loadCollections().then((_) => notifyListeners());

  // ── FTS index management ─────────────────────────────────────────────────────

  /// Creates an FTS index on [field] in [collection].
  ///
  /// Updates the in-memory [_ftsIndexDefs] list, persists the definition to
  /// [KmdbConfig] (best-effort — config save failures are logged but do not
  /// prevent the index from becoming active), then reopens the database so the
  /// new [FtsIndexDefinition] is registered with [FtsManager].
  Future<void> createFtsIndex({
    required String collection,
    required String field,
    bool stopWords = false,
    double k1 = 1.2,
    double b = 0.75,
  }) async {
    if (_selectedDatabasePath == null) return;

    // Deduplicate: replace any existing definition for the same field.
    _ftsIndexDefs = [
      ..._ftsIndexDefs.where(
        (d) => !(d.collection == collection && d.field == field),
      ),
      FtsIndexDefinition(
        collection: collection,
        field: field,
        k1: k1,
        b: b,
        stopWords: stopWords,
        lazy: true,
      ),
    ];

    try {
      final config = await KmdbConfig.forDatabase(_selectedDatabasePath!);
      config.addFtsIndex(collection, field, stopWords: stopWords, k1: k1, b: b);
      await config.save();
    } catch (e) {
      debugPrint('Could not persist FTS index to config: $e');
    }

    await _reopenDatabase();
  }

  /// Removes the FTS index on [field] in [collection].
  ///
  /// Mirrors [createFtsIndex]: updates in-memory list, best-effort config
  /// save, then reopens the database.
  Future<void> deleteFtsIndex(String collection, String field) async {
    if (_selectedDatabasePath == null) return;

    _ftsIndexDefs = _ftsIndexDefs
        .where((d) => !(d.collection == collection && d.field == field))
        .toList();

    try {
      final config = await KmdbConfig.forDatabase(_selectedDatabasePath!);
      config.removeFtsIndex(collection, field);
      await config.save();
    } catch (e) {
      debugPrint('Could not remove FTS index from config: $e');
    }

    await _reopenDatabase();
  }

  // ── Secondary index management ───────────────────────────────────────────────

  /// Creates a secondary index on [path] in [collection].
  ///
  /// Updates the in-memory [_secondaryIndexDefs] list, persists the definition
  /// to [KmdbConfig] (best-effort), then reopens the database so the new
  /// [IndexDefinition] is registered with [IndexManager].
  Future<void> createSecondaryIndex(String collection, String path) async {
    if (_selectedDatabasePath == null) return;

    _secondaryIndexDefs = [
      ..._secondaryIndexDefs.where(
        (d) => !(d.namespace == collection && d.path == path),
      ),
      IndexDefinition(collection, path),
    ];

    try {
      final config = await KmdbConfig.forDatabase(_selectedDatabasePath!);
      config.addIndex(collection, path);
      await config.save();
    } catch (e) {
      debugPrint('Could not persist secondary index to config: $e');
    }

    await _reopenDatabase();
  }

  /// Removes the secondary index on [path] in [collection].
  ///
  /// Drops stored index data while the database is still open, then updates
  /// the in-memory list, persists the change, and reopens.
  Future<void> deleteSecondaryIndex(String collection, String path) async {
    if (_selectedDatabasePath == null) return;

    // Remove stored index data while the DB is still open.
    try {
      await _database?.indexManager.removeIndex(collection, path);
    } catch (e) {
      debugPrint('Could not remove stored index data: $e');
    }

    _secondaryIndexDefs = _secondaryIndexDefs
        .where((d) => !(d.namespace == collection && d.path == path))
        .toList();

    try {
      final config = await KmdbConfig.forDatabase(_selectedDatabasePath!);
      config.removeIndex(collection, path);
      await config.save();
    } catch (e) {
      debugPrint('Could not remove secondary index from config: $e');
    }

    await _reopenDatabase();
  }

  /// Returns the current [IndexState] for the index at [path] in [collection],
  /// or null if no database is open or the state cannot be determined.
  Future<IndexState?> getIndexState(String collection, String path) async {
    try {
      return await _database?.indexManager.getState(collection, path);
    } catch (e) {
      return null;
    }
  }

  // ── Schema management ────────────────────────────────────────────────────────

  /// Registers a JSON schema for [collection] from a JSON string.
  ///
  /// Returns null on success, or a human-readable error string on failure.
  Future<String?> registerSchema(String collection, String jsonString) async {
    final db = _database;
    if (db == null) return 'No database open.';

    try {
      final raw = jsonDecode(jsonString);
      if (raw is! Map<String, dynamic>) return 'Schema must be a JSON object.';
      await db.registerSchema(
        CollectionSchema(collection: collection, jsonSchema: raw),
      );
      notifyListeners();
      return null;
    } catch (e) {
      return 'Failed to register schema: $e';
    }
  }

  /// Removes the registered schema for [collection].
  Future<void> deregisterSchema(String collection) async {
    final db = _database;
    if (db == null) return;

    await db.deregisterSchema(collection);
    notifyListeners();
  }

  /// Validates [jsonString] against the registered schema for [collection].
  ///
  /// Returns null when the document is valid (or no schema is registered),
  /// or a human-readable error string describing the violation.
  String? validateDocumentJson(String collection, String jsonString) {
    final db = _database;
    if (db == null) return 'No database open.';

    try {
      final raw = jsonDecode(jsonString);
      if (raw is! Map<String, dynamic>) {
        return 'Document must be a JSON object.';
      }
      db.schemaManager.validate(collection, raw);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Export / Import / Dump / Restore ─────────────────────────────────────────

  /// Exports all documents in [collection] as NDJSON to [filePath].
  ///
  /// Returns the number of documents written. The format is one JSON object
  /// per line, matching the CLI `export` command output.
  Future<int> exportCollection(String collection, String filePath) async {
    final db = _database;
    if (db == null) return 0;

    final sink = File(filePath).openWrite();
    const enc = JsonEncoder();
    int count = 0;

    try {
      await for (final doc in db.rawCollection(collection).all().stream()) {
        sink.writeln(enc.convert(doc));
        count++;
      }
    } finally {
      await sink.close();
    }

    return count;
  }

  /// Imports documents from an NDJSON file at [filePath] into [collection].
  ///
  /// [onConflict] controls behaviour when a document with the same `_id`
  /// already exists: `'ignore'` skips it, `'replace'` overwrites it,
  /// `'error'` records an error and stops. Returns counts and any error
  /// messages. The collection list is refreshed after a successful import.
  Future<({int imported, int skipped, List<String> errors})> importCollection(
    String collection,
    String filePath, {
    String onConflict = 'ignore',
  }) async {
    final db = _database;
    if (db == null) return (imported: 0, skipped: 0, errors: <String>[]);

    final col = db.rawCollection(collection);
    final lines = await File(filePath).readAsLines();
    int imported = 0;
    int skipped = 0;
    final errors = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      try {
        final raw = jsonDecode(line);
        if (raw is! Map<String, dynamic>) {
          errors.add('Line ${i + 1}: not a JSON object');
          continue;
        }

        if (raw['_id'] == null) {
          errors.add('Line ${i + 1}: missing _id field');
          continue;
        }

        final id = '${raw['_id']}';

        if (onConflict != 'replace') {
          final existing = await db.store.get(collection, id);
          if (existing != null) {
            if (onConflict == 'error') {
              errors.add('Line ${i + 1}: document $id already exists');
            } else {
              skipped++;
            }
            continue;
          }
        }

        await col.put(raw);
        imported++;
      } catch (e) {
        errors.add('Line ${i + 1}: $e');
      }
    }

    await _loadCollections();
    notifyListeners();
    return (imported: imported, skipped: skipped, errors: errors);
  }

  /// Dumps all collections to [filePath] as multi-collection NDJSON.
  ///
  /// Each collection is preceded by a `# collection: <name>` header line,
  /// matching the CLI `dump` format. Returns a record with the total document
  /// count and the number of collections written.
  Future<({int total, int collections})> dumpDatabase(String filePath) async {
    final db = _database;
    if (db == null) return (total: 0, collections: 0);

    final sink = File(filePath).openWrite();
    const enc = JsonEncoder();
    int total = 0;
    int collectionCount = 0;

    try {
      final namespaces = await db.store.listNamespaces();
      for (final name in namespaces) {
        if (name.startsWith(r'$')) continue;
        sink.writeln('# collection: $name');
        await for (final doc in db.rawCollection(name).all().stream()) {
          sink.writeln(enc.convert(doc));
          total++;
        }
        collectionCount++;
      }
    } finally {
      await sink.close();
    }

    return (total: total, collections: collectionCount);
  }

  /// Restores collections from a dump file at [filePath].
  ///
  /// Parses the multi-collection NDJSON format written by [dumpDatabase].
  /// Missing collections are created automatically. Returns a record with the
  /// total documents restored and the number of distinct collections seen.
  Future<({int restored, int collections})> restoreDatabase(
    String filePath,
  ) async {
    final db = _database;
    if (db == null) return (restored: 0, collections: 0);

    final lines = await File(filePath).readAsLines();
    String? currentCollection;
    int restored = 0;
    final collectionsSeen = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('# collection:')) {
        currentCollection = line.substring('# collection:'.length).trim();
        collectionsSeen.add(currentCollection);
        await db.store.createNamespace(currentCollection);
        continue;
      }

      if (currentCollection == null) continue;

      try {
        final raw = jsonDecode(line);
        if (raw is! Map<String, dynamic>) continue;
        if (raw['_id'] == null) continue;

        await db.rawCollection(currentCollection).put(raw);
        restored++;
      } catch (e) {
        debugPrint('Restore line ${i + 1}: $e');
      }
    }

    await _loadCollections();
    notifyListeners();
    return (restored: restored, collections: collectionsSeen.length);
  }

  // ── Remote management ────────────────────────────────────────────────────────

  /// Returns all named sync remotes for the open database.
  ///
  /// Reads [KmdbConfig] from disk on every call so the list is always current.
  /// Returns an empty map when no database is open or the config does not exist.
  Future<Map<String, RemoteConfig>> remotes() async {
    final dbPath = _selectedDatabasePath;
    if (dbPath == null) return {};
    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      return config.remotes;
    } catch (e) {
      debugPrint('Could not load remotes: $e');
      return {};
    }
  }

  /// Adds a local sync remote named [name] pointing at [path].
  ///
  /// Persists the change to [KmdbConfig] and notifies listeners. Returns null
  /// on success or a human-readable error string on failure.
  Future<String?> addRemote(String name, String path) async {
    final dbPath = _selectedDatabasePath;
    if (dbPath == null) return 'No database open.';

    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      config.addRemote(name, LocalRemoteConfig(path: path));
      await config.save();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Failed to add remote: $e';
    }
  }

  /// Removes the sync remote named [name].
  ///
  /// Returns null on success or an error string on failure.
  Future<String?> removeRemote(String name) async {
    final dbPath = _selectedDatabasePath;
    if (dbPath == null) return 'No database open.';

    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      config.removeRemote(name);
      await config.save();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Failed to remove remote: $e';
    }
  }

  // ── Sync operations ────────────────────────────────────────────────────────────

  /// Pushes local SSTables to the named remote [remoteName].
  ///
  /// Returns null on success or a human-readable error string on failure.
  /// This operation is only meaningful on macOS (filesystem sync).
  Future<String?> pushTo(String remoteName) async {
    final engine = await _buildSyncEngine(remoteName);
    if (engine is String) return engine; // error string
    try {
      await (engine as SyncEngine).push();
      return null;
    } catch (e) {
      return 'Push failed: $e';
    }
  }

  /// Pulls SSTables from the named remote [remoteName] and reloads collections.
  ///
  /// Returns null on success or a human-readable error string on failure.
  Future<String?> pullFrom(String remoteName) async {
    final engine = await _buildSyncEngine(remoteName);
    if (engine is String) return engine;
    try {
      await (engine as SyncEngine).pull();
      await _loadCollections();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Pull failed: $e';
    }
  }

  /// Pushes then pulls with the named remote [remoteName].
  ///
  /// Returns null on success or a human-readable error string on failure.
  Future<String?> syncWith(String remoteName) async {
    final engine = await _buildSyncEngine(remoteName);
    if (engine is String) return engine;
    try {
      await (engine as SyncEngine).sync();
      await _loadCollections();
      notifyListeners();
      return null;
    } catch (e) {
      return 'Sync failed: $e';
    }
  }

  /// Builds a [SyncEngine] for the named remote, or returns an error string.
  Future<Object> _buildSyncEngine(String remoteName) async {
    final db = _database;
    final dbPath = _selectedDatabasePath;
    if (db == null || dbPath == null) return 'No database open.';

    final Map<String, RemoteConfig> remoteMap;
    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      remoteMap = config.remotes;
    } catch (e) {
      return 'Could not read remotes: $e';
    }

    final remote = remoteMap[remoteName];
    if (remote == null) return 'Remote "$remoteName" not found.';
    if (remote is! LocalRemoteConfig) {
      return 'Unsupported remote type: ${remote.type}';
    }

    final info = await db.store.storeInfo();
    final namespaces = await db.store.listNamespaces();
    final syncNamespaces = namespaces.where((n) => !n.startsWith(r'$')).toSet();

    return SyncEngine(
      store: db.store,
      cloudAdapter: LocalDirectoryAdapter(remote.path),
      localAdapter: _adapter,
      deviceId: info.deviceId,
      dbDir: info.dbDir,
      syncRoot: '',
      syncNamespaces: syncNamespaces,
    );
  }

  // ── Maintenance ──────────────────────────────────────────────────────────────

  /// Returns storage statistics for the open database, or null if not open.
  Future<StoreStats?> storeStats() async {
    try {
      return await _database?.store.stats();
    } catch (e) {
      return null;
    }
  }

  /// Returns identifying information about the open database, or null.
  Future<StoreInfo?> storeInfo() async {
    try {
      return await _database?.store.storeInfo();
    } catch (e) {
      return null;
    }
  }

  /// Flushes the active memtable to an SSTable on disk.
  Future<void> flushDatabase() async => _database?.store.flush();

  /// Runs full compaction until no further compaction is needed.
  Future<void> compactDatabase() async => _database?.store.compactAll();

  /// Verifies all documents in every collection by scanning and decoding them.
  ///
  /// Returns a count of documents checked and errors encountered. Errors do
  /// not throw — they are counted so the caller can show a summary.
  Future<({int checked, int errors})> verifyDatabase() async {
    final db = _database;
    if (db == null) return (checked: 0, errors: 0);

    int checked = 0;
    int errors = 0;

    try {
      final namespaces = await db.store.listNamespaces();
      for (final name in namespaces) {
        if (name.startsWith(r'$')) continue;
        try {
          await for (final _ in db.rawCollection(name).all().stream()) {
            checked++;
          }
        } catch (e) {
          errors++;
          debugPrint('Verify error in $name: $e');
        }
      }
    } catch (e) {
      debugPrint('Verify failed: $e');
    }

    return (checked: checked, errors: errors);
  }

  /// Rotates the device identity to a fresh random 8-character hex ID.
  ///
  /// Reassigns the device ID in the engine metadata, then reopens the database
  /// to refresh all in-memory state. Returns null on success, or an error
  /// string on failure.
  Future<String?> rotateDeviceId() async {
    final db = _database;
    if (db == null) return 'No database open.';

    try {
      final rng = Random.secure();
      final newId = List.generate(
        4,
        (_) => rng.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      await db.store.reassignDeviceId(newId);
      await _reopenDatabase();
      return null;
    } catch (e) {
      return 'Failed to rotate device ID: $e';
    }
  }

  /// Closes and reopens the database with the current [_ftsIndexDefs].
  ///
  /// Used after FTS index changes to register the new definitions with
  /// [FtsManager] at open time. Temporarily nulls [_selectedCollection] so the
  /// [ChangeNotifierProxyProvider] discards the stale [CollectionProvider]
  /// (which holds a reference to the old [KmdbDatabase] instance) and creates
  /// a fresh one with the new database.
  Future<void> _reopenDatabase() async {
    final path = _selectedDatabasePath;
    if (path == null) return;

    final savedCollection = _selectedCollection;
    _isOpening = true;
    _selectedCollection = null;
    _selectedDocument = null;
    notifyListeners();

    try {
      await _closeCurrentDatabase();

      // Re-activate the macOS security-scoped bookmark after close, mirroring
      // the pattern in selectDatabase(). stopAccessing is called by
      // _closeCurrentDatabase, so the sandbox scope must be re-entered before
      // KmdbDatabase.open attempts to acquire the LOCK file.
      final bookmark = _bookmarks[path];
      if (bookmark != null && Platform.isMacOS) {
        try {
          await _channel.invokeMethod('startAccessing', {'bookmark': bookmark});
        } catch (e) {
          debugPrint('Error restarting access for bookmark: $e');
        }
      }

      _database = await KmdbDatabase.open(
        path: path,
        adapter: _adapter,
        ftsIndexes: _ftsIndexDefs,
        indexes: _secondaryIndexDefs,
      );
      await _loadCollections();
      _selectedCollection = savedCollection;
    } catch (e, stack) {
      debugPrint('Error reopening database at $path: $e\n$stack');
      _loadError = e.toString();
    } finally {
      _isOpening = false;
      notifyListeners();
    }
  }

  /// Loads [FtsIndexDefinition]s from [KmdbConfig] for the database at [dbPath].
  ///
  /// Returns an empty list on any error (e.g. config file not yet created).
  Future<List<FtsIndexDefinition>> _loadFtsDefsFromConfig(String dbPath) async {
    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      return config.ftsIndexes
          .map(
            (r) => FtsIndexDefinition(
              collection: r.collection,
              field: r.field,
              k1: r.k1,
              b: r.b,
              stopWords: r.stopWords,
              lazy: true,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('Could not load FTS indexes from config: $e');
      return const [];
    }
  }

  /// Loads [IndexDefinition]s from [KmdbConfig] for the database at [dbPath].
  ///
  /// Returns an empty list on any error (e.g. config file not yet created).
  Future<List<IndexDefinition>> _loadSecondaryIndexDefsFromConfig(
    String dbPath,
  ) async {
    try {
      final config = await KmdbConfig.forDatabase(dbPath);
      return config.indexes
          .map((r) => IndexDefinition(r.collection, r.path))
          .toList();
    } catch (e) {
      debugPrint('Could not load secondary indexes from config: $e');
      return const [];
    }
  }

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
