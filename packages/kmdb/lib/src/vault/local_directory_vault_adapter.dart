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
import '../encryption/value_context.dart';
import '../engine/kvstore/kv_store.dart';
import '../sync/auth/sync_artifact_class.dart';
import '../sync/auth/sync_auth_envelope.dart';
import '../sync/auth/sync_authenticator.dart';
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
///
/// ## Sync authentication (0.10.01 WI-4 T1, Q3)
///
/// Vault artefacts never pass through a [SyncStorageAdapter] — this adapter
/// talks to the remote side with raw `dart:io` `File` I/O — so the core
/// `SyncAuthenticatingAdapter` decorator (which wraps
/// `SyncStorageAdapter.upload`/`download`) cannot reach them. Every read
/// and write of remote content in this class is therefore manually wrapped
/// with [SyncAuthEnvelope], across three artefact classes:
/// [SyncArtifactClass.vaultManifest], [SyncArtifactClass.vaultBlob], and
/// [SyncArtifactClass.vaultTombstone] (a separate class from the manifest —
/// a forged or suppressed tombstone drives vault garbage collection, so it
/// earns its own sub-key rather than folding under the manifest's).
///
/// [hydrateVaultBlob] has two *nested* envelopes with different lifetimes:
/// the sync-auth envelope (a channel property, stripped on arrival) and the
/// [EncryptionEnvelope] (stored-at-rest). The sync-auth envelope is always
/// stripped and verified **first** — see that method's doc comment for the
/// full ordering.
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
  /// [_authenticator] authenticates every remote vault artefact this device
  /// reads or writes (0.10.01 WI-4 T1) — see the class doc comment.
  LocalDirectoryVaultAdapter({
    required this._syncRoot,
    required this._localStore,
    required this._kvStore,
    required this._authenticator,
    this.encryption,
  });

  /// The base directory for all remote vault paths.
  final String _syncRoot;

  /// The local vault store providing path helpers and staging.
  final VaultStore _localStore;

  /// The local KV store, used to verify the `$vault` ref before stub creation.
  final KvStore _kvStore;

  /// Authenticates every remote vault artefact — see the class doc comment.
  final SyncAuthenticator _authenticator;

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

  // ── Sync-auth logical path helpers ────────────────────────────────────────
  //
  // Distinct from the _remote*Path helpers above: the MAC covers a path
  // *relative to the sync root*, not the full filesystem path (which
  // embeds _syncRoot — a local mount point that may differ across devices
  // for the same logical remote, e.g. a NAS mounted under a different local
  // path on each machine). This mirrors SyncAuthenticatingAdapter's use of
  // the bare paths SyncEngine/ConsolidationCoordinator/HighwaterMark pass to
  // SyncStorageAdapter, which likewise never include a filesystem root.

  /// Returns the logical (sync-root-relative) hash directory for [sha256].
  String _logicalHashDir(String sha256) {
    final prefix = sha256.substring(0, 2);
    final suffix = sha256.substring(2);
    return 'vault/$prefix/$suffix';
  }

  /// Returns the logical path of the `manifest.json` for [sha256].
  String _logicalManifestPath(String sha256) =>
      '${_logicalHashDir(sha256)}/manifest.json';

  /// Returns the logical path of the `blob` file for [sha256].
  String _logicalBlobPath(String sha256) => '${_logicalHashDir(sha256)}/blob';

  /// Returns the logical path of the `tombstone.json` for [sha256].
  String _logicalTombstonePath(String sha256) =>
      '${_logicalHashDir(sha256)}/tombstone.json';

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
      final enveloped = await SyncAuthEnvelope.wrap(
        localManifestBytes,
        _authenticator,
        artifactClass: SyncArtifactClass.vaultManifest,
        relativePath: _logicalManifestPath(sha256),
      );
      await remoteManifest.parent.create(recursive: true);
      await remoteManifest.writeAsBytes(enveloped, flush: true);
    }
    // If remote manifest already exists, skip (first-writer-wins).

    // ── blob (idempotent) ────────────────────────────────────────────────
    final remoteBlob = File(_remoteBlobPath(sha256));
    if (!remoteBlob.existsSync()) {
      // Upload the local blob via the local store's adapter.
      final localBlobPath = _localStore.blobPath(sha256);
      if (await _localStore.adapter.fileExists(localBlobPath)) {
        final blobBytes = await _localStore.adapter.readFile(localBlobPath);
        final enveloped = await SyncAuthEnvelope.wrap(
          blobBytes,
          _authenticator,
          artifactClass: SyncArtifactClass.vaultBlob,
          relativePath: _logicalBlobPath(sha256),
        );
        await remoteBlob.parent.create(recursive: true);
        await remoteBlob.writeAsBytes(enveloped, flush: true);
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
        final enveloped = await SyncAuthEnvelope.wrap(
          tombstoneBytes,
          _authenticator,
          artifactClass: SyncArtifactClass.vaultTombstone,
          relativePath: _logicalTombstonePath(sha256),
        );
        await remoteTombstone.writeAsBytes(enveloped, flush: true);
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

    // Read and authenticate the remote manifest (0.10.01 WI-4 T1) — a
    // forged or tampered manifest must be rejected before its content ever
    // drives VaultStore.createStub, not merely before it lands on disk.
    final rawManifestBytes = await remoteManifest.readAsBytes();
    final manifestBytes = await SyncAuthEnvelope.unwrap(
      rawManifestBytes,
      _authenticator,
      artifactClass: SyncArtifactClass.vaultManifest,
      relativePath: _logicalManifestPath(sha256),
    );
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
      final rawTombstoneBytes = await remoteTombstone.readAsBytes();
      final tombstoneBytes = await SyncAuthEnvelope.unwrap(
        rawTombstoneBytes,
        _authenticator,
        artifactClass: SyncArtifactClass.vaultTombstone,
        relativePath: _logicalTombstonePath(sha256),
      );
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

    final rawBlobBytes = await remoteBlob.readAsBytes();

    // ## Two-envelope ordering (0.10.01 WI-4 T1, Q3)
    //
    // There are two nested envelopes with different lifetimes, and the
    // order below is deliberate:
    // 1. Strip + verify the sync-auth envelope FIRST — it is a channel
    //    property (this device's proof that a sync-set-key holder produced
    //    these bytes), stripped immediately on arrival. A bad/missing MAC
    //    throws SyncAuthException here, before anything below ever runs —
    //    an unauthenticated blob must never reach the encryption-unwrap or
    //    content-address check, let alone local disk.
    // 2. THEN EncryptionEnvelope.unwrap — a stored-at-rest property; the
    //    plaintext extracted here is what the sha256 check verifies.
    // 3. THEN the sha256 content-address check (S-4).
    // 4. THEN stage the still-EncryptionEnvelope-wrapped bytes and rename —
    //    the *sync-auth* envelope is never staged/persisted locally (it is
    //    channel-only), but the encryption envelope is (it is the at-rest
    //    format `VaultStore.getBytes` expects to unwrap later).
    final blobBytes = await SyncAuthEnvelope.unwrap(
      rawBlobBytes,
      _authenticator,
      artifactClass: SyncArtifactClass.vaultBlob,
      relativePath: _logicalBlobPath(sha256),
    );

    // S-4 (2026-07-18 release-readiness review): verify content against its
    // claimed address *before* it ever reaches local disk under a trusted
    // final path. Whatever the sync folder holds would otherwise become the
    // local blob for that address, unconditionally — this is the check that
    // makes the vault an actually content-addressable store rather than one
    // in name only. `encryption` must match the provider active on this
    // database (see the class doc), so unwrapping here mirrors
    // `VaultStore.getBytes`.
    final plaintext = await EncryptionEnvelope.unwrap(
      blobBytes,
      encryption,
      context: ValueContext.vaultBlob(sha256),
    );
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
