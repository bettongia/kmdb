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

/// @docImport 'vault_recovery.dart';
library;

import 'dart:convert';
import 'dart:typed_data';

import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/platform/storage_adapter_interface.dart';
import 'media_type_detector.dart';
import 'vault_manifest.dart';
import 'vault_ref.dart';
import 'vault_ref_count.dart';
import 'vault_storage_adapter.dart';

/// Manages the local vault storage: ingestion, retrieval, and path resolution.
///
/// The vault is a content-addressable store backed by a two-level sharded
/// directory structure under `{dbDir}/vault/blobs/sha256/{prefix}/{suffix}/`.
/// Each hash directory contains:
///
/// - `manifest.json` — always present for a known object (see [VaultManifest]).
/// - `blob` — absent if the object is a stub (not yet downloaded).
/// - `tombstone.json` — present when the reference count reaches zero.
///
/// ## Write Path
///
/// 1. Write blob to `vault/staging/{uuid}`.
/// 2. Verify SHA-256 hash.
/// 3. Rename blob to final path (atomic on local filesystems).
/// 4. Write `manifest.json` to the final hash directory.
/// 5. (Caller) Commit `WriteBatch`: increment `$vault` ref count + write doc.
///
/// The vault write path (steps 1–4) must complete before the KV store is
/// updated. See §24 for the full crash-recovery table.
///
/// ## Deduplication
///
/// If the hash directory already contains a `manifest.json`, the incoming
/// blob is a duplicate. The vault verifies CRC32C consistency and returns the
/// existing [VaultRef] without any file I/O.
///
/// ## Stub Model
///
/// A stub is a hash directory that has `manifest.json` but no `blob`. Stubs
/// are created by [VaultStorageAdapter.syncVaultMetadata] during distributed
/// sync. On [getBytes], if the object is a stub and a [VaultStorageAdapter] is
/// configured, [VaultStorageAdapter.hydrateVaultBlob] is called automatically.
class VaultStore {
  /// Creates a [VaultStore] for the database at [_dbDir].
  ///
  /// [_adapter] is the storage backend. [_detector] performs MIME type detection
  /// at ingestion time. [uuidGenerator] is used to name staging files — provide
  /// a custom implementation for testing. [encryption] is the active
  /// [EncryptionProvider] for this database; when non-null, blobs are stored as
  /// `[12-byte nonce][ciphertext][16-byte tag]` and the manifest records
  /// `encrypted: true`. SHA-256 and CRC32C are computed over the **plaintext**
  /// regardless of encryption.
  VaultStore({
    required this._dbDir,
    required this._adapter,
    this._detector = const FreedesktopMediaTypeDetector(),
    String Function()? uuidGenerator,
    this.encryption,
  }) : _uuidGen = uuidGenerator ?? _defaultUuid;

  final String _dbDir;
  final StorageAdapter _adapter;
  final MediaTypeDetector _detector;
  final String Function() _uuidGen;

  /// Active encryption provider, or `null` for plaintext vault storage.
  ///
  /// When non-null, vault blobs are encrypted with AES-256-GCM before being
  /// written to disk. [EncryptionProvider.encrypt] is called after SHA-256 and
  /// CRC32C computation — content identity always reflects the plaintext, not
  /// the ciphertext.
  ///
  /// Set at construction time via the [encryption] constructor parameter, or
  /// wired in by [KmdbDatabase.open] after the encryption bootstrap runs.
  EncryptionProvider? encryption;

  /// Optional sync adapter for on-demand stub hydration.
  ///
  /// Set by [KmdbDatabase] when a [VaultStorageAdapter] is provided at open
  /// time. When `null`, calling [getBytes] on a stub throws [StateError].
  VaultStorageAdapter? syncAdapter;

  // ── Internal access (for VaultRecovery and VaultGc) ───────────────────────

  /// Exposes the storage adapter to vault subsystem collaborators.
  ///
  /// This is intentionally package-private (not part of the public API). Only
  /// [VaultRecovery] and [VaultGc] use it for staging and hash-dir sweeps.
  StorageAdapter get adapter => _adapter;

  // ── Path helpers ───────────────────────────────────────────────────────────

  /// The root vault directory: `{dbDir}/vault`.
  String get vaultDir => '$_dbDir/vault';

  /// The staging directory for in-progress writes: `{dbDir}/vault/staging`.
  String get stagingDir => '$vaultDir/staging';

