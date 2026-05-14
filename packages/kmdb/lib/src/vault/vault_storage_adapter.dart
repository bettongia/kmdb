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

/// Abstract interface for vault distributed sync operations.
///
/// [VaultStorageAdapter] is a separate interface from `SyncStorageAdapter`,
/// maintaining a clean abstraction boundary. Most production implementations
/// provide both adapters together.
///
/// ## Conflict Avoidance
///
/// `blob` files have no conflict: two devices writing the same SHA-256 hash
/// produce identical bytes.
///
/// `manifest.json` files are semantically equivalent across devices (they
/// differ only in the `createdAt` timestamp). A **first-writer-wins** policy
/// is applied: [uploadVaultObject] checks whether `manifest.json` already
/// exists in the sync vault before uploading; if it does, the upload is skipped.
///
/// ## On-Demand Hydration
///
/// Devices receive stubs (metadata only) during normal sync. The `blob` is not
/// downloaded until the user requests the file or pins it. [hydrateVaultBlob]
/// performs the actual download.
abstract interface class VaultStorageAdapter {
  /// Uploads the full hash directory (`manifest.json` + `blob`) to the sync
  /// vault for [sha256].
  ///
  /// Applies first-writer-wins for `manifest.json`: checks for existence before
  /// uploading; skips the `manifest.json` upload if it is already present.
  /// The `blob` upload is always skipped if the remote blob already exists (blobs
  /// are content-identical across devices).
  ///
  /// Called by push/sync after a new file is ingested locally.
  Future<void> uploadVaultObject(String sha256);

  /// Downloads `manifest.json` (and `tombstone.json` if present) from the sync
  /// vault to the local vault for [sha256], creating a stub.
  ///
  /// Does not download the `blob`. Called during normal sync to propagate vault
  /// metadata to peer devices without transferring the full blob.
  Future<void> syncVaultMetadata(String sha256);

  /// Downloads the `blob` from the sync vault into local staging for hash
  /// verification, then renames it to the final path for [sha256].
  ///
  /// Implements the on-demand hydration write path:
  /// 1. Call [vaultObjectExists] to confirm the remote has the blob.
  /// 2. Write the blob to `vault/staging/{uuid}`.
  /// 3. Verify the SHA-256 hash.
  /// 4. Rename the staging file to the final `blob` path.
  ///
  /// Called when the user requests a stub's blob via [VaultStore.getBytes].
  Future<void> hydrateVaultBlob(String sha256);

  /// Returns `true` if the vault object (specifically its `manifest.json`)
  /// exists in the sync vault for [sha256].
  ///
  /// Used by [hydrateVaultBlob] before attempting a download, and internally
  /// by [uploadVaultObject] for the first-writer-wins check.
  Future<bool> vaultObjectExists(String sha256);
}
