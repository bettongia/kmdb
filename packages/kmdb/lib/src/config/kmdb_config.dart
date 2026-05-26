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

import 'dart:convert';

import 'io_kmdb_config_store.dart';
import 'kmdb_config_store.dart';
import 'remote_config.dart';

/// A single secondary-index definition stored in the KMDB config.
///
/// Uses the user-facing term "collection" (rather than the library-internal
/// "namespace") so the config file speaks the user's language.
typedef IndexRecord = ({String collection, String path});

/// A single FTS index definition stored in the KMDB config.
///
/// Mirrors [FtsIndexDefinition] from the search layer but is stored as a plain
/// Dart record so that the config module has no dependency on internal search
/// types.
typedef FtsIndexRecord = ({
  String collection,
  String field,
  bool stopWords,
  double k1,
  double b,
});

/// An embedding model configuration stored in the KMDB config.
///
/// The model is referenced by its ONNX file path so that the caller can
/// validate that semantic search is available before opening the database.
///
/// ```json
/// "embeddingModel": { "type": "onnx", "modelPath": "/path/to/bge_small.onnx" }
/// ```
typedef EmbeddingModelConfig = ({String type, String modelPath});

/// Manages the per-database configuration stored at
/// `{dbDir}/local/config.json`.
///
/// The config file stores named sync remotes, secondary index definitions,
/// FTS index definitions, and the optional embedding model path.  All I/O
/// is delegated to a [KmdbConfigStore] so that [KmdbConfig] itself has no
/// `dart:io` dependency and can be used on any platform.
///
/// ## Forward compatibility
///
/// Unknown top-level JSON keys are preserved in an internal `_extra` map and
/// round-tripped back to disk verbatim.  This means older versions of a
/// client application will not silently discard configuration written by
/// newer versions.
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
///   ],
///   "ftsIndexes": [
///     { "collection": "docs", "field": "body", "stopWords": false,
///       "k1": 1.2, "b": 0.75 }
///   ]
/// }
/// ```
///
/// ## Usage
///
/// ```dart
/// // Native platforms — wires up IoKmdbConfigStore automatically:
/// final config = await KmdbConfig.forDatabase('/path/to/db');
/// config.addRemote('origin', LocalRemoteConfig(path: '/mnt/nas/kmdb'));
/// config.addIndex('contacts', 'address.city');
/// await config.save();
/// ```
final class KmdbConfig {
  /// Creates a [KmdbConfig] with an explicit [_store] and the supplied field
  /// values.
  KmdbConfig._({
    required this._store,
    required this._remotes,
    required this._indexes,
    required this._ftsIndexes,
    required this.embeddingModel,
    required this._extra,
  });

  /// Creates an empty [KmdbConfig] with no backing store.
  ///
  /// All collections — remotes, indexes, ftsIndexes — start empty and
  /// [embeddingModel] is `null`.
  ///
  /// Calling [save] on an instance created with this constructor will throw
  /// an [UnsupportedError] because there is no backing store to write to.
  /// Use [KmdbConfig.load] or [KmdbConfig.forDatabase] to obtain a config
  /// that can be persisted.
  KmdbConfig.empty()
    : _store = const _NoOpConfigStore(),
      _remotes = {},
      _indexes = [],
      _ftsIndexes = [],
      embeddingModel = null,
      _extra = {};

  /// Creates an empty [KmdbConfig] backed by [store].
  ///
  /// All collections — remotes, indexes, ftsIndexes — start empty and
  /// [embeddingModel] is `null`.  Calling [save] writes to [store].
  KmdbConfig.emptyWithStore(KmdbConfigStore store)
    : _store = store,
      _remotes = {},
      _indexes = [],
      _ftsIndexes = [],
      embeddingModel = null,
      _extra = {};

  // The backing I/O store — all persistence goes through this.
  final KmdbConfigStore _store;

  // Mutable backing collections — all public mutation goes through the
  // named add/remove methods so invariants are enforced centrally.
  final Map<String, RemoteConfig> _remotes;
  final List<IndexRecord> _indexes;
  final List<FtsIndexRecord> _ftsIndexes;

  // Unknown top-level keys from the last load, preserved for round-trip
  // forward-compatibility.  Keys in this map do not overlap with the
  // recognised keys (remotes, indexes, ftsIndexes, embeddingModel).
  final Map<String, dynamic> _extra;

  /// Returns an unmodifiable view of the remotes map, keyed by name.
  Map<String, RemoteConfig> get remotes => Map.unmodifiable(_remotes);

  /// Returns an unmodifiable view of all secondary index definitions.
  List<IndexRecord> get indexes => List.unmodifiable(_indexes);

