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

import 'dart:collection' show LinkedHashMap;

/// A fixed-capacity Least-Recently-Used (LRU) map.
///
/// When the map reaches [capacity] and a new key is inserted, the
/// least-recently-used entry is evicted. Both [get] and [put] count as an
/// access and move the touched entry to the most-recently-used position.
///
/// All operations are O(1) amortised (remove + re-insert into a
/// [LinkedHashMap]).
///
/// ## Example
///
/// ```dart
/// final lru = LruMap<String, int>(3);
/// lru.put('a', 1);
/// lru.put('b', 2);
/// lru.put('c', 3);
/// lru.get('a');      // promotes 'a' to MRU
/// lru.put('d', 4);   // evicts 'b' (LRU)
/// ```
final class LruMap<K, V> {
  /// Creates an [LruMap] with the given [capacity].
  ///
  /// [capacity] must be greater than zero.
  LruMap(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  /// Maximum number of entries this map will hold before evicting.
  final int capacity;

  // Insertion-order preserved; we remove+reinsert on access to simulate
  // access-order (LRU head = oldest, tail = newest).
  // ignore: prefer_collection_literals — LinkedHashMap type needed for removeWhere
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  /// Current number of entries.
  int get length => _map.length;

  /// Returns the value for [key], or `null` if absent.
  ///
  /// Promotes [key] to the most-recently-used position.
  V? get(K key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value; // reinsert at tail = MRU
    return value;
  }

  /// Inserts or updates [key] → [value].
  ///
  /// If [key] already exists its value is replaced and the entry is promoted to
  /// the most-recently-used position. If the map is at [capacity] the
  /// least-recently-used entry (head) is evicted first.
  void put(K key, V value) {
    _map.remove(key); // remove old entry (if any) to reinsert at tail
    if (_map.length >= capacity) {
      _map.remove(_map.keys.first); // evict LRU (head)
    }
    _map[key] = value;
  }

  /// Removes [key] and returns its value, or `null` if absent.
  V? remove(K key) => _map.remove(key);

  /// Removes all entries for which [test] returns `true`.
  void removeWhere(bool Function(K key, V value) test) =>
      _map.removeWhere(test);

  /// Returns `true` if [key] is in the map (without affecting LRU order).
  bool containsKey(K key) => _map.containsKey(key);

  /// Removes all entries.
  void clear() => _map.clear();

  /// All entries in least-recently-used to most-recently-used order.
  Iterable<MapEntry<K, V>> get entries => _map.entries;

  /// All keys in least-recently-used to most-recently-used order.
  Iterable<K> get keys => _map.keys;
}
