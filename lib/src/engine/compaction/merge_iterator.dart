import 'dart:async';
import 'dart:typed_data';

import '../sstable/sstable_reader.dart';

/// An entry yielded by the [MergeIterator].
final class MergeEntry {
  const MergeEntry(this.key, this.value, {required this.source});

  /// Internal key bytes.
  final Uint8List key;

  /// Value bytes (may be empty for delete tombstones).
  final Uint8List value;

  /// Zero-based index of the source iterator (lower = higher priority).
  ///
  /// When two sources emit the same key, the one with the lower [source] index
  /// wins (newer data has priority). The merge job discards duplicates.
  final int source;
}

/// N-way merge of sorted [SstEntry] streams.
///
/// Merges multiple SSTable scan streams into a single ascending stream.
/// When multiple sources contain the same internal key the entry from the
/// lowest-numbered source is emitted and all duplicates are skipped — this
/// implements Last-Write-Wins: the caller should order sources from newest to
/// oldest so the latest value wins.
///
/// The merge is lazy: data blocks are fetched on demand as the iterator
/// advances.
///
/// ## Usage
///
/// ```dart
/// final merged = MergeIterator([reader0.scan(), reader1.scan()]);
/// await for (final entry in merged.entries) {
///   // process entry
/// }
/// ```
final class MergeIterator {
  MergeIterator(List<Stream<SstEntry>> sources)
      : _sources = sources.map(StreamIterator.new).toList();

  final List<StreamIterator<SstEntry>> _sources;

  /// Merged, deduplicated entry stream in ascending internal key order.
  ///
  /// For duplicate keys only the entry from the lowest-numbered (highest
  /// priority) source is emitted.
  Stream<MergeEntry> get entries => _merge();

  Stream<MergeEntry> _merge() async* {
    // Initialise: advance all iterators to their first element.
    final active = <int>[];
    for (var i = 0; i < _sources.length; i++) {
      if (await _sources[i].moveNext()) active.add(i);
    }

    while (active.isNotEmpty) {
      // Find the source with the smallest current key.
      // On ties (same key) the lowest index wins.
      var minIdx = active[0];
      for (var i = 1; i < active.length; i++) {
        final idx = active[i];
        final cmp = _compareKeys(
          _sources[idx].current.key,
          _sources[minIdx].current.key,
        );
        if (cmp < 0 || (cmp == 0 && idx < minIdx)) {
          minIdx = idx;
        }
      }

      final winner = _sources[minIdx].current;
      yield MergeEntry(winner.key, winner.value, source: minIdx);

      // Skip all sources whose current entry has the same key (duplicates).
      final winnerKey = winner.key;
      final toRemove = <int>[];
      for (final idx in active) {
        if (_sameKey(_sources[idx].current.key, winnerKey)) {
          final hasMore = await _sources[idx].moveNext();
          if (!hasMore) toRemove.add(idx);
        }
      }
      active.removeWhere(toRemove.contains);
    }
  }

  static int _compareKeys(Uint8List a, Uint8List b) {
    final min = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < min; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }

  static bool _sameKey(Uint8List a, Uint8List b) => _compareKeys(a, b) == 0;
}
