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

import '../compaction/reclamation_policy.dart' show ReclamationPolicyRegistry;
import '../util/hlc.dart';

// ── KvStore interface ─────────────────────────────────────────────────────────

/// The primary key-value storage interface.
///
/// Abstracts the LSM engine so upper layers (Cache Layer, Query Layer) do not
/// depend on the concrete implementation. Obtain an instance via
/// [KvStoreImpl.open].
///
/// ## System namespaces
///
/// Namespaces prefixed with `$` are reserved for internal use (e.g. `$meta`,
/// `$index:...`). Client code must not read or write these directly.
///
/// ## Thread safety
///
/// All methods are safe to call from a single isolate. KMDB does not use
/// background isolates; callers must not issue concurrent writes.
abstract interface class KvStore {
  /// Writes [value] under [key] in [namespace].
  ///
  /// [key] must be a 32-character lowercase hex string (binary UUIDv7).
  ///
  /// Validation is enforced for all user namespaces. Any key that does not
  /// follow the UUIDv7 format (version 7, variant 2) will cause an
  /// [ArgumentError] to be thrown. System namespaces (starting with `$`) are
  /// exempt from this format validation.
  Future<void> put(String namespace, String key, Uint8List value);

  /// Writes a delete tombstone for [key] in [namespace].
  ///
  /// [key] must be a valid UUIDv7 hex string. Format validation is enforced
  /// for user namespaces.
  ///
  /// Subsequent [get] calls return `null` until a new value is written.
  Future<void> delete(String namespace, String key);

  /// Commits all entries in [batch] atomically.
  ///
  /// Either all entries land in the WAL and memtable, or none do.
  Future<void> writeBatch(WriteBatch batch);

  /// Returns the raw value bytes for [key] in [namespace], or `null` if
  /// the key does not exist or has been deleted.
  Future<Uint8List?> get(String namespace, String key);

