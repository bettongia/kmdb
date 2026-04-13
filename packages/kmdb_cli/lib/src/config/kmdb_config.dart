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
import 'dart:math' as math;

import 'remote_config.dart';

/// A single secondary-index definition stored in the CLI config.
///
/// Uses the user-facing term "collection" (rather than the library-internal
/// "namespace") so the config file speaks the user's language.
typedef IndexRecord = ({String collection, String path});

/// A single FTS index definition stored in the CLI config.
///
/// Mirrors [FtsIndexDefinition] but is stored as a plain Dart record so the
/// CLI config module has no dependency on the `kmdb` library.
typedef FtsIndexRecord = ({
  String collection,
  String field,
  bool stopWords,
  double k1,
  double b,
});

/// Manages the per-database CLI configuration file at
/// `{dbDir}/local/config.json`.
///
/// The config file stores named sync remotes and secondary index definitions.
/// This class provides atomic read and write operations, lazy directory
/// creation, and a clean API for adding/removing both.
///
/// ## File format
///
/// ```json
/// {
///   "remotes": {
///     "origin": {
///       "type": "local",
///       "path": "/Volumes/NAS/myapp-sync"
///     }
///   },
///   "indexes": [
///     { "collection": "contacts", "path": "address.city" },
///     { "collection": "contacts", "path": "tags[]" }
///   ]
/// }
/// ```
///
/// ## Usage
///
/// ```dart
/// final config = await KmdbConfig.load('/path/to/db');
/// config.addRemote('origin', LocalRemoteConfig(path: '/mnt/nas/kmdb'));
/// config.addIndex('contacts', 'address.city');
/// await config.save('/path/to/db');
/// ```
final class KmdbConfig {
  /// Creates a [KmdbConfig] with the given mutable [remotes] map, [indexes]
  /// list, and [ftsIndexes] list.
  KmdbConfig._({
    required Map<String, RemoteConfig> remotes,
    required List<IndexRecord> indexes,
    required List<FtsIndexRecord> ftsIndexes,
  }) : _remotes = remotes,
       _indexes = indexes,
       _ftsIndexes = ftsIndexes;

  /// An empty config with no remotes, indexes, or FTS indexes.
  KmdbConfig.empty() : _remotes = {}, _indexes = [], _ftsIndexes = [];

  // Mutable backing map.  All public mutation goes through [addRemote] /
  // [removeRemote] so invariants are enforced centrally.
  final Map<String, RemoteConfig> _remotes;

  // Mutable backing list for secondary index definitions.
  final List<IndexRecord> _indexes;

  // Mutable backing list for FTS index definitions.
  final List<FtsIndexRecord> _ftsIndexes;

  /// Returns an unmodifiable view of the remotes map, keyed by name.
  Map<String, RemoteConfig> get remotes => Map.unmodifiable(_remotes);

  /// Returns an unmodifiable view of all secondary index definitions.
  List<IndexRecord> get indexes => List.unmodifiable(_indexes);

  /// Returns an unmodifiable view of all FTS index definitions.
  List<FtsIndexRecord> get ftsIndexes => List.unmodifiable(_ftsIndexes);

  // ── Factory ────────────────────────────────────────────────────────────────

  /// Loads (or creates) the config from `{dbDir}/local/config.json`.
  ///
  /// If the file does not exist, returns an empty [KmdbConfig]. If the file
  /// exists but is corrupt (invalid JSON or invalid remote type), throws a
  /// [FormatException] with a descriptive message rather than silently
  /// returning empty config.
  ///
  /// The [dbDir] parameter is the local database root directory (the one that
  /// contains `LOCK`, `MANIFEST-*`, etc.).
  static Future<KmdbConfig> load(String dbDir) async {
    final file = io.File(_configPath(dbDir));
    if (!await file.exists()) {
      return KmdbConfig.empty();
    }

    final String raw;
    try {
      raw = await file.readAsString();
    } on io.FileSystemException catch (e) {
      throw FormatException(
        'Failed to read config file "${file.path}": ${e.message}',
      );
    }

    // Decode the JSON — surface parse errors rather than silently returning
    // an empty config so the user knows something is wrong.
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException(
        'Corrupt config.json at "${file.path}": ${e.message}',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Corrupt config.json at "${file.path}": expected a JSON object.',
      );
    }

