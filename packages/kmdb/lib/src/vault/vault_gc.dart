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

import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/kv_store_impl.dart';
import 'search/vault_namespaces.dart';
import 'vault_ref_count.dart';
import 'vault_store.dart';

/// Manages tombstone-based garbage collection for the vault.
///
/// When a vault object's reference count reaches zero, [onZeroRefs] creates
/// a `tombstone.json` file in the hash directory, signalling that the object
/// is a GC candidate. [onRefRestored] removes the tombstone if a new reference
/// is added before the GC sweep runs.
///
/// [sweep] performs the actual deletion, but only after re-verifying that the
/// reference count in the KV store is still zero. This guards against
/// time-of-check/time-of-use races between tombstone creation and the sweep.
///
/// ## Design
///
/// Tombstoning (marking for GC) and the GC sweep are intentionally separated:
///
/// 1. [onZeroRefs] is called inside the same [WriteBatch] that sets the ref
///    count to zero, so the tombstone creation and ref-count update are atomic.
/// 2. [sweep] runs lazily (e.g. on open or periodically). It re-validates the
///    ref count before deleting so that a tombstone left by a crash cannot
///    accidentally delete a re-referenced object.
///
/// ## Tombstone format
///
/// `tombstone.json` is a simple JSON file whose presence (not content) is the
/// GC signal. It is created by [onZeroRefs] and deleted by [onRefRestored].
/// Its content is a timestamp for human-readability.
///
/// ## Vault search index cleanup
///
/// When [kvStore] is a [KvStoreImpl], [sweep] also deletes derived vault search
/// entries — `$$vault:fts:`, `$$vault:vec:idx:`, `$$vault:extract:`, and
/// `$vault:docref:` — in the same step as the blob deletion. This cleanup
/// operates directly on the KV namespaces and does not require
/// [VaultSearchManager] to be configured; if vault search was never enabled, the
/// scan returns empty results and the batch is a no-op.
///
/// If [kvStore] is not a [KvStoreImpl] (e.g. in tests that pass a mock), vault
/// search cleanup is skipped gracefully — no errors are raised.
final class VaultGc {
  /// Creates a [VaultGc] instance.
  ///
  /// [kvStore] is used to read vault reference counts via [VaultRefCount.read].
  /// Note that `$vault` ref-count entries use SHA-256 hex strings (64 chars)
  /// as keys — the key format is incompatible with the standard UUIDv7 key
  /// codec, so these reads are performed through the [KvStore] interface only
  /// (no write validation on the read path).
  ///
  /// [searchStore] is the [KvStoreImpl] used for vault search index cleanup
  /// during [sweep]. It defaults to [kvStore] when [kvStore] is itself a
  /// [KvStoreImpl], so production callers pass only [kvStore]. Tests may supply
  /// a separate [KvStoreImpl] for vault search entries when [kvStore] is a
  /// test double.
  ///
  /// [encryption] must match the provider used when the `$vault` ref count
  /// entries were written. When the database is encrypted (Q6 decision),
  /// `$vault` ref counts are stored as encrypted [ValueCodec] payloads, so the
  /// sweep must supply the same provider to decode them.
  const VaultGc({
    required this.store,
    required this.kvStore,
    this.searchStore,
    this.encryption,
  });

  /// The vault store that holds the blobs and manifests.
  final VaultStore store;

  /// The KV store for looking up vault reference counts.
  ///
  /// This store is used only for [VaultRefCount.read] (`$vault` namespace). It
  /// need not be a [KvStoreImpl]; any [KvStore] implementation that returns the
  /// correct bytes for `$vault` namespace reads is sufficient.
  final KvStore kvStore;

