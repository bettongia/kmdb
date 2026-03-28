import 'dart:typed_data';

import '../util/key_codec.dart';
import 'skip_list.dart';

/// Flush threshold in bytes. When [Memtable.sizeBytes] reaches this value the
/// engine schedules an SSTable flush.
const int kMemtableFlushThreshold = 64 * 1024; // 64 KB

/// A mutable in-memory write buffer backed by a [SkipList].
///
/// The memtable accumulates `put` and `delete` operations before they are
/// flushed to an immutable SSTable. Byte-size tracking drives the 64 KB flush
/// threshold.
///
/// ## Lifecycle
///
/// ```
/// Memtable (mutable)
///   → freeze() → FrozenMemtable (immutable snapshot, readable during flush)
/// ```
///
/// Only one memtable is active at a time. The engine freezes the current one,
/// starts a new mutable memtable for incoming writes, and flushes the frozen
/// copy to disk. The frozen memtable is discarded after the flush is confirmed
/// in the Manifest.
final class Memtable {
  Memtable();

  final SkipList _data = SkipList();

  /// Total bytes occupied by all keys and values, including internal key
  /// overhead. Used to trigger the 64 KB flush threshold.
  int _sizeBytes = 0;

  /// Number of entries (puts + deletes) stored.
  int get length => _data.length;

  /// Accumulated byte count of all stored keys and values.
  int get sizeBytes => _sizeBytes;

  /// Whether this memtable has reached or exceeded the flush threshold.
  bool get shouldFlush => _sizeBytes >= kMemtableFlushThreshold;

  // ── Write operations ──────────────────────────────────────────────────────

  /// Writes an internal key/value pair into the memtable.
  ///
  /// [internalKey] is the composite key built by [KeyCodec.encodeInternalKey].
  /// [value] is the raw encoded value bytes (may be empty for tombstones).
  void put(Uint8List internalKey, Uint8List value) {
    final existing = _data.get(internalKey);
    if (existing != null) {
      // Key already present (e.g. duplicate HLC within same write batch).
      // Update in-place; adjust size for new value.
      _sizeBytes -= existing.length;
      _sizeBytes += value.length;
    } else {
      _sizeBytes += internalKey.length + value.length;
    }
    _data.put(internalKey, value);
  }

  // ── Read operations ───────────────────────────────────────────────────────

  /// Returns the value for the given [internalKey], or `null` if not found.
  Uint8List? get(Uint8List internalKey) => _data.get(internalKey);

  /// Returns all entries whose internal keys fall in `[start, end)`.
  ///
  /// Results are in ascending internal key order. Pass `null` bounds to scan
  /// the full table.
  Iterable<SkipListEntry> scan({Uint8List? start, Uint8List? end}) =>
      _data.scan(start: start, end: end);

  // ── Snapshot ──────────────────────────────────────────────────────────────

  /// Freezes this memtable into an immutable snapshot.
  ///
  /// After calling [freeze], this [Memtable] instance must not be mutated.
  /// The engine creates a new empty [Memtable] for subsequent writes.
  FrozenMemtable freeze() => FrozenMemtable._(_data, _sizeBytes);
}

/// An immutable snapshot of a [Memtable], held in memory during an SSTable
/// flush.
///
/// [FrozenMemtable] is read-only; the storage engine reads from it while the
/// flush is in progress and discards it once the flush is confirmed in the
/// Manifest.
final class FrozenMemtable {
  FrozenMemtable._(this._data, this.sizeBytes);

  final SkipList _data;

  /// Total byte size at the time of freezing.
  final int sizeBytes;

  /// Returns the value for [internalKey], or `null` if absent.
  Uint8List? get(Uint8List internalKey) => _data.get(internalKey);

  /// Returns all entries in ascending internal key order within `[start, end)`.
  Iterable<SkipListEntry> scan({Uint8List? start, Uint8List? end}) =>
      _data.scan(start: start, end: end);

  /// Returns all entries in ascending internal key order.
  Iterable<SkipListEntry> get entries => _data.scan();
}
