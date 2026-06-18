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

import 'package:betto_schema/betto_schema.dart' show SchemaViolation;

import '../engine/util/hlc.dart';

/// Thrown by [KmdbCollection] write methods when a document fails validation
/// against the collection's registered [CollectionSchema].
///
/// All violations found in a single write attempt are reported together in
/// [violations] so UI forms can surface every error at once rather than
/// one at a time.
///
/// [SchemaValidationException] is thrown synchronously before the
/// [WriteBatch] is committed, so no partial write occurs.
///
/// Example:
/// ```dart
/// try {
///   await contacts.insert(contact);
/// } on SchemaValidationException catch (e) {
///   for (final v in e.violations) {
///     print('${v.path}: ${v.message}');
///   }
/// }
/// ```
final class SchemaValidationException implements Exception {
  /// Creates a [SchemaValidationException] for [collection] with [violations].
  const SchemaValidationException({
    required this.collection,
    required this.violations,
  });

  /// The collection namespace whose schema was violated.
  final String collection;

  /// Every violation found during validation of the rejected document.
  final List<SchemaViolation> violations;

  @override
  String toString() =>
      'SchemaValidationException in "$collection": '
      '${violations.map((v) => v.toString()).join('; ')}';
}

/// Thrown by [KmdbCollection.insert] when a document with the same key already
/// exists in the collection.
final class DocumentAlreadyExistsException implements Exception {
  const DocumentAlreadyExistsException(this.key, this.namespace);

  /// The document key that caused the conflict.
  final String key;

  /// The collection namespace.
  final String namespace;

  @override
  String toString() =>
      'DocumentAlreadyExistsException: document "$key" already exists in '
      'namespace "$namespace"';
}

/// Thrown by [KmdbCollection.replace] when no document with the given key
/// exists in the collection.
final class DocumentNotFoundException implements Exception {
  const DocumentNotFoundException(this.key, this.namespace);

  /// The document key that was not found.
  final String key;

  /// The collection namespace.
  final String namespace;

  @override
  String toString() =>
      'DocumentNotFoundException: document "$key" not found in '
      'namespace "$namespace"';
}

/// Thrown when a query or collection operation requires a fresh secondary index
/// but the index is currently stale or building.
///
/// KMDB secondary indexes are rebuilt lazily in the background. Most callers
/// can tolerate a temporarily stale index because the query layer falls back to
/// a full namespace scan. [StaleIndexException] is thrown only when the caller
/// has explicitly requested strict index freshness via
/// [KmdbQuery.requireFreshIndex].
///
/// Example:
/// ```dart
/// try {
///   final results = await collection
///       .where(Field('city').equals('London'))
///       .requireFreshIndex()
///       .get();
/// } on StaleIndexException catch (e) {
///   // The 'city' index is rebuilding — retry after a short delay.
///   print(e);
/// }
/// ```
final class StaleIndexException implements Exception {
  const StaleIndexException({
    required this.namespace,
    required this.path,
    required this.status,
  });

  /// The collection namespace containing the stale index.
  final String namespace;

  /// The dot-notation field path the index covers.
  final String path;

  /// The current lifecycle status of the index (e.g. `'stale'` or
  /// `'building'`).
  final String status;

  @override
  String toString() =>
      'StaleIndexException: index on "$path" in namespace "$namespace" '
      'is $status — cannot serve query with requireFreshIndex()';
}

/// Thrown when [KmdbCollection] detects that the map returned by
/// [KmdbCodec.encode] contains one or more top-level keys whose names begin
/// with `_`.
///
/// The `_` prefix is reserved for system-managed fields (e.g. `_id`). User
/// codecs must not emit these keys — the framework injects them automatically
/// around every read and write.
///
/// [offendingKeys] lists every reserved-prefix key that was found so the
/// developer can fix their codec in a single iteration.
///
/// Example:
/// ```dart
/// try {
///   await collection.put(myDoc);
/// } on ReservedFieldException catch (e) {
///   // e.offendingKeys contains every offending field name.
///   print(e);
/// }
/// ```
final class ReservedFieldException implements Exception {
  /// Creates a [ReservedFieldException] reporting [offendingKeys].
  const ReservedFieldException(this.offendingKeys);

  /// The top-level field names that start with `_` and must not appear in the
  /// encoded map produced by [KmdbCodec.encode].
  final List<String> offendingKeys;

  @override
  String toString() =>
      'ReservedFieldException: codec.encode() must not return top-level keys '
      'starting with "_". Offending keys: '
      '${offendingKeys.map((k) => '"$k"').join(', ')}. '
      'The "_" prefix is reserved for KMDB system fields (e.g. "_id").';
}

/// Thrown when [KmdbDatabase.open] is called with an [IndexDefinition] whose
/// [IndexDefinition.path] begins with `_`.
///
/// Fields with the `_` prefix are system-managed (e.g. `_id`). Secondary
/// indexes may only be defined on user-owned field paths.
///
/// Example:
/// ```dart
/// // This will throw at open() time:
/// await KmdbDatabase.open(
///   path: '/db',
///   indexes: [IndexDefinition('users', '_id')],  // invalid
/// );
/// ```
final class ReservedIndexPathException implements Exception {
  /// Creates a [ReservedIndexPathException] for the given [namespace] and
  /// offending [path].
  const ReservedIndexPathException(this.namespace, this.path);

  /// The namespace of the invalid index definition.
  final String namespace;

  /// The path that starts with `_`.
  final String path;

  @override
  String toString() =>
      'ReservedIndexPathException: index path "$path" in namespace '
      '"$namespace" starts with "_", which is reserved for system fields. '
      'Only user-owned field paths may be indexed.';
}

/// Thrown by [KmdbCollection.promoteVersion] when the specified version entry
/// no longer exists in the `$ver:` namespace.
///
/// This occurs when:
/// - The version was trimmed by compaction (beyond the collection's
///   `maxVersions` count or `retentionDays` window).
/// - The `hlc` was not produced by a write to this collection (e.g. it is
///   a typo or belongs to a different collection).
/// - Versioning was disabled for this collection when the document was written.
///
/// Example:
/// ```dart
/// try {
///   await tasks.promoteVersion(docKey, hlc);
/// } on VersionNotFoundError catch (e) {
///   print('Version ${e.requestedHlc.toHex()} has been trimmed');
/// }
/// ```
final class VersionNotFoundError implements Exception {
  /// Creates a [VersionNotFoundError].
  const VersionNotFoundError({
    required this.docKey,
    required this.namespace,
    required this.requestedHlc,
  });

  /// The document key whose version was requested.
  final String docKey;

  /// The collection namespace.
  final String namespace;

  /// The HLC that was not found in the `$ver:` namespace.
  final Hlc requestedHlc;

  @override
  String toString() =>
      'VersionNotFoundError: version "$requestedHlc" for document '
      '"$docKey" in namespace "$namespace" not found. '
      'It may have been trimmed by compaction or versioning was disabled '
      'for this collection.';
}

/// Describes an index whose build was interrupted by an unclean shutdown.
///
/// Passed to [KmdbDatabase.open]'s `onIndexRebuildRequired` callback when
/// the dirty-open flag indicates a previous session ended abruptly while an
/// index was in the `building` state (spec §16 "Interrupted Build Recovery").
final class IndexRebuildEvent {
  const IndexRebuildEvent({required this.namespace, required this.path});

  /// The collection namespace the index belongs to.
  final String namespace;

  /// The dot-notation field path the index was being built on.
  final String path;

  @override
  String toString() => 'IndexRebuildEvent(namespace: $namespace, path: $path)';
}
