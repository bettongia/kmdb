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
/// `json_serializable`, or hand-written converters):
///
/// ```dart
/// class TaskCodec implements KmdbCodec<Task> {
///   @override
///   String keyOf(Task value) => value.id;
///
///   @override
///   Map<String, dynamic> encode(Task value) => value.toJson();
///
///   @override
///   Task decode(Map<String, dynamic> json) => Task.fromJson(json);
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
  /// key encoded as hex). Use [KeyGenerator] or `uuid` package to generate
  /// compliant keys.
  String keyOf(T value);

  /// Encodes [value] to a JSON-compatible map.
  ///
  /// CBOR encoding and compression are applied by the Query Layer on top of
  /// this map — the codec itself must not produce pre-encoded bytes.
  Map<String, dynamic> encode(T value);

  /// Decodes a JSON-compatible map to a typed [T] value.
  ///
  /// Called by the Query Layer after CBOR decoding. Throws [FormatException]
  /// or any application-specific exception if the map is invalid.
  T decode(Map<String, dynamic> json);
}