    // Parse remotes section.
    final remotesRaw = decoded['remotes'];
    final remotes = <String, RemoteConfig>{};
    if (remotesRaw != null) {
      if (remotesRaw is! Map<String, dynamic>) {
        throw FormatException(
          'Corrupt config.json at "${file.path}": '
          "'remotes' must be a JSON object.",
        );
      }
      for (final entry in remotesRaw.entries) {
        final name = entry.key;
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "remote '$name' must be a JSON object.",
          );
        }
        // FormatException from RemoteConfig.fromJson propagates directly.
        remotes[name] = RemoteConfig.fromJson(value);
      }
    }

    // Parse indexes section — missing key → empty list (backwards compatible).
    final indexesRaw = decoded['indexes'];
    final indexes = <IndexRecord>[];
    if (indexesRaw != null) {
      if (indexesRaw is! List) {
        throw FormatException(
          'Corrupt config.json at "${file.path}": '
          "'indexes' must be a JSON array.",
        );
      }
      for (var i = 0; i < indexesRaw.length; i++) {
        final entry = indexesRaw[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "indexes[$i] must be a JSON object.",
          );
        }
        final collection = entry['collection'];
        final path = entry['path'];
        if (collection is! String || collection.isEmpty) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "indexes[$i] missing required string field 'collection'.",
          );
        }
        if (path is! String || path.isEmpty) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "indexes[$i] missing required string field 'path'.",
          );
        }
        indexes.add((collection: collection, path: path));
      }
    }

    // Parse ftsIndexes section — missing key → empty list (backwards compatible).
    final ftsIndexesRaw = decoded['ftsIndexes'];
    final ftsIndexes = <FtsIndexRecord>[];
    if (ftsIndexesRaw != null) {
      if (ftsIndexesRaw is! List) {
        throw FormatException(
          'Corrupt config.json at "${file.path}": '
          "'ftsIndexes' must be a JSON array.",
        );
      }
      for (var i = 0; i < ftsIndexesRaw.length; i++) {
        final entry = ftsIndexesRaw[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "ftsIndexes[$i] must be a JSON object.",
          );
        }
        final collection = entry['collection'];
        final field = entry['field'];
        if (collection is! String || collection.isEmpty) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "ftsIndexes[$i] missing required string field 'collection'.",
          );
        }
        if (field is! String || field.isEmpty) {
          throw FormatException(
            'Corrupt config.json at "${file.path}": '
            "ftsIndexes[$i] missing required string field 'field'.",
          );
        }
        ftsIndexes.add((
          collection: collection,
          field: field,
          stopWords: entry['stopWords'] as bool? ?? false,
          k1: (entry['k1'] as num?)?.toDouble() ?? 1.2,
          b: (entry['b'] as num?)?.toDouble() ?? 0.75,
        ));
      }
    }

    return KmdbConfig._(remotes: remotes, indexes: indexes, ftsIndexes: ftsIndexes);
  }

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Adds a remote under [name].
  ///
  /// Throws [ArgumentError] if a remote named [name] already exists and
  /// [force] is `false` (the default). Pass `force: true` to overwrite.
  void addRemote(String name, RemoteConfig remote, {bool force = false}) {
    if (_remotes.containsKey(name) && !force) {
      throw ArgumentError(
        "A remote named '$name' already exists. "
        'Use --force to overwrite.',
      );
    }
    _remotes[name] = remote;
  }

  /// Removes the remote named [name].
  ///
  /// Throws [ArgumentError] if no remote with that name exists.
  void removeRemote(String name) {
    if (!_remotes.containsKey(name)) {
      throw ArgumentError("No remote named '$name' found.");
    }
    _remotes.remove(name);
  }

  // ── Index mutations ────────────────────────────────────────────────────────

  /// Adds an index definition for [path] on [collection].
  ///
  /// Throws [ArgumentError] if an identical `(collection, path)` pair already
  /// exists in the config. Use [removeIndex] first if you want to re-add it.
  void addIndex(String collection, String path) {
    if (_indexes.any((r) => r.collection == collection && r.path == path)) {
      throw ArgumentError(
        "An index on '$collection.$path' already exists in the config.",
      );
    }
    _indexes.add((collection: collection, path: path));
  }

  /// Removes the index definition for [path] on [collection].
  ///
  /// Throws [ArgumentError] if no matching definition is found.
  void removeIndex(String collection, String path) {
    final idx = _indexes.indexWhere(
      (r) => r.collection == collection && r.path == path,
    );
    if (idx == -1) {
      throw ArgumentError(
        "No index on '$collection.$path' found in the config.",
      );
    }
    _indexes.removeAt(idx);
  }

  /// Returns all secondary index definitions for [collection].
  ///
  /// Returns an empty list when the collection has no configured indexes.
  List<IndexRecord> indexesForCollection(String collection) =>
      _indexes.where((r) => r.collection == collection).toList();

  // ── FTS index mutations ────────────────────────────────────────────────────

  /// Adds an FTS index definition for [field] on [collection].
  ///
  /// Throws [ArgumentError] if an identical `(collection, field)` pair already
  /// exists in the config.
  void addFtsIndex(
    String collection,
    String field, {
    bool stopWords = false,
    double k1 = 1.2,
    double b = 0.75,
  }) {
    if (_ftsIndexes.any(
      (r) => r.collection == collection && r.field == field,
    )) {
      throw ArgumentError(
        "An FTS index on '$collection.$field' already exists in the config.",
      );
    }
    _ftsIndexes.add((
      collection: collection,
      field: field,
      stopWords: stopWords,
      k1: k1,
      b: b,
    ));
  }

  /// Removes the FTS index definition for [field] on [collection].
  ///
  /// Throws [ArgumentError] if no matching definition is found.
  void removeFtsIndex(String collection, String field) {
    final idx = _ftsIndexes.indexWhere(
      (r) => r.collection == collection && r.field == field,
    );
    if (idx == -1) {
      throw ArgumentError(
        "No FTS index on '$collection.$field' found in the config.",
      );
    }
    _ftsIndexes.removeAt(idx);
  }

  /// Returns all FTS index definitions for [collection].
  List<FtsIndexRecord> ftsIndexesForCollection(String collection) =>
      _ftsIndexes.where((r) => r.collection == collection).toList();

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Atomically writes the config to `{dbDir}/local/config.json`.
  ///
  /// Creates the `{dbDir}/local/` directory lazily on first write. Uses a
  /// write-to-temp-then-rename strategy so the file is never partially written.
  Future<void> save(String dbDir) async {
    final localDir = io.Directory(_localDir(dbDir));
    if (!await localDir.exists()) {
      await localDir.create(recursive: true);
    }

    final configFile = io.File(_configPath(dbDir));

    // Build the JSON payload.
    final payload = {
      'remotes': {
        for (final entry in _remotes.entries) entry.key: entry.value.toJson(),
      },
      'indexes': [
        for (final idx in _indexes)
          {'collection': idx.collection, 'path': idx.path},
      ],
      'ftsIndexes': [
        for (final idx in _ftsIndexes)
          {
            'collection': idx.collection,
            'field': idx.field,
            'stopWords': idx.stopWords,
            'k1': idx.k1,
            'b': idx.b,
          },
      ],
    };
    final content = const JsonEncoder.withIndent('  ').convert(payload);

    // Write-to-temp-then-rename for atomicity: the file is either fully
    // written or not present — never half-written.
    final tmpPath = '${configFile.path}.tmp.${_randomHex()}';
    final tmpFile = io.File(tmpPath);
    try {
      await tmpFile.writeAsString(content, flush: true);
      await tmpFile.rename(configFile.path);
    } catch (_) {
      // Best-effort cleanup of the temp file if the rename or write fails.
      try {
        await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  // ── Static helpers ─────────────────────────────────────────────────────────

  /// The `local/` subdirectory path for [dbDir].
  static String localDir(String dbDir) => '$dbDir/local';

  /// The full config file path for [dbDir].
  static String configPath(String dbDir) => '$dbDir/local/config.json';

  // ── Private helpers ────────────────────────────────────────────────────────

  static String _localDir(String dbDir) => localDir(dbDir);

  static String _configPath(String dbDir) => configPath(dbDir);

  /// Returns a short random hex string for temporary file naming.
  static String _randomHex() {
    final r = math.Random();
    return r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0');
  }
}