  /// Returns an unmodifiable view of all FTS index definitions.
  List<FtsIndexRecord> get ftsIndexes => List.unmodifiable(_ftsIndexes);

  /// The configured embedding model, or `null` if none has been set.
  ///
  /// Required for semantic search (`--mode semantic` or `--mode auto` when a
  /// vector index is present).  Set via `embeddingModel` in `local/config.json`.
  EmbeddingModelConfig? embeddingModel;

  // ── Factories ──────────────────────────────────────────────────────────────

  /// Loads (or creates) a [KmdbConfig] from [store].
  ///
  /// If [store.read] returns `null` (file not present), an empty config is
  /// returned backed by [store].  If the file exists but contains corrupt JSON
  /// or an invalid structure, a [FormatException] is thrown with a descriptive
  /// message.
  ///
  /// After loading, the config object is bound to [store] and subsequent calls
  /// to [save] write back to the same store.
  static Future<KmdbConfig> load(KmdbConfigStore store) async {
    final raw = await store.read();
    if (raw == null) {
      return KmdbConfig.emptyWithStore(store);
    }
    return _parseJson(store, raw);
  }

  /// Convenience factory for native platforms.
  ///
  /// Creates an [IoKmdbConfigStore] for [dbDir] and delegates to [load].
  ///
  /// This is the one-liner for the common case:
  ///
  /// ```dart
  /// final config = await KmdbConfig.forDatabase('/path/to/db');
  /// ```
  ///
  /// **Not available on web.**  Web callers must construct a
  /// [KmdbConfigStore] and call [KmdbConfig.load] directly.
  static Future<KmdbConfig> forDatabase(String dbDir) =>
      load(IoKmdbConfigStore(dbDir: dbDir));

