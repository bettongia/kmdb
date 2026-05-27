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

/// Performs vault crash recovery after an unclean shutdown.
///
/// The recovery sweep is defined in §24 and runs as the last step of the
/// standard [CrashRecovery] sequence (after LSM recovery). It handles two
/// categories of leftover state:
///
/// ## Staging sweep
///
/// Deletes all files and directories under `vault/staging/`. The LOCK file
/// guarantees no other process is mid-write, so staging files are
/// unconditionally incomplete and safe to delete.
///
/// ## Hash directory sweep
///
/// Inspects each hash directory under `vault/blobs/sha256/`:
///
/// - Blob present, no `manifest.json`, no KV ref → delete (incomplete write).
/// - `manifest.json` present, no KV ref → delete (orphaned vault object).
///
/// A hash directory with a `manifest.json` **and** a KV ref is a valid stub or
/// fully hydrated object — leave it alone.
///
/// ## Fail-safe ref-count rule
///
/// Reference counts are read through the shared, fail-safe [VaultRefCount.read].
/// Recovery deletes an object only on a **positive determination of zero
/// references** — an absent counter or a decoded `refCount == 0`. A ref-count
/// entry that is *present but undecodable* (corrupt, truncated, or written by a
/// future/older codec) is treated as **referenced and retained**, and counted
/// in [VaultRecoveryResult.retainedUndecodable]. This prevents a single
/// malformed `$vault` entry from wiping a blob that documents still reference
/// (review finding H3).
///
/// ## Crash table (§24)
///
/// | Crash after step | State                                  | Recovery action       |
/// | :--------------- | :------------------------------------- | :-------------------- |
/// | 1 or 2           | Orphaned staging file, no final dir    | Delete staging file   |
/// | 3                | Blob in final dir, no manifest, no ref | Delete hash directory |
/// | 4                | manifest.json + blob, no ref           | Delete hash directory |
/// | —                | manifest.json + blob, undecodable ref  | Retain (fail-safe)    |
final class VaultRecovery {
  /// Creates a [VaultRecovery] instance.
  const VaultRecovery({required this.store, required this.kvStore});

  /// The vault store to recover.
  final VaultStore store;

  /// The KV store used to check reference counts in the `$vault` namespace.
  final KvStore kvStore;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Runs the full vault recovery sequence and returns a [VaultRecoveryResult].
  ///
  /// This method is called from [CrashRecovery.open] after the LSM engine has
  /// been fully recovered.
  Future<VaultRecoveryResult> recover() async {
    // Step 1: staging sweep — delete all files under vault/staging/.
    final stagingDeleted = await _sweepStaging();

    // Step 2: hash directory sweep — delete orphaned or incomplete objects.
    final (hashDirsDeleted, retainedUndecodable) = await _sweepHashDirs();

    return VaultRecoveryResult(
      stagingFilesDeleted: stagingDeleted,
      hashDirsDeleted: hashDirsDeleted,
      retainedUndecodable: retainedUndecodable,
    );
  }

  // ── Staging sweep ──────────────────────────────────────────────────────────

  /// Deletes all files under `vault/staging/`.
  ///
  /// Returns the number of staging files deleted.
  Future<int> _sweepStaging() async {
    final adapter = store.adapter;
    final stagingDir = store.stagingDir;
    var count = 0;

    // List all files directly under staging/ (staging files are direct
    // children, not nested).
    final files = await adapter.listFiles(stagingDir);
    for (final filename in files) {
      await adapter.deleteFile('$stagingDir/$filename');
      count++;
    }
    return count;
  }

  // ── Hash directory sweep ──────────────────────────────────────────────────

  /// Scans all hash directories and deletes orphaned or incomplete objects.
  ///
  /// Returns a record of `(deleted, retainedUndecodable)` — the number of hash
  /// directories deleted and the number retained because their ref-count entry
  /// was present but undecodable (the fail-safe case).
  Future<(int, int)> _sweepHashDirs() async {
    var deleted = 0;
    var retainedUndecodable = 0;

    final hashes = await store.listAllHashes();
    for (final sha256 in hashes) {
      switch (await _classify(sha256)) {
        case _RecoveryAction.delete:
          await store.deleteHashDir(sha256);
          deleted++;
        case _RecoveryAction.retain:
          // Referenced (or defensively retained) — leave the object in place.
          break;
        case _RecoveryAction.retainUndecodable:
          retainedUndecodable++;
      }
    }
    return (deleted, retainedUndecodable);
  }

