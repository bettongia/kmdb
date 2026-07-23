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

/// @docImport '../../engine/kvstore/meta_store.dart';
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The lifecycle states of a vector (semantic) search index.
///
/// ```
/// undefined → building → current
///                      ↘ stale → (rebuild) → current
/// undefined → (first write, lazy=true) → building → current
/// current → syncing → current
///         ↘ (crash during sync) → stale → (rebuild) → current
/// ```
enum VecIndexStatus {
  /// Declared in config but never built. No vector entries have been written.
  undefined,

  /// A full namespace scan is in progress to build the initial index.
  ///
  /// Queries during `building` run inference on every document in the
  /// namespace and fall back to a full-scan approach.
  building,

  /// The index is built and current. All writes are intercepted.
  current,

  /// The index was built previously but the namespace has been written to
  /// since the build completed. A rebuild is triggered on the next query.
  stale,

  /// A sync delta is being applied. Queries are served from the pre-sync index
  /// while catch-up writes (inference + quantisation) are in progress.
  syncing,
}

/// Persistent state for a single vector index field, stored as a CBOR map in
/// the local-only `$$vecstate` system namespace under the key derived from
/// [metaKey] (see `VecManager`'s `_loadState`/`_saveState`).
///
/// This moved out of synced `$meta` by the 0.10.01 WI-11 fix (SC-10): a
/// device that pulled a peer's `$meta` would inherit `status: current` for a
/// Vec index it never built locally, then scan its own empty `$$vec:*`
/// namespaces and silently return zero `search()` results for present,
/// matching documents. `$$vecstate` is local-only (never uploaded — see
/// `isLocalOnly` in `namespace_codec.dart`), so this can no longer happen.
final class VecIndexState {
  /// Creates a [VecIndexState].
  const VecIndexState({
    required this.namespace,
    required this.field,
    required this.status,
    this.builtThrough = '',
    this.builtAt = '',
    this.modelId = '',
  });

  /// The collection namespace this index covers.
  final String namespace;

  /// The document field path this index covers.
  final String field;

  /// Current lifecycle status.
  final VecIndexStatus status;

  /// The last document key (UUIDv7 hex) scanned during the initial build.
  ///
  /// Used to resume an interrupted build. Empty when not yet built.
  final String builtThrough;

  /// ISO-8601 UTC timestamp string recorded when the build last completed.
  ///
  /// Empty when not yet built. Informational only.
  final String builtAt;

  /// The [EmbeddingModel.modelId] of the model that built this index.
  ///
  /// Persisted alongside the index state so that a model change can be
  /// detected at open time and the index marked [VecIndexStatus.stale]. Empty
  /// (`''`) on indexes built before model identity tracking was introduced
  /// (backward-compatible reads: empty id is treated as a match and stamped
  /// on the next build, not an eager rebuild trigger).
  final String modelId;

  /// Returns a copy with the specified fields overridden.
  VecIndexState copyWith({
    VecIndexStatus? status,
    String? builtThrough,
    String? builtAt,
    String? modelId,
  }) => VecIndexState(
    namespace: namespace,
    field: field,
    status: status ?? this.status,
    builtThrough: builtThrough ?? this.builtThrough,
    builtAt: builtAt ?? this.builtAt,
    modelId: modelId ?? this.modelId,
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
      // modelId is always written so future reads can detect model changes.
      CborString('modelId'): CborString(modelId),
    });
    return Uint8List.fromList(cbor.encode(map));
  }

  /// Deserialises a [VecIndexState] from CBOR-encoded [bytes].
  ///
  /// Returns a state with [VecIndexStatus.undefined] if [bytes] is empty,
  /// null, or corrupt so that callers can always proceed safely.
  ///
  /// The [modelId] field defaults to `''` when absent from the serialised map
  /// for backward-compatible reads (indexes built before model identity
  /// tracking was added). An empty stored [modelId] is treated as a match
  /// rather than a mismatch — it is stamped with the current model id on the
  /// next [VecManager.ensureBuilt] call.
  static VecIndexState fromBytes(
    String namespace,
    String field,
    Uint8List? bytes,
  ) {
    final undefined = VecIndexState(
      namespace: namespace,
      field: field,
      status: VecIndexStatus.undefined,
    );
    if (bytes == null || bytes.isEmpty) return undefined;
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) return undefined;
      final map = decoded.toObject() as Map<dynamic, dynamic>;
      final statusStr = map['status'] as String? ?? 'undefined';
      final status = VecIndexStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => VecIndexStatus.undefined,
      );
      return VecIndexState(
        namespace: namespace,
        field: field,
        status: status,
        builtThrough: map['builtThrough'] as String? ?? '',
        builtAt: map['builtAt'] as String? ?? '',
        // Default to '' for backward-compatible reads (pre-identity indexes).
        modelId: map['modelId'] as String? ?? '',
      );
    } catch (_) {
      return undefined;
    }
  }

  // ── Static key/namespace helpers ───────────────────────────────────────────

  /// The KvStore namespace where SQ8-quantised vectors are stored.
  ///
  /// Format: `$$vec:{ns}:{field}`
  ///
  /// The `$$` prefix marks this as a local-only namespace — its contents are
  /// never uploaded to the sync folder. Each device rebuilds its vector index
  /// independently by running inference on the local document data.
  ///
  /// Within this namespace, the key is the 32-character UUIDv7 docId and the
  /// value is the D-byte SQ8-quantised embedding, where D is the model's
  /// [EmbeddingModel.dimensions].
  static String vecNamespace(String ns, String field) =>
      r'$$vec:'
      '$ns:$field';

  /// The KvStore namespace for corpus-level statistics.
  ///
  /// Format: `$$vec:corpus:{ns}:{field}`
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// Contains a single entry keyed by [corpusSentinelKey] with a CBOR map
  /// `{n: int}` — the total number of indexed documents.
  static String corpusNamespace(String ns, String field) =>
      r'$$vec:corpus:'
      '$ns:$field';

  /// The KvStore namespace for truncation markers.
  ///
  /// Format: `$$vec:truncated:{ns}:{field}`
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// A key exists in this namespace when the corresponding document's field
  /// value exceeded 510 usable BERT tokens. The entry value is empty bytes.
  /// Written as a diagnostic signal; not read on the query path.
  static String truncatedNamespace(String ns, String field) =>
      r'$$vec:truncated:'
      '$ns:$field';

  /// Fixed 32-char hex sentinel key for the corpus statistics entry.
  ///
  /// UUIDv7 keys begin with a 48-bit millisecond timestamp in the high bits,
  /// so they never start with all-zero bytes. This sentinel therefore never
  /// collides with a real document key.
  static const String corpusSentinelKey = '01900000000070009000000000000001';

  /// Symbolic name for the persisted [VecIndexState] CBOR blob, stored in the
  /// local-only `$$vecstate` namespace (moved from `$meta` by WI-11/SC-10 —
  /// see the class doc comment).
  ///
  /// Format: `vec:{ns}:{field}`
  ///
  /// Note: no `$` prefix here — this is a symbolic name, not a namespace. It
  /// is passed to [MetaStore.symbolicKey] to derive the actual storage key
  /// within `$$vecstate` (mirrors how [MetaStore.indexKey] does the same for
  /// secondary-index state, reusing the identical key-encoding scheme).
  static String metaKey(String ns, String field) => 'vec:$ns:$field';
}
