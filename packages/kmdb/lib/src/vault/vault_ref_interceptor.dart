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

import 'dart:typed_data';

import '../encoding/value_codec.dart';
import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import '../query/write_augmentor.dart';
import 'vault_gc.dart';
import 'vault_recovery.dart' show kVaultNamespace, kVaultRefCountSentinelKey;
import 'vault_ref.dart';
import 'vault_ref_count.dart';
import 'search/vault_namespaces.dart';

/// Intercepts document writes to maintain vault object reference counts.
///
/// The [VaultRefInterceptor] is called by the Query Layer's
/// `_writeDocument` and `_deleteDocument` methods. It diffs the old and new
/// document's vault URIs, increments and decrements reference counts in the
/// `$vault` system namespace, and fires [VaultGc.onZeroRefs] or
/// [VaultGc.onRefRestored] when the count transitions through zero.
///
/// All changes are applied to the same [WriteBatch] as the document write,
/// ensuring the document and its ref count adjustments are atomically
/// committed to the WAL.
///
/// ## How the `$vault` namespace stores ref counts
///
/// Each entry is keyed by the SHA-256 hex string and encoded as a
/// [ValueCodec]-encoded map: `{"refCount": N}`. All readers — this interceptor,
/// [VaultGc], and `VaultRecovery` — decode it through the shared, fail-safe
/// [VaultRefCount.read] rather than a hand-rolled parser.
///
/// ## Encryption
///
/// When [encryption] is non-null, `$vault` ref count values are encrypted via
/// [ValueCodec] before being written to the KV store (Q4/Q6 decision:
/// encrypt every `ValueCodec` call site uniformly, because `$vault` entries
/// ride in synced SSTables).
///
/// ## `$vault:docref:` document-reference index
///
/// In addition to ref counts, this interceptor also maintains the
/// `$vault:docref:{sha256}` / `{docId}` index (RQ-4). This index maps each
/// vault blob to the documents that reference it — enabling [VaultSearchManager]
/// to quickly locate candidate documents during `searchVault()` queries.
///
/// For each SHA-256 added in [newDoc], a `$vault:docref:{sha256}` / `{docId}`
/// entry is written with the first dot-notation field path in [newDoc] that
/// holds the vault URI for that sha256.
///
/// **First-field-path-wins**: when the same blob is referenced from more than
/// one field in the same document, only the first path found by the DFS scan
/// is recorded. A future upgrade (v2) may store all paths in a CBOR list.
///
/// Because `$vault:docref:` has a single `$` prefix it syncs normally (unlike
/// `$$vault:*` which is local-only). Docref entries are encrypted when
/// encryption is active, consistent with all other `$vault` entries.
///
/// Note: [decrementVersionRefs] does NOT delete docref entries — docref tracks
/// *live document* references, and a trimmed `$ver:` history entry does not
/// change which live documents currently reference a blob.
///
/// Implements [WriteAugmentor] so it integrates with the formal write pipeline
/// without requiring special-casing in [KmdbCollection]. The [namespace]
/// parameter is accepted but unused — vault URI diffing is
/// purely document-content-based. The [docKey] parameter IS used for
/// the docref index (`{docId}` key segment).
final class VaultRefInterceptor implements WriteAugmentor {
  /// Creates a [VaultRefInterceptor].
  const VaultRefInterceptor({
    required this.kvStore,
    required this.gc,
    this.encryption,
  });

  /// The KV store used to read and write ref counts.
  final KvStore kvStore;

  /// The GC instance to notify when a ref count reaches zero or is restored.
  final VaultGc gc;

  /// Optional encryption provider. When non-null, `$vault` ref count values
  /// are encrypted with AES-256-GCM before storage.
  final EncryptionProvider? encryption;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Intercepts a document write, adjusting vault ref counts and docref
  /// index entries in [batch].
  ///
  /// **Ref counts:** diffs [oldDoc] vs [newDoc] vault URIs:
  /// - URIs added in [newDoc] have their ref count incremented.
  /// - URIs removed in [newDoc] have their ref count decremented.
  /// - Unchanged URIs are not touched.
  ///
  /// When a ref count reaches zero, [VaultGc.onZeroRefs] is called (writes
  /// `tombstone.json`). When a previously-zero ref count is restored,
  /// [VaultGc.onRefRestored] is called (removes `tombstone.json`).
  ///
  /// **Docref index (`$vault:docref:{sha256}` / `{docId}`):** also diffs
  /// the path-aware vault URI maps to add/delete entries for newly added and
  /// removed sha256s. See class-level doc for design notes.
  ///
  /// [oldDoc] may be `null` for new inserts. [newDoc] may be `null` for
  /// deletes. The [namespace] parameter is accepted to satisfy the
  /// [WriteAugmentor] interface but is not used — vault URI diffing is
  /// purely document-content-based. The [docKey] parameter IS used as the
  /// `{docId}` key segment for the docref index.
  @override
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    final oldUris = _extractVaultUris(oldDoc);
    final newUris = _extractVaultUris(newDoc);

