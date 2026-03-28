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