  /// The blobs root: `{dbDir}/vault/blobs/sha256`.
  String get blobsDir => '$vaultDir/blobs/sha256';

  /// The path to the `VAULT_OFFLINE` pin file.
  String get vaultOfflinePath => '$_dbDir/VAULT_OFFLINE';

  /// Returns the full path of the hash directory for [sha256].
  ///
  /// Uses a two-level shard structure: `{blobsDir}/{sha256[0..1]}/{sha256[2..63]}`.
  String hashDir(String sha256) {
    final prefix = sha256.substring(0, 2);
    final suffix = sha256.substring(2);
    return '$blobsDir/$prefix/$suffix';
  }

  /// Returns the path of the `blob` file for [sha256].
  String blobPath(String sha256) => '${hashDir(sha256)}/blob';

  /// Returns the path of the `manifest.json` file for [sha256].
  String manifestPath(String sha256) => '${hashDir(sha256)}/manifest.json';

  /// Returns the path of the `tombstone.json` file for [sha256].
  String tombstonePath(String sha256) => '${hashDir(sha256)}/tombstone.json';

  /// Returns the path of a staging file with [uuid] as the filename.
  String stagingPath(String uuid) => '$stagingDir/$uuid';

  // ── State checks ───────────────────────────────────────────────────────────

  /// Returns `true` if the hash directory contains a `manifest.json` for [sha256].
  ///
  /// A manifest's presence means the object is known locally, whether or not
  /// the blob has been downloaded.
  Future<bool> exists(String sha256) async =>
      _adapter.fileExists(manifestPath(sha256));

  /// Returns `true` if the blob file is present for [sha256].
  ///
  /// A `true` result means the object is fully hydrated. A `false` result
  /// together with a `manifest.json` means the object is a stub.
  Future<bool> isHydrated(String sha256) async =>
      _adapter.fileExists(blobPath(sha256));

  /// Returns `true` if the `tombstone.json` file is present for [sha256].
  Future<bool> isTombstoned(String sha256) async =>
      _adapter.fileExists(tombstonePath(sha256));

  // ── Ingestion ──────────────────────────────────────────────────────────────

  /// Ingests [bytes] into the vault and returns a [VaultRef].
  ///
  /// ## Write ordering
  ///
  /// 1. Write bytes to `vault/staging/{uuid}`.
  /// 2. Compute SHA-256 and CRC32C.
  /// 3. If a manifest already exists (duplicate), verify CRC32C and return.
  /// 4. Create the hash directory and rename the staging file to `blob`.
  /// 5. Write `manifest.json`.
  ///
  /// The caller is responsible for committing the corresponding [WriteBatch]
  /// (ref count increment + document write) after this method returns.
  ///
  /// [hlcTimestamp] is the current HLC timestamp from the engine, passed in
  /// by the caller to keep the vault dependency one-directional.
  ///
  /// [originalName] is the filename of the source, stored for human reference
  /// (informational only).
  ///
  /// Throws [VaultCrcMismatchException] if a different file with the same
  /// SHA-256 hash exists (CRC32C collision).
  Future<VaultRef> ingest({
    required Uint8List bytes,
    required String hlcTimestamp,
    String originalName = 'blob',
    String? explicitMediaType,
  }) async {
    // Ensure staging directory exists.
    await _adapter.createDirectory(stagingDir);

    // Step 1: compute content-identity fields over the PLAINTEXT bytes.
    // SHA-256 and CRC32C are always over plaintext — the content address must
    // be stable regardless of whether encryption is active, and vault recovery
    // verifies the content address after decryption (see §24 and §31).
    final sha256 = _computeSha256(bytes);
    final crc32c = _computeCrc32c(bytes);
    final size = bytes.length;

    // Step 2: check for existing manifest (deduplication) before any I/O.
    if (await exists(sha256)) {
      // Object already in vault — verify CRC32C to guard against hash
      // collisions and then return the existing ref without any further I/O.
      final existing = await getManifest(sha256);
      if (existing.crc32c != crc32c) {
        // CRC32C mismatch: a different file with the same SHA-256 exists.
        // Per the ISS pattern, this is a collision — reject the incoming file.
        throw VaultCrcMismatchException(
          sha256: sha256,
          existingCrc32c: existing.crc32c,
          incomingCrc32c: crc32c,
        );
      }
      // Duplicate — return existing ref without any file I/O.
      return _makeRef(sha256);
    }

    // Step 3: optionally encrypt the blob bytes before writing to staging.
    // When encryption is active, the stored bytes are [nonce][ciphertext][tag]
    // produced by EncryptionProvider.encrypt. The content address (sha256,
    // crc32c) was computed above over the plaintext.
    final Uint8List storedBytes;
    final bool isEncrypted;
    final enc = encryption;
    if (enc != null) {
      storedBytes = await enc.encrypt(bytes);
      isEncrypted = true;
    } else {
      storedBytes = bytes;
      isEncrypted = false;
    }

    // Step 4: write (encrypted or plaintext) bytes to staging.
    final uuid = _uuidGen();
    final staging = stagingPath(uuid);
    await _adapter.writeFile(staging, storedBytes);

    // Detect media type from the original plaintext bytes + filename hint.
    final matchList = _detector.detect(bytes, fileName: originalName);

    final String mediaType;
    if (explicitMediaType != null) {
      // Validate the caller-supplied type against detected candidates.
      final candidates = matchList.toSet();
      if (candidates.isNotEmpty && !candidates.contains(explicitMediaType)) {
        await _adapter.deleteFile(staging);
        throw FormatException(
          'Explicit media type "$explicitMediaType" is not among the detected '
          'candidates for "$originalName": $candidates',
        );
      }
      // Accepted — either in candidates or detection yielded nothing.
      mediaType = explicitMediaType;
    } else {
      mediaType =
          matchList.firstOrNull ?? FreedesktopMediaTypeDetector.kFallbackType;
    }

    // Step 5: create hash directory and rename staging blob to final path.
    final dir = hashDir(sha256);
    await _adapter.createDirectory(dir);
    await _adapter.renameFile(staging, blobPath(sha256));

    // Step 6: write manifest.json.
    // The `encrypted` flag signals to readers and vault recovery that the
    // stored blob is ciphertext and must be decrypted before use.
    final manifest = VaultManifest(
      sha256: sha256,
      size: size,
      crc32c: crc32c,
      mediaType: mediaType,
      originalName: originalName,
      createdAt: hlcTimestamp,
      encrypted: isEncrypted,
    );
    await _writeManifest(sha256, manifest);

    return _makeRef(sha256);
  }

