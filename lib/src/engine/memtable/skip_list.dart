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

import 'dart:math';
import 'dart:typed_data';

/// A sorted key-value store backed by a probabilistic skip list.
///
/// Keys are [Uint8List] byte sequences compared lexicographically.
/// Duplicate keys are supported — inserting with an existing key overwrites
/// the associated value (last-write-wins within a single mutable skip list).
///
/// The implementation uses a fixed maximum level of 12 and a promotion
/// probability of 0.25, giving O(log n) expected time for get/put/remove.
///
/// ## Internal key ordering
///
/// KMDB stores entries with composite internal keys:
/// ```
/// [nsLen 1B][ns NB][userKey 16B][hlc 8B][type 1B]
/// ```
/// The primary sort is `(ns + userKey)` ascending; within the same user key
/// the HLC is big-endian so higher HLC bytes sort *after* lower ones — but the
/// merge iterator wants newer entries first (descending HLC). Callers handle
/// that ordering inversion externally; the skip list itself is a pure
/// lexicographic structure.
///
/// ## Thread safety
/// Not thread-safe. KMDB processes all writes on a single isolate.
final class SkipList {
  SkipList({Random? random}) : _random = random ?? Random();

  static const int _maxLevel = 12;
  static const double _probability = 0.25;

  final Random _random;

  // Sentinel head node — key is empty, level is maxLevel.
  final _SkipNode _head = _SkipNode(Uint8List(0), Uint8List(0), _maxLevel);

  int _size = 0;

  /// Number of entries currently stored.
  int get length => _size;

  /// Whether the skip list contains no entries.
  bool get isEmpty => _size == 0;

  // ── Write operations ──────────────────────────────────────────────────────

  /// Inserts or replaces the value for [key].
  ///
  /// If [key] already exists the value is updated in-place (no new node).
  void put(Uint8List key, Uint8List value) {
    final update = List<_SkipNode>.filled(_maxLevel, _head);
    var current = _head;

    for (var i = _maxLevel - 1; i >= 0; i--) {
      while (current.forward[i] != null &&
          _compare(current.forward[i]!.key, key) < 0) {
        current = current.forward[i]!;
      }
      update[i] = current;
    }

    final next = current.forward[0];
    if (next != null && _compare(next.key, key) == 0) {
      // Key already exists — update value in-place.
      next.value = value;
      return;
    }

    final level = _randomLevel();
    final node = _SkipNode(key, value, level);
    for (var i = 0; i < level; i++) {
      node.forward[i] = update[i].forward[i];
      update[i].forward[i] = node;
    }
    _size++;
  }

  /// Returns the value for [key], or `null` if not found.
  Uint8List? get(Uint8List key) {
    var current = _head;
    for (var i = _maxLevel - 1; i >= 0; i--) {
      while (current.forward[i] != null &&
          _compare(current.forward[i]!.key, key) < 0) {
        current = current.forward[i]!;
      }
    }
    final next = current.forward[0];
    if (next != null && _compare(next.key, key) == 0) return next.value;
    return null;
  }

  /// Returns whether [key] is present.
  bool containsKey(Uint8List key) => get(key) != null;

  // ── Range iteration ───────────────────────────────────────────────────────

  /// Returns an iterable over all entries in ascending key order.
  ///
  /// If [start] is provided, iteration begins at the first key ≥ [start].
  /// If [end] is provided, iteration stops before the first key ≥ [end]
  /// (exclusive upper bound).
  Iterable<SkipListEntry> scan({Uint8List? start, Uint8List? end}) sync* {
    var current = _head;

    if (start != null) {
      // Advance to the first node whose key ≥ start.
      for (var i = _maxLevel - 1; i >= 0; i--) {
        while (current.forward[i] != null &&
            _compare(current.forward[i]!.key, start) < 0) {
          current = current.forward[i]!;
        }
      }
    }

    current = current.forward[0] ?? _head; // first node ≥ start (or head if empty)
    if (identical(current, _head)) return; // empty list

    while (current != _head &&
        (end == null || _compare(current.key, end) < 0)) {
      yield SkipListEntry(current.key, current.value);
      current = current.forward[0] ?? _head;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  int _randomLevel() {
    var level = 1;
    while (level < _maxLevel && _random.nextDouble() < _probability) {
      level++;
    }
    return level;
  }

  /// Lexicographic comparison of two [Uint8List]s.
  static int _compare(Uint8List a, Uint8List b) {
    final minLen = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < minLen; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }

  /// Lexicographic comparison exposed for external key ordering checks.
  static int compareKeys(Uint8List a, Uint8List b) => _compare(a, b);
}

// ── Supporting types ──────────────────────────────────────────────────────────

/// A single entry returned from [SkipList.scan].
final class SkipListEntry {
  const SkipListEntry(this.key, this.value);

  /// The internal key bytes.
  final Uint8List key;

  /// The value bytes.
  final Uint8List value;
}

/// Internal skip list node.
final class _SkipNode {
  _SkipNode(this.key, this.value, int level)
      : forward = List<_SkipNode?>.filled(level, null);

  final Uint8List key;
  Uint8List value;

  /// Forward pointers, one per level.
  final List<_SkipNode?> forward;
}