  /// Returns a stream of entries in [namespace] in ascending key order.
  ///
  /// [startKey] and [endKey] are optional 32-character hex strings.
  /// [startKey] is inclusive; [endKey] is exclusive. Pass `null` for an
  /// unbounded scan.
  Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey});

  /// Returns a stream of **all** historical version entries for [docKey] in
  /// [namespace], in ascending HLC order (oldest first).
  ///
  /// Unlike [scan], which collapses multiple versions of the same user key to
  /// the latest (Last-Write-Wins), this method returns every version entry
  /// for the given [docKey], including superseded versions. It is intended
  /// exclusively for history-bearing namespaces such as `\$ver:{collection}`.
  ///
  /// Each yielded entry includes:
  /// - `VersionHistoryEntry.value` — the raw bytes stored for this version.
  /// - `VersionHistoryEntry.hlc` — the HLC extracted from the internal key,
  ///   which is the authoritative version timestamp.
  /// - `VersionHistoryEntry.isDelete` — whether this entry is a tombstone.
  ///
  /// Tombstones **are** included in the output (unlike [scan], which
  /// suppresses them). A tombstone in `\$ver:` is a delete-version entry
  /// recording that the document was deleted at this HLC.
  ///
  /// ## Usage
  ///
  /// ```dart
  /// await for (final v in store.scanVersionHistory(r'$ver:tasks', docKey)) {
  ///   print('${v.hlc.toHex()} isDelete=${v.isDelete}');
  /// }
  /// ```
  Stream<VersionHistoryEntry> scanVersionHistory(
    String namespace,
    String docKey,
  );

  /// Explicitly flushes the active memtable to an SSTable on disk.
  ///
  /// Normally the engine flushes automatically when the memtable reaches
  /// [KvStoreConfig.memtableSizeBytes]. This method is provided for tests and
  /// explicit durability checkpoints.
  Future<void> flush();

  /// Runs compaction until no further compaction is needed.
  ///
  /// Blocks the calling isolate. Only for tests and maintenance tooling.
  Future<void> compactAll();

  /// A broadcast stream that emits a namespace string after each successful
  /// write ([put], [delete], [writeBatch]).
  ///
  /// The Cache Layer and reactivity watcher subscribe to this stream to
  /// invalidate stale entries. Each write that touches multiple namespaces
  /// emits one event per unique namespace.
  Stream<String> get writeEvents;

  /// Ingests an externally-provided SSTable into the local database at L0.
  ///
  /// [filename] is the bare SSTable filename
  /// (e.g. `a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst`). [bytes] is the
  /// complete file content. The method:
  ///
  /// 1. Validates the SSTable footer checksum.
  /// 2. Writes the bytes to the local `sst/` directory.
  /// 3. Appends a VersionEdit to the Manifest recording the new L0 file.
  /// 4. Triggers compaction if needed.
  ///
  /// Throws an exception if the footer checksum fails. Throws
  /// [FormatException] if [filename] does not match the SSTable naming
  /// convention.
  ///
  /// This method is called by [SyncEngine.pull] after downloading a remote
  /// SSTable. The HLC clock is advanced to the SSTable's max HLC so locally
  /// generated timestamps remain causally after ingested ones.
  Future<void> ingestSstable(String filename, Uint8List bytes);

  /// Drops every SSTable currently tracked in the manifest and deletes the
  /// underlying files.
  ///
  /// Used by [SyncEngine] when stale-device eviction triggers a full re-sync.
  /// After this returns, no SSTables are registered in any level; the next
  /// [ingestSstable] call rebuilds the store from a peer-provided SSTable.
  ///
  /// The manifest update precedes file deletion, so a crash mid-call leaves
  /// the manifest referencing a strictly smaller (and consistent) set of
  /// files. The memtable, WAL, and HLC clock are not touched.
  ///
  /// **Caller responsibility:** any data not already replicated to the sync
  /// folder is lost. Callers must only invoke this in the eviction-recovery
  /// path or equivalent "discard local state and rebuild" scenarios.
  Future<void> dropAllSstables();

  /// Returns a sorted list of user-visible namespace names that have had at
  /// least one document written to them.
  ///
  /// System namespaces (those starting with `$`) are excluded. The list is
  /// derived from the namespace registry persisted in `$meta` and is therefore
  /// accurate across restarts.
  ///
  /// Returns an empty list for a brand-new database that has never been written
  /// to, or for databases created before this API was available.
  Future<List<String>> listNamespaces();

  /// Registers [namespace] in the namespace registry without writing any
  /// documents.
  ///
  /// Returns `true` if the namespace was newly created, or `false` if it was
  /// already registered (no-op, identical behaviour to `init` on an existing
  /// database).
  ///
  /// [namespace] must not start with `$` (system namespaces are reserved).
  /// Throws [ArgumentError] if that constraint is violated.
  Future<bool> createNamespace(String namespace);

  /// Returns a snapshot of engine-level statistics.
  ///
  /// Includes SSTable counts per level, total on-disk size, and the path to
  /// the database directory. Intended for the CLI `stats` command and
  /// diagnostic tooling.
  Future<StoreStats> stats();

  /// Returns identifying information about this database instance.
  ///
  /// Includes the stable device ID persisted in `$meta` and the current HLC
  /// clock value. Intended for the CLI `info` command.
  Future<StoreInfo> storeInfo();

  /// Assigns a new device identity to this store.
  ///
  /// All SSTable files whose filename begins with the current device ID are
  /// renamed to use [newDeviceId]. A single VersionEdit is appended to the
  /// Manifest recording the renames. The `$meta` device_id entry is updated
  /// last so that, on any crash before completion, the next open will still
  /// see the old ID and recover cleanly.
  ///
  /// [newDeviceId] must be an 8-character lowercase hex string. Throws
  /// [ArgumentError] if the format is invalid or if [newDeviceId] is the same
  /// as the current device ID.
  ///
  /// **Caller responsibility:** the store must be idle (no concurrent writes).
  /// The method calls [flush] internally before renaming to ensure all
  /// memtable data is persisted in SSTables first.
  ///
  /// Example:
  /// ```dart
  /// await store.reassignDeviceId('a1b2c3d4');
  /// ```
  Future<void> reassignDeviceId(String newDeviceId);

  /// Closes the store, optionally flushing the active memtable and releasing
  /// the LOCK.
  ///
  /// If [flush] is true (the default), the active memtable is flushed to an
  /// SSTable on disk before closing. If false, the data remains in the WAL/memtable
  /// and will be recovered by the next instance that opens this path.
  ///
  /// After [close] returns the instance must not be used again. A new
  /// instance can be opened on the same path.
  Future<void> close({bool flush = true});

  /// Registers a callback that provides the [ReclamationPolicyRegistry] for
  /// all-levels compaction, with per-collection `VersionRetentionPolicy`
  /// entries built from the current [VersionConfig] values in `$meta`.
  ///
  /// Called by [KvStoreImpl] after versioning is configured at open time.
  /// Pass `null` to revert to the default registry (no per-collection
  /// trimming).
  ///
  /// See `LsmEngine.setVersionRegistryProvider` for the implementation.
  void setVersionRegistryProvider(
    Future<ReclamationPolicyRegistry> Function()? provider,
  );

  /// Registers a callback that computes the GC horizon used by the
  /// all-levels compaction path to decide when a surviving delete
  /// tombstone may be dropped.
  ///
  /// A tombstone is eligible for drop only when its HLC is strictly below
  /// the returned horizon (see `plan_tombstone_gc.md`). The callback is
  /// invoked before each `_compactAll` and must not throw.
  ///
  /// When no provider is set, the engine falls back to the local-only
  /// computation `now - KvStoreConfig.tombstoneGraceDuration`. Pass `null`
  /// to revert to that default — for example if the [SyncEngine] is being
  /// detached or disabled.
  ///
  /// Used by [SyncEngine] to supply `min(currentHlc)` across all peer HWM
  /// files in the sync folder; not part of the normal application API.
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider);

  /// Registers a callback invoked after an all-levels compaction trims one or
  /// more `$ver:` version entries via `ReclamationPolicy.filterGroup`.
  ///
  /// The callback receives the raw value bytes (`List<Uint8List>`) of every
  /// trimmed [VersionEntry]. Each entry may contain vault URIs; the callback is
  /// responsible for decrementing the vault ref counts for those URIs.
  ///
  /// ## Crash posture (RQ5)
  ///
  /// The callback is invoked after `_compactAll` commits its [VersionEdit] to
  /// the Manifest (durable). If the process crashes before the callback
  /// completes, the ref counts are over-counted — the vault blobs are retained.
  /// This is the fail-safe: blobs are never deleted while possibly referenced.
  /// The count self-corrects on the next write that touches the same blob via
  /// the normal `VaultRefInterceptor.interceptWrite` diff.
  ///
  /// Pass `null` to unregister the callback (e.g. when vault is disabled).
  /// Mirrors the pattern of [setTombstoneHorizonProvider].
  void setVersionDropCallback(
    Future<void> Function(List<Uint8List> droppedValues)? callback,
  );

  /// Resets the tombstone GC floor to `Hlc(0, 0)` in `$meta`.
  ///
  /// Used by [SyncEngine._fullResync] before re-ingesting downloaded SSTables
  /// from the cloud folder. When a device performs a full re-sync it discards
  /// its local SSTables and rebuilds from the cloud's current state. The cloud
  /// folder may contain SSTables whose `maxHlc` is at or below the device's
  /// current GC floor — for example if consolidation has not yet run after the
  /// last GC cycle and individual per-device flush SSTables from before the
  /// consolidation are still present.
  ///
  /// Resetting the floor to zero before re-ingesting is safe because the
  /// re-sync rebuilds from the cloud's ground truth: all data the cloud has is
  /// ingested, including any SSTables that would otherwise be rejected. The
  /// floor will advance again the next time `_compactAll` drops a tombstone.
  ///
  /// ## Safety invariant
  ///
  /// After `resetTombstoneFloor` + re-ingest, the local state is consistent
  /// with the cloud's current view. The floor is zero, which means every
  /// incoming SSTable is accepted until the next tombstone-dropping compaction.
  /// This is the same state as a freshly-opened database that has never run GC.
  Future<void> resetTombstoneFloor();
}

