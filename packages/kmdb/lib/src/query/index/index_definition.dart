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

import '../exceptions.dart';

/// Declares a secondary index on a document field within a collection.
///
/// Index definitions are registered at [KmdbDatabase.open] time. No index
/// entries are written at open time — the index is built lazily on first query
/// (spec §16 "Lazy Index Build"). A declared index that is never queried incurs
/// zero storage overhead.
///
/// ## Path syntax
///
/// The [path] follows the dot-notation field path rules from spec §16:
///
/// | Syntax | Resolves to |
/// | ------ | ----------- |
/// | `"city"` | Top-level field |
/// | `"address.city"` | Nested object field |
/// | `"tags[0]"` | Specific array element |
/// | `"tags[]"` | Array fan-out — one index entry per array element |
/// | `"meta.stats.views"` | Deeply nested field |
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/db',
///   indexes: [
///     IndexDefinition('contacts', 'address.city'),
///     IndexDefinition('contacts', 'tags[]'),
///   ],
/// );
/// ```
final class IndexDefinition {
  /// Creates an [IndexDefinition] for [path] in [namespace].
  ///
  /// Throws [ReservedIndexPathException] if [path] starts with `_`, because
  /// `_`-prefixed fields are system-managed and not user-queryable.
  IndexDefinition(this.namespace, this.path) {
    if (path.startsWith('_')) {
      throw ReservedIndexPathException(namespace, path);
    }
  }

  /// The storage-layer namespace identifier for the collection this index
  /// belongs to. This matches the `name` parameter passed to
  /// [KmdbDatabase.collection] when the collection was created.
  final String namespace;

  /// The dot-notation field path to index.
  final String path;

  /// The system namespace where index entries are stored.
  ///
  /// Format: `$index:{namespace}:{path}`.
  String get indexNamespace =>
      r'$index:'
      '$namespace:$path';

  @override
  String toString() => 'IndexDefinition($namespace, $path)';

  @override
  bool operator ==(Object other) =>
      other is IndexDefinition &&
      other.namespace == namespace &&
      other.path == path;

  @override
  int get hashCode => Object.hash(namespace, path);
}
