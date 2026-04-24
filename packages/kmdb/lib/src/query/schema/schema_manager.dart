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
import 'dart:typed_data';

import 'package:kmdb_schema/schema.dart';

import '../../engine/kvstore/meta_store.dart';
import '../collection_schema.dart';
import '../exceptions.dart';
import '../write_validator.dart';

/// Manages collection schema registration, persistence, and validation.
///
/// [SchemaManager] is the bridge between the caller-facing [CollectionSchema]
/// objects registered at [KmdbDatabase.open] time and the runtime validation
/// gate in [KmdbCollection._writeDocument].
///
/// ## Lifecycle
///
/// 1. Instantiated during [KmdbDatabase.open].
/// 2. [load] reads any schemas already persisted in `$meta` (e.g. synced from
///    another device) for collections that were *not* explicitly provided by the
///    caller.
/// 3. [register] writes caller-supplied schemas to `$meta` and caches their
///    parsed [SchemaRule] trees in memory.
/// 4. [validate] is called by [KmdbCollection._writeDocument] for every write
///    and throws [SchemaValidationException] on violation.
///
/// ## Version handling
///
/// Each persisted schema carries a [kSchemaModelVersion] integer in its payload.
/// If a loaded schema has a version higher than [kSchemaModelVersion], the local
/// KMDB build does not understand it. In that case [onSchemaVersionMismatch] is
/// called and schema enforcement is disabled for that collection so writes are
/// not incorrectly blocked.
///
/// ## Persistence format
///
/// Schemas are stored as UTF-8 JSON under the symbolic name
/// `schema:{collection}` in `$meta`. The registry of known collection names is
/// stored under `schema:__registry__`.
///
/// Implements [WriteValidator] so it can be added to the formal write pipeline
/// and called uniformly by [KmdbCollection] without special-casing.
final class SchemaManager implements WriteValidator {
  /// Creates a [SchemaManager].
  ///
  /// [onSchemaVersionMismatch] is called when a persisted schema has a
  /// [kSchemaModelVersion] higher than [kSchemaModelVersion], indicating that
  /// this KMDB build cannot interpret the schema. Enforcement is disabled for
  /// the affected collection.
  SchemaManager({this.onSchemaVersionMismatch});

  /// The KMDB schema model version supported by this build.
  ///
  /// Increment this constant when new JSON Schema keywords are added to the
  /// supported subset. Schemas authored with a version ≤ this value are
  /// guaranteed to be interpreted correctly.
  static const int kSchemaModelVersion = 1;

  static const String _kRegistryName = 'schema:__registry__';

  /// Called when a stored schema has a [kSchemaModelVersion] this build
  /// doesn't support. Receives the collection name, stored version, and the
  /// maximum supported version.
  final void Function(
    String collection,
    int storedVersion,
    int supportedVersion,
  )?
  onSchemaVersionMismatch;

  // collection → parsed rule tree
  final Map<String, SchemaRule> _rules = {};

  // collection → raw JSON Schema map (retained for getSchema())
  final Map<String, Map<String, dynamic>> _rawSchemas = {};

  // ── Public API ──────────────────────────────────────────────────────────────

  /// The names of all collections that currently have a registered schema.
  ///
  /// The list is derived from the in-memory cache; call [load] first to ensure
  /// schemas persisted from other devices are included.
  ///
  /// Example:
  /// ```dart
  /// final collections = schemaManager.registeredCollections;
  /// // → ['contacts', 'tasks']
  /// ```
  List<String> get registeredCollections => _rules.keys.toList();

  /// Returns the raw JSON Schema map for [collection], or `null` if no schema
  /// is registered.
  ///
  /// The returned map is the original map that was passed to [CollectionSchema]
  /// (or loaded from `$meta`). It is suitable for display or re-serialisation
  /// without coupling the caller to the internal [SchemaRule] representation.
  ///
  /// Example:
  /// ```dart
  /// final schema = schemaManager.getSchema('contacts');
  /// if (schema != null) {
  ///   print(jsonEncode(schema));
  /// }
  /// ```
  Map<String, dynamic>? getSchema(String collection) => _rawSchemas[collection];

