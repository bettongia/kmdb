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
  Future<void> put(String namespace, String key, Uint8List value);

  /// Writes a delete tombstone for [key] in [namespace].
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
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  });

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

  /// Closes the store, flushing the active memtable and releasing the LOCK.
  ///
  /// After [close] returns the instance must not be used again. A new
  /// instance can be opened on the same path.
  Future<void> close();
}

// ── Public types ──────────────────────────────────────────────────────────────

/// A raw key-value entry returned by [KvStore.scan].
typedef KvEntry = ({String key, Uint8List value});

/// Describes what happened during [KvStore.open] crash recovery.
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
