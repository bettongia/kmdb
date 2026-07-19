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

// This file is native-only and imports dart:io directly.
// It must not be imported on web platforms.

import 'dart:convert';
import 'dart:io';

import '../encryption/encryption_envelope.dart';
import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import 'vault_manifest.dart';
import 'vault_storage_adapter.dart';
import 'vault_store.dart';

/// A [VaultStorageAdapter] backed by the local filesystem.
///
/// Suitable for testing, NAS mounts, SMB/CIFS shares, and locally-synced
/// cloud folders (e.g. Dropbox or OneDrive directories accessible via
/// `dart:io`).
///
/// ## Sync vault layout
///
/// Vault objects are stored under `{syncRoot}/vault/{prefix}/{suffix}/`:
///
/// ```
/// {syncRoot}/
///   vault/
///     ab/                ← first two hex chars of SHA-256
///       cdef.../         ← remaining 62 hex chars
///         manifest.json  ← always present for a known object
///         blob           ← absent on stubs (metadata-only devices)
///         tombstone.json ← present when reference count reached zero
/// ```
///
/// ## First-writer-wins for `manifest.json`
///
/// [uploadVaultObject] checks whether `manifest.json` already exists in the
/// sync vault before writing. If it does, the upload is skipped — two devices
/// that ingest the same content-identical file produce semantically equivalent
/// manifests (same SHA-256, size, and CRC32C), differing only in `createdAt`.
/// The first device to push wins; all others are silently no-ops.
///
/// ## Blob idempotency
///
/// Blobs are content-identical across all devices (SHA-256 is their identity).
/// If the remote blob already exists, the upload is skipped.
///
/// ## Stub hydration write path
///
/// [hydrateVaultBlob] follows the same crash-safe write ordering as local
/// ingestion:
/// 1. Download the remote blob to `vault/staging/{uuid}`.
/// 2. Rename the staging file to the final `blob` path.
///
/// A crash between steps 1 and 2 leaves an orphan staging file, which
/// [VaultRecovery] sweeps on the next open.
final class LocalDirectoryVaultAdapter implements VaultStorageAdapter {
  /// Creates a [LocalDirectoryVaultAdapter].
  ///
  /// [_syncRoot] is the base directory for all remote vault paths.
  /// [_localStore] is the local [VaultStore] used for staging and path
  /// resolution. [_kvStore] is the local KV store, used by [syncVaultMetadata]
  /// to verify that a positive `$vault` reference is present before creating
  /// a stub (the producer-side contract enforced by [VaultStore.createStub]).
  /// [encryption] must match the provider active on this database; when
  /// non-null, `$vault` ref count entries are encrypted and must be decrypted
  /// before the producer-side guard in [VaultStore.createStub] can read them.
  LocalDirectoryVaultAdapter({
    required this._syncRoot,
    required this._localStore,
    required this._kvStore,
    this.encryption,
  });

  /// The base directory for all remote vault paths.
  final String _syncRoot;

  /// The local vault store providing path helpers and staging.
  final VaultStore _localStore;

  /// The local KV store, used to verify the `$vault` ref before stub creation.
  final KvStore _kvStore;

  /// Active encryption provider, or `null` for plaintext databases.
  ///
  /// Forwarded to [VaultStore.createStub] so that encrypted `$vault` ref count
  /// entries are decoded correctly when the producer-side guard runs.
  final EncryptionProvider? encryption;

  // ── Remote path helpers ───────────────────────────────────────────────────

  /// Returns the remote sync-vault directory for [sha256].
  ///
  /// Uses the same two-level shard structure as the local vault:
  /// `{syncRoot}/vault/{prefix}/{suffix}`.
  String _remoteHashDir(String sha256) {
    final prefix = sha256.substring(0, 2);
    final suffix = sha256.substring(2);
    return '$_syncRoot/vault/$prefix/$suffix';
  }

  /// Returns the remote path of the `manifest.json` for [sha256].
  String _remoteManifestPath(String sha256) =>
      '${_remoteHashDir(sha256)}/manifest.json';

  /// Returns the remote path of the `blob` file for [sha256].
  String _remoteBlobPath(String sha256) => '${_remoteHashDir(sha256)}/blob';

  /// Returns the remote path of the `tombstone.json` for [sha256].
  String _remoteTombstonePath(String sha256) =>
      '${_remoteHashDir(sha256)}/tombstone.json';

  // ── VaultStorageAdapter implementation ───────────────────────────────────