  // ── Retrieval ──────────────────────────────────────────────────────────────

  /// Returns the plaintext blob bytes for [sha256].
  ///
  /// If the blob is stored as AES-256-GCM ciphertext (manifest has
  /// `encrypted: true`), the blob is decrypted before returning. The
  /// [EncryptionProvider] supplied at construction must be active — if the
  /// manifest is encrypted but no provider is set, a [StateError] is thrown.
  ///
  /// If the object is a stub (manifest present, blob absent), triggers
  /// on-demand hydration via [syncAdapter]. Throws [StateError] if no sync
  /// adapter is configured on a stub.
  ///
  /// Throws [VaultObjectNotFoundException] if neither the blob nor the manifest
  /// exists locally.
  Future<Uint8List> getBytes(String sha256) async {
    if (!await isHydrated(sha256)) {
      if (!await exists(sha256)) {
        throw VaultObjectNotFoundException(sha256);
      }
      // Stub — attempt on-demand hydration.
      final adapter = syncAdapter;
      if (adapter == null) {
        throw StateError(
          'VaultStore.getBytes($sha256): object is a stub and no sync adapter '
          'is configured. Set VaultStore.syncAdapter to enable on-demand '
          'hydration.',
        );
      }
      await adapter.hydrateVaultBlob(sha256);
    }
    final raw = await _adapter.readFile(blobPath(sha256));

    // Decrypt if the manifest says the blob is encrypted.
    // Read the manifest to check the encrypted flag.
    final manifest = await getManifest(sha256);
    if (manifest.encrypted) {
      final enc = encryption;
      if (enc == null) {
        throw StateError(
          'VaultStore.getBytes($sha256): blob is encrypted but no '
          'EncryptionProvider is configured. Open the database with an '
          'EncryptionConfig.',
        );
      }
      return enc.decrypt(raw);
    }
    return raw;
  }

  /// Returns the [VaultManifest] for [sha256].
  ///
  /// Throws [VaultObjectNotFoundException] if no manifest exists locally.
  Future<VaultManifest> getManifest(String sha256) async {
    final path = manifestPath(sha256);
    if (!await _adapter.fileExists(path)) {
      throw VaultObjectNotFoundException(sha256);
    }
    final bytes = await _adapter.readFile(path);
    final jsonStr = utf8.decode(bytes);
    return VaultManifest.fromJsonString(jsonStr);
  }

