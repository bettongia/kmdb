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

/// Thin bridge between a typed Dart model and KMDB storage.
///
/// [KmdbCodec] is the only piece of serialization logic that application code
/// provides. Implementors delegate to generated code (`freezed`,
/// `json_serializable`, or hand-written converters).
///
/// ## Reserved field prefix
///
/// The `_` prefix is reserved for KMDB system-managed fields. The most
/// important is `_id`, which holds the document's UUIDv7 key.
///
/// - **`encode()`** must **not** include any top-level key starting with `_`.
///   The framework validates this contract before every write and throws
///   [ReservedFieldException] if violated.
/// - **`decode()`** will receive the map with `_id` pre-injected by the
///   framework. Implementations should read `json['_id']` to reconstruct the
///   typed model's key field.
/// - **`withKey()`** stamps the system key onto the typed model so that
///   [KmdbCollection.insert] can return the document with its assigned `_id`.
///
/// ## Example
///
/// ```dart
/// class TaskCodec implements KmdbCodec<Task> {
///   @override
///   String keyOf(Task value) => value.id;
///
///   @override
///   Task withKey(Task value, String key) => Task(
///         id: key,
///         title: value.title,
///         done: value.done,
///       );
///
///   // Do NOT include 'id' or any '_'-prefixed key here.
///   @override
///   Map<String, dynamic> encode(Task value) => {
///     'title': value.title,
///     'done': value.done,
///   };
///
///   // The framework injects '_id' into the map before calling decode().
///   @override
///   Task decode(Map<String, dynamic> json) => Task(
///     id: json['_id'] as String,
///     title: json['title'] as String,
///     done: json['done'] as bool? ?? false,
///   );
/// }
/// ```
///
/// KMDB applies CBOR encoding and optional compression on top of the
/// [Map<String, dynamic>] produced by [encode] — the codec itself deals only
/// with JSON-compatible maps.
abstract interface class KmdbCodec<T> {
  /// Returns the document's stable, immutable key.
  ///
  /// Must not change after a document is written. KMDB uses this key to
  /// identify the document in the LSM store and in secondary indexes.
  ///
  /// The key must be a 32-character lowercase hex string (a UUIDv7 binary
  /// key encoded as hex). KMDB enforces UUIDv7 format validation (version 7,
  /// variant 2) at the storage boundary.
  String keyOf(T value);

  /// Returns a new instance of [value] with [key] assigned to its identifier
  /// field.
  ///
  /// Called by [KmdbCollection.insert] after generating a new system key for
  /// a document. Implementations usually use a `copyWith` method.
  T withKey(T value, String key);

  /// Encodes [value] to a JSON-compatible map.
  ///
  /// **Must not** include any top-level key starting with `_`. The framework
  /// validates this before every write and throws [ReservedFieldException] if
  /// any `_`-prefixed key is found. The `_id` field in particular must not be
  /// emitted here — it is injected automatically by the framework on the read
  /// path.
  ///
  /// CBOR encoding and compression are applied by the Query Layer on top of
  /// this map — the codec itself must not produce pre-encoded bytes.
  Map<String, dynamic> encode(T value);

  /// Decodes a JSON-compatible map to a typed [T] value.
  ///
  /// Called by the Query Layer after CBOR decoding. The map will contain
  /// `_id` (the document's UUIDv7 key) injected by the framework. Use
  /// `json['_id']` to reconstruct the typed model's key field.
  ///
  /// Throws [FormatException] or any application-specific exception if the
  /// map is invalid.
  T decode(Map<String, dynamic> json);
}