  @override
  Future<void> uploadVaultObject(String sha256) async {
    // ── manifest.json (first-writer-wins) ────────────────────────────────
    final remoteManifest = File(_remoteManifestPath(sha256));
    if (!remoteManifest.existsSync()) {
      // No remote manifest yet — read from the local store's adapter and upload.
      final localManifestBytes = await _localStore.adapter.readFile(
        _localStore.manifestPath(sha256),
      );
      await remoteManifest.parent.create(recursive: true);
      await remoteManifest.writeAsBytes(localManifestBytes, flush: true);
    }
    // If remote manifest already exists, skip (first-writer-wins).

    // ── blob (idempotent) ────────────────────────────────────────────────
    final remoteBlob = File(_remoteBlobPath(sha256));
    if (!remoteBlob.existsSync()) {
      // Upload the local blob via the local store's adapter.
      final localBlobPath = _localStore.blobPath(sha256);
      if (await _localStore.adapter.fileExists(localBlobPath)) {
        final blobBytes = await _localStore.adapter.readFile(localBlobPath);
        await remoteBlob.parent.create(recursive: true);
        await remoteBlob.writeAsBytes(blobBytes, flush: true);
      }
    }
    // Remote blob already present: skip (content-identical by design).

    // ── tombstone.json (upload if present) ──────────────────────────────
    final localTombstonePath = _localStore.tombstonePath(sha256);
    if (await _localStore.adapter.fileExists(localTombstonePath)) {
      final remoteTombstone = File(_remoteTombstonePath(sha256));
      if (!remoteTombstone.existsSync()) {
        final tombstoneBytes = await _localStore.adapter.readFile(
          localTombstonePath,
        );
        await remoteTombstone.writeAsBytes(tombstoneBytes, flush: true);
      }
    }
  }

  @override
  Future<void> syncVaultMetadata(String sha256) async {
    // Download `manifest.json` (and `tombstone.json` if present) from the
    // sync vault to the local vault, creating a stub.
    //
    // Ordering requirement: the caller must have established a positive
    // `$vault:{sha256}` reference on this device **before** invoking this
    // method (typically via SSTable ingest, which carries `$vault` entries
    // authored by the originating device). [VaultStore.createStub] enforces
    // this contract and throws [StateError] if the ref is absent or zero.
    final remoteManifest = File(_remoteManifestPath(sha256));
    if (!remoteManifest.existsSync()) {
      throw StateError(
        'Cannot sync vault metadata for $sha256: '
        'manifest.json not found at ${remoteManifest.path}',
      );
    }

    // Read the remote manifest.
    final manifestBytes = await remoteManifest.readAsBytes();
    final manifest = VaultManifest.fromJsonString(utf8.decode(manifestBytes));

    // Delegate to VaultStore.createStub which checks the producer-side
    // contract (positive ref required) and writes manifest.json. Pass
    // encryption so the ref count guard can decode encrypted entries.
    await _localStore.createStub(
      manifest,
      kvStore: _kvStore,
      encryption: encryption,
    );

    // Sync tombstone.json if present on the remote.
    final remoteTombstone = File(_remoteTombstonePath(sha256));
    if (remoteTombstone.existsSync()) {
      final tombstoneBytes = await remoteTombstone.readAsBytes();
      await _localStore.adapter.writeFile(
        _localStore.tombstonePath(sha256),
        tombstoneBytes,
      );
    }
  }

  @override
  Future<void> hydrateVaultBlob(String sha256) async {
    // On-demand hydration write path:
    // 1. Verify the remote blob exists.
    if (!await vaultObjectExists(sha256)) {
      throw StateError(
        'Cannot hydrate vault blob for $sha256: '
        'object does not exist in the sync vault.',
      );
    }

    final remoteBlob = File(_remoteBlobPath(sha256));
    if (!remoteBlob.existsSync()) {
      throw StateError(
        'Cannot hydrate vault blob for $sha256: '
        'blob file not found at ${remoteBlob.path}.',
      );
    }

    final blobBytes = await remoteBlob.readAsBytes();

    // S-4 (2026-07-18 release-readiness review): verify content against its
    // claimed address *before* it ever reaches local disk under a trusted
    // final path. Whatever the sync folder holds would otherwise become the
    // local blob for that address, unconditionally — this is the check that
    // makes the vault an actually content-addressable store rather than one
    // in name only. `encryption` must match the provider active on this
    // database (see the class doc), so unwrapping here mirrors
    // `VaultStore.getBytes`.
    final plaintext = await EncryptionEnvelope.unwrap(blobBytes, encryption);
    final actual = VaultStore.computeSha256(plaintext);
    if (actual != sha256) {
      throw VaultContentMismatchException(expected: sha256, actual: actual);
    }

    // 2. Stage the verified (still envelope-wrapped) bytes via the local
    // store's adapter, at a unique per-run path.
    final stagingPath = _localStore.stagingPath(
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    // Write to staging using the local adapter (works for both memory and
    // native filesystem adapters).
    await _localStore.adapter.createDirectory(_localStore.stagingDir);
    await _localStore.adapter.writeFile(stagingPath, blobBytes);

    // 3. Rename staging file to the final blob path (atomic on POSIX for
    // native adapters; memory adapter rename is also atomic by construction).
    final finalBlobPath = _localStore.blobPath(sha256);
    await _localStore.adapter.createDirectory(_localStore.hashDir(sha256));
    await _localStore.adapter.renameFile(stagingPath, finalBlobPath);
  }

  @override
  Future<bool> vaultObjectExists(String sha256) async =>
      File(_remoteManifestPath(sha256)).existsSync();
}
