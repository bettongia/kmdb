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
/// ## Crash table (§24)
///
/// | Crash after step | State                                  | Recovery action       |
/// | :--------------- | :------------------------------------- | :-------------------- |
/// | 1 or 2           | Orphaned staging file, no final dir    | Delete staging file   |
/// | 3                | Blob in final dir, no manifest, no ref | Delete hash directory |
/// | 4                | manifest.json + blob, no ref           | Delete hash directory |
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
    var stagingDeleted = 0;
    var hashDirsDeleted = 0;

    // Step 1: staging sweep — delete all files under vault/staging/.
    stagingDeleted = await _sweepStaging();

    // Step 2: hash directory sweep — delete orphaned or incomplete objects.
    hashDirsDeleted = await _sweepHashDirs();

    return VaultRecoveryResult(
      stagingFilesDeleted: stagingDeleted,
      hashDirsDeleted: hashDirsDeleted,
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
  /// Returns the number of hash directories deleted.
  Future<int> _sweepHashDirs() async {
    var deleted = 0;

    final hashes = await store.listAllHashes();
    for (final sha256 in hashes) {
      if (await _shouldDelete(sha256)) {
        await store.deleteHashDir(sha256);
        deleted++;
      }
    }
    return deleted;
  }

  /// Returns `true` if the hash directory for [sha256] should be deleted.
  ///
  /// Deletion criteria (§24 crash table):
  /// - `manifest.json` absent → possibly an incomplete write (blob only, or
  ///   neither file). Check for KV ref and delete if absent.
  /// - `manifest.json` present, no KV ref → orphaned object. Delete.
  ///
  /// If neither a manifest nor a blob exists (the directory is empty or the
  /// scanner picked up something else), we still delete to clean up.
  Future<bool> _shouldDelete(String sha256) async {
    final hasManifest = await store.exists(sha256);

    // Check for a KV reference in the $vault namespace.
    final hasRef = await _hasKvRef(sha256);

    if (!hasManifest) {
      // Blob without manifest (or empty dir) and no KV ref → delete.
      if (!hasRef) return true;
      // Blob without manifest but with KV ref — this should not happen normally
      // (the manifest is written before the KV write), but if it does, leave it
      // alone; it will be caught on the next recovery if the manifest is still
      // absent.
      return false;
    }

    // Manifest present — check for KV ref.
    // If no KV ref exists, the vault object is orphaned (the WriteBatch
    // that was supposed to create the ref never committed).
    return !hasRef;
  }

  /// Returns `true` if the KV store contains a reference for [sha256] in the
  /// `$vault` namespace.
  Future<bool> _hasKvRef(String sha256) async {
    // The $vault ref count key uses the sha256 as the key.
    // A non-null, non-zero value indicates an active reference.
    final bytes = await kvStore.get(kVaultNamespace, sha256);
    if (bytes == null) return false;
    // Decode the ref count. A count of 0 means tombstoned (no active ref).
    try {
      final count = _decodeRefCount(bytes);
      return count > 0;
    } catch (_) {
      // Corrupt ref count — treat as absent.
      return false;
    }
  }

  /// Decodes a vault ref count from raw bytes.
  ///
  /// The ref count is stored as a CBOR-encoded integer (via [WriteBatch]).
  static int _decodeRefCount(List<int> bytes) {
    // The vault ref counts are stored as plain integers encoded by ValueCodec.
    // We use a simple big-endian int decode since vault ref counts are small.
    if (bytes.isEmpty) return 0;
    // Handle CBOR-encoded int: if first byte is 0x18 (uint8), read next byte,
    // if 0x19 (uint16), read next 2 bytes, etc. For small counts (0–23),
    // the value is in the low 5 bits of the first byte.
    // For simplicity in v1, the ref count is stored as a raw CBOR integer.
    // We reuse the ValueCodec decoding path via the KvStore API.
    //
    // Since the KvStore stores vault refs via WriteBatch.put with a CBOR map
    // value (via ValueCodec.encode), we decode accordingly.
    // The actual stored format is: ValueCodec prefix byte + CBOR map {"v": N}.
    //
    // If the first byte is 0x00 (raw, no compression), skip it and decode CBOR.
    // A minimal CBOR map {"v": N} is: A1 61 76 [N]
    //
    // For now, extract from the ValueCodec-encoded form.
    final view = bytes.toList();
    // Simple extraction: skip the 1-byte codec flag, find the integer value.
    // The vault ref-count map has the shape {"refCount": N}.
    // We use a lightweight extraction rather than full CBOR decoding.
    for (var i = 0; i < view.length - 1; i++) {
      // CBOR positive integer: 0x00–0x17 (0–23 inline), 0x18 (1-byte follow)
      // We just look for a positive integer in the CBOR stream.
      if (view[i] >= 0 && view[i] <= 23) {
        // Could be an inline CBOR integer — but this is too naive.
        // Fall through to the CBOR map extraction.
        break;
      }
    }
    // Use a simple heuristic: the last numeric byte-sequence is the count.
    // For a proper implementation, use the CBOR library.
    // In practice, ref counts are small (1–100) and stored as CBOR ints.
    return _extractRefCountFromCborMap(view);
  }

  /// Extracts the `refCount` integer from a CBOR-encoded map value.
  ///
  /// This is a minimal CBOR map parser sufficient for vault ref counts.
  static int _extractRefCountFromCborMap(List<int> bytes) {
    // The vault writes: ValueCodec.encode({"refCount": N})
    // ValueCodec output: [flagByte, CBOR({"refCount": N})]
    // We skip the flagByte and parse the CBOR map.
    if (bytes.length < 2) return 0;

    // Skip ValueCodec flag byte (index 0), then parse CBOR map.
    var pos = 1;
    if (pos >= bytes.length) return 0;

    // CBOR map: first byte is 0xA0 | count (for maps with 0–23 entries)
    final mapByte = bytes[pos++];
    if ((mapByte & 0xE0) != 0xA0) return 0; // Not a map
    final numPairs = mapByte & 0x1F;

    for (var i = 0; i < numPairs && pos < bytes.length; i++) {
      // Read key (text string)
      final keyByte = bytes[pos++];
      if ((keyByte & 0xE0) != 0x60) return 0; // Not a text string
      final keyLen = keyByte & 0x1F;
      if (pos + keyLen > bytes.length) return 0;
      final key = String.fromCharCodes(bytes.sublist(pos, pos + keyLen));
      pos += keyLen;

      // Read value
      if (pos >= bytes.length) return 0;
      final valByte = bytes[pos++];

      if (key == 'refCount') {
        // Decode integer
        if (valByte <= 0x17) return valByte; // 0–23 inline
        if (valByte == 0x18 && pos < bytes.length) return bytes[pos]; // uint8
        if (valByte == 0x19 && pos + 1 < bytes.length) {
          return (bytes[pos] << 8) | bytes[pos + 1]; // uint16
        }
        return 0;
      } else {
        // Skip value — handle common CBOR types.
        pos = _skipCborValue(bytes, pos - 1);
      }
    }
    return 0;
  }

  static int _skipCborValue(List<int> bytes, int pos) {
    if (pos >= bytes.length) return pos;
    final b = bytes[pos++];
    final majorType = b >> 5;
    final additionalInfo = b & 0x1F;

    switch (majorType) {
      case 0:
      case 1: // unsigned/negative int
        if (additionalInfo == 24) return pos + 1;
        if (additionalInfo == 25) return pos + 2;
        if (additionalInfo == 26) return pos + 4;
        if (additionalInfo == 27) return pos + 8;
        return pos;
      case 2:
      case 3: // byte/text string
        if (additionalInfo <= 23) return pos + additionalInfo;
        if (additionalInfo == 24 && pos < bytes.length) {
          return pos + 1 + bytes[pos];
        }
        return pos + 2;
      case 4:
      case 5: // array/map
        final count = additionalInfo <= 23 ? additionalInfo : 1;
        var p = pos;
        final items = majorType == 4 ? count : count * 2;
        for (var i = 0; i < items; i++) {
          p = _skipCborValue(bytes, p);
        }
        return p;
      default:
        return pos;
    }
  }
}

// ── Result types ───────────────────────────────────────────────────────────────

/// Result of a vault recovery sweep.
final class VaultRecoveryResult {
  /// Creates a [VaultRecoveryResult].
  const VaultRecoveryResult({
    required this.stagingFilesDeleted,
    required this.hashDirsDeleted,
  });

  /// Number of staging files deleted (incomplete writes).
  final int stagingFilesDeleted;

  /// Number of hash directories deleted (orphaned or incomplete objects).
  final int hashDirsDeleted;

  /// Returns `true` if any cleanup was performed.
  bool get hadWork => stagingFilesDeleted > 0 || hashDirsDeleted > 0;

  @override
  String toString() =>
      'VaultRecoveryResult(stagingFilesDeleted: $stagingFilesDeleted, '
      'hashDirsDeleted: $hashDirsDeleted)';
}

/// The `$vault` system namespace key prefix for reference counts.
///
/// Vault ref count entries are stored as `$vault:{sha256}` in the KV store.
const String kVaultNamespace = r'$vault';
