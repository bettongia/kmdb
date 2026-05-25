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

import '../engine/kvstore/kv_store.dart';
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
final class VaultGc {
  /// Creates a [VaultGc] instance.
  const VaultGc({required this.store, required this.kvStore});

  /// The vault store that holds the blobs and manifests.
  final VaultStore store;

  /// The KV store for looking up vault reference counts.
  final KvStore kvStore;

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
      // crucially, against acting on an undecodable counter.
      final result = await VaultRefCount.read(kvStore, sha256);
      switch (result) {
        case RefCountAbsent():
          // No entry → genuinely zero references (the entry is deleted when the
          // count reaches zero). Safe to delete.
          await store.deleteHashDir(sha256);
          deleted++;
        case RefCountValue(:final count):
          if (count > 0) {
            // Object has been re-referenced since tombstoning. Remove the
            // tombstone to restore it to the normal hydrated/stub state.
            await store.deleteTombstone(sha256);
            skipped++;
          } else {
            // Decoded to exactly zero references. Safe to delete.
            await store.deleteHashDir(sha256);
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