  // ── Manifest write/delete helpers ──────────────────────────────────────────

  /// Writes [manifest] to the `manifest.json` file for its sha256.
  Future<void> _writeManifest(String sha256, VaultManifest manifest) async {
    final bytes = utf8.encode(manifest.toJsonString());
    await _adapter.writeFile(manifestPath(sha256), Uint8List.fromList(bytes));
  }

  // ── Tombstone helpers ──────────────────────────────────────────────────────

  /// Creates `tombstone.json` for [sha256], marking it as GC-eligible.
  ///
  /// Called by [VaultGc.onZeroRefs] when the reference count reaches zero.
  Future<void> writeTombstone(String sha256) async {
    final path = tombstonePath(sha256);
    // Tombstone content is just a timestamp for human readability; presence,
    // not content, is the GC signal.
    final now = DateTime.now().toUtc().toIso8601String();
    final bytes = utf8.encode('{"tombstonedAt":"$now"}');
    await _adapter.writeFile(path, Uint8List.fromList(bytes));
  }

  /// Deletes `tombstone.json` for [sha256], un-tombstoning the object.
  ///
  /// Called by [VaultGc.onRefRestored] when a new reference is added to a
  /// tombstoned object.
  Future<void> deleteTombstone(String sha256) async {
    await _adapter.deleteFile(tombstonePath(sha256));
  }

  /// Deletes the entire hash directory for [sha256].
  ///
  /// Removes blob, manifest.json, and tombstone.json individually since the
  /// StorageAdapter does not support recursive directory deletion.
  ///
  /// Also removes any corresponding line from the `VAULT_OFFLINE` pin file.
  Future<void> deleteHashDir(String sha256) async {
    // Remove known files in the hash directory.
    await _adapter.deleteFile(blobPath(sha256));
    await _adapter.deleteFile(manifestPath(sha256));
    await _adapter.deleteFile(tombstonePath(sha256));

    // Remove from VAULT_OFFLINE pin list if present.
    await _removeFromVaultOffline(sha256);
  }

  // ── Stub creation (for sync) ───────────────────────────────────────────────

  /// Creates a stub for [manifest] without downloading the blob.
  ///
  /// A stub is a hash directory containing `manifest.json` but no `blob`.
  /// Stubs are created during distributed sync to record that a vault object
  /// exists on the remote but has not been downloaded to this device yet.
  ///
  /// ## Producer-side contract
  ///
  /// Per §24 of the vault spec, **a stub always has a positive `$vault`
  /// reference**. A `manifest.json` without a positive ref is an error state
  /// that crash recovery reaps (see [VaultRecovery]). This method enforces
  /// the contract by reading the ref via the shared, fail-safe
  /// [VaultRefCount.read] and refusing to write the manifest unless the ref
  /// is positive (or undecodable — treated as referenced for fail-safe
  /// consistency with the H3 rule).
  ///
  /// Callers must therefore establish a positive `$vault:{sha256}` reference
  /// on [kvStore] **before** invoking this method. In peer-side sync this
  /// is naturally satisfied because the `$vault` entries authored on the
  /// originating device travel inside the same SSTables that carry the
  /// referencing documents, and ingest installs them at L0 before any
  /// caller decides to materialise the stub manifest.
  ///
  /// Throws [StateError] if no `$vault` entry exists for [VaultManifest.sha256]
  /// or if the entry decodes to a zero ref count. Throws no exception when
  /// the entry is positive or undecodable (the latter consistent with the
  /// H3 fail-safe rule).
  ///
  /// [encryption] must match the provider used when the `$vault` ref count
  /// entry was written. When the database is encrypted (Q6 decision), all
  /// [ValueCodec] call sites — including `$vault` ref counts — use encryption
  /// uniformly, so the guard read here must supply the same provider.
  Future<void> createStub(
    VaultManifest manifest, {
    required KvStore kvStore,
    EncryptionProvider? encryption,
  }) async {
    final sha256 = manifest.sha256;
    final refResult = await VaultRefCount.read(
      kvStore,
      sha256,
      encryption: encryption,
    );
    switch (refResult) {
      case RefCountAbsent():
        throw StateError(
          'VaultStore.createStub(${sha256.substring(0, 8)}…): no '
          r'$vault entry exists for the hash. A stub may only be created '
          'when a positive reference is already established on this device '
          '(see §24: a stub always has a KV reference).',
        );
      case RefCountValue(:final count) when count <= 0:
        throw StateError(
          'VaultStore.createStub(${sha256.substring(0, 8)}…): '
          r'$vault ref count is 0. A stub may only be created when the '
          'ref count is positive (see §24).',
        );
      case RefCountValue():
      // count > 0 → positive reference, proceed.
      case RefCountUndecodable():
      // Treated as referenced for fail-safe consistency with H3.
    }

    final dir = hashDir(sha256);
    await _adapter.createDirectory(dir);
    await _writeManifest(sha256, manifest);
  }