// ── StoreStats ────────────────────────────────────────────────────────────────

/// Engine-level statistics returned by [KvStore.stats].
final class StoreStats {
  /// Creates a [StoreStats] snapshot.
  const StoreStats({
    required this.dbDir,
    required this.l0Count,
    required this.l1Count,
    required this.l2Count,
    required this.totalSstBytes,
    required this.totalDbBytes,
  });

  /// Absolute path to the database directory.
  final String dbDir;

  /// Number of SSTables at Level 0.
  final int l0Count;

  /// Number of SSTables at Level 1.
  final int l1Count;

  /// Number of SSTables at Level 2.
  final int l2Count;

  /// Total on-disk size of all SSTable files in bytes.
  final int totalSstBytes;

  /// Total on-disk size of all database files (SSTables + WAL + Manifest).
  final int totalDbBytes;

  /// Total number of SSTables across all levels.
  int get totalSstCount => l0Count + l1Count + l2Count;
}

// ── StoreInfo ────────────────────────────────────────────────────────────────

/// Identifying information returned by [KvStore.storeInfo].
final class StoreInfo {
  /// Creates a [StoreInfo] snapshot.
  const StoreInfo({
    required this.dbDir,
    required this.deviceId,
    required this.currentHlc,
  });

  /// Absolute path to the database directory.
  final String dbDir;

