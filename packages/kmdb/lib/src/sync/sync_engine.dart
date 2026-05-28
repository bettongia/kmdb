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
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/sstable/sstable_info.dart';
import '../engine/sstable/sstable_reader.dart';
import '../engine/util/hlc.dart';
import 'sync_storage_adapter.dart';
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
  /// [_store] is the local [KvStore] instance. [_cloudAdapter] accesses the
  /// shared sync folder. [_localAdapter] accesses the local database directory.
  /// [_deviceId] is the 8-character hex identifier for this device. [_dbDir] is
  /// the local database root directory (contains the `sst/` subdirectory).
  /// [_syncRoot] is the root path in the cloud adapter. [_syncNamespaces] is the
  /// set of user namespaces to include in sync (system `$` namespaces are
  /// always excluded). [config] supplies the [KvStoreConfig.staleDeviceEvictionAfter]
  /// threshold used for the tombstone-GC horizon computation — if omitted,
  /// [KvStoreConfig] defaults are used (90 days).
  SyncEngine({
    required this._store,
    required this._cloudAdapter,
    required this._localAdapter,
    required this._deviceId,
    required this._dbDir,
    required this._syncRoot,
    required this._syncNamespaces,
    this._consolidationConfig = const ConsolidationConfig(),
    KvStoreConfig? config,
  }) : _config = config ?? const KvStoreConfig() {
    // Register the synced-database tombstone-GC horizon provider on the
    // store (H4 PR2 / H4-FU2). The store uses this for the all-levels
    // `_compactAll` path; partial compactions never drop tombstones regardless.
    // When the HWM scan finds no live `.hwm` files (sync not yet established,
    // or all non-local HWMs are stale), we return `Hlc(0, 0)` so no
    // tombstones drop until at least one device has pushed an HWM — the safe
    // behaviour for a freshly-configured sync folder or a temporarily
    // quiescent topology.
    _store.setTombstoneHorizonProvider(() async {
      final min = await HighwaterMark.minCurrentHlcAcrossDevices(
        _remoteHwmDir,
        _cloudAdapter,
        localDeviceId: _deviceId,
        evictAfter: _config.staleDeviceEvictionAfter,
      );
      return min ?? const Hlc(0, 0);
    });
  }

  final KvStore _store;
  final SyncStorageAdapter _cloudAdapter;
  final StorageAdapter _localAdapter;
  final String _deviceId;
  final String _dbDir;
  final String _syncRoot;
  final Set<String> _syncNamespaces;
  final ConsolidationConfig _consolidationConfig;

  /// The store configuration, used for the eviction threshold and other
  /// sync-related parameters.
  final KvStoreConfig _config;

  /// The set of user namespaces included in sync.
  ///
  /// Used in Phase 6+ to filter which SSTables are downloaded and ingested.
  /// Exposed as a getter to prevent the "unused field" warning while the
  /// field is reserved for future use.
  Set<String> get syncNamespaces => _syncNamespaces;

  /// Local SSTable directory.
  String get _sstDir => '$_dbDir/sst';

  /// Remote SSTable directory path in the sync folder.
  ///
  /// When [_syncRoot] is empty, the path is `'sstables'` (no leading slash).
  /// When [_syncRoot] is non-empty, the path is `'$_syncRoot/sstables'`.
  /// This avoids a leading-slash mismatch in adapters that use exact string
  /// matching (e.g. [MemorySyncAdapter]), while remaining compatible with
  /// filesystem adapters where a leading slash in a subpath is collapsed.
  String get _remoteSstDir =>
      _syncRoot.isEmpty ? 'sstables' : '$_syncRoot/sstables';

  /// Remote highwater directory path in the sync folder.
  ///
  /// Same empty-root handling as [_remoteSstDir].
  String get _remoteHwmDir =>
      _syncRoot.isEmpty ? 'highwater' : '$_syncRoot/highwater';

  /// Remote HWM file path for this device.
  String get _remoteHwmPath => '$_remoteHwmDir/$_deviceId.hwm';

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Flushes the local store, uploads new SSTables, and updates the HWM.
  ///
  /// Steps:
  /// 1. Flush the local memtable to ensure all data is in SSTables.
  /// 2. Read peer HWMs and detect whether this device has been evicted
  ///    from the GC horizon (H4-FU2 re-admission check).
  ///    If evicted: perform a full re-sync (see [_fullResync]) and return.
  /// 3. List local SSTables from `{dbDir}/sst/`.
  /// 4. List remote SSTables already in `{syncRoot}/sstables/`.
  /// 5. Upload SSTables from local that are absent from remote.
  /// 6. Read (or create) the local HWM.
  /// 7. Compute the max HLC across uploaded SSTables.
  /// 8. Update and upload the HWM with the new currentHlc.
  Future<void> push() async {
    // 1. Flush to materialise all memtable data as SSTables.
    await _store.flush();

    // 2. Re-admission check (H4-FU2).
    //
    // Peer HWMs are already needed at this point (to detect eviction), and
    // they are used again below for the incremental upload path. We read them
    // once here. This does NOT add a round-trip; peer HWMs are always read
    // before uploading to avoid shipping SSTables that have already been
    // superseded by a consolidation.
    //
    // The two-condition eviction test:
    //   (a) localCurrentHlc < min(livePeers.currentHlc)
    //   (b) localHwm.lastUpdated < now - staleDeviceEvictionAfter
    //
    // Only BOTH conditions together indicate the device has been excluded from
    // the GC horizon. Condition (a) alone means "merely behind" — a normal
    // catch-up sync; condition (b) alone means "clock-skew or recently offline"
    // — also safe incrementally. Both together mean "I was evicted and the
    // horizon has advanced past my data."
    final evictionTriggered = await _checkAndHandleEviction();
    if (evictionTriggered) {
      // Full re-sync was performed; local state is now consistent with the
      // current sync folder. Skip the incremental push for this cycle —
      // the next push will upload any newly-ingest-derived SSTables.
      return;
    }

    // 3. List local SSTables — only include files belonging to this device
    //    (named with our deviceId prefix) to avoid re-uploading peer files
    //    that were ingested during pull.
    final localFiles = await _localAdapter.listFiles(
      _sstDir,
      extension: '.sst',
    );
    final ownLocalFiles = localFiles
        .where((f) => _safeDeviceId(f) == _deviceId)
        .toSet();

    // 4. List remote SSTables.
    final remoteFiles = (await _cloudAdapter.list(
      _remoteSstDir,
      extension: '.sst',
    )).toSet();

    // 5. Upload new SSTables.
    for (final filename in ownLocalFiles) {
      if (remoteFiles.contains(filename)) continue; // already uploaded
      final bytes = await _localAdapter.readFile('$_sstDir/$filename');
      await _cloudAdapter.upload('$_remoteSstDir/$filename', bytes);
    }

    // 6. Load or create the local HWM.
    var hwm =
        await HighwaterMark.load(_remoteHwmPath, _cloudAdapter) ??
        HighwaterMark(
          deviceId: _deviceId,
          currentHlc: const Hlc(0, 0),
          lastUpdated: DateTime.now().toUtc(),
          peers: const {},
        );

    // 7. Compute the max HLC from all uploaded (and previously uploaded) SSTables.
    Hlc maxHlc = hwm.currentHlc;
    for (final filename in ownLocalFiles) {
      try {
        final info = SstableInfo.parse(filename);
        if (info.maxHlc > maxHlc) maxHlc = info.maxHlc;
      } catch (_) {
        // Skip files with unparseable names.
      }
    }

    // 8. Update and upload HWM.
    hwm = hwm.withCurrentHlc(maxHlc);
    await hwm.save(_remoteHwmPath, _cloudAdapter);
  }

  /// Checks whether this device has been excluded from the GC horizon by all
  /// live peers (H4-FU2 re-admission check).
  ///
  /// Returns `true` if both eviction conditions hold AND a full re-sync was
  /// performed; returns `false` if the incremental push may proceed normally.
  ///
  /// ## Two-condition detection rule
  ///
  /// A device is considered evicted (and therefore requires a full re-sync)
  /// only when **both** of the following hold simultaneously:
  ///
  /// 1. `localCurrentHlc < min(livePeers.currentHlc)` — the local device's
  ///    HLC is behind all current live peers, indicating it has been bypassed.
  /// 2. `localHwm.lastUpdated < now - staleDeviceEvictionAfter` — the local
  ///    HWM file is older than the eviction window, meaning the device has not
  ///    updated it within the threshold period.
  ///
  /// Condition 1 alone is "merely behind" (normal incremental catch-up).
  /// Condition 2 alone is "recently offline or clock-skewed" (also safe
  /// incrementally). Only both together indicate the device was excluded from
  /// the horizon and that its local SSTables may contain data the topology has
  /// already moved past via tombstone GC.
  ///
  /// ## Consolidated-set handling
  ///
  /// When performing a full re-sync, the method downloads whatever SSTables
  /// are present in the remote `sstables/` folder. If a consolidated set
  /// exists (4-segment filenames), those are included. If no consolidation
  /// has run (e.g. a single-device sync folder after the other device
  /// vanished), all individual SSTables are downloaded. Both cases are handled
  /// uniformly — the method downloads all remote SSTables regardless of format.
  ///
  /// ## Simultaneous returning devices
  ///
  /// If two devices were both evicted and both return at the same time, each
  /// will see the other as a live peer with a stale HLC; the two-condition
  /// detection may fire for both. Both re-sync from the cloud state, which
  /// converges — this is safe. The comment below documents this edge case.
  Future<bool> _checkAndHandleEviction() async {
    // Read the local HWM (if any). A brand-new device has no HWM yet;
    // it cannot have been evicted (it was never in the horizon to begin with).
    final localHwm = await HighwaterMark.load(_remoteHwmPath, _cloudAdapter);
    if (localHwm == null) return false;

    final now = DateTime.now().toUtc();

    // Condition (b): is the local HWM file older than the eviction threshold?
    final localAge = now.difference(localHwm.lastUpdated);
    if (localAge <= _config.staleDeviceEvictionAfter) {
      // Within the window — definitely not evicted, no need to read peers.
      return false;
    }

    // Condition (b) holds — the local HWM is stale by wall-clock age.
    // Now check condition (a): is our HLC behind all live peers?
    //
    // We read all peer HWMs from the sync folder, using the eviction filter
    // to identify which peers are currently "live." The local device is
    // excluded from the peer min (we want to compare against others, not self).
    final allHwmFiles = await _cloudAdapter.list(
      _remoteHwmDir,
      extension: '.hwm',
    );

    // Compute min(livePeers.currentHlc) — excluding self and stale peers.
    Hlc? livePeerMin;
    for (final filename in allHwmFiles) {
      final hwm = await HighwaterMark.load(
        '$_remoteHwmDir/$filename',
        _cloudAdapter,
      );
      if (hwm == null) continue;
      if (hwm.deviceId == _deviceId) continue; // exclude self

      // Apply the same eviction filter: only count live peers.
      final peerAge = now.difference(hwm.lastUpdated);
      if (peerAge > _config.staleDeviceEvictionAfter) continue; // stale, skip

      if (livePeerMin == null || hwm.currentHlc.compareTo(livePeerMin) < 0) {
        livePeerMin = hwm.currentHlc;
      }
    }

    // If there are no live peers (all peers are also stale, or this is the
    // only device), then there is no one to have evicted us — safe to proceed
    // incrementally. Edge case: two simultaneously-returning devices will each
    // see the other as stale; neither triggers a full re-sync. That is the
    // correct behaviour: neither was actually excluded while the other was
    // also absent.
    if (livePeerMin == null) return false;

    // Condition (a): is our HLC behind the live-peer minimum?
    if (localHwm.currentHlc.compareTo(livePeerMin) >= 0) {
      // We are at or ahead of the live-peer minimum — not evicted.
      return false;
    }

    // Both conditions hold: perform a full re-sync.
    await _fullResync();
    return true;
  }

  /// Performs a full re-sync for a device that has been excluded from the GC
  /// horizon (H4-FU2 re-admission).
  ///
  /// ## Steps
  ///
  /// 1. Delete all local SSTables that originated from this device (the ones
  ///    with our `_deviceId` prefix). Peer SSTables that were previously
  ///    ingested are also removed since the incoming consolidated/individual
  ///    SSTables from the sync folder will replace them.
  /// 2. Re-download all SSTables currently in the remote `sstables/` folder.
  ///    This includes consolidated (4-segment) files if the consolidation
  ///    coordinator has run, or individual flush files otherwise.
  /// 3. Ingest each downloaded SSTable into the local store. Invalid or
  ///    corrupted files are skipped (defensive; should not occur in a
  ///    healthy sync folder).
  /// 4. Reset and re-upload the local HWM with `currentHlc = Hlc(0, 0)` and
  ///    an updated `lastUpdated` timestamp, signalling to peers that this
  ///    device has re-joined with a clean state.
  ///
  /// After this method returns, the local store reflects the current
  /// consolidated state of the sync folder. The next pull cycle will then
  /// bring in any peer SSTables that were missed.
  Future<void> _fullResync() async {
    // 1. Discard all local SSTables (own + previously-ingested peer) via the
    //    engine so the manifest is updated atomically before files vanish.
    //    Removing files behind the manifest's back would cause the next
    //    compaction triggered by ingestAt0 (step 3 below) to open a now-
    //    nonexistent file and fail with StorageException(File not found).
    await _store.dropAllSstables();

    // 2. Download all SSTables from the remote folder.
    final remoteFiles = await _cloudAdapter.list(
      _remoteSstDir,
      extension: '.sst',
    );

    // 3. Ingest each downloaded SSTable. Handles both:
    //    - Consolidated set (4-segment filenames, if coordinator ran).
    //    - Individual flush SSTables (3-segment filenames, if no consolidation).
    for (final filename in remoteFiles) {
      final bytes = await _cloudAdapter.download('$_remoteSstDir/$filename');
      if (bytes == null) continue; // file removed between list and download

      try {
        await _store.ingestSstable(filename, bytes);
      } on CorruptedSstableException {
        continue; // Defensive: skip corrupted remote files.
      } on FormatException {
        continue; // Defensive: skip files with invalid names.
      }
    }

    // 4. Reset the local HWM to signal re-admission.
    //    currentHlc of Hlc(0, 0) will be updated on the next push cycle once
    //    the store reflects the full re-synced state.
    final resetHwm = HighwaterMark(
      deviceId: _deviceId,
      currentHlc: const Hlc(0, 0),
      lastUpdated: DateTime.now().toUtc(),
      peers: const {},
    );
    await resetHwm.save(_remoteHwmPath, _cloudAdapter);
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
    var hwm =
        await HighwaterMark.load(_remoteHwmPath, _cloudAdapter) ??
        HighwaterMark(
          deviceId: _deviceId,
          currentHlc: const Hlc(0, 0),
          lastUpdated: DateTime.now().toUtc(),
          peers: const {},
        );

    // 2. List all remote SSTables.
    final remoteFiles = await _cloudAdapter.list(
      _remoteSstDir,
      extension: '.sst',
    );

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
