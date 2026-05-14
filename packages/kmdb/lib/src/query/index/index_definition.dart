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

import '../exceptions.dart';
import '../filter/field_path.dart';

/// Declares a secondary index on a document field within a collection.
///
/// Index definitions are registered at [KmdbDatabase.open] time. No index
/// entries are written at open time — the index is built lazily on first query
/// (spec §16 "Lazy Index Build"). A declared index that is never queried incurs
/// zero storage overhead.
///
/// ## Path syntax
///
/// The [path] supports the same JSONPath subset as [FieldPath] (spec §13):
///
/// | Syntax              | Example               | Resolves to                  |
/// | ------------------- | --------------------- | ---------------------------- |
/// | Identifier          | `city`                | Top-level field              |
/// | Dot child           | `address.city`        | Nested object field          |
/// | Optional root sigil | `$.address.city`      | Same as `address.city`       |
/// | Array wildcard      | `tags[*]` or `tags[]` | Fan-out — one entry per elem |
/// | Positional index    | `tags[0]`             | Element at index 0           |
/// | Negative index      | `tags[-1]`            | Last element                 |
/// | Deep nested         | `meta.stats.views`    | Deeply nested field          |
///
/// ### Normalisation
///
/// The path is normalised at construction time: `$.address.city` is stored and
/// used identically to `address.city`, and `[*]` is rewritten to `[]`.
/// Normalisation is applied before the `indexNamespace` is computed, so the
/// storage key is always derived from the canonical path.
///
/// Note: `$`-prefixed index paths were never previously documented or accepted
/// as valid input, so no existing database can contain a `$`-prefixed index
/// namespace. Normalisation is purely additive — there is no migration needed.
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/db',
///   indexes: [
///     IndexDefinition('contacts', 'address.city'),
///     IndexDefinition('contacts', r'$.address.city'), // same index
///     IndexDefinition('contacts', 'tags[]'),
///   ],
/// );
/// ```
final class IndexDefinition {
  /// Creates an [IndexDefinition] for [path] in [namespace].
  ///
  /// The [path] is normalised: a leading `$.` prefix is stripped and `[*]` is
  /// rewritten to `[]`, so `$.address.city` and `address.city` refer to the
  /// same index.
  ///
  /// Throws [ArgumentError] if [path] is a bare `$` (no child path).
  ///
  /// Throws [ReservedIndexPathException] if [path] starts with `_` after
  /// normalisation, because `_`-prefixed fields are system-managed and not
  /// user-queryable.
  IndexDefinition(this.namespace, String path)
    : path = FieldPath.normalisePath(path) {
    if (this.path.startsWith('_')) {
      throw ReservedIndexPathException(namespace, this.path);
    }
    // Also reject a bare "$" path — normalisePath() already throws for this,
    // but we guard here explicitly for clarity. The check above follows the
    // same pattern used for "_"-prefixed paths.
    if (this.path.startsWith(r'$')) {
      throw ArgumentError.value(
        path,
        'path',
        "Index path must not start with '\$' after normalisation. "
            "Use a bare field path such as 'address.city'.",
      );
    }
  }

  /// The storage-layer namespace identifier for the collection this index
  /// belongs to. This matches the `name` parameter passed to
  /// [KmdbDatabase.collection] when the collection was created.
  final String namespace;

  /// The normalised dot-notation field path to index.
  ///
  /// Leading `$.` prefixes and `[*]` wildcards are rewritten to their
  /// canonical forms at construction time.
  final String path;

  /// The system namespace where index entries are stored.
  ///
  /// Format: `$index:{namespace}:{path}` where `{path}` is the normalised
  /// path. Because normalisation runs at construction time, this namespace is
  /// always derived from the canonical path — `$.address.city` and
  /// `address.city` produce the same `indexNamespace`.
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
