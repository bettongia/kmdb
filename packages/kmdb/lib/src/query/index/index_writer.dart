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

import 'dart:convert';
import 'dart:typed_data';

import '../../encryption/encryption_provider.dart';
import '../../engine/kvstore/kv_store.dart';
import '../filter/field_path.dart';
import 'index_definition.dart';

/// Encodes secondary index entries into a [WriteBatch].
///
/// ## Storage layout
///
/// Index entries use a **namespace-per-value** scheme to stay within the
/// engine's 32-character hex key constraint. For each unique field value, a
/// dedicated system namespace is allocated:
///
/// ```
/// $$index:{ns}:{path}:{token}
/// ```
///
/// Within that namespace, each document that has the given field value is
/// stored with its 32-character document key and an empty value:
///
/// ```
/// key   = docKey (32-char hex)
/// value = Uint8List(0)
/// ```
///
/// An equality lookup therefore reduces to: compute the index namespace for
/// the query value, scan that namespace, return all keys.
///
/// ## Value encoding
///
/// Field values are first encoded to a namespace-safe hex string (see
/// [_encodeValueHex]):
///
/// | Field type | Encoding |
/// | ---------- | -------- |
/// | `String` | UTF-8 bytes → hex |
/// | `int` | 8-byte big-endian with sign-bit flip → hex (sort order preserved) |
/// | `double` | 8-byte IEEE-754 with bit adjustment → hex (sort order preserved) |
/// | `bool` | 1 byte (`0x00` = false, `0x01` = true) → hex |
/// | `null` / missing | No entry written |
///
/// `{token}` above is this hex string verbatim when the database is
/// unencrypted, or an HMAC-SHA256 token derived from it (via
/// [EncryptionProvider.indexToken], domain-separated by `ns`/`path`) when the
/// database is encrypted (Encryption confidentiality reconciliation plan,
/// Gap 2). The HMAC token is **not** sort-order-preserving, so encrypted
/// secondary indexes cannot support the `Future` "sort-order prefix for range
/// scans" use noted on [encodeValueHex] below — no current query path relies
/// on that ordering (equality lookup only, per [IndexReader]), so this is a
/// deferred limitation, not a regression, and is documented in §31.
///
/// ## Array fan-out
///
/// When [IndexDefinition.path] ends with `[]`, one entry is written per
/// non-null array element, each in its own value namespace.
abstract final class IndexWriter {
  IndexWriter._();

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Adds index entries for [docKey] to [batch].
  ///
  /// For fan-out paths (ending `[]`), one entry is written per non-null
  /// array element. [encryption], when non-null, tokenises the namespace
  /// suffix via [EncryptionProvider.indexToken] instead of plaintext hex
  /// (Gap 2).
  static Future<void> addEntries({
    required WriteBatch batch,
    required IndexDefinition definition,
    required String docKey,
    required Map<String, dynamic> document,
    EncryptionProvider? encryption,
  }) async {
    for (final value in _resolveValues(definition.path, document)) {
      if (value == null || value == missing) continue;
      final ns = await indexNamespaceForValue(
        definition,
        value,
        encryption: encryption,
      );
      if (ns == null) continue;
      batch.put(ns, docKey, Uint8List(0));
    }
  }

  /// Removes index entries for [docKey] from [batch].
  ///
  /// [encryption] must match whatever was passed to the [addEntries] call
  /// that originally wrote the entries being removed, so the same namespace
  /// tokens are reconstructed.
  static Future<void> removeEntries({
    required WriteBatch batch,
    required IndexDefinition definition,
    required String docKey,
    required Map<String, dynamic> document,
    EncryptionProvider? encryption,
  }) async {
    for (final value in _resolveValues(definition.path, document)) {
      if (value == null || value == missing) continue;
      final ns = await indexNamespaceForValue(
        definition,
        value,
        encryption: encryption,
      );
      if (ns == null) continue;
      batch.delete(ns, docKey);
    }
  }