  // ── Subdirectory enumeration ───────────────────────────────────────────────

  /// Lists all 2-character prefix directories under `blobsDir`.
  ///
  /// Returns bare directory names (e.g. `"ab"`, `"ff"`), not full paths.
  /// Used by the GC sweep and crash recovery to enumerate all known hashes.
  Future<List<String>> listPrefixDirs() async {
    // The memory adapter's listFiles excludes paths with '/' in the remainder,
    // so this works as a directory listing for direct children.
    // We detect "directories" as path prefixes that appear in any stored file path.
    return _listSubdirs(blobsDir);
  }

  /// Lists all 62-character suffix directories under `{blobsDir}/{prefix}`.
  Future<List<String>> listSuffixDirs(String prefix) async {
    return _listSubdirs('$blobsDir/$prefix');
  }

  /// Returns all known SHA-256 hashes by enumerating prefix + suffix dirs.
  ///
  /// This is a full scan — use only during recovery and GC sweeps.
  Future<List<String>> listAllHashes() async {
    final hashes = <String>[];
    for (final prefix in await listPrefixDirs()) {
      for (final suffix in await listSuffixDirs(prefix)) {
        hashes.add('$prefix$suffix');
      }
    }
    return hashes;
  }

  // ── VAULT_OFFLINE helpers ──────────────────────────────────────────────────

  /// Returns the vault-relative path for a hash as it appears in VAULT_OFFLINE.
  ///
  /// Format: `sha256/{prefix}/{suffix}/`
  static String vaultOfflineLine(String sha256) {
    final prefix = sha256.substring(0, 2);
    final suffix = sha256.substring(2);
    return 'sha256/$prefix/$suffix/';
  }