  /// The stable 8-character device identifier persisted in `$meta`.
  final String deviceId;

  /// The current HLC timestamp as a hex string (`physicalMs:logical`).
  ///
  /// Format: `"<48-bit physical ms as 12 hex chars>:<16-bit logical as 4 hex chars>"`
  final String currentHlc;
}

// ── Public types ──────────────────────────────────────────────────────────────

/// A raw key-value entry returned by [KvStore.scan].
typedef KvEntry = ({String key, Uint8List value});

/// A single version history entry returned by [KvStore.scanVersionHistory].
///
/// Carries the raw [value] bytes, the authoritative [hlc] extracted from the
/// internal key, and a flag indicating whether the entry is a tombstone.
typedef VersionHistoryEntry = ({Uint8List value, Hlc hlc, bool isDelete});

/// Describes what happened during KvStoreImpl.open crash recovery.
///
/// Recovery deletes WAL files whose sequence is below the Manifest's highest
/// `logNumber` (their writes are already in an SSTable) and replays every
/// retained WAL file — including the active one, whose sequence equals
/// `logNumber` — **in full**. Full replay is idempotent under HLC
/// last-write-wins, so any record already present in an SSTable is harmlessly
/// re-applied; this is what guarantees writes made after the last flush survive
/// an unclean shutdown (see §17).
final class OpenResult {
  const OpenResult({
    this.hadInterruptedWrites = false,
    this.affectedNamespaces = const [],
    this.hadUnclosedSession = false,
  });

  /// True if a retained WAL file was truncated and replay discarded its final
  /// partial record (checksum failure at the tail). Records before the
  /// truncation point are recovered.
  final bool hadInterruptedWrites;

  /// Namespaces that had interrupted writes. The Query Layer may need to
  /// rebuild indexes for these namespaces.
  final List<String> affectedNamespaces;

  /// True if the dirty-open flag in `$meta` was set, indicating an unclean
  /// shutdown. Broader than WAL checksum failures — any crash sets this.
  final bool hadUnclosedSession;
}

// ── WriteBatch ────────────────────────────────────────────────────────────────

/// A mutable builder for multi-write atomic operations.
///
/// The Query Layer constructs batches incrementally (including write
/// interception for secondary indexes — see §16) before committing with
/// [KvStore.writeBatch].
///
/// A batch is atomic: either all writes land in the WAL and memtable, or none
/// do. A crash after the WAL fsync but before the memtable update replays the
/// full batch on next open.
final class WriteBatch {
  WriteBatch();

