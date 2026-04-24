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

import '../encoding/value_codec.dart';
import '../engine/kvstore/kv_store.dart';
import '../query/write_augmentor.dart';
import 'vault_gc.dart';
import 'vault_recovery.dart' show kVaultNamespace;
import 'vault_ref.dart';

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
/// [ValueCodec]-encoded map: `{"refCount": N}`. The miniature CBOR decoder
/// in [VaultGc] and [VaultRecovery] reads this format.
///
/// Implements [WriteAugmentor] so it integrates with the formal write pipeline
/// without requiring special-casing in [KmdbCollection]. The [namespace] and
/// [docKey] parameters are accepted but unused — vault URI diffing is
/// purely document-content-based.
final class VaultRefInterceptor implements WriteAugmentor {
  /// Creates a [VaultRefInterceptor].
  const VaultRefInterceptor({required this.kvStore, required this.gc});

  /// The KV store used to read and write ref counts.
  final KvStore kvStore;

  /// The GC instance to notify when a ref count reaches zero or is restored.
  final VaultGc gc;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Intercepts a document write, adjusting vault ref counts in [batch].
  ///
  /// Diffs [oldDoc] vs [newDoc] vault URIs:
  /// - URIs added in [newDoc] have their ref count incremented.
  /// - URIs removed in [newDoc] have their ref count decremented.
  /// - Unchanged URIs are not touched.
  ///
  /// When a ref count reaches zero, [VaultGc.onZeroRefs] is called (writes
  /// `tombstone.json`). When a previously-zero ref count is restored,
  /// [VaultGc.onRefRestored] is called (removes `tombstone.json`).
  ///
  /// [oldDoc] may be `null` for new inserts. [newDoc] may be `null` for
  /// deletes. The [namespace] and [docKey] parameters are accepted to satisfy
  /// the [WriteAugmentor] interface but are not used — vault URI diffing is
  /// purely document-content-based.
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

  /// Reads the current ref count for [sha256] from the KV store.
  ///
  /// Returns 0 if no entry exists.
  Future<int> _readRefCount(String sha256) async {
    final bytes = await kvStore.get(kVaultNamespace, sha256);
    if (bytes == null) return 0;
    final decoded = ValueCodec.decode(bytes);
    final count = decoded['refCount'];
    return count is int ? count : 0;
  }

  /// Increments the ref count for [sha256] in [batch].
  ///
  /// If the count was previously zero and the object was tombstoned (waiting
  /// for GC sweep), [VaultGc.onRefRestored] is called to remove the tombstone.
  Future<void> _increment(String sha256, WriteBatch batch) async {
    final current = await _readRefCount(sha256);
    final next = current + 1;
    batch.put(kVaultNamespace, sha256, ValueCodec.encode({'refCount': next}));

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
      batch.delete(kVaultNamespace, sha256);
      await gc.onZeroRefs(sha256);
    } else {
      batch.put(kVaultNamespace, sha256, ValueCodec.encode({'refCount': next}));
    }
  }
}
