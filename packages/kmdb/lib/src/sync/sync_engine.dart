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

import 'dart:typed_data';

import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/quarantine.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/sstable/sstable_info.dart';
import '../engine/sstable/sstable_reader.dart';
import '../engine/util/hlc.dart';
import 'auth/sync_auth_exception.dart';
import 'sync_context.dart';
import 'sync_storage_adapter.dart';
import 'consolidation_config.dart';
import 'consolidation_coordinator.dart';
import 'highwater.dart';
import 'pull_result.dart';
import 'sync_result.dart';

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
/// ## Cancellation
///
/// [SyncEngine] accepts a [SyncContext] at construction time and threads it
/// to every adapter call site. A cancelled or timed-out context causes the
/// first adapter call boundary to throw [SyncCancelledException], which
/// propagates to the caller of [push], [pull], or [sync].
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
  /// [KvStoreConfig] defaults are used (90 days). [ctx] is the optional
  /// per-sync-run cancellation/deadline context; it is forwarded to every
  /// adapter call site.
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
    this._ctx,
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

  /// The optional per-sync-run cancellation/deadline context.
  ///
  /// Forwarded to every adapter call site. When non-null, each adapter call
  /// will throw [SyncCancelledException] if the context is cancelled or has
  /// exceeded its deadline.
  final SyncContext? _ctx;

  /// The set of user namespaces included in sync.
  ///
  /// Governs which user collections are uploaded and downloaded. System `$`
  /// namespaces are never synced regardless of this set. Exposed as a getter
  /// for use by [KmdbDatabase] and the CLI sync commands.
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
    //    (named with our deviceId prefix) and exclude local-only files
    //    (`.local.sst` suffix). Local-only SSTables contain derived data
    //    (FTS, vector, secondary indexes) that each device rebuilds locally;
    //    uploading them would waste bandwidth and the receiving device would
    //    discard them anyway.
    //
    //    Because `.local.sst` files end in `.sst`, they are included in the
    //    `listFiles(extension: '.sst')` result. Parsing the filename via
    //    [SstableInfo.parse] is the authoritative way to detect the suffix —
    //    both the upload loop and the HWM fold iterate `ownLocalFiles`, so
    //    excluding here covers both in one place.
    final localFiles = await _localAdapter.listFiles(
      _sstDir,
      extension: '.sst',
    );
    final ownLocalFiles = localFiles.where((f) {
      if (_safeDeviceId(f) != _deviceId) return false;
      // Exclude local-only SSTables by parsing the filename.
      try {
        return !SstableInfo.parse(f).localOnly;
      } catch (_) {
        // Unparseable filename — treat as syncable to be conservative.
        return true;
      }
    }).toSet();

    // 4. List remote SSTables.
    final remoteFiles = (await _cloudAdapter.list(
      _remoteSstDir,
      extension: '.sst',
      ctx: _ctx,
    )).toSet();

    // 5. Upload new SSTables.
    for (final filename in ownLocalFiles) {
      if (remoteFiles.contains(filename)) continue; // already uploaded
      final bytes = await _localAdapter.readFile('$_sstDir/$filename');
      await _cloudAdapter.upload('$_remoteSstDir/$filename', bytes, ctx: _ctx);
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
      ctx: _ctx,
    );

    // Compute min(livePeers.currentHlc) — excluding self and stale peers.
    Hlc? livePeerMin;
    for (final filename in allHwmFiles) {
      final HighwaterMark? hwm;
      try {
        hwm = await HighwaterMark.load(
          '$_remoteHwmDir/$filename',
          _cloudAdapter,
        );
      } on SyncAuthException {
        // A peer's HWM failed authentication (0.10.01 WI-4 T1, Q2 rejection
        // table): skip that one peer's contribution to the eviction check
        // rather than aborting the whole check — a forged/tampered peer
        // HWM must not be able to block this device's own re-admission
        // logic for every *other*, legitimately-authenticated peer.
        continue;
      }
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

    // 1a. Reset the tombstone GC floor to Hlc(0, 0) (H4-FU3 interaction).
    //
    // Once H4-FU3 is in place every ingestSstable call in step 3 below goes
    // through the floor check in ingestAt0. If this device had a non-zero floor
    // (i.e. it had previously run a tombstone-dropping compaction) and the cloud
    // folder still contains individual flush SSTables from before the last GC
    // cycle (because consolidation has not run since then), those SSTables would
    // have maxHlc <= floor and would be rejected with StaleSstableIngestException,
    // stalling the re-sync.
    //
    // Resetting the floor to zero is safe: the full re-sync rebuilds the local
    // state from the cloud's ground truth. After the ingest completes the local
    // state is consistent with the cloud. The floor will advance again the next
    // time _compactAll drops a tombstone. A floor of zero is identical to the
    // state of a freshly-opened database that has never run GC — all incoming
    // SSTables are accepted without restriction until the next GC cycle.
    await _store.resetTombstoneFloor();

    // 2. Download all SSTables from the remote folder.
    final remoteFiles = await _cloudAdapter.list(
      _remoteSstDir,
      extension: '.sst',
      ctx: _ctx,
    );

    // 3. Ingest each downloaded SSTable. Handles both:
    //    - Consolidated set (4-segment filenames, if coordinator ran).
    //    - Individual flush SSTables (3-segment filenames, if no consolidation).
    for (final filename in remoteFiles) {
      final Uint8List? bytes;
      try {
        bytes = await _cloudAdapter.download(
          '$_remoteSstDir/$filename',
          ctx: _ctx,
        );
      } on SyncAuthException catch (e) {
        // Unlike pull()'s Q1 handling, it is always safe to quarantine here:
        // _fullResync has already reset the local HWM to Hlc(0, 0) (step 1a
        // above), so there is no peer high-water mark this record could
        // poison — the peer-suppression attack Q1 defends against in pull()
        // does not apply to this method. Recorded for audit visibility
        // (0.10.01 WI-4 T1) using best-effort peerDeviceId/maxHlc parsed
        // from the filename; a filename that doesn't even parse falls back
        // to Hlc(0, 0), matching this method's already-defensive posture
        // toward malformed remote filenames.
        Hlc maxHlc = const Hlc(0, 0);
        try {
          maxHlc = SstableInfo.parse(filename).maxHlc;
        } catch (_) {
          // Unparseable filename — keep the Hlc(0, 0) sentinel.
        }
        await _store.appendQuarantine(
          QuarantinedSstable(
            peerDeviceId: _safeDeviceId(filename),
            filename: filename,
            maxHlc: maxHlc,
            reason: QuarantineReason.unauthenticated,
            detail: e.message,
            quarantinedAt: DateTime.now().toUtc(),
          ),
        );
        continue;
      }
      if (bytes == null) continue; // file removed between list and download

      try {
        await _store.ingestSstable(filename, bytes);
      } on CorruptedSstableException {
        continue; // Defensive: skip corrupted remote files.
      } on FormatException {
        continue; // Defensive: skip files with invalid names.
      } on RangeError {
        // S-1: same structural-bounds-violation class as SyncEngine.pull —
        // see the enumerated-types note there.
        continue;
      } on StorageException {
        continue;
      } on OutOfMemoryError {
        // `OutOfMemoryError` is an `Error`, not an `Exception` — caught
        // explicitly rather than via a bare `catch`, which would also
        // swallow `SyncCancelledException` (see the note in [pull]).
        continue;
      }
      // StaleSstableIngestException should not occur here because the floor was
      // reset to zero above. If it does fire (e.g. a concurrent compaction ran
      // between the reset and this ingest, which cannot happen in the single-
      // isolate model), skip defensively — the file will be reconsidered later.
      // ignore: avoid_catches_without_on_clauses — handled below
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
  /// 2. List all remote SSTables and load the durable quarantine log's
  ///    filename set (0.10.01 WI-4 T1, Q1) — see the pre-download skip-list
  ///    note below.
  /// 3. For each SSTable from a different device: skip if already ingested
  ///    (minHlc ≤ recorded peer HWM) or already quarantined, otherwise
  ///    download and ingest. A download that fails sync authentication
  ///    (`SyncAuthException`) is quarantined under
  ///    [QuarantineReason.unauthenticated] and skipped *without* advancing
  ///    the peer HWM — see "Q1" below.
  /// 4. Update the HWM for each successfully ingested peer.
  /// 5. Optionally run consolidation if threshold is met.
  ///
  /// Returns a [PullResult] reporting every peer SSTable this call
  /// permanently quarantined ([PullResult.quarantined]) or transiently
  /// deferred ([PullResult.deferred]) — see those fields' doc comments.
  ///
  /// ## Q1 — the quarantine log is the re-fetch guard for unauthenticated files
  ///
  /// For every reason *except* [QuarantineReason.unauthenticated], the
  /// crash-safety ordering below (advance the HWM only after the quarantine
  /// record is durable) is what prevents re-fetching a permanently-dropped
  /// file. [QuarantineReason.unauthenticated] never advances the HWM at all
  /// (see the inline comment at its download site) — a MAC-failed file's
  /// filename, and therefore its claimed `maxHlc`, is attacker-controlled,
  /// so trusting it to advance a peer's HWM would let one forged file
  /// permanently suppress that peer's genuine data. With no HWM advance,
  /// the **quarantine log itself** is the only thing preventing an
  /// infinite re-download/re-reject loop of the same forged file: this
  /// method loads the full set of already-quarantined filenames once, at
  /// the top (step 2), and skips any listed filename *before* attempting a
  /// download for it.
  ///
  /// ## Crash-safety ordering (finding A3 / WI-7)
  ///
  /// Quarantine advances the per-peer high-water mark past a rejected file's
  /// `maxHlc`, which is the mechanism that makes the drop permanent (step 4,
  /// below) — the file is never re-fetched or reconsidered once the HWM
  /// clears it. Before this HWM advance is persisted, this method durably
  /// records the [QuarantinedSstable] to the local-only `$$quarantine` log
  /// (`_store.appendQuarantine`, called per-file inside the loop, step 3) —
  /// strictly *before* the single post-loop `hwm.save` (step 4). This
  /// ordering is deliberate and the only safe one:
  ///
  /// - If the log write throws (e.g. a full disk), the exception propagates
  ///   from *inside* the loop, before the HWM is ever saved — the file is
  ///   therefore reconsidered on the next pull rather than being silently and
  ///   permanently dropped with no trace (the fail-safe direction).
  /// - The dangerous inverse — HWM advanced first, log write lost — is made
  ///   structurally impossible: no code path here writes the HWM before every
  ///   in-flight file's quarantine record has already been durably appended.
  ///
  /// Each log entry is keyed by filename, so a re-quarantine after a crash
  /// between the log write and the HWM save (the file is reconsidered, fails
  /// ingest again, and is quarantined again) is a harmless idempotent
  /// overwrite — never a duplicate.
  ///
  /// ## Cancellation
  ///
  /// If [SyncCancelledException] is thrown at any adapter call boundary, it
  /// propagates uncaught and this method does not return a [PullResult] at
  /// all — any [QuarantinedSstable]/[DeferredSstable] entries accumulated so
  /// far in this call are discarded along with the rest of the call stack.
  /// This is deliberate (see [PullResult]'s cancellation-contract doc
  /// comment): quarantine records already durably logged before the
  /// cancellation are unaffected (they were already true and permanent when
  /// written) and remain queryable via `KmdbDatabase.quarantinedSstables`;
  /// only the *report* of this specific call's activity is lost.
  Future<PullResult> pull() async {
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
      ctx: _ctx,
    );

    // Load the set of already-quarantined filenames once (0.10.01 WI-4 T1,
    // Q1). A file quarantined under QuarantineReason.unauthenticated never
    // had its peer HWM advanced — advancing it would be exactly the
    // peer-suppression primitive Q1 exists to prevent, since the filename's
    // maxHlc is attacker-controlled for a MAC-failed file. Without that HWM
    // advance, the *log* is the only thing standing between this device and
    // re-downloading (and re-rejecting) the same forged file every pull
    // cycle — so it must be consulted before download, not only recorded
    // after.
    final quarantinedFilenames = await _store.quarantinedFilenames();

    // Track highest ingested HLC per peer for HWM update.
    final peerMaxHlc = <String, Hlc>{};

    // Accumulate this call's PullResult. Declared before the loop and
    // returned only after it — no catch/on Exception wraps the loop body, so
    // SyncCancelledException always propagates uncaught rather than being
    // trapped while building a partial result (D4 / see the class doc
    // comment's cancellation section).
    final quarantined = <QuarantinedSstable>[];
    final deferred = <DeferredSstable>[];

    // 3. Process each remote SSTable from a different device.
    for (final filename in remoteFiles) {
      final peerDeviceId = _safeDeviceId(filename);
      if (peerDeviceId == _deviceId) continue; // skip our own files
      if (peerDeviceId.isEmpty) continue; // skip unparseable filenames

      // Check if we already have this file locally (ingested in a prior pull).
      final localPath = '$_sstDir/$filename';
      if (await _localAdapter.fileExists(localPath)) continue;

      // Pre-download quarantine skip-list consult (Q1) — see the comment
      // above quarantinedFilenames' loading. Must run before any download
      // attempt: this is the only re-fetch guard for a MAC-failed file,
      // since that file's peer HWM was never advanced.
      if (quarantinedFilenames.contains(filename)) continue;

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
      //
      // ## Q1 — verify the MAC before any HWM decision
      //
      // SyncAuthEnvelope authentication happens inside the
      // SyncAuthenticatingAdapter decorator wrapping _cloudAdapter (applied
      // once, at the adapter-wiring point — see that class's doc comment),
      // so a bad or missing MAC surfaces here as SyncAuthException. Unlike
      // every ingest-failure reason below, `info.maxHlc` is NOT trustworthy
      // in this branch: the filename (and therefore maxHlc) is exactly what
      // an attacker with mere write access to the sync folder controls,
      // since they hold no sync-set key to forge a valid envelope for real
      // content. Advancing peerMaxHlc/the HWM off it would let a single
      // forged file — naming a real peer with a huge maxHlc — permanently
      // suppress every subsequent genuine SSTable from that peer (see the
      // Q1 peer-suppression regression test). So this branch quarantines
      // and `continue`s *before* reaching the peerMaxHlc fold at the bottom
      // of the loop, never after it.
      final Uint8List? bytes;
      try {
        bytes = await _cloudAdapter.download(
          '$_remoteSstDir/$filename',
          ctx: _ctx,
        );
      } on SyncAuthException catch (e) {
        final record = QuarantinedSstable(
          peerDeviceId: peerDeviceId,
          filename: filename,
          maxHlc: info.maxHlc,
          reason: QuarantineReason.unauthenticated,
          detail: e.message,
          quarantinedAt: DateTime.now().toUtc(),
        );
        await _store.appendQuarantine(record);
        quarantined.add(record);
        continue;
      }
      if (bytes == null) continue; // file removed between list and download

      // Validate footer checksum before ingestion.
      //
      // ## Quarantine, don't just reject (S-1)
      //
      // A peer SSTable can fail to ingest for two very different reasons:
      // genuine transient corruption (e.g. a partial upload still in
      // flight — rare, since cloud object stores generally do not expose a
      // partially-written object to `download`), or a structurally hostile
      // file crafted by an untrusted provider or malicious peer. The
      // original behaviour treated every failure as the former and never
      // advanced the peer HWM, which the review confirmed (PEER-A/B) turns
      // a single hostile file into a **permanent** denial of sync: the same
      // poisoned file is re-downloaded and re-rejected on every subsequent
      // pull, forever. `info.maxHlc` is already known at this point (parsed
      // from the *filename*, before any of the file's untrusted body content
      // was touched) — advancing the peer HWM past it quarantines the file:
      // it is not re-fetched, and the sync cycle can complete. The exception
      // types below are the complete enumeration of what
      // `KvStore.ingestSstable` can throw for a structurally-invalid file;
      // see the type-by-type notes for why each is included.
      var rejected = false;
      QuarantineReason? rejectReason;
      String? rejectDetail;
      try {
        await _store.ingestSstable(filename, bytes);
      } on CorruptedSstableException catch (e) {
        _logRejectedSstable(filename, e);
        rejected = true;
        rejectReason = QuarantineReason.corruptedSstable;
        rejectDetail = e.toString();
      } on FormatException catch (e) {
        _logRejectedSstable(filename, e);
        rejected = true;
        rejectReason = QuarantineReason.invalidFormat;
        rejectDetail = e.toString();
      } on RangeError catch (e) {
        // A structural bounds violation that slipped past SstableReader's
        // own validation (belt-and-suspenders — see sstable_reader.dart).
        _logRejectedSstable(filename, e);
        rejected = true;
        rejectReason = QuarantineReason.structuralBoundsViolation;
        rejectDetail = e.toString();
      } on StorageException catch (e) {
        // Raised by StorageAdapterNative.readFileRange when a footer/index
        // field points past the end of the file (S-1 PROBE2).
        _logRejectedSstable(filename, e);
        rejected = true;
        rejectReason = QuarantineReason.storageError;
        rejectDetail = e.toString();
      } on OutOfMemoryError catch (e) {
        // `OutOfMemoryError` is an `Error`, not an `Exception` — a bare
        // `on Exception` clause does not see it (S-1 PROBE1: an attacker-
        // declared `filterSize`/`indexSize` reaching `malloc` before any
        // bounds check could reject it). Caught explicitly here, and only
        // here — never via a catch-all `catch (e)`, which would also
        // swallow `SyncCancelledException` (deliberately uncaught elsewhere
        // in this class so cooperative cancellation always propagates).
        _logRejectedSstable(filename, e);
        rejected = true;
        rejectReason = QuarantineReason.outOfMemory;
        rejectDetail = e.toString();
      } on StaleSstableIngestException catch (e) {
        // The SSTable's maxHlc is at or below the local GC floor (H4-FU3).
        // Ingesting it could resurrect tombstone-GC'd data. Skip without
        // advancing the peer HWM so the file is reconsidered on the next
        // pull cycle (e.g. after consolidation has produced post-floor output).
        // Unlike the quarantine cases above, this is not corruption — the
        // file is well-formed and will very likely become ingestable again
        // once a newer consolidated file supersedes it, so retry-forever is
        // the correct behaviour here, not quarantine. Recorded as a
        // DeferredSstable — a structurally distinct, never-persisted type
        // (A3 / Q2) — never as a QuarantinedSstable.
        //
        // Log at WARN: filename, sub-floor HLC, and current floor.
        // ignore: avoid_print — structured logging deferred (Q8 decision).
        print(
          'WARN [SyncEngine.pull] Sub-floor SSTable rejected: '
          '${e.filename} maxHlc=${e.maxHlc.toHex()} '
          'floor=${e.floor.toHex()}',
        );
        deferred.add(
          DeferredSstable(
            peerDeviceId: peerDeviceId,
            filename: e.filename,
            maxHlc: e.maxHlc,
            floor: e.floor,
          ),
        );
        continue;
      }

      // Quarantine: durably record the rejection BEFORE folding maxHlc into
      // peerMaxHlc / the post-loop HWM save below (D3 crash-safety ordering
      // — see this method's class-level "Crash-safety ordering" doc-comment
      // section). `info.maxHlc` was parsed from the *filename* before the
      // untrusted body was ever read, so it is safe to persist even though
      // the file itself was rejected. If `appendQuarantine` throws, the
      // exception propagates here — before any HWM advance for this or any
      // later file in this pull — which is the fail-safe direction.
      if (rejected) {
        final record = QuarantinedSstable(
          peerDeviceId: peerDeviceId,
          filename: filename,
          maxHlc: info.maxHlc,
          reason: rejectReason!,
          detail: rejectDetail!,
          quarantinedAt: DateTime.now().toUtc(),
        );
        await _store.appendQuarantine(record);
        quarantined.add(record);
      }
      final existing = peerMaxHlc[peerDeviceId];
      if (existing == null || info.maxHlc > existing) {
        peerMaxHlc[peerDeviceId] = info.maxHlc;
      }
    }

    // 4. Update HWM with ingested peer HLCs. Every quarantine record for a
    //    peer folded into peerMaxHlc above has already been durably
    //    appended to the quarantine log (see the loop above) — this save is
    //    always the second of the two writes, never the first.
    for (final entry in peerMaxHlc.entries) {
      hwm = hwm.withPeer(entry.key, entry.value);
    }
    if (peerMaxHlc.isNotEmpty) {
      await hwm.save(_remoteHwmPath, _cloudAdapter);
    }

    // 5. Optionally run consolidation.
    await _maybeConsolidate(remoteFiles);

    return PullResult(quarantined: quarantined, deferred: deferred);
  }

  /// Convenience method that calls [push] then [pull].
  ///
  /// A failure in [push] propagates immediately — [pull] is **not** attempted
  /// in that case. Callers that want fire-and-forget pull semantics (receive
  /// incoming changes even when the upload fails) must call [push] and [pull]
  /// separately and handle the push exception themselves.
  ///
  /// Returns a [SyncResult] wrapping the [pull] call's [PullResult]. [push]
  /// currently reports nothing structured beyond success/failure — see
  /// [SyncResult]'s doc comment for why it exists as a wrapper today rather
  /// than returning a bare [PullResult].
  Future<SyncResult> sync() async {
    await push();
    final pullResult = await pull();
    return SyncResult(pull: pullResult);
  }

  // ── Consolidation ────────────────────────────────────────────────────────────

  /// Runs consolidation if the threshold is met.
  Future<void> _maybeConsolidate(List<String> remoteFiles) async {
    final coordinator = ConsolidationCoordinator(
      deviceId: _deviceId,
      cloudAdapter: _cloudAdapter,
      localAdapter: _localAdapter,
      syncRoot: _syncRoot,
      dbDir: _dbDir,
      config: _consolidationConfig,
      ctx: _ctx,
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

  /// Logs that [filename] was rejected during ingest, for any of the
  /// structural-failure types enumerated in [pull] (S-1).
  // ignore: avoid_print — structured logging deferred (Q8 decision).
  static void _logRejectedSstable(String filename, Object error) {
    print('WARN [SyncEngine.pull] Rejected SSTable $filename: $error');
  }
}