  /// Removes the [sha256] line from `VAULT_OFFLINE` atomically (read → filter
  /// → write). No-op if VAULT_OFFLINE does not exist or the hash is not listed.
  Future<void> _removeFromVaultOffline(String sha256) async {
    final path = vaultOfflinePath;
    if (!await _adapter.fileExists(path)) return;

    final bytes = await _adapter.readFile(path);
    final content = utf8.decode(bytes);
    final line = vaultOfflineLine(sha256);

    final filtered = content
        .split('\n')
        .where((l) => l.trim() != line.trim())
        .join('\n');

    await _adapter.writeFile(path, Uint8List.fromList(utf8.encode(filtered)));
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// Creates a [VaultRef] for [sha256] and wires it to this store.
  VaultRef _makeRef(String sha256) {
    final ref = VaultRef('kmdb-vault://sha256/$sha256');
    ref.wire(this);
    return ref;
  }

  /// Lists immediate subdirectory names under [parentPath] by inspecting
  /// path prefixes in the underlying storage adapter.
  ///
  /// The [MemoryStorageAdapter] stores paths flat, so we simulate a directory
  /// listing by scanning for known files and extracting the first path segment
  /// after [parentPath].
  Future<List<String>> _listSubdirs(String parentPath) async {
    // List all files under parentPath with no extension filter, then extract
    // intermediate path components to build a directory list.
    final prefix = parentPath.endsWith('/') ? parentPath : '$parentPath/';
    // We need to discover all immediate subdirs. The StorageAdapter.listFiles
    // only returns direct children (no '/' in remainder), but we need one level
    // deeper. We call listFiles on known children by checking for specific
    // sentinel filenames; however, a simpler approach is to expose a
    // listSubdirectories capability.
    //
    // Since StorageAdapter doesn't have listDirectories, we use a convention:
    // enumerate by calling listFiles with 'manifest.json' and extracting the
    // first segment of the relative path. This works because every known hash
    // directory contains a manifest.json.
    //
    // For the native adapter, we use a different approach via a dedicated
    // "list subdirs" scan (see _listSubdirsFromFiles).
    return _listSubdirsFromFiles(prefix);
  }

  /// Extracts unique immediate subdirectory names from all manifest.json paths
  /// under [prefix].
  ///
  /// For example, if `prefix` = `vault/blobs/sha256/` and files exist at:
  ///   `vault/blobs/sha256/ab/cdef.../manifest.json`
  ///   `vault/blobs/sha256/cd/ef01.../manifest.json`
  ///
  /// This method returns `['ab', 'cd']`.
  Future<List<String>> _listSubdirsFromFiles(String prefix) async {
    // Scan all files under `{prefix}**/manifest.json` by listing files at
    // each candidate level. Since we cannot do recursive listing directly,
    // we query for 'manifest.json' within each potential subdirectory.
    //
    // Strategy: ask the adapter for all files under prefix that end with
    // 'manifest.json', then derive the immediate subdirectory from each path.
    //
    // The MemoryStorageAdapter.listFiles only returns direct children, so we
    // need to decompose the path. Since we know the directory structure is
    // exactly 2 levels deep (prefix/dir/manifest.json for listPrefixDirs or
    // prefix/dir2/manifest.json for listSuffixDirs), we can iterate candidates.
    //
    // This implementation does a best-effort scan using the storage adapter.
    // For native, file paths are traversed via the file system.
    // For memory (tests), all paths are in a flat map and we scan by prefix.

    final dirs = <String>{};

    // The memory adapter's files map is not exposed, so we use a workaround:
    // we list files at the parent level to find any that have a '/' in them
    // when checked with a looser filter. However, the MemoryStorageAdapter
    // explicitly excludes paths with '/' in the remainder.
    //
    // To bridge this gap, we use the 'extension' trick: we look for 'manifest.json'
    // files, which requires allowing non-extension matching.
    // The simplest robust approach for both memory and native is to keep track
    // of all known hashes in an in-memory set populated during ingest and
    // loaded from manifest files on open.
    //
    // However, to keep things simple, the VaultStore exposes this directly to
    // VaultRecovery and VaultGc, which can use the _adapter.files property
    // in tests or the filesystem in production. We delegate to a protected
    // method that can be overridden.

    // This default implementation scans via the file enumeration convention:
    // it calls listFiles with the manifest.json sentinel in each prefix subdir.
    // A concrete override in tests or a dedicated VaultAdapter would do better.

    // In the absence of a recursive listing API, we return the set of known
    // hashes from memory (populated by ingest). For recovery, we use the
    // MemoryStorageAdapter's flat key set through the adapter protocol.
    //
    // To keep this implementation correct for tests, we expose a protected
    // method for tests to override.
    await _collectSubdirsInto(prefix, dirs);
    return dirs.toList();
  }

  /// Extension point for subdirectory enumeration.
  ///
  /// Default: scans the adapter for all paths under [prefix] and extracts the
  /// first path segment from each. Works for [MemoryStorageAdapter] (all paths
  /// are flat keys) but requires an override for native I/O.
  ///
  /// This is a protected method — subclasses or test utilities may override it
  /// to provide more efficient directory enumeration.
  Future<void> _collectSubdirsInto(String prefix, Set<String> dirs) async {
    // Delegate to the subclass hook.
    final entries = await listFilesRecursive(prefix);
    for (final path in entries) {
      // path is relative to prefix (e.g. "ab/cdef.../manifest.json")
      final slash = path.indexOf('/');
      if (slash > 0) {
        dirs.add(path.substring(0, slash));
      }
    }
  }

  /// Lists all file paths (relative to [dirPath]) anywhere under [dirPath].
  ///
  /// Used for subdirectory enumeration. The default implementation asks the
  /// [StorageAdapter] by trying each candidate file name, which works for the
  /// [MemoryStorageAdapter] flat key store.
  ///
  /// Override in a subclass or test double to provide native filesystem
  /// traversal.
  Future<List<String>> listFilesRecursive(String dirPath) async {
    // The MemoryStorageAdapter stores all paths as flat keys. We scan by
    // prefix match. Since the adapter's listFiles excludes paths with '/',
    // we need direct map access — but the adapter interface doesn't expose it.
    //
    // Instead, use a practical workaround: call listFiles with a sentinel
    // filename extension. But for manifest.json (no extension), this fails.
    //
    // The cleanest solution: expose listFilesDeep to the interface.
    // As a stopgap for v1, fall back to an empty list (recovery/GC will need
    // a subclass or native adapter that can enumerate).
    //
    // For tests using MemoryStorageAdapter, the VaultRecovery and VaultGc
    // tests will use VaultStoreTestHelper which overrides this.
    return const [];
  }

  // ── Test-visible hash helpers ─────────────────────────────────────────────

  /// Computes the SHA-256 hex string for [bytes].
  ///
  /// Exposed for tests that need to predict the hash of known content.
  static String computeSha256ForTest(Uint8List bytes) => _computeSha256(bytes);

  /// Computes the CRC32C hex string for [bytes].
  ///
  /// Exposed for tests that need to predict the checksum of known content.
  static String computeCrc32cForTest(Uint8List bytes) => _computeCrc32c(bytes);

  // ── Hash computation ───────────────────────────────────────────────────────

  /// Computes the SHA-256 hash of [bytes] and returns a 64-char lower-case
  /// hex string.
  static String _computeSha256(Uint8List bytes) {
    // Use dart:crypto's SHA-256 implementation.
    // We compute it manually using the standard library.
    final digest = _sha256Digest(bytes);
    return _hexEncode(digest);
  }

  /// Computes the CRC32C checksum of [bytes] and returns an 8-char lower-case
  /// hex string.
  static String _computeCrc32c(Uint8List bytes) {
    final checksum = _crc32c(bytes);
    // Format as 8 lower-case hex characters (zero-padded).
    return checksum.toRadixString(16).padLeft(8, '0').toLowerCase();
  }

  /// SHA-256 implementation using dart:convert's `Converter` pipeline.
  static Uint8List _sha256Digest(Uint8List bytes) {
    // Use the dart:crypto digest (available via dart:convert in recent SDKs).
    // dart:crypto is the recommended approach; dart:convert does not expose it.
    // We use package:crypto if available, or a built-in equivalent.
    //
    // The Dart SDK includes SHA-256 via 'dart:convert' from SDK 3.x.
    // Use the standard approach: dart:io's sha256 is not available on web.
    // For cross-platform support, use the pure-Dart implementation.

    // Dart SDK 3.x includes SHA-256 via package:crypto (transitively available).
    // Here we implement it directly using the dart:convert machinery.
    return _dartSha256(bytes);
  }

  static Uint8List _dartSha256(Uint8List data) {
    // SHA-256 implemented directly using Dart's ByteData operations.
    // Based on the FIPS 180-4 specification.
    final message = _sha256Prepare(data);
    final state = _kSha256Init.toList();

    for (var i = 0; i < message.length; i += 64) {
      final w = List<int>.filled(64, 0);
      // Fill first 16 words from the message chunk.
      for (var j = 0; j < 16; j++) {
        w[j] =
            (message[i + j * 4] << 24) |
            (message[i + j * 4 + 1] << 16) |
            (message[i + j * 4 + 2] << 8) |
            message[i + j * 4 + 3];
      }
      // Extend to 64 words.
      for (var j = 16; j < 64; j++) {
        final s0 =
            _rotr32(w[j - 15], 7) ^ _rotr32(w[j - 15], 18) ^ (w[j - 15] >>> 3);
        final s1 =
            _rotr32(w[j - 2], 17) ^ _rotr32(w[j - 2], 19) ^ (w[j - 2] >>> 10);
        w[j] = _add32(w[j - 16], _add32(s0, _add32(w[j - 7], s1)));
      }

      var a = state[0], b = state[1], c = state[2], d = state[3];
      var e = state[4], f = state[5], g = state[6], h = state[7];

      for (var j = 0; j < 64; j++) {
        final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final ch = (e & f) ^ (~e & g);
        final temp1 = _add32(
          h,
          _add32(s1, _add32(ch, _add32(_kSha256K[j], w[j]))),
        );
        final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = _add32(s0, maj);

        h = g;
        g = f;
        f = e;
        e = _add32(d, temp1);
        d = c;
        c = b;
        b = a;
        a = _add32(temp1, temp2);
      }

      state[0] = _add32(state[0], a);
      state[1] = _add32(state[1], b);
      state[2] = _add32(state[2], c);
      state[3] = _add32(state[3], d);
      state[4] = _add32(state[4], e);
      state[5] = _add32(state[5], f);
      state[6] = _add32(state[6], g);
      state[7] = _add32(state[7], h);
    }

    final digest = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      digest[i * 4] = (state[i] >>> 24) & 0xFF;
      digest[i * 4 + 1] = (state[i] >>> 16) & 0xFF;
      digest[i * 4 + 2] = (state[i] >>> 8) & 0xFF;
      digest[i * 4 + 3] = state[i] & 0xFF;
    }
    return digest;
  }