  /// Optional [KvStoreImpl] for vault search index cleanup in [sweep].
  ///
  /// When non-null, this store is used in [_deleteBlob] to scan and delete
  /// `$$vault:*` and `$vault:docref:*` entries. When null, [kvStore] is used
  /// (and the `is KvStoreImpl` check determines whether cleanup is possible).
  ///
  /// In production, [KmdbDatabase] leaves this null; [kvStore] is always a
  /// [KvStoreImpl] so the `is KvStoreImpl` cast succeeds. In tests that use a
  /// [KvStore] test double, pass the real [KvStoreImpl] holding vault search
  /// entries as [searchStore] to enable cleanup verification.
  final KvStoreImpl? searchStore;

  /// Active encryption provider, or `null` for plaintext databases.
  ///
  /// Forwarded to [VaultRefCount.read] so that encrypted `$vault` ref count
  /// entries are decoded correctly during the GC sweep.
  final EncryptionProvider? encryption;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Marks [sha256] as a GC candidate by creating `tombstone.json`.
  ///
  /// Called when the `$vault:{sha256}` ref count drops to zero. The tombstone
  /// creation must happen in the same [WriteBatch] as the ref-count update for
  /// atomicity — the caller is responsible for scheduling both operations.
  ///
  /// This method only writes the tombstone file; it does not delete the blob or
  /// manifest. Deletion happens in [sweep].
  Future<void> onZeroRefs(String sha256) => store.writeTombstone(sha256);

  /// Removes the tombstone for [sha256], un-tombstoning the object.
  ///
  /// Called when a new document references a previously tombstoned vault
  /// object. The tombstone removal must happen in the same [WriteBatch] as the
  /// ref-count increment.
  Future<void> onRefRestored(String sha256) => store.deleteTombstone(sha256);