  final List<BatchEntry> _entries = [];

  /// Adds a put operation to the batch.
  void put(String namespace, String key, Uint8List value) {
    _entries.add(BatchEntry(namespace: namespace, key: key, value: value));
  }

  /// Adds a delete tombstone to the batch.
  void delete(String namespace, String key) {
    _entries.add(BatchEntry(namespace: namespace, key: key, isDelete: true));
  }

  /// Removes all entries from the batch.
  void clear() => _entries.clear();

  /// Whether the batch has no entries.
  bool get isEmpty => _entries.isEmpty;

  /// Number of entries in the batch.
  int get length => _entries.length;

  /// Read-only view of the entries.
  List<BatchEntry> get entries => List.unmodifiable(_entries);
}

/// A single operation inside a [WriteBatch].
final class BatchEntry {
  const BatchEntry({
    required this.namespace,
    required this.key,
    this.value,
    this.isDelete = false,
  });

  final String namespace;
  final String key;
  final Uint8List? value;
  final bool isDelete;
}

// ── KvStoreConfig ─────────────────────────────────────────────────────────────

/// Configuration for [KvStore].
final class KvStoreConfig {
  const KvStoreConfig({
    this.memtableSizeBytes = 65536,
    this.l0CompactionTrigger = 2,
    this.l1MaxBytes = 2 * 1024 * 1024,
    this.l2MaxBytes = 20 * 1024 * 1024,
    this.singleFileThresholdBytes = 512 * 1024,
    this.blockSizeBytes = 4096,
    this.blockRestartInterval = 16,
    this.bloomBitsPerKey = 10,
    this.fsyncOnWrite = true,
    this.watchDebounce = const Duration(milliseconds: 50),
    this.maxClockSkew = const Duration(seconds: 60),
    this.maxValueBytes = 1024 * 1024,
    this.tombstoneGraceDuration = const Duration(days: 7),
    this.staleDeviceEvictionAfter = const Duration(days: 90),
    this.tableCacheSize = 256,
  });

  /// Memtable flush threshold in bytes.
  final int memtableSizeBytes;

  /// Number of L0 files that triggers a compaction.
  final int l0CompactionTrigger;

  /// Maximum total bytes at L1 before L1→L2 compaction.
  final int l1MaxBytes;

  /// Maximum total bytes at L2.
  final int l2MaxBytes;

  /// When total data ≤ this value, compact everything to a single L2 file.
  final int singleFileThresholdBytes;

  /// Target size for SSTable data blocks.
  final int blockSizeBytes;

  /// Restart interval for prefix compression within a data block.
  final int blockRestartInterval;

  /// Bits per key for the Bloom filter (~0.8% FPR at 10).
  final int bloomBitsPerKey;

  /// Whether to fsync the WAL after every write.
  final bool fsyncOnWrite;

  /// Debounce duration for [KvStore.writeEvents].
  final Duration watchDebounce;

  /// Maximum allowable clock skew for HLC updates.
  ///
  /// Forwarded to the engine's [HlcClock] and governs both the SSTable ingest
  /// path ([KvStore.ingestSstable]) and the write path. An [HlcClock] with this
  /// skew limit is constructed by `CrashRecovery` and injected into `LsmEngine`.
  /// If an observed HLC (from a peer SSTable) exceeds the local wall clock by
  /// more than this duration, a [ClockSkewException] is thrown.
  final Duration maxClockSkew;

  /// Maximum encoded value size in bytes.
  ///
  /// [KvStore.put] and [KvStore.writeBatch] throw [ArgumentError] when a value
  /// exceeds this limit. The check applies to the post-encoding bytes (CBOR +
  /// optional compression) that the Query Layer passes down. For large payloads
  /// such as file attachments, use the vault facility instead.
  ///
  /// Defaults to 1 MiB. Set to [maxValueBytesUnlimited] to disable the check.
  final int maxValueBytes;

  /// Sentinel value for [maxValueBytes] that disables the size check entirely.
  static const int maxValueBytesUnlimited = -1;

