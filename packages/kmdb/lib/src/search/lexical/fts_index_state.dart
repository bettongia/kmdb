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

/// @docImport '../../engine/kvstore/meta_store.dart';
library;

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

/// Discriminates how base-entry namespace tokens (the `{token}` segment of
/// [FtsIndexState.baseKey]) were computed when this index was last (re)built.
///
/// Introduced by the Encryption confidentiality reconciliation plan, Gap 2
/// (Q5), as a persisted format-version marker — the same role
/// [VecIndexState.modelId] plays for embedding-model identity. It is **not**
/// a runtime toggle: encryption cannot be enabled/disabled on an existing
/// database (see `KmdbDatabase.open`'s `cannotProvisionNonEmptyDatabase`
/// check), so the only way this value can mismatch what the current code
/// would produce is a software upgrade that changes the tokenisation scheme
/// for an already-encrypted database.
enum FtsTokenMode {
  /// Terms are UTF-8-encoded and hex-stringified in plaintext
  /// ([FtsManager._termToHex]). Used when the database is unencrypted, and
  /// also the value read back from indexes built before Gap 2 shipped
  /// (absent/unrecognised `tokenMode` decodes to this — see [fromBytes]).
  hex,

  /// Terms are tokenised via [EncryptionProvider.indexToken] (HMAC-SHA256,
  /// keyed by a sub-key derived from the database's DEK). Used when the
  /// database is encrypted.
  hmac,
}

/// Persistent state for a single FTS index field, stored as a CBOR map in
/// the local-only `$$ftsstate` system namespace under the key derived from
/// [metaKey] (see [FtsManager]'s `_loadState`/`_saveState`).
///
/// This moved out of synced `$meta` by the 0.10.01 WI-11 fix (SC-10): a
/// device that pulled a peer's `$meta` would inherit `status: current` for an
/// FTS index it never built locally, then scan its own empty `$$fts:*`
/// namespaces and silently return zero `search()` results for present,
/// matching documents. `$$ftsstate` is local-only (never uploaded — see
/// `isLocalOnly` in `namespace_codec.dart`), so this can no longer happen.
final class FtsIndexState {
  /// Creates an [FtsIndexState].
  const FtsIndexState({
    required this.namespace,
    required this.field,
    required this.status,
    this.builtThrough = '',
    this.builtAt = '',
    this.tokenMode = FtsTokenMode.hex,
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

  /// How base-entry namespace tokens were computed as of the last build.
  ///
  /// Compared against what the currently-running code would produce (`hmac`
  /// when an [EncryptionProvider] is configured, `hex` otherwise) at
  /// `KmdbDatabase.open` time; a mismatch triggers a full rebuild — see
  /// [FtsManager.checkAndTransitionOnOpen] (Gap 2, Q5).
  final FtsTokenMode tokenMode;

  /// Returns a copy with the specified fields overridden.
  FtsIndexState copyWith({
    FtsIndexStatus? status,
    String? builtThrough,
    String? builtAt,
    FtsTokenMode? tokenMode,
  }) => FtsIndexState(
    namespace: namespace,
    field: field,
    status: status ?? this.status,
    builtThrough: builtThrough ?? this.builtThrough,
    builtAt: builtAt ?? this.builtAt,
    tokenMode: tokenMode ?? this.tokenMode,
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
      CborString('tokenMode'): CborString(tokenMode.name),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  /// Deserialises an [FtsIndexState] from CBOR-encoded [bytes].
  ///
  /// Returns a state with [FtsIndexStatus.undefined] if [bytes] is empty,
  /// null, or corrupt so that callers can always proceed safely.
  ///
  /// [tokenMode] defaults to [FtsTokenMode.hex] when absent from the
  /// serialised map — indexes built before Gap 2 shipped were always
  /// hex-tokenised, so this default is not a guess, it is the actual prior
  /// behaviour. This is also what lets [FtsManager.checkAndTransitionOnOpen]
  /// detect the pre-Gap-2 → Gap-2 upgrade on an already-encrypted database:
  /// the absent-tokenMode-defaults-to-`hex` read will mismatch the `hmac`
  /// the current (encrypted) code expects, exactly as intended.
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
      final tokenModeStr = map['tokenMode'] as String? ?? 'hex';
      final tokenMode = FtsTokenMode.values.firstWhere(
        (m) => m.name == tokenModeStr,
        orElse: () => FtsTokenMode.hex,
      );
      return FtsIndexState(
        namespace: namespace,
        field: field,
        status: status,
        builtThrough: map['builtThrough'] as String? ?? '',
        builtAt: map['builtAt'] as String? ?? '',
        tokenMode: tokenMode,
      );
    } catch (_) {
      return undefined;
    }
  }

  // ── Static key helpers ─────────────────────────────────────────────────────

  /// Key for a base-index posting entry.
  ///
  /// Format: `$$fts:{ns}:{field}:{term}:{docId}`
  ///
  /// The `$$` prefix marks this as a local-only namespace — its contents are
  /// never uploaded to the sync folder. Each device rebuilds its FTS index
  /// independently from document data.
  ///
  /// One entry per (term, document) pair. The value is the term frequency
  /// (number of times the term appears in the document field) encoded as a
  /// CBOR integer.
  static String baseKey(String ns, String field, String term, String docId) =>
      r'$$fts:'
      '$ns:$field:$term:$docId';

  /// Key for an overlay entry (tracks updates/deletes since last compaction).
  ///
  /// Format: `$$fts:overlay:{ns}:{field}:{docId}`
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// The value is a CBOR map of `{term: tf}` for the current document state,
  /// or the sentinel value [kFtsTombstone] to indicate a deletion.
  static String overlayKey(String ns, String field, String docId) =>
      r'$$fts:overlay:'
      '$ns:$field:$docId';

  /// Key for corpus-level aggregate statistics.
  ///
  /// Format: `$$fts:corpus:{ns}:{field}`
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// The value is a CBOR map with keys:
  /// - `n` (int) — total number of indexed documents
  /// - `totalTokens` (int) — sum of field lengths across all documents
  static String corpusKey(String ns, String field) =>
      r'$$fts:corpus:'
      '$ns:$field';

  /// Key for per-document token count (field length).
  ///
  /// Format: `$$fts:doc:{ns}:{field}:{docId}`
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// Stores the number of tokens in the field for [docId]. Used to adjust
  /// corpus stats correctly during updates and deletes.
  static String docKey(String ns, String field, String docId) =>
      r'$$fts:doc:'
      '$ns:$field:$docId';

  /// Symbolic name for the persisted [FtsIndexState] CBOR blob, stored in the
  /// local-only `$$ftsstate` namespace (moved from `$meta` by WI-11/SC-10 —
  /// see the class doc comment).
  ///
  /// Format: `fts:{ns}:{field}`
  ///
  /// Note: no `$` prefix here — this is a symbolic name, not a namespace. It
  /// is passed to [MetaStore.symbolicKey] to derive the actual storage key
  /// within `$$ftsstate` (mirrors how [MetaStore.indexKey] does the same for
  /// secondary-index state, reusing the identical key-encoding scheme).
  static String metaKey(String ns, String field) => 'fts:$ns:$field';
}

/// Sentinel value written to the overlay namespace to mark a deleted document.
///
/// A document whose overlay entry equals [kFtsTombstone] is excluded from all
/// query results until [FtsManager.compact] reconciles the overlay with the
/// base index and removes both the base entries and the overlay entry.
const String kFtsTombstone = '__tombstone__';