  /// Returns the system namespace used to store entries for [value] in
  /// [definition]'s index.
  ///
  /// Returns `null` for value types that are not indexable (List, Map, etc.).
  ///
  /// When [encryption] is `null` (unencrypted database), the namespace
  /// suffix is the plaintext hex encoding from [_encodeValueHex] — unchanged
  /// from the pre-Gap-2 behaviour. When [encryption] is set, the suffix is an
  /// HMAC-SHA256 token via [EncryptionProvider.indexToken], computed from a
  /// message domain-separated by [IndexDefinition.namespace] and
  /// [IndexDefinition.path] so the same value in a different field/collection
  /// never produces the same token (Gap 2, Q4).
  static Future<String?> indexNamespaceForValue(
    IndexDefinition definition,
    Object value, {
    EncryptionProvider? encryption,
  }) async {
    final hex = _encodeValueHex(value);
    if (hex == null) return null;
    final token = encryption == null
        ? hex
        : await encryption.indexToken(
            '${definition.namespace}:${definition.path}:$hex',
          );
    return '${definition.indexNamespace}:$token';
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  /// Resolves the field value(s) for [path] from [document].
  ///
  /// Fan-out paths return each element individually. Scalar paths return a
  /// single-element list.
  ///
  /// The fan-out guard checks `path.endsWith('[]')`. Because
  /// [IndexDefinition] normalises the path at construction time — rewriting
  /// `[*]` to `[]` — this guard always sees the canonical form regardless of
  /// whether the user originally supplied `[*]` or `[]`. No change is needed
  /// here when [FieldPath._normalise] is updated.
  static List<Object?> _resolveValues(
    String path,
    Map<String, dynamic> document,
  ) {
    final resolved = FieldPath.resolve(path, document);
    if (resolved == missing) return const [missing];
    if (resolved is List && path.endsWith('[]')) {
      return resolved.cast<Object?>();
    }
    return [resolved];
  }

  /// Encodes [value] as a lowercase hex string for use in a namespace suffix.
  ///
  /// Returns `null` for un-indexable types (Map, List for non-fan-out paths).
  static String? _encodeValueHex(Object value) {
    if (value is String) {
      final bytes = utf8.encode(value);
      return _bytesToHex(Uint8List.fromList(bytes));
    }
    if (value is int) {
      return _bytesToHex(_encodeInt(value));
    }
    if (value is double) {
      if (value.isNaN) return null;
      return _bytesToHex(_encodeDouble(value));
    }
    if (value is bool) {
      return _bytesToHex(Uint8List.fromList([value ? 0x01 : 0x00]));
    }
    return null; // null, List, Map — not indexable
  }

  /// Encodes a signed integer as 8 big-endian bytes with the sign bit flipped
  /// so that lexicographic ordering of the hex strings matches numeric ordering.
  static Uint8List _encodeInt(int value) {
    final bytes = Uint8List(8);
    final bd = ByteData.sublistView(bytes);
    bd.setInt64(0, value, Endian.big);
    bytes[0] ^= 0x80; // flip sign bit → negatives sort before positives
    return bytes;
  }

  /// Encodes a double as 8 big-endian bytes with bits adjusted for sort order.
  static Uint8List _encodeDouble(double value) {
    final bytes = Uint8List(8);
    final bd = ByteData.sublistView(bytes);
    bd.setFloat64(0, value, Endian.big);
    if (bytes[0] & 0x80 != 0) {
      for (var i = 0; i < 8; i++) {
        bytes[i] ^=
            0xFF; // negative: flip all bits so more-negative sorts first
      }
    } else {
      bytes[0] ^= 0x80; // positive: flip sign bit only
    }
    return bytes;
  }

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ── Sort-order prefix for range scans (future use) ──────────────────────────

  /// Encodes [value] as a hex string that preserves lexicographic sort order.
  ///
  /// Identical to [_encodeValueHex] but exposed for [IndexReader] to build
  /// scan prefixes.  Returns `null` for un-indexable types.
  static String? encodeValueHex(Object value) => _encodeValueHex(value);
}
