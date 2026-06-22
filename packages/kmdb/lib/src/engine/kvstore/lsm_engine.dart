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

import 'dart:async';
import 'dart:typed_data';

import '../compaction/compaction_job.dart';
import '../compaction/merge_iterator.dart';
import '../compaction/reclamation_policy.dart' show ReclamationPolicyRegistry;
import '../manifest/current_file.dart';
import '../manifest/manifest_writer.dart';
import '../manifest/version_edit.dart';
import '../memtable/memtable.dart';
import '../memtable/skip_list.dart';
import '../platform/storage_adapter_interface.dart';
import '../sstable/sstable_reader.dart';
import '../sstable/sstable_writer.dart';
import '../sstable/sstable_info.dart';
import '../sstable/table_cache.dart';
import '../util/hlc.dart';
import '../util/key_codec.dart';
import '../util/namespace_codec.dart';
import '../wal/wal_record.dart';
import '../wal/wal_writer.dart';
import '../../sync/hlc_clock.dart';
import 'kv_store.dart';
import 'meta_store.dart';

/// The core LSM engine.
///
/// [LsmEngine] orchestrates the write path (WAL → memtable → SSTable flush),
/// the read path (memtable → L0 → L1 → L2), compaction, and the HLC clock.
/// It is not publicly exported; external code uses [KvStoreImpl].
///
/// ## Concurrency
///
/// All operations execute on a single isolate. There is no background
/// compaction thread. Compaction runs synchronously on the write path, before
/// the triggering write returns.
///
/// ## Level layout
///
/// `_levels[n]` is a [List] of [SstableMeta] entries at level `n`, each
/// carrying the full diagnostic metadata (filename, minKey, maxKey, entryCount,
/// walSequence) for that SSTable. The list for L0 is ordered from oldest
/// (index 0) to newest (last index); point lookups search L0 in reverse
/// (newest-first = highest priority). L1 and L2 files are assumed
/// non-overlapping after compaction.
final class LsmEngine {
  LsmEngine._({
    required this._dbDir,
    required this._sstDir,
    required this._adapter,
    required this._config,
    required this._deviceId,
    required this._levels,
    required this._manifestWriter,
    required this._walWriter,
    required this._clock,
  }) : _active = Memtable(),
       // TableCache capacity comes from config. The this.field constructor
       // parameter makes _config accessible in the initializer list.
       _tableCache = TableCache(capacity: _config.tableCacheSize),
       // sync: true delivers events synchronously to subscribers — correct for
       // KMDB's single-isolate model where listeners are set up before writes.
       _writeEventsController = StreamController<String>.broadcast(sync: true);

  final String _dbDir;
  final String _sstDir;
  final StorageAdapter _adapter;
  final KvStoreConfig _config;

  /// LRU cache of open [SstableReader]s, keyed by absolute file path.
  ///
  /// Caching avoids the O(file-size) whole-file XXH64 hash on every read.
  /// The first open for a given path validates and caches the reader;
  /// subsequent calls reuse the cached object. Entries are explicitly evicted
  /// whenever a file is removed, replaced, or renamed (flush, compaction,
  /// ingest, manifest rotation, device-ID rename, and close).
  final TableCache _tableCache;

  /// The 8-character device identifier used for new SSTable filenames.
  ///
  /// Mutable so that [reassignDeviceId] can update it after renaming existing
  /// SSTable files. All methods that generate new SSTable names read this field
  /// at the time of flush/compaction.
  String _deviceId;

  /// Live SSTable metadata grouped by level (0, 1, 2).
  ///
  /// Each [SstableMeta] carries the full diagnostic metadata for one SSTable
  /// file: filename, minKey, maxKey, entryCount, and walSequence. The fields
  /// are populated with real values at every flush, compaction, ingest, and
  /// reassignment site. Rotation snapshots carry the metadata directly from
  /// this map, so post-fix rotations always record real values.
  ///
  /// Files last seen by a pre-fix rotation-snapshot edit (written before this
  /// plan was implemented) will surface with empty minKey/maxKey and zero
  /// entryCount until the next write that touches those files re-records real
  /// metadata. This is self-healing for any actively written database.
  final Map<int, List<SstableMeta>> _levels;

  ManifestWriter _manifestWriter;
  final WalWriter _walWriter;

  /// The injected HLC clock. Advances on every write via [_clock.now()].
  final HlcClock _clock;

  /// The active (mutable) memtable. Incoming writes go here.
  Memtable _active;

  /// Frozen snapshot of the memtable, held in memory while its SSTable is
  /// being written. `null` when no flush is in progress.
  FrozenMemtable? _frozen;

  final StreamController<String> _writeEventsController;

  /// Optional callback supplying the tombstone-GC horizon used by the
  /// all-levels compaction path (H4 PR2). When `null` the engine falls
  /// back to `now - KvStoreConfig.tombstoneGraceDuration` (local-only
  /// safety window). Set by [setTombstoneHorizonProvider] — wired by
  /// `SyncEngine` to `min(currentHlc)` across all peer HWM files in a
  /// synced database.
  Future<Hlc> Function()? _tombstoneHorizonProvider;

  /// Optional callback invoked after an all-levels compaction trims `$ver:`
  /// version entries via [ReclamationPolicy.filterGroup]. The callback receives
  /// the raw value bytes of every trimmed entry and is responsible for
  /// decrementing vault ref counts for any vault URIs in those entries.
  ///
  /// Injected by [KvStoreImpl.setVersionDropCallback], wired by [KmdbDatabase]
  /// to the vault ref decrement path (RQ5). `null` when vault is disabled.
  ///
  /// **Crash posture:** if the process crashes after `_compactAll` commits but
  /// before this callback completes, vault refs are over-counted (blobs
  /// retained). This is the fail-safe: blobs are never deleted while possibly
  /// referenced (H3 posture, RQ5).
  Future<void> Function(List<Uint8List>)? _versionDropCallback;

  /// Optional callback that provides a [ReclamationPolicyRegistry] with
  /// per-collection [VersionRetentionPolicy] instances for `_compactAll`.
  ///
  /// Called at the start of `_compactAll()` to obtain the registry. The
  /// callback reads current [VersionConfig] entries from `$meta` and builds
  /// one `VersionRetentionPolicy` per `$ver:{collection}` prefix.
  ///
  /// Injected by [KvStoreImpl] after versioning is configured. `null` means
  /// [_compactAll] uses the default registry ([ReclamationPolicyRegistry()],
  /// which assigns [RetainAllVersionsPolicy] to all `$ver:` prefixes — no
  /// per-collection trimming).
  Future<ReclamationPolicyRegistry> Function()? _versionRegistryProvider;

  /// The [MetaStore] used to persist the tombstone GC floor (H4-FU3).
  ///
  /// Injected by [KvStoreImpl] after construction via [setMetaStore].
  /// When `null`, [_compactAll] cannot advance the floor — the engine still
  /// runs compaction correctly, but the floor is not updated. This only occurs
  /// in low-level tests that bypass [KvStoreImpl].
  MetaStore? _metaStore;

  /// Broadcast stream that emits a namespace string after each successful write.
  Stream<String> get writeEvents => _writeEventsController.stream;

  /// The SSTable directory path. Exposed for [KvStoreImpl.ingestSstable].
  String get sstDir => _sstDir;

  /// The storage adapter. Exposed for [KvStoreImpl.ingestSstable].
  StorageAdapter get adapter => _adapter;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Creates an [LsmEngine] from the result of crash recovery.
  ///
  /// [clock] is the seeded [HlcClock] constructed by [CrashRecovery.open].
  /// Tests may pass a pre-built clock with an injected wall-clock function to
  /// obtain deterministic HLC values without going through [CrashRecovery].
  ///
  /// Callers should use [CrashRecovery.open] instead of this constructor.
  static LsmEngine create({
    required String dbDir,
    required String sstDir,
    required StorageAdapter adapter,
    required KvStoreConfig config,
    required String deviceId,
    required Map<int, List<SstableMeta>> levels,
    required ManifestWriter manifestWriter,
    required WalWriter walWriter,
    required HlcClock clock,
    required Memtable restoredMemtable,
  }) {
    final engine = LsmEngine._(
      dbDir: dbDir,
      sstDir: sstDir,
      adapter: adapter,
      config: config,
      deviceId: deviceId,
      levels: levels,
      manifestWriter: manifestWriter,
      walWriter: walWriter,
      clock: clock,
    );
    engine._active = restoredMemtable;
    return engine;
  }