  /// Loads persisted schemas from [meta] for collections not already registered.
  ///
  /// Called once during [KmdbDatabase.open] after [register] has been called
  /// for caller-supplied schemas. Schemas whose collection is already registered
  /// (because the caller supplied one) are skipped — the caller's declaration
  /// wins.
  Future<void> load(MetaStore meta) async {
    final collections = await _loadRegistry(meta);
    for (final collection in collections) {
      if (_rules.containsKey(collection)) continue; // caller's schema wins
      final bytes = await meta.getRawByName('schema:$collection');
      if (bytes == null) continue;
      _loadFromBytes(collection, bytes);
    }
  }

  /// Parses [schema], persists it to [meta], and registers it for validation.
  ///
  /// Always writes to storage (LWW: the most recent open call on any device
  /// that supplies a schema wins). Adds the collection to the persistent
  /// registry so [load] can find it on future opens.
  Future<void> register(CollectionSchema schema, MetaStore meta) async {
    final rule = SchemaParser().parse(schema.jsonSchema);
    _rules[schema.collection] = rule;
    _rawSchemas[schema.collection] = schema.jsonSchema;

    final payload = jsonEncode({
      'schemaModelVersion': kSchemaModelVersion,
      'schema': schema.jsonSchema,
    });
    await meta.putRawByName(
      'schema:${schema.collection}',
      Uint8List.fromList(utf8.encode(payload)),
    );

    await _updateRegistry(meta, schema.collection);
  }

  /// Validates [doc] against the registered schema for [collection].
  ///
  /// No-op if no schema is registered for [collection]. Throws
  /// [SchemaValidationException] listing every violation found if the document
  /// does not conform.
  @override
  void validate(String collection, Map<String, dynamic> doc) {
    final rule = _rules[collection];
    if (rule == null) return;
    final violations = rule.validate(doc, '');
    if (violations.isNotEmpty) {
      throw SchemaValidationException(
        collection: collection,
        violations: violations,
      );
    }
  }

  /// Removes the schema for [collection] from both storage and the in-memory
  /// cache.
  ///
  /// After a successful call, writes to [collection] are no longer validated
  /// against any schema. Deregistering an unknown collection (one that was
  /// never registered) is a no-op — this method does not throw.
  ///
  /// Implementation steps:
  ///
  /// 1. Delete the `schema:{collection}` key from [meta].
  /// 2. Read the registry, remove [collection], and rewrite it.
  /// 3. Evict [collection] from the in-memory caches.
  ///
  /// Example:
  /// ```dart
  /// await schemaManager.deregister('contacts', meta);
  /// // Future writes to 'contacts' are no longer validated.
  /// ```
  Future<void> deregister(String collection, MetaStore meta) async {
    // Step 1: delete the per-collection schema key from storage.
    await meta.deleteRawByName('schema:$collection');

    // Step 2: rebuild the registry without the removed collection.
    final current = await _loadRegistry(meta);
    if (current.contains(collection)) {
      final updated = current.where((c) => c != collection).toList()..sort();
      await meta.putRawByName(
        _kRegistryName,
        Uint8List.fromList(utf8.encode(jsonEncode(updated))),
      );
    }

    // Step 3: evict from in-memory caches.
    _rules.remove(collection);
    _rawSchemas.remove(collection);
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  void _loadFromBytes(String collection, Uint8List bytes) {
    try {
      final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final version = payload['schemaModelVersion'] as int? ?? 0;
      if (version > kSchemaModelVersion) {
        onSchemaVersionMismatch?.call(collection, version, kSchemaModelVersion);
        return;
      }
      final schemaMap = payload['schema'] as Map<String, dynamic>;
      _rules[collection] = SchemaParser().parse(schemaMap);
      _rawSchemas[collection] = schemaMap;
    } catch (_) {
      // Corrupt or unreadable schema payload — skip silently.
    }
  }

  Future<List<String>> _loadRegistry(MetaStore meta) async {
    final bytes = await meta.getRawByName(_kRegistryName);
    if (bytes == null || bytes.isEmpty) return [];
    try {
      return List<String>.from(jsonDecode(utf8.decode(bytes)) as List);
    } catch (_) {
      return [];
    }
  }

  Future<void> _updateRegistry(MetaStore meta, String collection) async {
    final current = await _loadRegistry(meta);
    if (current.contains(collection)) return;
    final updated = [...current, collection]..sort();
    await meta.putRawByName(
      _kRegistryName,
      Uint8List.fromList(utf8.encode(jsonEncode(updated))),
    );
  }
}