  /// Decides what recovery should do with the hash directory for [sha256].
  ///
  /// The decision is **fail-safe**: an object is only deleted on a positive
  /// determination of zero references. Specifically:
  ///
  /// - Ref entry present but undecodable → [_RecoveryAction.retainUndecodable].
  ///   A corrupt, truncated, or unrecognised `$vault` entry must never be read
  ///   as "no reference"; the object is kept so a malformed ref cannot wipe a
  ///   blob that documents still reference (review finding H3).
  /// - `manifest.json` absent, no KV ref → [_RecoveryAction.delete] (incomplete
  ///   write — blob only, or empty directory).
  /// - `manifest.json` absent, KV ref present → [_RecoveryAction.retain]. This
  ///   should not happen normally (the manifest is written before the KV write),
  ///   but if it does, leave it alone; it will be re-examined on the next
  ///   recovery if the manifest is still absent.
  /// - `manifest.json` present, no KV ref → [_RecoveryAction.delete] (orphaned
  ///   object — the `WriteBatch` that was supposed to create the ref never
  ///   committed). Per §24, a stub *always* has a positive `$vault` reference
  ///   (the producer-side contract enforced by [VaultStore.createStub]), so a
  ///   ref-less manifest is by definition an error state, not a synced stub.
  /// - `manifest.json` present, KV ref present → [_RecoveryAction.retain] (a
  ///   valid stub or fully hydrated object).
  Future<_RecoveryAction> _classify(String sha256) async {
    final refResult = await VaultRefCount.read(kvStore, sha256);

    // Fail-safe short-circuit: a present-but-undecodable ref entry means we
    // cannot prove the object is unreferenced. Treat it as referenced and keep
    // it — never delete on uncertainty.
    if (refResult is RefCountUndecodable) {
      return _RecoveryAction.retainUndecodable;
    }

    // Absent or Value(0) → no active reference; Value(n>0) → referenced.
    final hasRef = refResult is RefCountValue && refResult.count > 0;
    final hasManifest = await store.exists(sha256);

    if (!hasManifest) {
      // Blob without manifest (or empty dir): delete only if there is no ref.
      return hasRef ? _RecoveryAction.retain : _RecoveryAction.delete;
    }

    // Manifest present: orphaned (delete) if there is no KV ref, otherwise a
    // valid stub/hydrated object (retain).
    return hasRef ? _RecoveryAction.retain : _RecoveryAction.delete;
  }
}

/// The action vault recovery takes for a single hash directory.
enum _RecoveryAction {
  /// The object is provably unreferenced (or an incomplete write) — delete it.
  delete,

  /// The object is referenced, or defensively retained — leave it in place.
  retain,

  /// The object's ref-count entry is present but undecodable — retain it under
  /// the fail-safe rule and report it via
  /// [VaultRecoveryResult.retainedUndecodable].
  retainUndecodable,
}

// ── Result types ───────────────────────────────────────────────────────────────

/// Result of a vault recovery sweep.
final class VaultRecoveryResult {
  /// Creates a [VaultRecoveryResult].
  const VaultRecoveryResult({
    required this.stagingFilesDeleted,
    required this.hashDirsDeleted,
    this.retainedUndecodable = 0,
  });

  /// Number of staging files deleted (incomplete writes).
  final int stagingFilesDeleted;

  /// Number of hash directories deleted (orphaned or incomplete objects).
  final int hashDirsDeleted;

  /// Number of hash directories retained because their `$vault` ref-count entry
  /// was present but undecodable.
  ///
  /// Under the fail-safe rule, recovery never deletes an object whose reference
  /// count cannot be proven zero. A non-zero value here surfaces corrupt or
  /// unrecognised ref-count entries that warrant investigation, instead of the
  /// silent blob deletion the previous decoder would have caused.
  final int retainedUndecodable;

  /// Returns `true` if any cleanup was performed.
  bool get hadWork => stagingFilesDeleted > 0 || hashDirsDeleted > 0;

  @override
  String toString() =>
      'VaultRecoveryResult(stagingFilesDeleted: $stagingFilesDeleted, '
      'hashDirsDeleted: $hashDirsDeleted, '
      'retainedUndecodable: $retainedUndecodable)';
}

/// The `$vault` system namespace key prefix for reference counts.
///
/// Vault ref count entries are stored as `$vault:{sha256}` in the KV store.
const String kVaultNamespace = r'$vault';
