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

import 'kmdb_codec.dart';

/// A built-in pass-through codec for untyped `Map<String, dynamic>` documents.
///
/// [RawDocumentCodec] implements [KmdbCodec] with identity encode/decode
/// semantics. It is used by [KmdbDatabase.rawCollection] to provide access to
/// the full write pipeline (validation, index maintenance, FTS, vault ref
/// counts) without requiring a typed model.
///
/// The `_id` field is removed by [encode] (the document body must not contain
/// the key) and re-injected by [withKey]. [keyOf] reads `_id` from the map.
///
/// ## Example
///
/// ```dart
/// final col = db.collection(
///   name: 'contacts',
///   codec: const RawDocumentCodec(),
/// );
/// await col.insert({'name': 'Alice', 'email': 'alice@example.com'});
/// ```
///
/// Prefer [KmdbDatabase.rawCollection] over constructing this codec manually.
final class RawDocumentCodec implements KmdbCodec<Map<String, dynamic>> {
  /// Creates a [RawDocumentCodec].
  const RawDocumentCodec();

  /// Returns the `_id` field value from [value] as the document key.
  ///
  /// Throws [StateError] if the `_id` field is absent or not a [String].
  /// The `_id` field is always present when [withKey] has been called (i.e.
  /// on documents returned from a [KmdbCollection] read operation).
  @override
  String keyOf(Map<String, dynamic> value) {
    final id = value['_id'];
    if (id is! String) {
      throw StateError(
        'RawDocumentCodec.keyOf: document missing _id field or _id is not a String. '
        'Only call keyOf on documents returned from a KmdbCollection read.',
      );
    }
    return id;
  }

  /// Returns a copy of [value] with the `_id` field set to [key].
  @override
  Map<String, dynamic> withKey(Map<String, dynamic> value, String key) => {
    ...value,
    '_id': key,
  };

  /// Returns a copy of [value] with the `_id` field removed.
  ///
  /// The returned map is what is stored in the LSM — the `_id` is always
  /// the storage key and must not appear in the encoded body.
  @override
  Map<String, dynamic> encode(Map<String, dynamic> value) {
    final m = Map<String, dynamic>.of(value)..remove('_id');
    return m;
  }

  /// Returns [json] unchanged — the stored body is already the document map.
  @override
  Map<String, dynamic> decode(Map<String, dynamic> json) => json;
}
