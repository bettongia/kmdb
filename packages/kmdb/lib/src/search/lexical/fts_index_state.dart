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

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The lifecycle states of a full-text search (FTS) index.
///
/// ```
/// undefined → building → current
///                      ↘ stale → (rebuild) → current
/// undefined → (first write, lazy=true) → building → current
/// current → syncing → current
///         ↘ (crash during sync) → stale → (rebuild) → current
/// ```
enum FtsIndexStatus {
  /// Declared in config but never built. No FTS entries have been written.
  undefined,

  /// A full namespace scan is in progress to build the initial index.
  ///
  /// Queries during `building` fall back to a full-scan + BM25 pass.
  building,

  /// The index is built and current. All writes are intercepted.
  current,

  /// The index was built previously but the namespace has been written to
  /// since the build completed. A rebuild is triggered on the next query.
  stale,

  /// A sync delta is being applied. Queries are served from the pre-sync index
  /// while catch-up writes are in progress.
  syncing,
}

/// Persistent state for a single FTS index field, stored as a CBOR map in
/// the `$meta` system namespace under the key returned by [metaKey].
final class FtsIndexState {
  /// Creates an [FtsIndexState].
  const FtsIndexState({
    required this.namespace,
    required this.field,
    required this.status,
    this.builtThrough = '',
    this.builtAt = '',
  });

  /// The collection namespace this index covers.
  final String namespace;

  /// The document field path this index covers.
  final String field;

  /// Current lifecycle status.
  final FtsIndexStatus status;

  /// The last document key (UUIDv7 hex) that was scanned during the initial
  /// build. Used to resume an interrupted build. Empty when not yet built.
  final String builtThrough;

  /// ISO-8601 UTC timestamp string recorded when the build last completed.
  /// Empty when not yet built. Informational only.
  final String builtAt;

  /// Returns a copy with the specified fields overridden.
  FtsIndexState copyWith({
    FtsIndexStatus? status,
    String? builtThrough,
    String? builtAt,
  }) => FtsIndexState(
    namespace: namespace,
    field: field,
    status: status ?? this.status,
    builtThrough: builtThrough ?? this.builtThrough,
    builtAt: builtAt ?? this.builtAt,
  );

  // ── CBOR serialisation ─────────────────────────────────────────────────────

  /// Serialises this state to a CBOR-encoded [Uint8List] for `$meta` storage.
  Uint8List toBytes() {
    final map = CborMap({
      CborString('namespace'): CborString(namespace),
      CborString('field'): CborString(field),
      CborString('status'): CborString(status.name),
      CborString('builtThrough'): CborString(builtThrough),
      CborString('builtAt'): CborString(builtAt),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  /// Deserialises an [FtsIndexState] from CBOR-encoded [bytes].
  ///
  /// Returns a state with [FtsIndexStatus.undefined] if [bytes] is empty,
  /// null, or corrupt so that callers can always proceed safely.
  static FtsIndexState fromBytes(
    String namespace,
    String field,
    Uint8List? bytes,
  ) {
    final undefined = FtsIndexState(
      namespace: namespace,
      field: field,
      status: FtsIndexStatus.undefined,
    );
    if (bytes == null || bytes.isEmpty) return undefined;
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) return undefined;
      final map = decoded.toObject() as Map<dynamic, dynamic>;
      final statusStr = map['status'] as String? ?? 'undefined';
      final status = FtsIndexStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => FtsIndexStatus.undefined,
      );
      return FtsIndexState(
        namespace: namespace,
        field: field,
        status: status,
        builtThrough: map['builtThrough'] as String? ?? '',
        builtAt: map['builtAt'] as String? ?? '',
      );
    } catch (_) {
      return undefined;
    }
  }

  // ── Static key helpers ─────────────────────────────────────────────────────

  /// Key for a base-index posting entry.
  ///
  /// Format: `$fts:{ns}:{field}:{term}:{docId}`
  ///
  /// One entry per (term, document) pair. The value is the term frequency
  /// (number of times the term appears in the document field) encoded as a
  /// CBOR integer.
  static String baseKey(String ns, String field, String term, String docId) =>
      '\$fts:$ns:$field:$term:$docId';

  /// Key for an overlay entry (tracks updates/deletes since last compaction).
  ///
  /// Format: `$fts:overlay:{ns}:{field}:{docId}`
  ///
  /// The value is a CBOR map of `{term: tf}` for the current document state,
  /// or the sentinel value [kFtsTombstone] to indicate a deletion.
  static String overlayKey(String ns, String field, String docId) =>
      '\$fts:overlay:$ns:$field:$docId';

  /// Key for corpus-level aggregate statistics.
  ///
  /// Format: `$fts:corpus:{ns}:{field}`
  ///
  /// The value is a CBOR map with keys:
  /// - `n` (int) — total number of indexed documents
  /// - `totalTokens` (int) — sum of field lengths across all documents
  static String corpusKey(String ns, String field) => '\$fts:corpus:$ns:$field';

  /// Key for per-document token count (field length).
  ///
  /// Format: `$fts:doc:{ns}:{field}:{docId}`
  ///
  /// Stores the number of tokens in the field for [docId]. Used to adjust
  /// corpus stats correctly during updates and deletes.
  static String docKey(String ns, String field, String docId) =>
      '\$fts:doc:$ns:$field:$docId';

  /// Key for the persisted [FtsIndexState] CBOR blob in `$meta`.
  ///
  /// Format: `fts:{ns}:{field}`
  ///
  /// Note: no `$` prefix here because this is used as the symbolic name
  /// passed to [MetaStore.getRawByName] / [MetaStore.putRawByName], which
  /// operate in the `$meta` namespace.
  static String metaKey(String ns, String field) => 'fts:$ns:$field';
}

/// Sentinel value written to the overlay namespace to mark a deleted document.
///
/// A document whose overlay entry equals [kFtsTombstone] is excluded from all
/// query results until [FtsManager.compact] reconciles the overlay with the
/// base index and removes both the base entries and the overlay entry.
const String kFtsTombstone = '__tombstone__';