    // Compute the deltas: added URIs need increment, removed URIs need
    // decrement. URIs present in both old and new are unchanged.
    final added = newUris.difference(oldUris);
    final removed = oldUris.difference(newUris);

    for (final sha256 in added) {
      await _increment(sha256, batch);
    }
    for (final sha256 in removed) {
      await _decrement(sha256, batch);
    }

    // ── Docref index maintenance ──────────────────────────────────────────
    // Compute path-aware maps to diff added/removed docref entries.
    // This is a separate scan from ref-count diffing (path information is
    // needed here but discarded by _extractVaultUris).
    final oldPaths = _scanVaultUrisWithPaths(oldDoc);
    final newPaths = _scanVaultUrisWithPaths(newDoc);

    final oldSha256s = oldPaths.keys.toSet();
    final newSha256s = newPaths.keys.toSet();

    // sha256s newly added in newDoc → write a docref entry.
    // The field path is stored as a CBOR map `{"p": fieldPath}` so it can be
    // encoded via ValueCodec (which requires a Map<String, dynamic>) and
    // encrypted uniformly with other $vault entries.
    for (final sha256 in newSha256s.difference(oldSha256s)) {
      final fieldPath = newPaths[sha256]!;
      batch.put(
        '$kVaultDocRefPrefix$sha256',
        docKey,
        await ValueCodec.encode({'p': fieldPath}, encryption: encryption),
      );
    }

    // sha256s removed from newDoc → delete the docref entry for this docId.
    for (final sha256 in oldSha256s.difference(newSha256s)) {
      batch.delete('$kVaultDocRefPrefix$sha256', docKey);
    }

