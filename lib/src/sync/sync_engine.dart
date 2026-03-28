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
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/sstable/sstable_info.dart';
import '../engine/sstable/sstable_reader.dart';
import '../engine/util/hlc.dart';
import 'cloud/cloud_adapter.dart';
import 'consolidation_config.dart';
import 'consolidation_coordinator.dart';
import 'highwater.dart';

/// Coordinates push/pull synchronisation between a local [KvStore] and the
/// shared sync folder.
///
/// ## Sync folder layout
///
/// ```
/// {syncRoot}/
///   highwater/
///     {deviceId}.hwm      ← per-device high-water mark files
///   sstables/
///     *.sst               ← all SSTable files from all devices
///   .consolidation-lease  ← lease file for cross-device consolidation
/// ```
///
/// ## Push
///
/// 1. Flush the local memtable so all data is in SSTables.
/// 2. Identify local SSTables not yet present in the sync folder.
/// 3. Upload new SSTables.
/// 4. Update and upload the local high-water mark file.
///
/// ## Pull
///
/// 1. Read the local high-water mark.
/// 2. List all SSTables in the sync folder.
/// 3. For each SSTable from a different device: check if it is new (HLC
///    > recorded peer HWM).
/// 4. Download and ingest new SSTables into the local database.
/// 5. Update the high-water mark for each ingested peer.
///
/// ## Sync
///
/// [sync] is a convenience method that calls [push] then [pull].
///
/// ## Concurrency
///
/// All operations run synchronously on the calling isolate. The [KvStore]
/// must not have concurrent writes in progress during sync. Callers should
/// ensure this by suspending other writers for the duration of [sync].
///
/// ## Example
///
/// ```dart
/// final engine = SyncEngine(
///   store: store,
///   cloudAdapter: adapter,
///   localAdapter: localAdapter,
///   deviceId: 'a1b2c3d4',
///   dbDir: '/path/to/db',
///   syncRoot: 'kmdb-sync',
///   syncNamespaces: {'tasks', 'notes'},
/// );
/// await engine.sync();
/// ```
final class SyncEngine {
  /// Creates a [SyncEngine].
  ///
  /// [store] is the local [KvStore] instance. [cloudAdapter] accesses the
  /// shared sync folder. [localAdapter] accesses the local database directory.
  /// [deviceId] is the 8-character hex identifier for this device. [dbDir] is
  /// the local database root directory (contains the `sst/` subdirectory).
  /// [syncRoot] is the root path in the cloud adapter. [syncNamespaces] is the
  /// set of user namespaces to include in sync (system `$` namespaces are
  /// always excluded).
  SyncEngine({
    required KvStore store,
    required CloudAdapter cloudAdapter,
    required StorageAdapter localAdapter,
    required String deviceId,
    required String dbDir,
    required String syncRoot,
    required Set<String> syncNamespaces,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
  })  : _store = store,
        _cloudAdapter = cloudAdapter,
        _localAdapter = localAdapter,
        _deviceId = deviceId,
        _dbDir = dbDir,
        _syncRoot = syncRoot,
        _syncNamespaces = syncNamespaces,
        _consolidationConfig = consolidationConfig;

  final KvStore _store;
  final CloudAdapter _cloudAdapter;
  final StorageAdapter _localAdapter;
  final String _deviceId;
  final String _dbDir;
  final String _syncRoot;
  final Set<String> _syncNamespaces;
  final ConsolidationConfig _consolidationConfig;

  /// The set of user namespaces included in sync.
  ///
  /// Used in Phase 6+ to filter which SSTables are downloaded and ingested.
  /// Exposed as a getter to prevent the "unused field" warning while the
  /// field is reserved for future use.
  Set<String> get syncNamespaces => _syncNamespaces;

  /// Local SSTable directory.
  String get _sstDir => '$_dbDir/sst';

  /// Remote SSTable directory path in the sync folder.
  String get _remoteSstDir => '$_syncRoot/sstables';

  /// Remote highwater directory path in the sync folder.
  String get _remoteHwmDir => '$_syncRoot/highwater';

  /// Remote HWM file path for this device.
  String get _remoteHwmPath => '$_remoteHwmDir/$_deviceId.hwm';

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Flushes the local store, uploads new SSTables, and updates the HWM.
  ///
  /// Steps:
  /// 1. Flush the local memtable to ensure all data is in SSTables.
  /// 2. List local SSTables from `{dbDir}/sst/`.
  /// 3. List remote SSTables already in `{syncRoot}/sstables/`.
  /// 4. Upload SSTables from local that are absent from remote.
  /// 5. Read (or create) the local HWM.
  /// 6. Compute the max HLC across uploaded SSTables.
  /// 7. Update and upload the HWM with the new currentHlc.
  Future<void> push() async {
    // 1. Flush to materialise all memtable data as SSTables.
    await _store.flush();

    // 2. List local SSTables — only include files belonging to this device
    //    (named with our deviceId prefix) to avoid re-uploading peer files
    //    that were ingested during pull.
    final localFiles = await _localAdapter.listFiles(_sstDir, extension: '.sst');
    final ownLocalFiles = localFiles
        .where((f) => _safeDeviceId(f) == _deviceId)
        .toSet();

    // 3. List remote SSTables.
    final remoteFiles = (await _cloudAdapter.list(_remoteSstDir, extension: '.sst')).toSet();

    // 4. Upload new SSTables.
    final uploaded = <String>[];
    for (final filename in ownLocalFiles) {
      if (remoteFiles.contains(filename)) continue; // already uploaded
      final bytes = await _localAdapter.readFile('$_sstDir/$filename');
      await _cloudAdapter.upload('$_remoteSstDir/$filename', bytes);
      uploaded.add(filename);
    }

    // 5. Load or create the local HWM.
    var hwm = await HighwaterMark.load(_remoteHwmPath, _cloudAdapter) ??
        HighwaterMark(
          deviceId: _deviceId,
          currentHlc: const Hlc(0, 0),
          lastUpdated: DateTime.now().toUtc(),
          peers: const {},
        );

    // 6. Compute the max HLC from all uploaded (and previously uploaded) SSTables.
    Hlc maxHlc = hwm.currentHlc;
    for (final filename in ownLocalFiles) {
      try {
        final info = SstableInfo.parse(filename);
        if (info.maxHlc > maxHlc) maxHlc = info.maxHlc;
      } catch (_) {
        // Skip files with unparseable names.
      }
    }

    // 7. Update and upload HWM.
    hwm = hwm.withCurrentHlc(maxHlc);
    await hwm.save(_remoteHwmPath, _cloudAdapter);
  }

