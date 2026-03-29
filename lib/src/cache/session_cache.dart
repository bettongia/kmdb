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

import 'lru_map.dart';

/// In-memory LRU cache of raw KvStore values for a single process session.
///
/// ## Cache key
///
/// Entries are keyed by `(namespace, key, generation)` where `generation` is
/// the namespace-level generation counter stored in `$meta` under `gen:{ns}`
/// (spec §15). This is sometimes called "sequenceNumber" in the spec to
/// emphasise its role as an ordered invalidation token, but it is a
/// per-namespace counter — not a per-entry HLC sequence number.
///
/// When a namespace is written, its generation counter increments. Any cached
/// entry that carries the old generation will no longer match on the next
/// [get] call — it simply ages out of the LRU without ever being served again.
///
/// Proactive eviction is also performed via [evictNamespace] when a write
/// event fires for the namespace, keeping memory usage bounded even for
/// write-heavy workloads.
///
/// ## Capacity
///
/// The [maxObjects] capacity is controlled by [CacheTier]:
/// - Desktop: 2,000 objects
/// - Mobile / Web: 256 objects
final class SessionCache {
  /// Creates a [SessionCache] that holds at most [maxObjects] entries.
  SessionCache({required int maxObjects})
      : _lru = LruMap(maxObjects);

  final LruMap<String, _Entry> _lru;

  /// Number of entries currently held.
  int get length => _lru.length;

  /// Returns the cached raw bytes for [(namespace, key)] if the [generation]
  /// matches the stored entry's generation. Returns `null` on a miss.
  ///
  /// A hit promotes the entry to the most-recently-used position.
  Uint8List? get(String namespace, String key, int generation) {
    final entry = _lru.get(_cacheKey(namespace, key));
    if (entry == null || entry.generation != generation) return null;
    return entry.bytes;
  }

  /// Stores [bytes] for [(namespace, key)] at [generation].
  ///
  /// Replaces any existing entry for the same namespace+key. If the cache is
  /// at capacity the least-recently-used entry is evicted first.
  void put(String namespace, String key, int generation, Uint8List bytes) {
    _lru.put(_cacheKey(namespace, key), _Entry(generation, bytes));
  }

  /// Evicts all entries for [namespace] whose stored generation does not match
  /// [currentGeneration].
  ///
  /// Called when a write event fires for [namespace] so that stale entries are
  /// removed proactively rather than waiting to age out.
  void evictNamespace(String namespace, int currentGeneration) {
    final prefix = '$namespace\x00';
    _lru.removeWhere(
        (k, v) => k.startsWith(prefix) && v.generation != currentGeneration);
  }

  /// Evicts all entries for [namespace] regardless of generation.
  ///
  /// Used when a namespace should be completely flushed — for example, after
  /// [CacheLayer.onResume] detects that the generation counter has advanced
  /// while the app was suspended (e.g. a background sync ran). On mobile/web,
  /// [CacheLayer.onResume] calls [evictNamespace] (not this method) for a
  /// generation-discriminating eviction, but callers needing a full flush can
  /// use this method directly.
  void evictNamespaceAll(String namespace) {
    final prefix = '$namespace\x00';
    _lru.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Removes all entries.
  void clear() => _lru.clear();

  // The cache key encodes namespace and document key separated by a NUL byte,
  // which cannot appear in valid namespace or key strings.
  static String _cacheKey(String namespace, String key) => '$namespace\x00$key';
}

final class _Entry {
  const _Entry(this.generation, this.bytes);
  final int generation;
  final Uint8List bytes;
}
