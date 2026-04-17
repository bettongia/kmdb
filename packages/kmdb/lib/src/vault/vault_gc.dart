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

import '../engine/kvstore/kv_store.dart';
import 'vault_recovery.dart' show kVaultNamespace;
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

  /// Sweeps tombstoned vault objects, deleting those whose ref count is still
  /// zero.
  ///
  /// This method:
  /// 1. Enumerates all known vault hashes.
  /// 2. For each tombstoned hash, re-reads the current ref count from the KV
  ///    store.
  /// 3. Deletes the hash directory only if the ref count is still zero.
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

    final hashes = await store.listAllHashes();
    for (final sha256 in hashes) {
      // Only process tombstoned objects.
      if (!await store.isTombstoned(sha256)) continue;
      examined++;

      // Re-validate ref count before deleting — guard against TOCTOU.
      final refCount = await _readRefCount(sha256);
      if (refCount > 0) {
        // Object has been re-referenced since tombstoning. Remove the tombstone
        // to restore it to the normal hydrated/stub state.
        await store.deleteTombstone(sha256);
        skipped++;
        continue;
      }

      // Safe to delete: ref count is still zero.
      await store.deleteHashDir(sha256);
      deleted++;
    }

    return VaultGcResult(
      examined: examined,
      deleted: deleted,
      skipped: skipped,
    );
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// Reads the current reference count for [sha256] from the KV store.
  ///
  /// Returns 0 if no entry exists or if the stored value cannot be decoded.
  Future<int> _readRefCount(String sha256) async {
    final bytes = await kvStore.get(kVaultNamespace, sha256);
    if (bytes == null) return 0;
    return _decodeRefCount(bytes);
  }

  /// Decodes a vault reference count from KV-store bytes.
  ///
  /// The ref count is stored as a ValueCodec-encoded integer map:
  /// `flag_byte + CBOR({"refCount": N})`.
  ///
  /// Returns 0 if the bytes cannot be decoded.
  static int _decodeRefCount(List<int> bytes) {
    if (bytes.length < 2) return 0;
    var pos = 1; // skip ValueCodec flag byte
    if (pos >= bytes.length) return 0;

    final mapByte = bytes[pos++];
    if ((mapByte & 0xE0) != 0xA0) return 0; // not a CBOR map
    final numPairs = mapByte & 0x1F;

    for (var i = 0; i < numPairs && pos < bytes.length; i++) {
      // Read text key.
      final keyByte = bytes[pos++];
      if ((keyByte & 0xE0) != 0x60) return 0;
      final keyLen = keyByte & 0x1F;
      if (pos + keyLen > bytes.length) return 0;
      final key = String.fromCharCodes(bytes.sublist(pos, pos + keyLen));
      pos += keyLen;

      if (pos >= bytes.length) return 0;
      final valByte = bytes[pos++];

      if (key == 'refCount') {
        if (valByte <= 0x17) return valByte;
        if (valByte == 0x18 && pos < bytes.length) return bytes[pos];
        if (valByte == 0x19 && pos + 1 < bytes.length) {
          return (bytes[pos] << 8) | bytes[pos + 1];
        }
        return 0;
      } else {
        pos = _skipValue(bytes, pos - 1);
      }
    }
    return 0;
  }

  static int _skipValue(List<int> bytes, int pos) {
    if (pos >= bytes.length) return pos;
    final b = bytes[pos++];
    final mt = b >> 5;
    final ai = b & 0x1F;
    switch (mt) {
      case 0:
      case 1:
        if (ai == 24) return pos + 1;
        if (ai == 25) return pos + 2;
        if (ai == 26) return pos + 4;
        if (ai == 27) return pos + 8;
        return pos;
      case 2:
      case 3:
        if (ai <= 23) return pos + ai;
        if (ai == 24 && pos < bytes.length) return pos + 1 + bytes[pos];
        return pos + 2;
      default:
        return pos;
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
  });

  /// Total number of tombstoned objects found during the sweep.
  final int examined;

  /// Number of hash directories permanently deleted.
  final int deleted;

  /// Number of objects that had their tombstones removed because the ref count
  /// was restored before the sweep ran (TOCTOU guard).
  final int skipped;

  /// Returns `true` if any deletions occurred.
  bool get hadWork => deleted > 0;

  @override
  String toString() =>
      'VaultGcResult(examined: $examined, deleted: $deleted, skipped: $skipped)';
}
