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

import 'dart:typed_data';

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

/// Describes what happened during KvStoreImpl.open crash recovery.
final class OpenResult {
  const OpenResult({
    this.hadInterruptedWrites = false,
    this.affectedNamespaces = const [],
    this.hadUnclosedSession = false,
  });

  /// True if WAL replay discarded one or more records (checksum failure).
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
  final Duration maxClockSkew;

  /// Configuration for unit tests: tiny thresholds, no fsync, small cache.
  factory KvStoreConfig.forTesting() => const KvStoreConfig(
    memtableSizeBytes: 4096,
    l0CompactionTrigger: 2,
    l1MaxBytes: 16 * 1024,
    l2MaxBytes: 64 * 1024,
    singleFileThresholdBytes: 8 * 1024,
    fsyncOnWrite: false,
  );
}