  /// Sweeps tombstoned vault objects, deleting only those that are provably
  /// unreferenced.
  ///
  /// This method:
  /// 1. Enumerates all known vault hashes.
  /// 2. For each tombstoned hash, re-reads the current ref count from the KV
  ///    store via the fail-safe [VaultRefCount.read].
  /// 3. Acts on the [RefCountReadResult]:
  ///    - [RefCountAbsent] or [RefCountValue] `== 0` → ref count is still zero,
  ///      delete the hash directory.
  ///    - [RefCountValue] `> 0` → object was re-referenced since tombstoning;
  ///      remove the tombstone and count it as skipped (TOCTOU guard).
  ///    - [RefCountUndecodable] → the ref entry is present but cannot be
  ///      decoded. **Fail-safe: the object is retained** (tombstone left in
  ///      place) and counted in [VaultGcResult.retainedUndecodable]. Deletion
  ///      requires a positive determination of zero references — an undecodable
  ///      counter never qualifies, because a corrupt entry must not be allowed
  ///      to destroy a blob that documents may still reference.
  ///
  /// The re-validation guard prevents deleting objects that have been
  /// re-referenced since the tombstone was created (e.g. via a concurrent sync
  /// or import that completed between [onZeroRefs] and [sweep]).
  ///
  /// Returns a [VaultGcResult] describing how many objects were swept.
  Future<VaultGcResult> sweep() async {
    var examined = 0;
    var deleted = 0;
    var skipped = 0;
    var retainedUndecodable = 0;

    final hashes = await store.listAllHashes();
    for (final sha256 in hashes) {
      // Only process tombstoned objects.
      if (!await store.isTombstoned(sha256)) continue;
      examined++;

      // Re-validate ref count before deleting — guard against TOCTOU and,
      // crucially, against acting on an undecodable counter. Pass the
      // encryption provider so that encrypted $vault entries are decoded
      // correctly (Q6: ref counts ride in synced SSTables and are encrypted
      // uniformly with all other ValueCodec call sites).
      final result = await VaultRefCount.read(
        kvStore,
        sha256,
        encryption: encryption,
      );
      switch (result) {
        case RefCountAbsent():
          // No entry → genuinely zero references (the entry is deleted when the
          // count reaches zero). Safe to delete.
          await _deleteBlob(sha256);
          deleted++;
        case RefCountValue(:final count):
          if (count > 0) {
            // Object has been re-referenced since tombstoning. Remove the
            // tombstone to restore it to the normal hydrated/stub state.
            await store.deleteTombstone(sha256);
            skipped++;
          } else {
            // Decoded to exactly zero references. Safe to delete.
            await _deleteBlob(sha256);
            deleted++;
          }
        case RefCountUndecodable():
          // Fail-safe: we cannot prove the object is unreferenced, so retain it
          // and leave the tombstone in place for a future sweep (once the entry
          // is readable again or the object is genuinely dereferenced).
          retainedUndecodable++;
      }
    }

    return VaultGcResult(
      examined: examined,
      deleted: deleted,
      skipped: skipped,
      retainedUndecodable: retainedUndecodable,
    );
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  /// Deletes the vault blob hash directory and its derived vault search index
  /// entries in one step.
  ///
  /// Deletion order:
  /// 1. Delete all derived vault search KV entries (`$$vault:*`, `$vault:docref:*`).
  /// 2. Delete the `extract/` filesystem subdirectory (vault search artefacts).
  /// 3. Delete the main blob hash directory (blob, manifest, tombstone).
  ///
  /// KV deletion happens first so that on crash the blob dir (with its
  /// tombstone.json) is still present and the next sweep can retry steps 2–3.
  /// If the blob dir were deleted before the KV batch, a crash would leave
  /// orphaned index entries with no blob for the GC to re-examine.
  ///
  /// Steps 1 and 2 are no-ops when vault search was never configured for this
  /// blob — the KV namespaces are empty and `deleteExtractDir` finds nothing.
  Future<void> _deleteBlob(String sha256) async {
    // Step 1: Delete all derived vault search KV entries.
    //
    // Prefer the dedicated searchStore when provided; otherwise fall back to
    // kvStore when it happens to be a KvStoreImpl. The dedicated searchStore
    // parameter exists to support tests that use a KvStore test double for ref
    // count reads but need a real KvStoreImpl for vault search cleanup
    // verification (see VaultGc.searchStore doc comment). In production,
    // KmdbDatabase always passes a KvStoreImpl as kvStore and leaves searchStore
    // null, so the cast succeeds on the kvStore path.
    final impl =
        searchStore ?? (kvStore is KvStoreImpl ? kvStore as KvStoreImpl : null);
    if (impl != null) {
      await _deleteVaultSearchEntries(impl, sha256);
    }

    // Step 2: Delete the extract/ subdirectory (text.txt, chunks_v1.json,
    // vectors_{modelId}_sq8.bin, extract_status.json). No-op if the directory
    // does not exist (vault search was never run on this blob).
    await store.deleteExtractDir(sha256);

    // Step 3: Delete the main blob directory (blob, manifest, tombstone).
    await store.deleteHashDir(sha256);
  }

  /// Deletes all vault search KV entries for [sha256] via [writeBatchInternal].
  ///
  /// Scans and deletes:
  /// - `$$vault:fts:corpus:{sha256}` — corpus sentinel
  /// - `$$vault:fts:{sha256}:{hexTerm}` — all per-chunk BM25 term entries
  /// - `$$vault:vec:idx:{sha256}` — all per-chunk SQ8 vector entries
  /// - `$$vault:extract:{sha256}` — extraction status sentinel
  /// - `$vault:docref:{sha256}` — all document-reference entries
  ///
  /// The scan is a no-op if vault search was never configured for this blob;
  /// the WriteBatch is empty and no write is issued.
  ///
  /// ## Per-term entry enumeration
  ///
  /// Per-term namespaces are `$$vault:fts:{sha256}:{hexTerm}` (one namespace
  /// per unique term). Because we cannot enumerate sub-namespaces without a
  /// full LSM scan, [allStoredNamespaces] is used to find all namespaces that
  /// start with `$$vault:fts:{sha256}:` (the per-term prefix). For each such
  /// namespace, every chunk-index key is scanned and deleted. This is an
  /// O(terms × chunks) operation, acceptable for GC (an infrequent path).
  ///
  /// The corpus sentinel is deleted separately via `$$vault:fts:corpus:{sha256}`
  /// (which has a distinct prefix from `$$vault:fts:{sha256}:`).
  static Future<void> _deleteVaultSearchEntries(
    KvStoreImpl store,
    String sha256,
  ) async {
    final batch = WriteBatch();

    // ── 1. Delete the corpus sentinel ($$vault:fts:corpus:{sha256}) ──────────
    final corpusNs = '$kVaultFtsCorpusPrefix$sha256';
    batch.delete(corpusNs, kVaultCorpusSentinelKey);

    // ── 2. Delete all per-term BM25 entries ($$vault:fts:{sha256}:{hexTerm}) ─
    //
    // Each unique term gets its own namespace: `$$vault:fts:{sha256}:{hexTerm}`.
    // We enumerate all namespaces in the LSM that start with the per-term
    // prefix `$$vault:fts:{sha256}:` and delete every chunk-index key within
    // each. allStoredNamespaces() performs a full LSM merge scan — expensive
    // but correct. GC is infrequent so this cost is acceptable.
    final termNsPrefix = '$kVaultFtsPrefix$sha256:';
    final allNs = await store.allStoredNamespaces();
    for (final ns in allNs) {
      if (ns.startsWith(termNsPrefix)) {
        // Scan the per-term namespace and delete each chunk-index entry.
        await for (final entry in store.scan(ns)) {
          batch.delete(ns, entry.key);
        }
      }
    }

    // ── 3. Delete per-chunk vector entries ($$vault:vec:idx:{sha256}) ────────
    final vecNs = '$kVaultVecIdxPrefix$sha256';
    await for (final entry in store.scan(vecNs)) {
      batch.delete(vecNs, entry.key);
    }

    // ── 4. Delete the extraction status sentinel ($$vault:extract:{sha256}) ──
    final extractNs = '$kVaultExtractPrefix$sha256';
    batch.delete(extractNs, kVaultCorpusSentinelKey);

    // ── 5. Delete all document-reference entries ($vault:docref:{sha256}) ────
    final docRefNs = '$kVaultDocRefPrefix$sha256';
    await for (final entry in store.scan(docRefNs)) {
      batch.delete(docRefNs, entry.key);
    }

    // Commit all deletions in one atomic WriteBatch. If the batch is empty
    // (no vault search entries existed for this blob), writeBatchInternal is
    // still called but produces no WAL writes (empty batch short-circuits).
    if (batch.entries.isNotEmpty) {
      await store.writeBatchInternal(batch);
    }
  }
}

// ── Result types ──────────────────────────────────────────────────────────────

/// Result of a [VaultGc.sweep] pass.
final class VaultGcResult {
  /// Creates a [VaultGcResult].
  const VaultGcResult({
    required this.examined,
    required this.deleted,
    required this.skipped,
    this.retainedUndecodable = 0,
  });

  /// Total number of tombstoned objects found during the sweep.
  final int examined;

  /// Number of hash directories permanently deleted.
  final int deleted;

  /// Number of objects that had their tombstones removed because the ref count
  /// was restored before the sweep ran (TOCTOU guard).
  final int skipped;

  /// Number of tombstoned objects retained because their `$vault` ref-count
  /// entry was present but undecodable.
  ///
  /// These objects are *not* deleted — the fail-safe rule keeps any object whose
  /// reference count cannot be proven zero. A non-zero value signals corrupt or
  /// unrecognised ref-count entries that warrant investigation, rather than the
  /// silent data loss the previous decoder would have caused.
  final int retainedUndecodable;

  /// Returns `true` if any deletions occurred.
  bool get hadWork => deleted > 0;

  @override
  String toString() =>
      'VaultGcResult(examined: $examined, deleted: $deleted, '
      'skipped: $skipped, retainedUndecodable: $retainedUndecodable)';
}
