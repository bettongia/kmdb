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

/// @docImport 'sync_authenticator.dart';
/// @docImport 'default_sync_authenticator.dart';
library;

import 'dart:convert';

/// The six classes of sync-folder artefact authenticated by
/// [SyncAuthenticator] (0.10.01 WI-4 T1).
///
/// Each class derives its own HKDF sub-key from the sync-set root key (see
/// [DefaultSyncAuthenticator]), via a distinct `info` label of the form
/// `kmdb-sync-auth-{label}`. Domain separation means a MAC valid for one
/// class can never be replayed as another — e.g. a captured, genuine SSTable
/// envelope cannot be re-used to forge a `.consolidation-lease` file, even
/// though both ultimately derive from the same root key.
///
/// Three classes ([sstable], [hwm], [lease]) are applied automatically by the
/// core [SyncStorageAdapter] decorator (`SyncAuthenticatingAdapter`), which
/// classifies a remote path by its shape. The other three ([vaultBlob],
/// [vaultManifest], [vaultTombstone]) are applied manually at
/// `LocalDirectoryVaultAdapter`'s raw `dart:io` `File` I/O sites, which never
/// go through [SyncStorageAdapter] — see that class's doc comment.
enum SyncArtifactClass {
  /// A regular-flush or consolidation-output SSTable file
  /// (`{syncRoot}/sstables/*.sst`).
  sstable,

  /// A vault content blob (`{syncRoot}/vault/{prefix}/{suffix}/blob`).
  vaultBlob,

  /// A vault object manifest
  /// (`{syncRoot}/vault/{prefix}/{suffix}/manifest.json`).
  vaultManifest,

  /// A vault tombstone record
  /// (`{syncRoot}/vault/{prefix}/{suffix}/tombstone.json`).
  ///
  /// Assigned its own sub-key rather than folding under [vaultManifest]
  /// because it is a distinct, deletion-triggering artefact: a forged or
  /// suppressed tombstone drives vault garbage collection, so domain
  /// separation from the manifest is worth the extra label.
  vaultTombstone,

  /// A per-device high-water-mark file (`{syncRoot}/highwater/{deviceId}.hwm`).
  hwm,

  /// The consolidation coordination lease
  /// (`{syncRoot}/.consolidation-lease`).
  lease;

  /// The HKDF `info` label for this artefact class's sub-key, as UTF-8 bytes.
  ///
  /// Of the form `kmdb-sync-auth-{label}`, mirroring
  /// `AesGcmEncryptionProvider._kIndexTokenInfo`'s domain-separation pattern
  /// (`encryption_provider.dart`).
  List<int> get hkdfInfo => utf8.encode('kmdb-sync-auth-$_label');

  String get _label => switch (this) {
    SyncArtifactClass.sstable => 'sstable',
    SyncArtifactClass.vaultBlob => 'vault-blob',
    SyncArtifactClass.vaultManifest => 'vault-manifest',
    SyncArtifactClass.vaultTombstone => 'vault-tombstone',
    SyncArtifactClass.hwm => 'hwm',
    SyncArtifactClass.lease => 'lease',
  };
}
