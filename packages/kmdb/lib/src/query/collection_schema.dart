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

/// Declares an optional JSON Schema for a KMDB collection.
///
/// Passed to [KmdbDatabase.open] via the `schemas` parameter. When a schema
/// is registered for a collection, every document write to that collection is
/// validated against the schema before the [WriteBatch] is committed. Writes
/// that violate the schema throw [SchemaValidationException].
///
/// The schema is authored as a JSON Schema subset (spec §25). It is translated
/// internally to a Dart-native rule tree at open time — the JSON map is only
/// used for authoring and persistence.
///
/// Example:
/// ```dart
/// CollectionSchema(
///   collection: 'contacts',
///   jsonSchema: {
///     'required': ['name', 'email'],
///     'properties': {
///       'name': {'type': 'string', 'minLength': 1},
///       'email': {'type': 'string', 'format': 'email'},
///       'age':  {'type': 'integer', 'minimum': 0},
///     },
///     'additionalProperties': false,
///   },
/// )
/// ```
final class CollectionSchema {
  /// Creates a [CollectionSchema] for [collection] using [jsonSchema].
  ///
  /// [collection] must match the `name` passed to [KmdbDatabase.collection].
  /// [jsonSchema] must be a valid JSON Schema subset map (spec §25).
  const CollectionSchema({required this.collection, required this.jsonSchema});

  /// The collection namespace this schema applies to.
  ///
  /// Must match the `name` argument passed to [KmdbDatabase.collection].
  final String collection;

  /// The JSON Schema definition used to validate documents in this collection.
  ///
  /// See spec §25 for the supported keyword subset. Unknown keywords are
  /// silently ignored, allowing schemas written by a newer KMDB version to be
  /// partially interpreted by an older one.
  final Map<String, dynamic> jsonSchema;
}