  /// Parses a [KmdbConfig] from a raw JSON string, bound to [store].
  ///
  /// Throws [FormatException] on invalid JSON or an invalid config structure.
  static KmdbConfig _parseJson(KmdbConfigStore store, String raw) {
    // Decode the JSON — surface parse errors rather than silently swallowing
    // them, so the caller knows something is wrong.
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Corrupt config.json: ${e.message}');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Corrupt config.json: expected a JSON object.',
      );
    }

    // ── Remotes ─────────────────────────────────────────────────────────────
    final remotesRaw = decoded['remotes'];
    final remotes = <String, RemoteConfig>{};
    if (remotesRaw != null) {
      if (remotesRaw is! Map<String, dynamic>) {
        throw const FormatException(
          "Corrupt config.json: 'remotes' must be a JSON object.",
        );
      }
      for (final entry in remotesRaw.entries) {
        final name = entry.key;
        final value = entry.value;
        if (value is! Map<String, dynamic>) {
          throw FormatException(
            "Corrupt config.json: remote '$name' must be a JSON object.",
          );
        }
        // FormatException from RemoteConfig.fromJson propagates directly.
        remotes[name] = RemoteConfig.fromJson(value);
      }
    }

    // ── Secondary indexes ────────────────────────────────────────────────────
    final indexesRaw = decoded['indexes'];
    final indexes = <IndexRecord>[];
    if (indexesRaw != null) {
      if (indexesRaw is! List) {
        throw const FormatException(
          "Corrupt config.json: 'indexes' must be a JSON array.",
        );
      }
      for (var i = 0; i < indexesRaw.length; i++) {
        final entry = indexesRaw[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json: indexes[$i] must be a JSON object.',
          );
        }
        final collection = entry['collection'];
        final path = entry['path'];
        if (collection is! String || collection.isEmpty) {
          throw FormatException(
            "Corrupt config.json: indexes[$i] missing required string field "
            "'collection'.",
          );
        }
        if (path is! String || path.isEmpty) {
          throw FormatException(
            "Corrupt config.json: indexes[$i] missing required string field "
            "'path'.",
          );
        }
        indexes.add((collection: collection, path: path));
      }
    }

    // ── FTS indexes ──────────────────────────────────────────────────────────
    final ftsIndexesRaw = decoded['ftsIndexes'];
    final ftsIndexes = <FtsIndexRecord>[];
    if (ftsIndexesRaw != null) {
      if (ftsIndexesRaw is! List) {
        throw const FormatException(
          "Corrupt config.json: 'ftsIndexes' must be a JSON array.",
        );
      }
      for (var i = 0; i < ftsIndexesRaw.length; i++) {
        final entry = ftsIndexesRaw[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException(
            'Corrupt config.json: ftsIndexes[$i] must be a JSON object.',
          );
        }
        final collection = entry['collection'];
        final field = entry['field'];
        if (collection is! String || collection.isEmpty) {
          throw FormatException(
            "Corrupt config.json: ftsIndexes[$i] missing required string "
            "field 'collection'.",
          );
        }
        if (field is! String || field.isEmpty) {
          throw FormatException(
            "Corrupt config.json: ftsIndexes[$i] missing required string "
            "field 'field'.",
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

    // ── Embedding model ──────────────────────────────────────────────────────
    EmbeddingModelConfig? embeddingModel;
    final emRaw = decoded['embeddingModel'];
    if (emRaw != null) {
      if (emRaw is! Map<String, dynamic>) {
        throw const FormatException(
          "Corrupt config.json: 'embeddingModel' must be a JSON object.",
        );
      }
      final type = emRaw['type'];
      final modelPath = emRaw['modelPath'];
      if (type is! String || type.isEmpty) {
        throw const FormatException(
          "Corrupt config.json: 'embeddingModel.type' must be a non-empty "
          'string.',
        );
      }
      if (modelPath is! String || modelPath.isEmpty) {
        throw const FormatException(
          "Corrupt config.json: 'embeddingModel.modelPath' must be a "
          'non-empty string.',
        );
      }
      embeddingModel = (type: type, modelPath: modelPath);
    }

    // ── Unknown keys (forward compatibility) ─────────────────────────────────
    // Capture any keys not recognised by this version of the code so they are
    // preserved verbatim on the next [save], preventing data loss when the
    // config was written by a newer client.
    const knownKeys = {'remotes', 'indexes', 'ftsIndexes', 'embeddingModel'};
    final extra = <String, dynamic>{
      for (final entry in decoded.entries)
        if (!knownKeys.contains(entry.key)) entry.key: entry.value,
    };

    return KmdbConfig._(
      store: store,
      remotes: remotes,
      indexes: indexes,
      ftsIndexes: ftsIndexes,
      embeddingModel: embeddingModel,
      extra: extra,
    );
  }

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Adds a remote under [name].
  ///
  /// Throws [ArgumentError] if a remote named [name] already exists and
  /// [force] is `false` (the default).  Pass `force: true` to overwrite.
  void addRemote(String name, RemoteConfig remote, {bool force = false}) {
    if (_remotes.containsKey(name) && !force) {
      throw ArgumentError(
        "A remote named '$name' already exists.  "
        'Use force: true to overwrite.',
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

  // ── Secondary index mutations ──────────────────────────────────────────────

  /// Adds a secondary index definition for [path] on [collection].
  ///
  /// Throws [ArgumentError] if an identical `(collection, path)` pair already
  /// exists in the config.  Use [removeIndex] first if you want to re-add it.
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
  ///
  /// Returns an empty list when no FTS indexes are configured for the
  /// collection.
  List<FtsIndexRecord> ftsIndexesForCollection(String collection) =>
      _ftsIndexes.where((r) => r.collection == collection).toList();

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Serialises this config to a JSON string.
  ///
  /// The output is pretty-printed with two-space indentation and preserves any
  /// unknown top-level keys that were present when the config was last loaded
  /// (see the forward-compatibility note in the class documentation).
  String toJson() {
    // Start with the preserved unknown keys so that known keys always appear
    // after them (predictable output ordering puts the well-known sections
    // first via the spread below).
    final payload = <String, Object?>{
      ..._extra,
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
      if (embeddingModel != null)
        'embeddingModel': {
          'type': embeddingModel!.type,
          'modelPath': embeddingModel!.modelPath,
        },
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Persists this config to the backing [KmdbConfigStore].
  ///
  /// Equivalent to `store.write(toJson())`.
  Future<void> save() => _store.write(toJson());

  // ── Static path helpers ────────────────────────────────────────────────────

  /// Returns the `local/` subdirectory path for [dbDir].
  ///
  /// This is a pure path calculation — no I/O is performed.
  static String localDir(String dbDir) => '$dbDir/local';

  /// Returns the full config file path for [dbDir].
  ///
  /// This is a pure path calculation — no I/O is performed.
  static String configPath(String dbDir) => '$dbDir/local/config.json';
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// A [KmdbConfigStore] that always reports no content and throws on write.
///
/// Used by [KmdbConfig.empty] when no backing store is provided.  Calling
/// [save] on such a config will throw [UnsupportedError], which is the
/// intended signal that the caller should use [KmdbConfig.forDatabase] or
/// [KmdbConfig.load] instead.
final class _NoOpConfigStore implements KmdbConfigStore {
  const _NoOpConfigStore();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String json) => throw UnsupportedError(
    'KmdbConfig.empty() has no backing store.  '
    'Use KmdbConfig.forDatabase() or KmdbConfig.load(store) to obtain '
    'a config that can be persisted.',
  );
}
