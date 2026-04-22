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
final class SchemaManager {
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

  // ── Public API ──────────────────────────────────────────────────────────────

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
