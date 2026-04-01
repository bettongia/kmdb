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

/// Describes an index whose build was interrupted by an unclean shutdown.
///
/// Passed to [KmdbDatabase.open]'s `onIndexRebuildRequired` callback when
/// the dirty-open flag indicates a previous session ended abruptly while an
/// index was in the `building` state (spec §16 "Interrupted Build Recovery").
final class IndexRebuildEvent {
  const IndexRebuildEvent({
    required this.namespace,
    required this.path,
  });

  /// The collection namespace the index belongs to.
  final String namespace;

  /// The dot-notation field path the index was being built on.
  final String path;

  @override
  String toString() =>
      'IndexRebuildEvent(namespace: $namespace, path: $path)';
}