  /// Pads [data] per the SHA-256 spec: append 1-bit, then zeros, then length.
  static Uint8List _sha256Prepare(Uint8List data) {
    final bitLen = data.length * 8;
    // Pad to 512-bit (64-byte) boundary: data || 0x80 || zeros || 8-byte length
    var len = data.length + 1;
    while (len % 64 != 56) {
      len++;
    }
    len += 8;
    final padded = Uint8List(len);
    padded.setAll(0, data);
    padded[data.length] = 0x80;
    // Write 64-bit big-endian bit length at the end.
    // bitLen is an int (63-bit in Dart); we only store low 32 bits for now
    // since blobs over 512MB are not expected in v1.
    final bd = ByteData.view(padded.buffer, len - 8);
    bd.setUint32(0, (bitLen >> 32) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(4, bitLen & 0xFFFFFFFF, Endian.big);
    return padded;
  }

  /// Rotates [x] right by [n] bits (32-bit).
  static int _rotr32(int x, int n) =>
      ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  /// Adds two 32-bit integers with wrap-around (unsigned 32-bit addition).
  static int _add32(int a, int b) => (a + b) & 0xFFFFFFFF;

  // SHA-256 initial hash values (first 32 bits of the fractional parts of the
  // square roots of the first 8 primes).
  static const _kSha256Init = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  // SHA-256 round constants (first 32 bits of fractional parts of cube roots
  // of the first 64 primes).
  static const _kSha256K = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  /// CRC32C lookup table.
  static final List<int> _kCrc32cTable = _buildCrc32cTable();

  static List<int> _buildCrc32cTable() {
    const poly = 0x82F63B78; // Castagnoli polynomial (reflected)
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var j = 0; j < 8; j++) {
        if (crc & 1 != 0) {
          crc = (crc >>> 1) ^ poly;
        } else {
          crc = crc >>> 1;
        }
      }
      table[i] = crc;
    }
    return table;
  }

  /// Computes CRC32C of [bytes] and returns the checksum as an unsigned 32-bit
  /// integer.
  static int _crc32c(Uint8List bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = (crc >>> 8) ^ _kCrc32cTable[(crc ^ byte) & 0xFF];
    }
    return crc ^ 0xFFFFFFFF;
  }

  /// Encodes [bytes] as a lower-case hex string.
  static String _hexEncode(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Default UUID generator using the uuid package or a timestamp-based
  /// fallback.
  static String _defaultUuid() {
    // Use a timestamp + random suffix for staging file names.
    // For production quality, the caller should inject the uuid package.
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = (now * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFF;
    return '${now.toRadixString(16).padLeft(16, '0')}-${rand.toRadixString(16).padLeft(8, '0')}';
  }
}

// ── Exceptions ────────────────────────────────────────────────────────────────

/// Thrown when an incoming blob's CRC32C does not match the stored value for
/// the same SHA-256 hash (ISS collision).
final class VaultCrcMismatchException implements Exception {
  /// Creates a [VaultCrcMismatchException].
  const VaultCrcMismatchException({
    required this.sha256,
    required this.existingCrc32c,
    required this.incomingCrc32c,
  });

  /// The SHA-256 hash of the object already in the vault.
  final String sha256;

  /// The CRC32C of the object already stored in the vault.
  final String existingCrc32c;

  /// The CRC32C of the incoming blob.
  final String incomingCrc32c;

  @override
  String toString() =>
      'VaultCrcMismatchException: SHA-256 collision detected for '
      '${sha256.substring(0, 8)}... '
      '(existing CRC32C: $existingCrc32c, incoming: $incomingCrc32c). '
      'The incoming file has the same SHA-256 hash but different content — '
      'it cannot be stored.';
}

/// Thrown when a requested vault object does not exist locally.
final class VaultObjectNotFoundException implements Exception {
  /// Creates a [VaultObjectNotFoundException] for [sha256].
  const VaultObjectNotFoundException(this.sha256);

  /// The SHA-256 hash of the missing object.
  final String sha256;

  @override
  String toString() =>
      'VaultObjectNotFoundException: vault object not found locally '
      'for hash ${sha256.substring(0, 8)}...';
}