  /// Downloads new SSTables from the sync folder and ingests them locally.
  ///
  /// Steps:
  /// 1. Read local HWM.
  /// 2. List all remote SSTables.
  /// 3. For each SSTable from a different device: skip if already ingested
  ///    (minHlc ≤ recorded peer HWM), otherwise download and ingest.
  /// 4. Update the HWM for each successfully ingested peer.
  /// 5. Optionally run consolidation if threshold is met.
  Future<void> pull() async {
    // 1. Load local HWM.
    var hwm = await HighwaterMark.load(_remoteHwmPath, _cloudAdapter) ??
        HighwaterMark(
          deviceId: _deviceId,
          currentHlc: const Hlc(0, 0),
          lastUpdated: DateTime.now().toUtc(),
          peers: const {},
        );

    // 2. List all remote SSTables.
    final remoteFiles = await _cloudAdapter.list(_remoteSstDir, extension: '.sst');

    // Track highest ingested HLC per peer for HWM update.
    final peerMaxHlc = <String, Hlc>{};

    // 3. Process each remote SSTable from a different device.
    for (final filename in remoteFiles) {
      final peerDeviceId = _safeDeviceId(filename);
      if (peerDeviceId == _deviceId) continue; // skip our own files
      if (peerDeviceId.isEmpty) continue; // skip unparseable filenames

      // Check if we already have this file locally (ingested in a prior pull).
      final localPath = '$_sstDir/$filename';
      if (await _localAdapter.fileExists(localPath)) continue;

      // Check high-water mark: skip SSTables we have already processed.
      final SstableInfo info;
      try {
        info = SstableInfo.parse(filename);
      } catch (_) {
        continue; // skip unparseable filenames
      }

      final peerHwm = hwm.peers[peerDeviceId];
      if (peerHwm != null && info.maxHlc <= peerHwm) continue;

      // Download the SSTable.
      final bytes = await _cloudAdapter.download('$_remoteSstDir/$filename');
      if (bytes == null) continue; // file removed between list and download

      // Validate footer checksum before ingestion.
      try {
        await _store.ingestSstable(filename, bytes);
      } on CorruptedSstableException {
        // Corrupted SSTable — log and skip. Do not update HWM so we retry
        // on the next pull (the file may be partially uploaded).
        continue;
      } on FormatException {
        continue; // Invalid filename format — skip.
      }

      // Track the highest ingested HLC for this peer.
      final existing = peerMaxHlc[peerDeviceId];
      if (existing == null || info.maxHlc > existing) {
        peerMaxHlc[peerDeviceId] = info.maxHlc;
      }
    }

    // 4. Update HWM with ingested peer HLCs.
    for (final entry in peerMaxHlc.entries) {
      hwm = hwm.withPeer(entry.key, entry.value);
    }
    if (peerMaxHlc.isNotEmpty) {
      hwm = hwm.withCurrentHlc(hwm.currentHlc);
      await hwm.save(_remoteHwmPath, _cloudAdapter);
    }

    // 5. Optionally run consolidation.
    await _maybeConsolidate(remoteFiles);
  }

  /// Convenience method that calls [push] then [pull].
  ///
  /// On failure in [push], [pull] is still attempted so the local database
  /// receives incoming changes even if the upload fails.
  Future<void> sync() async {
    await push();
    await pull();
  }

  // ── Consolidation ────────────────────────────────────────────────────────────

  /// Runs consolidation if the threshold is met.
  Future<void> _maybeConsolidate(List<String> remoteFiles) async {
    final coordinator = ConsolidationCoordinator(
      deviceId: _deviceId,
      cloudAdapter: _cloudAdapter,
      localAdapter: _localAdapter,
      syncRoot: _syncRoot,
      config: _consolidationConfig,
    );
    await coordinator.runIfNeeded(remoteFiles);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Extracts the device ID from a bare SSTable filename, returning an empty
  /// string if the filename cannot be parsed.
  static String _safeDeviceId(String filename) {
    try {
      return SstableInfo.parse(filename).deviceId;
    } catch (_) {
      return '';
    }
  }
}