    // sha256s present in both: docKey→path mapping is unchanged; leave as-is.
    // (If the field path itself changed but the sha256 is still referenced,
    // that change is not tracked in v1 — first-field-path-wins is documented.)
  }

  // ── Public helpers ─────────────────────────────────────────────────────────

  /// Decrements vault ref counts for every vault URI found in [encodedValue].
  ///
  /// Decodes [encodedValue] via [ValueCodec] to obtain a document map, then
  /// extracts all vault URIs from the map and appends decrement operations to
  /// [batch]. Used by the compaction version-drop callback (RQ5) to release
  /// vault ref counts for `$ver:` entries trimmed at compaction time.
  ///
  /// ## Crash posture
  ///
  /// The caller ([KmdbDatabase]) issues [batch] as a post-compaction write.
  /// If the process crashes before this batch commits, the ref count is
  /// over-counted (blob retained). This is the fail-safe posture from H3.
  Future<void> decrementVersionRefs(
    Uint8List encodedValue,
    WriteBatch batch,
  ) async {
    final Map<String, dynamic> doc;
    try {
      doc = await ValueCodec.decode(encodedValue, encryption: encryption);
    } catch (_) {
      // Cannot decode — skip. The fail-safe posture means undecodable entries
      // leave the ref count over-counted (blob retained), never under-counted.
      return;
    }
    final uris = _extractVaultUris(doc);
    for (final sha256 in uris) {
      await _decrement(sha256, batch);
    }
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// Extracts the set of SHA-256 hashes from vault URIs found in [doc].
  ///
  /// Scans all values in the document recursively (nested maps and lists).
  /// Returns an empty set if [doc] is null.
  Set<String> _extractVaultUris(Map<String, dynamic>? doc) {
    if (doc == null) return const {};
    final result = <String>{};
    _scanForVaultUris(doc, result);
    return result;
  }

  /// Recursively scans [value] for vault URI strings, adding SHA-256 hashes
  /// to [result].
  void _scanForVaultUris(dynamic value, Set<String> result) {
    if (value is String) {
      if (VaultRef.isVaultUri(value)) {
        // Extract the sha256 from the URI — safe since isVaultUri passed.
        result.add(VaultRef(value).sha256);
      }
    } else if (value is Map<String, dynamic>) {
      for (final v in value.values) {
        _scanForVaultUris(v, result);
      }
    } else if (value is List<dynamic>) {
      for (final item in value) {
        _scanForVaultUris(item, result);
      }
    }
  }

  /// Scans [doc] recursively for vault URIs, returning a map from SHA-256 to
  /// the **first** dot-notation field path that contains that sha256.
  ///
  /// This is a path-aware counterpart to [_extractVaultUris]. The first-wins
  /// rule means: when the same sha256 appears in multiple fields of the same
  /// document, only the first field path found by the DFS traversal is stored.
  /// This is a documented v1 limitation — a future version may store all paths
  /// in a CBOR list.
  ///
  /// Returns an empty map if [doc] is null.
  Map<String, String> _scanVaultUrisWithPaths(Map<String, dynamic>? doc) {
    if (doc == null) return const {};
    final result = <String, String>{};
    _scanForVaultUrisWithPaths(doc, '', result);
    return result;
  }

  /// Recursively scans [value] for vault URI strings, recording the first
  /// field path for each sha256 in [result].
  ///
  /// [currentPath] is the dot-notation prefix accumulated from parent nodes.
  void _scanForVaultUrisWithPaths(
    dynamic value,
    String currentPath,
    Map<String, String> result,
  ) {
    if (value is String) {
      if (VaultRef.isVaultUri(value)) {
        final sha256 = VaultRef(value).sha256;
        // First-wins: only record if this sha256 has not been seen yet.
        result.putIfAbsent(sha256, () => currentPath);
      }
    } else if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        final childPath = currentPath.isEmpty
            ? entry.key
            : '$currentPath.${entry.key}';
        _scanForVaultUrisWithPaths(entry.value, childPath, result);
      }
    } else if (value is List<dynamic>) {
      for (var i = 0; i < value.length; i++) {
        final childPath = currentPath.isEmpty ? '[$i]' : '$currentPath[$i]';
        _scanForVaultUrisWithPaths(value[i], childPath, result);
      }
    }
  }

  /// Reads the current ref count for [sha256] from the KV store.
  ///
  /// Delegates to the shared [VaultRefCount.read] so all four call sites share
  /// one decoder. Returns `0` when no entry exists. An undecodable entry is also
  /// reported as `0` here: the interceptor is the *writer* of these entries and
  /// only ever encounters its own valid [ValueCodec] encodings in practice, so a
  /// corrupt entry can only arise from external corruption — in which case the
  /// fail-safe authorities are the deletion paths ([VaultGc.sweep] and
  /// [VaultRecovery]), both of which now re-read via [VaultRefCount.read] and
  /// retain on `undecodable`.
  Future<int> _readRefCount(String sha256) async {
    final result = await VaultRefCount.read(
      kvStore,
      sha256,
      encryption: encryption,
    );
    return switch (result) {
      RefCountValue(:final count) => count,
      RefCountAbsent() => 0,
      RefCountUndecodable() => 0,
    };
  }

  /// Increments the ref count for [sha256] in [batch].
  ///
  /// If the count was previously zero and the object was tombstoned (waiting
  /// for GC sweep), [VaultGc.onRefRestored] is called to remove the tombstone.
  Future<void> _increment(String sha256, WriteBatch batch) async {
    final current = await _readRefCount(sha256);
    final next = current + 1;
    // See VaultRefCount's doc comment: the ref count lives at
    // (namespace: '$vault:{sha256}', key: kVaultRefCountSentinelKey), not
    // (namespace: '$vault', key: sha256) — a 64-char sha256 cannot pass
    // KeyCodec.keyToBytes as a KV key.
    batch.put(
      '$kVaultNamespace:$sha256',
      kVaultRefCountSentinelKey,
      await ValueCodec.encode({'refCount': next}, encryption: encryption),
    );

    // If transitioning from 0 → 1, a tombstone may have been left by a prior
    // zero-ref decrement. Remove it to un-tombstone the object.
    if (current == 0) {
      await gc.onRefRestored(sha256);
    }
  }

  /// Decrements the ref count for [sha256] in [batch].
  ///
  /// If the resulting count is zero, [VaultGc.onZeroRefs] is called to mark
  /// the object as a GC candidate (creates `tombstone.json`).
  Future<void> _decrement(String sha256, WriteBatch batch) async {
    final current = await _readRefCount(sha256);
    // Guard against going below zero (should not occur in well-formed data,
    // but a defensive clamp prevents silent corruption).
    final next = current > 0 ? current - 1 : 0;

    if (next == 0) {
      // Remove the ref count entry entirely when it reaches zero so GC and
      // recovery can use absence-of-entry as a reliable zero signal.
      batch.delete('$kVaultNamespace:$sha256', kVaultRefCountSentinelKey);
      await gc.onZeroRefs(sha256);
    } else {
      batch.put(
        '$kVaultNamespace:$sha256',
        kVaultRefCountSentinelKey,
        await ValueCodec.encode({'refCount': next}, encryption: encryption),
      );
    }
  }
}
