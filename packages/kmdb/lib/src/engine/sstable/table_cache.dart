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

import '../platform/storage_adapter_interface.dart';
import 'sstable_reader.dart';
import '../../cache/lru_map.dart';

/// A bounded LRU cache of open [SstableReader]s, keyed by file path.
///
/// Opening an [SstableReader] validates the whole-file XXH64 checksum and
/// loads the footer, index block, and Bloom filter into memory — an O(file
/// size) operation. [TableCache] makes this a one-time-per-file cost by
/// caching the open reader and reusing it for subsequent reads.
///
/// ## Invalidation
///
/// Cached readers must be evicted whenever the underlying file is removed or
/// replaced. Call [evict] for each file path that is being compacted, flushed
/// over, renamed, or deleted. Call [clear] on database close.
///
/// ## Thread safety
///
/// All operations execute on a single isolate — no locking required. The
/// KMDB engine does not use background isolates.
///
/// ## Relationship with the §15 Cache Layer
///
/// [TableCache] is a **storage-layer** cache (parsed footer + index + filter).
/// It is distinct from and complementary to the §15 query-layer object cache
/// ([LruMap]-backed [SessionCache]). They live at different layers and serve
/// different purposes.
///
/// ## Example
///
/// ```dart
/// final cache = TableCache(capacity: 256);
/// final reader = await cache.open('/db/sst/abc.sst', adapter);
/// // Subsequent calls for the same path reuse the cached reader:
/// final same = await cache.open('/db/sst/abc.sst', adapter);
/// assert(identical(reader, same));
/// ```
final class TableCache {
  /// Creates a [TableCache] with the given [capacity].
  ///
  /// [capacity] is the maximum number of open [SstableReader]s held in memory.
  /// When the limit is reached, the least-recently-used reader is evicted.
  ///
  /// [capacity] must be greater than zero.
  TableCache({required int capacity}) : _lru = LruMap(capacity);

  final LruMap<String, SstableReader> _lru;

  /// Returns the number of readers currently held in the cache.
  int get length => _lru.length;

  /// Returns the maximum number of readers the cache will hold.
  int get capacity => _lru.capacity;

  /// Opens the SSTable at [path] and returns its reader.
  ///
  /// If a reader for [path] is already cached it is returned immediately
  /// (no file I/O, no checksum recomputation). On a cache miss the file is
  /// opened via [SstableReader.open], which reads and validates the
  /// whole-file XXH64 checksum, loads the index block, and loads the Bloom
  /// filter — then the resulting reader is cached for future calls.
  ///
  /// Throws [CorruptedSstableException] if the file's checksum does not match.
  /// Throws [StorageException] if the file does not exist.
  Future<SstableReader> open(String path, StorageAdapter adapter) async {
    // Fast path: reader already cached — promote to MRU and return.
    final cached = _lru.get(path);
    if (cached != null) return cached;

    // Slow path: open the file (reads + hashes the whole file once).
    final reader = await SstableReader.open(path, adapter);
    _lru.put(path, reader);
    return reader;
  }

  /// Evicts the cached reader for [path], if any.
  ///
  /// Should be called when a file is removed, replaced, or renamed (e.g.
  /// after a compaction, flush, or device-ID reassignment). A subsequent
  /// [open] call for the same path will re-read the file from disk.
  void evict(String path) {
    _lru.remove(path);
  }

  /// Evicts all cached readers whose path starts with [prefix].
  ///
  /// Useful for bulk eviction when an entire level is replaced by a
  /// compaction output, or when all files owned by a device are renamed.
  void evictByPrefix(String prefix) {
    _lru.removeWhere((path, _) => path.startsWith(prefix));
  }

  /// Removes all cached readers.
  ///
  /// Called on database close to release in-memory state.
  void clear() {
    _lru.clear();
  }
}