  /// Wall-clock grace window before a delete tombstone is eligible for GC
  /// on a **local-only** database (no sync configured). The horizon used by
  /// the all-levels compaction path is `now - tombstoneGraceDuration`:
  /// tombstones older than this can be dropped, younger ones are retained.
  ///
  /// The grace window protects the local → synced transition. If sync is
  /// enabled within the window, every tombstone written before the
  /// transition is still present to suppress peer values on first sync.
  /// Setting this too short permits deleted data to resurrect on the first
  /// post-enable sync if any peer ever held an older copy.
  ///
  /// On a synced database the engine uses `min(currentHlc)` across all
  /// `.hwm` files instead and this value is ignored. See `plan_tombstone_gc.md`
  /// (H4 PR2) for the safety analysis.
  ///
  /// Defaults to 7 days — comfortably greater than the expected maximum
  /// time between sync attempts in any practical KMDB deployment, while
  /// short enough that deleted data is reclaimed in a reasonable window.
  /// Set to [Duration.zero] only when tombstones must drop on the next
  /// compaction (e.g. tests).
  ///
  /// ## Relationship with [staleDeviceEvictionAfter]
  ///
  /// [tombstoneGraceDuration] is the *local-only* grace window; it answers
  /// "how long must a tombstone survive on a single device before it is safe
  /// to drop?" [staleDeviceEvictionAfter] is the *distributed* eviction
  /// window; it answers "how long can a peer be absent before we exclude it
  /// from the GC horizon?" Together they are the two halves of "how long
  /// until a delete is considered globally observed." Setting
  /// [staleDeviceEvictionAfter] shorter than [tombstoneGraceDuration] is
  /// meaningless: a device can be evicted before the local grace window has
  /// elapsed, which offers no additional safety and may cause unnecessary
  /// full re-syncs.
  final Duration tombstoneGraceDuration;

  /// Maximum time a peer device may be absent from the sync folder before its
  /// `.hwm` file is excluded from the `min(currentHlc)` horizon computation.
  ///
  /// ## Safety trade-off
  ///
  /// A longer threshold is safer (the horizon advances more conservatively)
  /// but defers tombstone GC for longer when a device goes offline. A shorter
  /// threshold allows GC to proceed sooner but increases the likelihood that a
  /// legitimately-active device (phone in a drawer, laptop in storage) is
  /// evicted and forced into a full re-sync on return.
  ///
  /// ## Re-admission requirement — read before shortening this value
  ///
  /// A device whose `.hwm` has been excluded from the horizon may have its
  /// data become inconsistent with the advanced horizon: tombstones that were
  /// GC'd while it was absent may no longer exist, so if the device pushes its
  /// pre-eviction SSTables, deleted keys can be resurrected. To prevent this,
  /// the [SyncEngine] detects the evicted state on the next push and
  /// **performs a full re-sync** (discards local SSTables for synced
  /// namespaces and re-downloads the current consolidated set). Incremental
  /// catch-up is *unsafe* for an evicted device.
  ///
  /// ## Pairing with [tombstoneGraceDuration]
  ///
  /// [tombstoneGraceDuration] is the local-only grace window;
  /// [staleDeviceEvictionAfter] is the distributed eviction window. They are
  /// the two halves of "how long until a delete is considered globally
  /// observed." Setting [staleDeviceEvictionAfter] shorter than
  /// [tombstoneGraceDuration] is meaningless (see [tombstoneGraceDuration]
  /// doc comment for details).
  ///
  /// Defaults to 90 days — a conservative value that accommodates phones in
  /// drawers, laptops in storage, and devices that sync only over a specific
  /// Wi-Fi network.
  final Duration staleDeviceEvictionAfter;