  // ── Tombstone GC horizon (H4 PR2) ─────────────────────────────────────────

  /// Registers [provider] as the source of the all-levels tombstone-GC
  /// horizon, overriding the local-only `now - tombstoneGraceDuration`
  /// fallback. Pass `null` to revert. Called by [KvStoreImpl.setTombstoneHorizonProvider].
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider) {
    _tombstoneHorizonProvider = provider;
  }

  /// Injects the [MetaStore] used to persist the tombstone GC floor (H4-FU3).
  ///
  /// Called once by [KvStoreImpl] immediately after the engine is constructed.
  /// After this is set, [_compactAll] will advance the floor in `$meta`
  /// whenever it drops at least one tombstone.
  void setMetaStore(MetaStore metaStore) {
    _metaStore = metaStore;
  }

  /// Registers [callback] as the post-compaction vault ref-decrement handler
  /// for trimmed `$ver:` version entries (RQ5). Pass `null` to unregister.
  ///
  /// Called by [KvStoreImpl.setVersionDropCallback], wired by [KmdbDatabase]
  /// to the vault ref decrement path. Mirrors the pattern of [setMetaStore].
  void setVersionDropCallback(
    Future<void> Function(List<Uint8List>)? callback,
  ) {
    _versionDropCallback = callback;
  }

  /// Registers a [provider] that builds a [ReclamationPolicyRegistry] with
  /// per-collection [VersionRetentionPolicy] entries for `_compactAll`.
  ///
  /// Called by [KvStoreImpl] after versioning is configured. Pass `null` to
  /// revert to the default registry (all `$ver:` prefixes get
  /// [RetainAllVersionsPolicy] — no per-collection trimming).
  void setVersionRegistryProvider(
    Future<ReclamationPolicyRegistry> Function()? provider,
  ) {
    _versionRegistryProvider = provider;
  }

  /// Computes the tombstone-GC horizon for the next all-levels compaction.
  ///
  /// Returns the registered provider's value when present (used by
  /// `SyncEngine` to supply `min(currentHlc)` across all peer HWMs);
  /// otherwise returns `now - tombstoneGraceDuration` from
  /// [KvStoreConfig.tombstoneGraceDuration], clamped to `Hlc(0, 0)` if
  /// the grace window pre-dates the epoch.
  Future<Hlc> _computeTombstoneHorizon() async {
    final provider = _tombstoneHorizonProvider;
    if (provider != null) return provider();
    final nowMs = _clock.now().physicalMs;
    final graceMs = _config.tombstoneGraceDuration.inMilliseconds;
    final horizonMs = nowMs - graceMs;
    return horizonMs > 0 ? Hlc(horizonMs, 0) : const Hlc(0, 0);
  }

  // ── HLC clock ─────────────────────────────────────────────────────────────

  /// Advances the local clock to be at least [observed] (causal consistency).
  ///
  /// Used when ingesting external SSTables so the engine never generates a
  /// timestamp earlier than one it has already seen. Propagates
  /// [ClockSkewException] if [observed] is more than [KvStoreConfig.maxClockSkew]
  /// ahead of the local wall clock.
  void advanceClock(Hlc observed) {
    _clock.update(observed);
  }

  // ── Write operations ──────────────────────────────────────────────────────

  /// Writes a single value to the WAL and memtable.
  Future<void> put(String namespace, String key, Uint8List value) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final hlc = _clock.now();
    final internalKey = KeyCodec.encodeInternalKey(
      namespace,
      keyBytes,
      hlc,
      RecordType.put,
    );
    await _walWriter.writePut(
      sequence: hlc,
      namespace: namespace,
      keyBytes: keyBytes,
      value: value,
    );
    _active.put(internalKey, value);
    _writeEventsController.add(namespace);
    await _flushIfNeeded();
  }

  /// Writes a delete tombstone to the WAL and memtable.
  Future<void> delete(String namespace, String key) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final hlc = _clock.now();
    final internalKey = KeyCodec.encodeInternalKey(
      namespace,
      keyBytes,
      hlc,
      RecordType.delete,
    );
    await _walWriter.writeDelete(
      sequence: hlc,
      namespace: namespace,
      keyBytes: keyBytes,
    );
    _active.put(internalKey, Uint8List(0));
    _writeEventsController.add(namespace);
    await _flushIfNeeded();
  }

  /// Commits all entries in [batch] as a single atomic unit.
  ///
  /// ## Crash atomicity (WAL level)
  ///
  /// All entries are encoded into one [WalBatchFrame] under a single XXH64
  /// checksum, written with one `appendFile`, and fsynced once. A crash
  /// mid-write either leaves the frame absent (OS never flushed the buffer) or
  /// leaves a truncated frame whose checksum won't match — in either case
  /// recovery drops the entire frame. The database can never observe a partial
  /// batch across a crash (review finding H2).
  ///
  /// ## In-process atomicity (memtable level)
  ///
  /// After the single WAL append+fsync completes, every entry is applied to the
  /// memtable in one synchronous block with **no `await` between mutations**.
  /// Because Dart's event loop does not context-switch inside a synchronous
  /// block, a concurrent `get()` either sees all entries or none — never a
  /// half-applied batch.
  ///
  /// ## Event emission
  ///
  /// Write events are emitted after all memtable mutations so that any subscriber
  /// that immediately re-reads (e.g. the Cache Layer) observes the complete batch.
  Future<void> writeBatch(WriteBatch batch) async {
    // Phase 1: Assign HLC timestamps and build WAL records for every entry.
    // We need the timestamps before encoding the frame so the WAL and the
    // internal key share the same HLC value.
    final walRecords = <WalRecord>[];
    // Pair each WAL record with its encoded internal key and value bytes so
    // Phase 3 can apply them without re-parsing.
    final memtableOps = <({Uint8List internalKey, Uint8List value})>[];
    final namespaces = <String>{};

    for (final entry in batch.entries) {
      final keyBytes = KeyCodec.keyToBytes(entry.key);
      final hlc = _clock.now();

      if (entry.isDelete) {
        final internalKey = KeyCodec.encodeInternalKey(
          entry.namespace,
          keyBytes,
          hlc,
          RecordType.delete,
        );
        walRecords.add(
          WalRecord(
            type: WalRecordType.delete,
            sequence: hlc,
            namespace: entry.namespace,
            key: keyBytes,
          ),
        );
        memtableOps.add((internalKey: internalKey, value: Uint8List(0)));
      } else {
        final value = entry.value!;
        final internalKey = KeyCodec.encodeInternalKey(
          entry.namespace,
          keyBytes,
          hlc,
          RecordType.put,
        );
        walRecords.add(
          WalRecord(
            type: WalRecordType.put,
            sequence: hlc,
            namespace: entry.namespace,
            key: keyBytes,
            value: value,
          ),
        );
        memtableOps.add((internalKey: internalKey, value: value));
      }
      namespaces.add(entry.namespace);
    }

    // Phase 2: Write the batch frame to the WAL — one append, one fsync.
    // After this await completes the frame is durable. Any crash before this
    // point leaves the frame absent; after this point recovery can apply all
    // entries atomically.
    await _walWriter.appendBatch(walRecords);

    // Phase 3: Apply all entries to the memtable synchronously.
    // No `await` here — this is intentional. Dart's single-isolate event loop
    // cannot context-switch inside a synchronous loop, so a concurrent `get()`
    // will not observe a half-applied batch.
    for (final op in memtableOps) {
      _active.put(op.internalKey, op.value);
    }

    // Phase 4: Emit write events after all mutations are visible.
    for (final ns in namespaces) {
      _writeEventsController.add(ns);
    }

    await _flushIfNeeded();
  }

  // ── Read operations ───────────────────────────────────────────────────────

  /// Returns the raw value bytes for [key] in [namespace], or `null`.
  ///
  /// Search order: active memtable → frozen memtable → L0 (newest-first) →
  /// L1 → L2. The first non-tombstone hit is returned.
  Future<Uint8List?> get(String namespace, String key) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final prefix = _buildKeyPrefix(namespace, keyBytes);
    final prefixEnd = _nextPrefix(prefix);

    // 1. Active memtable.
    final fromActive = _latestFromIterable(
      _active.scan(start: prefix, end: prefixEnd),
    );
    if (fromActive != null) {
      return fromActive.isDelete ? null : fromActive.value;
    }

    // 2. Frozen memtable (if present).
    if (_frozen != null) {
      final fromFrozen = _latestFromIterable(
        _frozen!.scan(start: prefix, end: prefixEnd),
      );
      if (fromFrozen != null) {
        return fromFrozen.isDelete ? null : fromFrozen.value;
      }
    }

    // 3. L0 files — search newest-first (last in list).
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final result = await _getFromSstable(
        '$_sstDir/${l0[i].filename}',
        prefix,
        prefixEnd,
      );
      // Non-null result means this file had the key (hit or tombstone); stop.
      // Tombstone: result.value == null → return null (deleted).
      // Hit: result.value != null → return the value.
      if (result != null) return result.value;
    }

    // 4. L1, then L2.
    for (final level in [1, 2]) {
      for (final entry in (_levels[level] ?? [])) {
        final result = await _getFromSstable(
          '$_sstDir/${entry.filename}',
          prefix,
          prefixEnd,
        );
        // Same three-state semantics: non-null result stops the search.
        if (result != null) return result.value;
      }
    }

    return null;
  }

  /// Returns an ordered stream of entries in [namespace].
  ///
  /// Merges the memtable, frozen memtable, and all SSTable levels. Tombstones
  /// are suppressed from the output.
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  }) async* {
    // Convert user-key bounds to internal-key bounds.
    final scanStart = startKey != null
        ? _buildKeyPrefix(namespace, KeyCodec.keyToBytes(startKey))
        : _buildNamespacePrefix(namespace);
    final scanEnd = endKey != null
        ? _buildKeyPrefix(namespace, KeyCodec.keyToBytes(endKey))
        : _nextPrefix(_buildNamespacePrefix(namespace));

    // Collect streams from all sources (memtable, then SSTable levels).
    final streams = <Stream<SstEntry>>[];

    // Memtable sources: convert SkipListEntry → SstEntry stream.
    streams.add(_skipListRangeToStream(_active, scanStart, scanEnd));
    if (_frozen != null) {
      streams.add(_skipListRangeToStream(_frozen!, scanStart, scanEnd));
    }

    // SSTable sources — L0 newest-first, then L1, L2.
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final reader = await _openReader('$_sstDir/${l0[i].filename}');
      if (reader != null) {
        streams.add(reader.scan(start: scanStart, end: scanEnd));
      }
    }
    for (final level in [1, 2]) {
      for (final entry in (_levels[level] ?? [])) {
        final reader = await _openReader('$_sstDir/${entry.filename}');
        if (reader != null) {
          streams.add(reader.scan(start: scanStart, end: scanEnd));
        }
      }
    }

    // Merge all streams. The MergeIterator yields entries in ascending internal
    // key order. For a given user key, lower HLC (older version) comes first,
    // higher HLC (newer version) comes last. We must buffer and emit only the
    // LAST version per user key, checking whether it is a tombstone.
    final merge = MergeIterator(streams);

    String? bufferedKey;
    Uint8List? bufferedValue;
    bool bufferedIsDelete = false;

    await for (final entry in merge.entries) {
      final ns = KeyCodec.decodeNamespace(entry.key);
      if (ns != namespace) continue; // skip entries from other namespaces

      final userKeyHex = KeyCodec.bytesToKey(KeyCodec.decodeUserKey(entry.key));

      if (userKeyHex != bufferedKey) {
        // New user key arrived: emit the previously buffered one (if any and
        // not a tombstone).
        if (bufferedKey != null && !bufferedIsDelete) {
          yield (key: bufferedKey, value: bufferedValue!);
        }
        bufferedKey = userKeyHex;
        bufferedValue = entry.value;
        bufferedIsDelete =
            KeyCodec.decodeRecordType(entry.key) == RecordType.delete;
      } else {
        // Same user key, later HLC — update to this newer version.
        bufferedValue = entry.value;
        bufferedIsDelete =
            KeyCodec.decodeRecordType(entry.key) == RecordType.delete;
      }
    }

    // Emit the last buffered entry if not a tombstone.
    if (bufferedKey != null && !bufferedIsDelete) {
      yield (key: bufferedKey, value: bufferedValue!);
    }
  }

  /// Returns a stream of **all** historical entries for [docKey] in [namespace],
  /// in ascending HLC order (oldest first).
  ///
  /// Unlike [scan], which collapses multiple versions of the same user key to
  /// the latest (Last-Write-Wins), this method returns every entry including
  /// superseded versions and tombstones. It is intended for history-bearing
  /// namespaces such as `$ver:{collection}`.
  ///
  /// Each yielded [VersionHistoryEntry] carries the raw value bytes, the HLC
  /// extracted from the internal key (the authoritative version timestamp), and
  /// a flag indicating whether the entry is a tombstone (delete-version).
  ///
  /// ## Implementation
  ///
  /// Mirrors [scan]'s stream construction but does not buffer and collapse by
  /// user key — every entry in the merge output for the given
  /// `[nsLen][ns][userKey]` prefix is yielded.
  Stream<VersionHistoryEntry> scanVersionHistory(
    String namespace,
    String docKey,
  ) async* {
    final keyBytes = KeyCodec.keyToBytes(docKey);
    // The prefix covers exactly the [nsLen][ns][16B userKey] portion; the HLC
    // and record-type bytes are not part of the prefix. All versions of this
    // docKey in this namespace form a contiguous block in the merge output.
    final prefix = _buildKeyPrefix(namespace, keyBytes);
    final prefixEnd = _nextPrefix(prefix);

    // Build source streams from all storage levels.
    final streams = <Stream<SstEntry>>[];
    streams.add(_skipListRangeToStream(_active, prefix, prefixEnd));
    if (_frozen != null) {
      streams.add(_skipListRangeToStream(_frozen!, prefix, prefixEnd));
    }
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final reader = await _openReader('$_sstDir/${l0[i].filename}');
      if (reader != null) {
        streams.add(reader.scan(start: prefix, end: prefixEnd));
      }
    }
    for (final level in [1, 2]) {
      for (final entry in (_levels[level] ?? [])) {
        final reader = await _openReader('$_sstDir/${entry.filename}');
        if (reader != null) {
          streams.add(reader.scan(start: prefix, end: prefixEnd));
        }
      }
    }

    // Yield every entry from the merge without any LWW collapsing. The merge
    // iterator emits in ascending internal-key order, which for a fixed
    // [nsLen][ns][userKey] prefix means ascending HLC order.
    final merge = MergeIterator(streams);
    await for (final entry in merge.entries) {
      // Verify the entry belongs to our namespace+docKey (safety guard).
      if (!_hasPrefix(entry.key, prefix)) break;
      final hlc = KeyCodec.decodeHlc(entry.key);
      final isDelete =
          KeyCodec.decodeRecordType(entry.key) == RecordType.delete;
      yield (value: entry.value, hlc: hlc, isDelete: isDelete);
    }
  }

  /// Returns all distinct namespace strings currently present in storage
  /// (including system namespaces such as `$meta` and `$$index:*`).
  ///
  /// Only namespaces that have at least one live (non-tombstoned) entry are
  /// returned. Tombstone-only namespaces are excluded.
  ///
  /// This is an expensive operation that merges the memtable and all SSTables.
  /// It is intended for infrequent administrative operations such as index
  /// removal. Production hot-paths should use [scan] instead.
  Future<Set<String>> allStoredNamespaces() async {
    // Build the full merged stream (all keys, all levels, no namespace filter).
    final streams = <Stream<SstEntry>>[];

    // Collect entries from memtable sources — use an empty prefix so the scan
    // starts at the very beginning of the key space.
    final unbounded = Uint8List(0);
    streams.add(_skipListRangeToStream(_active, unbounded, null));
    if (_frozen != null) {
      streams.add(_skipListRangeToStream(_frozen!, unbounded, null));
    }

    // Collect entries from all SSTable levels.
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final reader = await _openReader('$_sstDir/${l0[i].filename}');
      if (reader != null) {
        streams.add(reader.scan(start: unbounded, end: null));
      }
    }
    for (final level in [1, 2]) {
      for (final entry in (_levels[level] ?? [])) {
        final reader = await _openReader('$_sstDir/${entry.filename}');
        if (reader != null) {
          streams.add(reader.scan(start: unbounded, end: null));
        }
      }
    }

    // Merge and collect unique namespaces from live (non-tombstone) entries.
    // The same deduplication logic used by [scan] applies here: buffer the last
    // version per user key and only count it if it is not a tombstone.
    final merge = MergeIterator(streams);
    final namespaces = <String>{};

    String? bufferedNs;
    String? bufferedKey;
    bool bufferedIsDelete = false;

    await for (final entry in merge.entries) {
      final ns = KeyCodec.decodeNamespace(entry.key);
      final userKeyHex = KeyCodec.bytesToKey(KeyCodec.decodeUserKey(entry.key));
      final isDelete =
          KeyCodec.decodeRecordType(entry.key) == RecordType.delete;

      if (ns != bufferedNs || userKeyHex != bufferedKey) {
        // Emit previously buffered entry (if live).
        if (bufferedKey != null && !bufferedIsDelete && bufferedNs != null) {
          namespaces.add(bufferedNs);
        }
        bufferedNs = ns;
        bufferedKey = userKeyHex;
        bufferedIsDelete = isDelete;
      } else {
        // Same key — newer version supersedes previous.
        bufferedIsDelete = isDelete;
      }
    }

    // Emit the last buffered entry.
    if (bufferedKey != null && !bufferedIsDelete && bufferedNs != null) {
      namespaces.add(bufferedNs);
    }

    return namespaces;
  }

  // ── Flush ─────────────────────────────────────────────────────────────────

  /// Checks whether the active memtable has reached the flush threshold and
  /// flushes + compacts if so.
  Future<void> _flushIfNeeded() async {
    if (_active.sizeBytes >= _config.memtableSizeBytes) {
      await flush();
    }
  }

  /// Flushes the active memtable to L0 SSTables and rotates the WAL.
  ///
  /// ## Two-writer split (local-only namespace segregation)
  ///
  /// The memtable is partitioned into two writers at flush time:
  ///
  /// - **Syncable writer** — receives entries whose namespace does NOT start
  ///   with `$$`. Produces `{deviceId}-{minHlc}-{maxHlc}.sst`.
  /// - **Local-only writer** — receives entries whose namespace starts with
  ///   `$$` (derived data: FTS, vector, secondary indexes). Produces
  ///   `{deviceId}-{minHlc}-{maxHlc}.local.sst`.
  ///
  /// If either partition is empty, its writer is discarded — no file is
  /// created and no `SstableMeta` entry is added for the empty partition.
  /// A single atomic [VersionEdit] is appended with up to two `SstableMeta`
  /// entries, ensuring the Manifest transition is crash-safe regardless of
  /// which partitions were non-empty.
  ///
  /// Steps:
  /// 1. Freeze the active memtable; start a new one.
  /// 2. Rotate the WAL (closes the current file, increments sequence). The new
  ///    active WAL's sequence becomes the boundary recovery replays from.
  /// 3. Partition and write up to two SSTable files.
  /// 4. Append a single [VersionEdit] to the Manifest (up to two `added`).
  /// 5. Discard the frozen memtable.
  /// 6. Run compaction if triggered.
  Future<void> flush() async {
    if (_active.length == 0) return; // nothing to flush

    // 1. Freeze and start fresh.
    _frozen = _active.freeze();
    _active = Memtable();

    // 2. Rotate WAL. The retired file is kept until its SSTable is confirmed
    // in the Manifest, then deleted in step 5 below.
    final hlc = _clock.now();
    await _walWriter.rotate();

    // 3. Partition the frozen memtable into syncable and local-only entries.
    //    Each partition tracks its own HLC range, key bounds, and entry count
    //    so the resulting SstableMeta records are fully accurate.
    final syncWriter = SstableWriter();
    Hlc? syncMinHlc;
    Hlc? syncMaxHlc;
    var syncEntryCount = 0;
    Uint8List? syncMinKeyBytes;
    Uint8List? syncMaxKeyBytes;

    final localWriter = SstableWriter();
    Hlc? localMinHlc;
    Hlc? localMaxHlc;
    var localEntryCount = 0;
    Uint8List? localMinKeyBytes;
    Uint8List? localMaxKeyBytes;

    for (final entry in _frozen!.entries) {
      final entryHlc = KeyCodec.decodeHlc(entry.key);
      final ns = KeyCodec.decodeNamespace(entry.key);

      if (isLocalOnly(ns)) {
        // Entry belongs to a $$-prefixed local-only namespace.
        localWriter.add(entry.key, entry.value);
        localEntryCount++;
        if (localMinHlc == null || entryHlc < localMinHlc) {
          localMinHlc = entryHlc;
        }
        if (localMaxHlc == null || entryHlc > localMaxHlc) {
          localMaxHlc = entryHlc;
        }
        localMinKeyBytes ??= entry.key;
        localMaxKeyBytes = entry.key;
      } else {
        // Entry belongs to a syncable namespace.
        syncWriter.add(entry.key, entry.value);
        syncEntryCount++;
        if (syncMinHlc == null || entryHlc < syncMinHlc) syncMinHlc = entryHlc;
        if (syncMaxHlc == null || entryHlc > syncMaxHlc) syncMaxHlc = entryHlc;
        syncMinKeyBytes ??= entry.key;
        syncMaxKeyBytes = entry.key;
      }
    }

    // Write non-empty partitions to disk and accumulate SstableMeta entries.
    // Both files (if present) are fsynced before the single Manifest append so
    // that a crash between the two file writes leaves both files on disk but
    // neither referenced by the Manifest — crash recovery discards them as
    // orphans. This preserves the crash-atomicity guarantee of a single
    // VersionEdit (review finding C2).
    final adds = <SstableMeta>[];

    if (syncEntryCount > 0) {
      final effectiveMin = syncMinHlc ?? hlc;
      final effectiveMax = syncMaxHlc ?? hlc;
      final filename = SstableInfo.flushName(
        _deviceId,
        effectiveMin,
        effectiveMax,
      );
      final sstPath = '$_sstDir/$filename';
      await _adapter.writeFile(sstPath, syncWriter.finish());
      await _adapter.syncFile(sstPath);
      adds.add(
        SstableMeta(
          level: 0,
          filename: filename,
          minKey: syncMinKeyBytes != null ? _bytesToHex(syncMinKeyBytes) : '',
          maxKey: syncMaxKeyBytes != null ? _bytesToHex(syncMaxKeyBytes) : '',
          entryCount: syncEntryCount,
          walSequence: _walWriter.activeSequence - 1, // the now-retired WAL
          localOnly: false,
        ),
      );
    }

    if (localEntryCount > 0) {
      final effectiveMin = localMinHlc ?? hlc;
      final effectiveMax = localMaxHlc ?? hlc;
      final filename = SstableInfo.flushName(
        _deviceId,
        effectiveMin,
        effectiveMax,
        localOnly: true,
      );
      final sstPath = '$_sstDir/$filename';
      await _adapter.writeFile(sstPath, localWriter.finish());
      await _adapter.syncFile(sstPath);
      adds.add(
        SstableMeta(
          level: 0,
          filename: filename,
          minKey: localMinKeyBytes != null ? _bytesToHex(localMinKeyBytes) : '',
          maxKey: localMaxKeyBytes != null ? _bytesToHex(localMaxKeyBytes) : '',
          entryCount: localEntryCount,
          // walSequence only on the syncable file; local-only files do not
          // retire a separate WAL (both partitions share the same retired WAL
          // from step 2 above). Recording walSequence on the local-only file
          // would be redundant and could confuse crash recovery.
          localOnly: true,
        ),
      );
    }

    // Durably link all new SSTable directory entries before the manifest records
    // them; on Linux the fsyncs above do not persist the names (review H1).
    await _adapter.syncDir(_sstDir);

    // 4. Append a single VersionEdit to the Manifest — one atomic write covers
    // up to two SstableMeta entries. The fsyncs above guarantee both files are
    // durable before this point (review finding C2). An empty `adds` list means
    // the memtable had zero entries (guarded by the early return above, so this
    // is only reachable in tests that bypass the guard).
    await _manifestWriter.append(
      VersionEdit(
        logNumber: _walWriter.activeSequence,
        nextSeq: hlc.encoded,
        added: adds,
      ),
    );

    // Update level 0 list with the produced SstableMeta objects.
    for (final meta in adds) {
      (_levels[0] ??= []).add(meta);
    }

    // 5. Discard frozen memtable.
    _frozen = null;

    // Delete all WAL files that have now been fully persisted in the SSTable.
    // Normally this is just the one file returned by rotate(), but after a
    // two-phase open (e.g. DatabaseOpener) older WAL files may have been
    // replayed into the restored memtable and are now superseded as well.
    // Any file with sequence < activeSequence is safe to remove.
    final allWalFiles = await _adapter.listFiles(_dbDir, extension: '.log');
    for (final name in allWalFiles) {
      if (!name.startsWith('wal-') || !name.endsWith('.log')) continue;
      final seqStr = name.substring(4, name.length - 4);
      final seq = int.tryParse(seqStr);
      if (seq == null || seq >= _walWriter.activeSequence) continue;
      await _adapter.deleteFile('$_dbDir/$name');
    }

    // 6. Rotate manifest if needed, then compact.
    await _rotateManifestIfNeeded();
    await _compactIfNeeded();
  }

  // ── Compaction ────────────────────────────────────────────────────────────

  /// Runs one round of compaction if any trigger condition is met.
  Future<void> _compactIfNeeded() async {
    // Single-file shortcut: collapse everything to one L2 file if total
    // data ≤ singleFileThresholdBytes.
    final totalFiles =
        (_levels[0] ?? []).length +
        (_levels[1] ?? []).length +
        (_levels[2] ?? []).length;

    if (totalFiles > 1 &&
        await _totalSstBytes() <= _config.singleFileThresholdBytes) {
      await _compactAll();
      return;
    }

    // L0 trigger: ≥ l0CompactionTrigger files.
    if ((_levels[0] ?? []).length >= _config.l0CompactionTrigger) {
      await _compactL0ToL1();
    }

    // L1 trigger: total L1 bytes > l1MaxBytes.
    if (await _levelBytes(1) > _config.l1MaxBytes) {
      await _compactL1ToL2();
    }
  }

  /// Compacts all L0 files (plus any existing L1 files) into one or more L1
  /// files.
  ///
  /// Both L0 and L1 are cleared and replaced with the compaction output. Using
  /// a single job for both input levels avoids double-counting issues.
  Future<void> _compactL0ToL1() async {
    final l0 = (_levels[0] ?? [])
        .map((e) => SstableRef(level: 0, filename: e.filename))
        .toList();
    final l1 = (_levels[1] ?? [])
        .map((e) => SstableRef(level: 1, filename: e.filename))
        .toList();
    final inputs = [...l0, ...l1];
    if (inputs.isEmpty) return;

    final hlc = _clock.now();
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 1,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
    );
    final edit = await job.run();

    // Build a set of output filenames so we never delete a file that was
    // written as the compaction output. This guards against the edge case
    // where the output HLC range exactly matches an input (same filename).
    // Evict ALL removed-file cache entries regardless of whether the filename
    // matches a compaction output. When an output filename equals an input
    // filename (the HLC range did not change), the compaction job overwrites
    // the file in place — so the cached reader for that path is stale and
    // must not be served. The file itself must not be deleted in that case
    // (it now holds the compaction output), so the eviction and deletion
    // steps are separated.
    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      // Evict always: the file was an input and is now either deleted or
      // overwritten by the compaction output.
      _tableCache.evict('$_sstDir/${ref.filename}');
      if (outputNames.contains(ref.filename)) {
        // Same filename reused as output — the compaction wrote the new
        // content in place. Do not delete it.
        continue;
      }
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    // Clear both input levels and populate with the job's output SstableMeta
    // objects — they already carry real minKey/maxKey/entryCount from the
    // CompactionJob, so no re-derivation is needed.
    _levels[0] = [];
    _levels[1] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added);
    }
  }

  /// Compacts all L1 files into L2.
  Future<void> _compactL1ToL2() async {
    final inputs = (_levels[1] ?? [])
        .map((e) => SstableRef(level: 1, filename: e.filename))
        .toList();
    if (inputs.isEmpty) return;

    final hlc = _clock.now();
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 2,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
    );
    final edit = await job.run();

    // Evict all removed-file cache entries. Skip file deletion for any input
    // whose filename was reused as the output (in-place overwrite).
    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      _tableCache.evict('$_sstDir/${ref.filename}');
      if (outputNames.contains(ref.filename)) continue;
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    // Populate from the job's output SstableMeta (real minKey/maxKey/entryCount).
    _levels[1] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added);
    }
  }

  /// Collapses all files across all levels into a single L2 file.
  ///
  /// Used when total data fits within [KvStoreConfig.singleFileThresholdBytes].
  /// This is the **only** compaction path that may drop tombstones: it
  /// covers every level that could hold an older version (so the
  /// `allLevels` safety condition is satisfied) and passes the computed
  /// tombstone-GC horizon to [CompactionJob]. See `plan_tombstone_gc.md`.
  ///
  /// ## GC floor advance (H4-FU3)
  ///
  /// After the [VersionEdit] is persisted to the manifest (durable), if the
  /// [CompactionJob] dropped at least one tombstone, the tombstone GC floor
  /// in `$meta` is advanced to [horizon] via a separate `$meta` put.
  ///
  /// ### Atomicity note (Q6 option b)
  ///
  /// The floor write is a *separate* WAL frame from the compaction's manifest
  /// commit. There is a small crash window between "manifest committed" and
  /// "floor written": if the process crashes here the engine will have GC'd
  /// state (manifest reflects the post-compaction files) with a stale floor
  /// (still the pre-compaction value). In that window, a subsequent ingest of
  /// a sub-floor SSTable would succeed instead of being rejected. This is a
  /// pessimistic outcome — the data may be benign — but it is not a permanent
  /// safety violation: the floor is advanced the next time any all-levels
  /// compaction drops a tombstone. The window is identical to the window that
  /// existed before H4-FU3 was applied (i.e. no floor at all), and closes
  /// permanently once the floor is written. Option (c) — folding the floor
  /// into the compaction's atomic unit — is not structurally available because
  /// [CompactionJob.run] writes its [VersionEdit] directly to the
  /// [ManifestWriter] and returns to this method only after the manifest is
  /// already durable.
  Future<void> _compactAll() async {
    final inputs = [
      ...(_levels[0] ?? []).map(
        (e) => SstableRef(level: 0, filename: e.filename),
      ),
      ...(_levels[1] ?? []).map(
        (e) => SstableRef(level: 1, filename: e.filename),
      ),
      ...(_levels[2] ?? []).map(
        (e) => SstableRef(level: 2, filename: e.filename),
      ),
    ];
    if (inputs.isEmpty) return;

    // Run a single job treating all inputs as a single merge and outputting to L2.
    final hlc = _clock.now();
    final horizon = await _computeTombstoneHorizon();
    // Build the policy registry: use the version-registry provider if available,
    // otherwise fall back to the default registry (RetainAllVersionsPolicy for
    // all $ver: prefixes — no per-collection trimming).
    final policyRegistry = _versionRegistryProvider != null
        ? await _versionRegistryProvider!()
        : ReclamationPolicyRegistry();
    // Clock injection (RQ6): wall-clock ms is captured here at job-construction
    // time so the compaction's filterGroup calls use a consistent snapshot of
    // "now" regardless of how long the compaction takes.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 2,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
      allLevels: true,
      horizon: horizon,
      nowMs: nowMs,
      policyRegistry: policyRegistry,
    );
    final edit = await job.run();

    // Evict all removed-file cache entries, then delete files whose name is
    // not reused by the compaction output. When the merged HLC range equals an
    // input's range the output is written to the same path; deleting it would
    // erase the new content. Eviction is always required — even for files whose
    // name is reused, because the compaction overwrites the content in place.
    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      _tableCache.evict('$_sstDir/${ref.filename}');
      if (outputNames.contains(ref.filename)) continue;
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    // Update levels from VersionEdit outputs. The job's SstableMeta objects
    // already carry real minKey/maxKey/entryCount — store them directly.
    _levels[0] = [];
    _levels[1] = [];
    _levels[2] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added);
    }

    // Advance the GC floor if this compaction dropped at least one tombstone.
    // The floor write is a separate $meta put *after* the manifest is durable
    // (Q6 option b — see doc comment above for the atomicity analysis).
    if (job.tombstonesDropped > 0) {
      await _metaStore?.setTombstoneFloor(horizon);
    }

    // Invoke the version-drop callback if any $ver: entries were trimmed by
    // filterGroup. This releases vault ref counts for vault URIs in those
    // entries (RQ5). The callback runs AFTER the manifest is durable so a
    // crash here leaves refs over-counted (fail-safe: retain, never delete).
    final droppedValues = job.droppedVersionValues;
    if (droppedValues.isNotEmpty) {
      await _versionDropCallback?.call(droppedValues);
    }
  }

  /// Runs compaction until all trigger conditions are cleared.
  Future<void> compactAll() async {
    for (var i = 0; i < 20; i++) {
      // Safety limit: at most 20 passes.
      final before = _levelsSummary();
      await _compactIfNeeded();
      if (_levelsSummary() == before) break; // stable
    }
  }

  // ── Manifest rotation ─────────────────────────────────────────────────────

  /// Rotates the Manifest if it has grown beyond [kManifestRotationThreshold].
  ///
  /// Writes a snapshot VersionEdit listing all live files, then updates CURRENT
  /// to point to the new Manifest.
  Future<void> _rotateManifestIfNeeded() async {
    if (!_manifestWriter.shouldRotate) return;

    // Lazily import to avoid circular reference — CurrentFile and
    // ManifestWriter are separate classes.
    await _doManifestRotation();
  }

  /// Performs the manifest rotation: writes a snapshot [VersionEdit] listing
  /// all live files to a new manifest, atomically updates `CURRENT`, and
  /// deletes the old manifest.
  ///
  /// The snapshot edit is built directly from the [SstableMeta] values in
  /// [_levels], so all diagnostic fields (minKey, maxKey, entryCount) are
  /// preserved verbatim from the in-memory level map. Because every flush,
  /// compaction, ingest, and reassignment site now populates real metadata into
  /// [_levels], rotation snapshots will carry real values for all live files.
  ///
  /// **Pre-fix manifests:** files last seen by a pre-fix rotation-snapshot edit
  /// (written before `plan_sstable_meta_tracking.md` was implemented) will
  /// surface with empty minKey/maxKey and zero entryCount in [_levels] and
  /// therefore in the rotated snapshot too. These stale zeros are self-healing:
  /// the next flush/compaction/ingest/reassignment edit for those files will
  /// carry real metadata, and subsequent rotations will snapshot the corrected
  /// level map. No retroactive file re-reading is performed at rotation time
  /// (D2 rationale: startup I/O proportional to file count for a diagnostic-only
  /// field).
  Future<void> _doManifestRotation() async {
    // Derive the new manifest name from the current one.
    final currentFile = CurrentFile(dbDir: _dbDir, adapter: _adapter);
    final currentName = await currentFile.read();
    final newName = CurrentFile.nextManifestName(currentName);
    final newPath = '$_dbDir/$newName';

    // Build snapshot edit from the metadata-bearing level map. Each SstableMeta
    // in _levels already carries the correct level, filename, minKey, maxKey,
    // entryCount, and walSequence — use them directly without reconstruction.
    final hlc = _clock.now();
    final allFiles = <SstableMeta>[];
    for (final lvlEntry in _levels.entries) {
      allFiles.addAll(lvlEntry.value);
    }
    final snapshotEdit = VersionEdit(
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
      added: allFiles,
    );

    // Durable commit order for the rotation (review findings C2 / M3):
    // 1. Write the new manifest; append() fsyncs its content.
    final newWriter = ManifestWriter(path: newPath, adapter: _adapter);
    await newWriter.append(snapshotEdit);
    // 2. Link the new manifest's directory entry before anything points to it.
    await _adapter.syncDir(_dbDir);
    // 3. Publish CURRENT durably (write+fsync tmp → rename → syncDir). Only now
    //    is the new manifest authoritative; a crash before this leaves the old
    //    manifest valid.
    await currentFile.write(newName);
    // 4. The old manifest is now unreferenced — delete it last.
    await _adapter.deleteFile(_manifestWriter.path);

    _manifestWriter = newWriter;
  }

  // ── SSTable ingestion ─────────────────────────────────────────────────────

  /// Registers [filename] as an L0 SSTable and persists a [VersionEdit].
  ///
  /// The file must already be written to `[_sstDir]/[filename]`. This method:
  ///
  /// 1. Opens the SSTable reader to validate the footer checksum and read
  ///    entry metadata.
  /// 2. Parses the filename to extract the HLC range.
  /// 3. **Checks the GC floor (H4-FU3).** If `info.maxHlc <= floor` the file
  ///    is rejected with [StaleSstableIngestException]. The floor is the
  ///    highest `horizon` ever used by a tombstone-dropping [CompactionJob] on
  ///    this device. Ingesting a file below the floor could resurrect deleted
  ///    data whose tombstone no longer exists. The check uses `<=` (not `<`)
  ///    because a record at exactly the floor HLC was not itself GC-eligible,
  ///    but the conservative `<=` posture avoids an off-by-one argument at
  ///    review time (see Q7 in the plan).
  ///
  ///    **The file is left on disk after rejection** — it was written before
  ///    this method was called and removing it here would risk a partial-state
  ///    hazard under retry. The next open's orphan-sweep reclaims it if needed.
  /// 4. Advances the local HLC clock to `info.maxHlc` (causal consistency).
  /// 5. Appends a [VersionEdit] to the Manifest.
  /// 6. Adds the file to the L0 level list.
  /// 7. Runs compaction if triggered.
  ///
  /// Throws [CorruptedSstableException] if the footer checksum is invalid.
  /// Throws [StaleSstableIngestException] if `info.maxHlc <= gcFloor`.
  Future<void> ingestAt0(String filename) async {
    final path = '$_sstDir/$filename';
    // Open the reader — validates footer checksum and loads index/filter.
    // Route through _tableCache so the validated reader is available for
    // the compaction that may immediately follow.
    final reader = await _tableCache.open(path, _adapter);
    final entryCount = reader.entryCount;

    // Parse the filename to obtain minHlc / maxHlc cheaply (no body scan).
    final info = SstableInfo.parse(filename);

    // GC floor check (H4-FU3): reject SSTables whose maxHlc is at or below
    // the highest horizon ever used for a tombstone drop on this device.
    // Using <= is correct and conservative — see the doc comment above.
    final metaStore = _metaStore;
    if (metaStore != null) {
      final floor = await metaStore.getTombstoneFloor();
      if (floor.encoded != 0 && info.maxHlc <= floor) {
        throw StaleSstableIngestException(
          filename: filename,
          maxHlc: info.maxHlc,
          floor: floor,
        );
      }
    }

    // Advance the local clock to ensure subsequent local writes are causally
    // after the ingested data.
    advanceClock(info.maxHlc);

    final hlc = _clock.now();

    // Derive diagnostic metadata from the already-opened reader.
    //
    // maxKey: reader.index.last.lastKey is available without any extra I/O —
    // the index block was loaded during reader.open() above.
    //
    // minKey: requires reading the first data block to obtain the first key;
    // this is one readFileRange of ≤4 KiB. Wrapped in try/catch because minKey
    // is a diagnostic-only field — a failure must never abort an ingest that has
    // already passed its correctness checks (D4 rationale).
    String maxKey = '';
    String minKey = '';
    if (reader.index.isNotEmpty) {
      maxKey = _bytesToHex(reader.index.last.lastKey);
      try {
        final firstKeyBytes = await reader.firstKey();
        if (firstKeyBytes != null) {
          minKey = _bytesToHex(firstKeyBytes);
        }
      } on Exception {
        // First-block read failed — fall back to empty string. The ingest
        // itself is unaffected; only the diagnostic minKey field is missing.
      }
    }

    final meta = SstableMeta(
      level: 0,
      filename: filename,
      minKey: minKey,
      maxKey: maxKey,
      entryCount: entryCount,
      // walSequence is null for peer-ingested files (they don't retire a WAL).
    );

    await _manifestWriter.append(
      VersionEdit(
        logNumber: _walWriter.activeSequence,
        nextSeq: hlc.encoded,
        added: [meta],
      ),
    );

    (_levels[0] ??= []).add(meta);

    // Notify listeners that new data is available (use '$sync' namespace to
    // signal sync-sourced data without targeting a specific user namespace).
    _writeEventsController.add(r'$sync');

    await _rotateManifestIfNeeded();
    await _compactIfNeeded();
  }

  // ── Full-resync support ───────────────────────────────────────────────────

  /// Removes every SSTable currently tracked in the manifest and deletes
  /// each file from disk.
  ///
  /// Used by [SyncEngine] when stale-device eviction triggers a full re-sync:
  /// the local SSTables are no longer trustworthy relative to the advanced
  /// horizon, so they are discarded and the engine is left ready to receive
  /// the consolidated set from the sync folder via [ingestAt0].
  ///
  /// Manifest consistency is the load-bearing invariant: a single
  /// [VersionEdit] with every current file in `removed` is appended *before*
  /// the `.sst` files are unlinked, so a crash mid-call leaves the manifest
  /// pointing at a strictly smaller set of files (the leftover orphans are
  /// reclaimed by crash recovery on the next open). Removing files first
  /// would create the inverse hazard — manifest entries referencing files
  /// that no longer exist.
  ///
  /// The memtable, WAL, and HLC clock are intentionally **not** touched.
  /// Callers that need a fully empty state must arrange that themselves; the
  /// SyncEngine eviction path treats the in-memory state as either already
  /// flushed (the common case — push() drains it) or recoverable from the
  /// WAL on the next open.
  Future<void> dropAllSstables() async {
    final removed = <SstableRef>[];
    for (final lvlEntry in _levels.entries) {
      for (final entry in lvlEntry.value) {
        removed.add(SstableRef(level: lvlEntry.key, filename: entry.filename));
      }
    }
    if (removed.isEmpty) return;

    final hlc = _clock.now();
    await _manifestWriter.append(
      VersionEdit(
        logNumber: _walWriter.activeSequence,
        nextSeq: hlc.encoded,
        removed: removed,
      ),
    );

    // Clear the table cache — all files being removed from the manifest are no
    // longer valid reads. Evict before deleting so a concurrent _openReader call
    // (in theory) cannot be handed a reader for a file that no longer exists.
    _tableCache.clear();
    _levels.clear();

    for (final ref in removed) {
      final path = '$_sstDir/${ref.filename}';
      try {
        await _adapter.deleteFile(path);
      } on Object {
        // File already absent; the manifest is the authority and is now
        // consistent. A returning device that finds an orphan SSTable will
        // also reclaim it via crash recovery on the next open.
      }
    }
  }

  // ── Device ID reassignment ────────────────────────────────────────────────

  /// Assigns a new device identity to this engine instance.
  ///
  /// This is the low-level implementation called by [KvStoreImpl.reassignDeviceId].
  /// It:
  ///
  /// 1. Validates [newDeviceId] — must be 8 lowercase hex chars, not equal to
  ///    the current device ID.
  /// 2. Flushes the active memtable so all in-memory data lands in SSTables
  ///    before any renaming occurs.
  /// 3. For each SSTable owned by this device (filename prefix matches current
  ///    device ID), renames the file to use [newDeviceId].
  /// 4. Appends a single [VersionEdit] to the Manifest recording all renames.
  /// 5. Updates `[_deviceId]` so subsequent flushes and compactions use the
  ///    new identity.
  ///
  /// **Crash safety:** if the process dies during step 3 (renames), the next
  /// open will replay the Manifest and find the old filenames still referenced.
  /// The renamed files will be treated as orphans and deleted during crash
  /// recovery, while the old-named files remain valid — i.e. the rename is
  /// idempotent. The device ID in `$meta` is not written until after the
  /// VersionEdit is persisted, so the caller ([KvStoreImpl]) updates `$meta`
  /// after this method returns.
  Future<void> reassignDeviceId(String newDeviceId) async {
    // Validate format: must be exactly 8 lowercase hex characters.
    final hexPattern = RegExp(r'^[0-9a-f]{8}$');
    if (!hexPattern.hasMatch(newDeviceId)) {
      throw ArgumentError.value(
        newDeviceId,
        'newDeviceId',
        'Device ID must be exactly 8 lowercase hex characters (e.g. "a1b2c3d4")',
      );
    }
    if (newDeviceId == _deviceId) {
      throw ArgumentError.value(
        newDeviceId,
        'newDeviceId',
        'New device ID must differ from the current device ID ($_deviceId)',
      );
    }

    // Flush the active memtable first so there are no in-memory entries that
    // have not yet been written to an SSTable under the old device ID. This
    // ensures the rename step covers the complete set of owned SSTables.
    await flush();

    // Collect all SSTable entries from the current manifest state that belong
    // to this device (filename prefix = current device ID).
    final oldPrefix = '$_deviceId-';
    final removed = <SstableRef>[];
    final added = <SstableMeta>[];

    // Build the list of renames across all levels, carrying metadata forward.
    final newLevels = <int, List<SstableMeta>>{};
    for (final lvlEntry in _levels.entries) {
      final level = lvlEntry.key;
      final newMetas = <SstableMeta>[];
      for (final oldMeta in lvlEntry.value) {
        if (oldMeta.filename.startsWith(oldPrefix)) {
          // Replace only the device ID prefix — the rest of the filename
          // (HLC timestamps and extension) is unchanged.
          final newFilename = newDeviceId + oldMeta.filename.substring(8);

          // Evict the old-path reader from the cache before the rename: after
          // the rename the old path no longer exists, so any cached reader for
          // it would be stale. The new path will be populated lazily on the
          // first _openReader call after the rename.
          _tableCache.evict('$_sstDir/${oldMeta.filename}');

          // Rename on disk.
          await _adapter.renameFile(
            '$_sstDir/${oldMeta.filename}',
            '$_sstDir/$newFilename',
          );

          // Record the rename for the VersionEdit. The new SstableMeta copies
          // all diagnostic fields from the source — the renamed file is
          // byte-identical, so minKey/maxKey/entryCount/walSequence/localOnly
          // are unchanged. Only the filename is updated.
          removed.add(SstableRef(level: level, filename: oldMeta.filename));
          final newMeta = SstableMeta(
            level: level,
            filename: newFilename,
            minKey: oldMeta.minKey,
            maxKey: oldMeta.maxKey,
            entryCount: oldMeta.entryCount,
            walSequence: oldMeta.walSequence,
            localOnly: oldMeta.localOnly,
          );
          added.add(newMeta);
          newMetas.add(newMeta);
        } else {
          // Peer-owned SSTable — do not rename; preserve metadata as-is.
          newMetas.add(oldMeta);
        }
      }
      newLevels[level] = newMetas;
    }

    // Append a single VersionEdit to the Manifest recording all renames.
    // This is written before updating _deviceId so that, on crash recovery,
    // the old names are still in the Manifest and the renamed files on disk
    // are treated as orphans (deleted) — a safe, recoverable state.
    if (removed.isNotEmpty) {
      final hlc = _clock.now();
      await _manifestWriter.append(
        VersionEdit(
          logNumber: _walWriter.activeSequence,
          nextSeq: hlc.encoded,
          added: added,
          removed: removed,
        ),
      );
    }

    // Update the in-memory level map and device ID.
    for (final entry in newLevels.entries) {
      _levels[entry.key] = entry.value;
    }
    _deviceId = newDeviceId;
  }

  // ── Close ─────────────────────────────────────────────────────────────────

  /// Flushes the active memtable (if [flush] is true) and releases the LOCK file.
  Future<void> close({bool flush = true}) async {
    if (flush && _active.length > 0) await this.flush();
    // Release cached readers before releasing the LOCK — all in-memory
    // SSTable state is discarded with the engine instance.
    _tableCache.clear();
    await _adapter.releaseLock('$_dbDir/LOCK');
    await _writeEventsController.close();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Returns a string key summarising the current level file counts (for
  /// compaction stability detection).
  String _levelsSummary() =>
      '${(_levels[0] ?? []).length}/${(_levels[1] ?? []).length}/${(_levels[2] ?? []).length}';

  /// Opens the SSTable at [path] via the [TableCache], returning `null` on
  /// I/O or corruption error.
  ///
  /// On the first call for a given [path] the file is read, its whole-file
  /// XXH64 checksum validated, and the resulting reader cached. Subsequent
  /// calls return the cached reader without any file I/O. The cache is
  /// LRU-bounded by [KvStoreConfig.tableCacheSize].
  ///
  /// Returns `null` (rather than throwing) so callers can skip missing files
  /// without disrupting the read/scan loop — a file may be absent because it
  /// was deleted by a concurrent compaction in a future multi-isolate model, or
  /// because the recovery path found an orphan.
  Future<SstableReader?> _openReader(String path) async {
    try {
      return await _tableCache.open(path, _adapter);
    } on StorageException {
      return null;
    }
  }

  /// Gets the latest value for the user key identified by [prefix]/[prefixEnd]
  /// from an SSTable at [path].
  ///
  /// Returns a named record with three distinct states:
  /// - `null` (outer) — the key is absent in this file; the caller should
  ///   continue searching older files.
  /// - `({value: null})` — the key's newest version in this file is a
  ///   tombstone; the caller must **stop** and treat the key as deleted,
  ///   i.e. return `null` to the reader without consulting older files.
  ///   Collapsing this state into plain `null` would cause the loop to skip
  ///   past the tombstone and resurrect the deleted value from an older file.
  /// - `({value: bytes})` — a live value was found; return it.
  ///
  /// Returns `null` (outer) also when the file is unreadable.
  Future<({Uint8List? value})?> _getFromSstable(
    String path,
    Uint8List prefix,
    Uint8List? prefixEnd,
  ) async {
    final reader = await _openReader(path);
    if (reader == null) return null;

    // Scan over all internal-key versions for this user key.
    // The LAST entry in the scan is the most recent (highest HLC).
    Uint8List? lastKey;
    Uint8List? lastValue;

    await for (final entry in reader.scan(start: prefix, end: prefixEnd)) {
      // Verify the entry's key actually starts with our prefix (safety check).
      if (!_hasPrefix(entry.key, prefix)) break;
      lastKey = entry.key;
      lastValue = entry.value;
    }

    if (lastKey == null) return null; // key not in this SSTable — try next file
    final type = KeyCodec.decodeRecordType(lastKey);
    // Tombstone: stop the search — do not fall through to older files.
    if (type == RecordType.delete) return (value: null);
    return (value: lastValue);
  }

  /// Returns the last entry from an iterable of [SkipListEntry]s (highest
  /// HLC = most recent version for a given user key).
  ///
  /// Returns `null` if [entries] is empty.
  ({bool isDelete, Uint8List value})? _latestFromIterable(
    Iterable<SkipListEntry> entries,
  ) {
    SkipListEntry? last;
    for (final e in entries) {
      last = e;
    }
    if (last == null) return null;
    final type = KeyCodec.decodeRecordType(last.key);
    return (isDelete: type == RecordType.delete, value: last.value);
  }

  /// Returns true when [key] starts with [prefix] byte-by-byte.
  static bool _hasPrefix(Uint8List key, Uint8List prefix) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Builds the `[nsLen][ns][userKey16]` prefix used for range lookups.
  ///
  /// Uses [namespaceToBytes] to produce the same UTF-8 encoding as the write
  /// path, so scan prefixes always match the keys on disk.
  static Uint8List _buildKeyPrefix(String namespace, Uint8List userKeyBytes) {
    final nsBytes = namespaceToBytes(namespace);
    final out = Uint8List(1 + nsBytes.length + 16);
    out[0] = nsBytes.length;
    out.setAll(1, nsBytes);
    out.setAll(1 + nsBytes.length, userKeyBytes);
    return out;
  }

  /// Builds the `[nsLen][ns]` prefix used for scanning an entire namespace.
  ///
  /// Uses [namespaceToBytes] to produce the same UTF-8 encoding as the write
  /// path, so scan prefixes always match the keys on disk.
  static Uint8List _buildNamespacePrefix(String namespace) {
    final nsBytes = namespaceToBytes(namespace);
    final out = Uint8List(1 + nsBytes.length);
    out[0] = nsBytes.length;
    out.setAll(1, nsBytes);
    return out;
  }

  /// Returns the exclusive upper bound for a prefix scan.
  ///
  /// Increments the last non-0xFF byte of [prefix]. Returns `null` when
  /// [prefix] is all 0xFF bytes (scan has no upper bound).
  static Uint8List? _nextPrefix(Uint8List prefix) {
    if (prefix.isEmpty) return null;
    final result = Uint8List.fromList(prefix);
    for (var i = result.length - 1; i >= 0; i--) {
      if (result[i] < 0xFF) {
        result[i]++;
        return result;
      }
      result[i] = 0;
    }
    return null; // all 0xFF — no upper bound
  }

  /// Converts a memtable scan range to a [SstEntry] stream.
  Stream<SstEntry> _skipListRangeToStream(
    dynamic source, // Memtable | FrozenMemtable
    Uint8List start,
    Uint8List? end,
  ) async* {
    final Iterable<SkipListEntry> entries;
    if (source is Memtable) {
      entries = source.scan(start: start, end: end);
    } else if (source is FrozenMemtable) {
      entries = source.scan(start: start, end: end);
    } else {
      return;
    }
    for (final e in entries) {
      yield SstEntry(e.key, e.value);
    }
  }

  /// Total bytes across all SSTable files on disk.
  Future<int> _totalSstBytes() async {
    var total = 0;
    for (final level in _levels.values) {
      for (final entry in level) {
        try {
          total += await _adapter.fileSize('$_sstDir/${entry.filename}');
        } on StorageException {
          // File may have been deleted by a concurrent compaction.
        }
      }
    }
    return total;
  }

  /// Total bytes at a specific level.
  Future<int> _levelBytes(int level) async {
    var total = 0;
    for (final entry in (_levels[level] ?? [])) {
      try {
        total += await _adapter.fileSize('$_sstDir/${entry.filename}');
      } on StorageException {
        /* skip */
      }
    }
    return total;
  }

  // ── Public stats / info ───────────────────────────────────────────────────

  /// Returns the database directory path.
  String get dbDir => _dbDir;

  /// Returns the current device ID.
  String get deviceId => _deviceId;

  /// Returns the current HLC clock value as a hex string.
  ///
  /// Format: `<12 hex chars for physical ms>:<4 hex chars for logical counter>`
  String get currentHlcString {
    final physHex = _clock.current.physicalMs
        .toRadixString(16)
        .padLeft(12, '0');
    final logHex = _clock.current.logical.toRadixString(16).padLeft(4, '0');
    return '$physHex:$logHex';
  }

  /// Returns SSTable file counts per level and total on-disk byte sizes.
  Future<({int l0, int l1, int l2, int totalSstBytes, int totalDbBytes})>
  levelStats() async {
    final l0 = (_levels[0] ?? []).length;
    final l1 = (_levels[1] ?? []).length;
    final l2 = (_levels[2] ?? []).length;
    final sstBytes = await _totalSstBytes();

    // Total DB bytes: SSTables + all files in _dbDir (WAL, Manifest, CURRENT,
    // LOCK). We sum sizes for all known SST files and add a pass over the
    // root dir for the remaining files.
    var rootBytes = 0;
    try {
      for (final name in await _adapter.listFiles(_dbDir)) {
        try {
          rootBytes += await _adapter.fileSize('$_dbDir/$name');
        } on StorageException {
          /* skip */
        }
      }
    } on StorageException {
      /* skip if dir listing fails */
    }
    final totalDbBytes = sstBytes + rootBytes;

    return (
      l0: l0,
      l1: l1,
      l2: l2,
      totalSstBytes: sstBytes,
      totalDbBytes: totalDbBytes,
    );
  }

  // ── Hex helper ────────────────────────────────────────────────────────────

  static String _bytesToHex(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