  /// Maximum number of open [SstableReader]s held in the `TableCache`.
  ///
  /// The table cache amortises the cost of opening an SSTable file: the first
  /// open validates the whole-file XXH64 checksum and loads the footer, index,
  /// and Bloom filter into memory; subsequent reads of the same file reuse the
  /// cached reader without any file I/O or hashing.
  ///
  /// ## Sizing
  ///
  /// Each cached reader holds the footer (48 bytes), Bloom filter (~1 KB for a
  /// typical 100-entry block), and index (a few hundred bytes per file) — on
  /// the order of **2–5 KiB per entry**. At the default of 256 entries that is
  /// roughly 0.5–1.3 MiB of overhead, which is appropriate for desktop and
  /// server deployments. For memory-constrained environments (mobile, web) set
  /// this to 64 or lower.
  ///
  /// The cache is LRU-evicting: when full, the least-recently-used reader is
  /// dropped. Reads still succeed after eviction — they just re-open the file.
  ///
  /// ## Platform tier defaults
  ///
  /// | Platform | Recommended value |
  /// |----------|------------------|
  /// | Desktop / server | 256 (default) |
  /// | Mobile / embedded | 64 |
  ///
  /// Defaults to 256. Must be > 0.
  final int tableCacheSize;

  /// Configuration for unit tests: tiny thresholds, no fsync, small cache.
  ///
  /// [staleDeviceEvictionAfter] is intentionally left at the default 90 days
  /// so tests that exercise sync-horizon behaviour must supply their own
  /// short threshold via the named parameter. Tests that do not exercise
  /// eviction are unaffected by the default.
  factory KvStoreConfig.forTesting() => const KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    l1MaxBytes: 16 * 1024,
    l2MaxBytes: 64 * 1024,
    singleFileThresholdBytes: 8 * 1024,
    fsyncOnWrite: false,
    tableCacheSize: 16,
  );
}

// ── StaleSstableIngestException ───────────────────────────────────────────────

/// Exception thrown by [KvStore.ingestSstable] when the incoming SSTable's
/// `maxHlc` is at or below the local tombstone GC floor (H4-FU3).
///
/// ## What this means
///
/// The GC floor records the highest `horizon` value ever used by a tombstone-
/// dropping compaction on this device. An SSTable with `maxHlc <= floor`
/// contains only records at HLCs that were GC-eligible during that compaction
/// — ingesting it could resurrect deleted data whose tombstone has already been
/// dropped locally.
///
/// The check is conservative: an SSTable with `maxHlc` exactly equal to the
/// floor carries a record at the exact horizon used for the last drop. That
/// record was not itself eligible for GC (the drop predicate is strict less-
/// than: `tombstoneHlc < horizon`), but the `<=` posture avoids a subtle off-
/// by-one argument and is the correct defence-in-depth choice.
///
/// ## Protocol behaviour
///
/// [SyncEngine.pull] catches this exception per-file, logs at WARN, and
/// continues to the next file **without** advancing the peer high-water mark.
/// The file is left in the cloud folder and will be reconsidered on the next
/// pull cycle (e.g. after a consolidation has run and replaced the sub-floor
/// files with post-floor consolidated output).
///
/// ## File on disk
///
/// [KvStoreImpl.ingestSstable] writes the file to the local `sst/` directory
/// before calling [LsmEngine.ingestAt0], so the file already exists on disk
/// when this exception is thrown. It is intentionally left in place: the
/// rejection is a diagnostic signal, not a tombstone for the file. A future
/// open's orphan-sweep will reclaim it if needed.
final class StaleSstableIngestException implements Exception {
  /// Creates a [StaleSstableIngestException].
  ///
  /// [filename] is the bare SSTable filename. [maxHlc] is the SSTable's
  /// `maxHlc` from its filename. [floor] is the current local GC floor.
  const StaleSstableIngestException({
    required this.filename,
    required this.maxHlc,
    required this.floor,
  });

  /// The bare SSTable filename that was rejected.
  final String filename;

  /// The SSTable's `maxHlc` as parsed from the filename.
  final Hlc maxHlc;

  /// The local tombstone GC floor at the time of the check.
  final Hlc floor;

  @override
  String toString() =>
      'StaleSstableIngestException: $filename — maxHlc=${maxHlc.toHex()} '
      'is at or below GC floor=${floor.toHex()}. '
      'Ingesting this file could resurrect tombstone-GC\'d data.';
}
