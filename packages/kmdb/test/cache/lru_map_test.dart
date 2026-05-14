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

import 'package:kmdb/src/cache/lru_map.dart';
import 'package:test/test.dart';

void main() {
  group('LruMap', () {
    test('stores and retrieves values', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.get('a'), 1);
      expect(lru.get('b'), 2);
      expect(lru.get('c'), isNull);
    });

    test('returns correct length', () {
      final lru = LruMap<String, int>(5);
      expect(lru.length, 0);
      lru.put('x', 10);
      expect(lru.length, 1);
      lru.put('y', 20);
      expect(lru.length, 2);
    });

    test('evicts LRU entry when at capacity', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      // 'a' is LRU — inserting 'd' evicts it
      lru.put('d', 4);
      expect(lru.get('a'), isNull);
      expect(lru.get('b'), 2);
      expect(lru.get('c'), 3);
      expect(lru.get('d'), 4);
    });

    test('get promotes entry to MRU, preventing its eviction', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      lru.get('a'); // promote 'a' to MRU; 'b' is now LRU
      lru.put('d', 4); // evicts 'b'
      expect(lru.get('a'), 1);
      expect(lru.get('b'), isNull);
      expect(lru.get('c'), 3);
      expect(lru.get('d'), 4);
    });

    test('put on existing key updates value and promotes to MRU', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      lru.put('a', 99); // update 'a'; 'b' becomes LRU
      lru.put('d', 4); // evicts 'b'
      expect(lru.get('a'), 99);
      expect(lru.get('b'), isNull);
    });

    test('remove deletes an entry', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.remove('a'), 1);
      expect(lru.get('a'), isNull);
      expect(lru.length, 1);
    });

    test('remove on absent key returns null', () {
      final lru = LruMap<String, int>(3);
      expect(lru.remove('missing'), isNull);
    });

    test('removeWhere removes matching entries', () {
      final lru = LruMap<String, int>(5);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      lru.removeWhere((k, v) => v.isEven);
      expect(lru.get('a'), 1);
      expect(lru.get('b'), isNull);
      expect(lru.get('c'), 3);
    });

    test('clear empties the map', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.clear();
      expect(lru.length, 0);
      expect(lru.get('a'), isNull);
    });

    test('containsKey returns correct result', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      expect(lru.containsKey('a'), isTrue);
      expect(lru.containsKey('z'), isFalse);
    });

    test('capacity=1 evicts on every new insert', () {
      final lru = LruMap<String, int>(1);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.get('a'), isNull);
      expect(lru.get('b'), 2);
      lru.put('c', 3);
      expect(lru.get('b'), isNull);
      expect(lru.get('c'), 3);
    });

    test('eviction order is correct across multiple promotes', () {
      final lru = LruMap<String, int>(3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      // Access order: a (oldest), b, c (newest)
      lru.get('b'); // b→MRU; order: a, c, b
      lru.get('a'); // a→MRU; order: c, b, a
      lru.put('d', 4); // evicts c
      expect(lru.get('c'), isNull);
      expect(lru.get('b'), 2);
      expect(lru.get('a'), 1);
      expect(lru.get('d'), 4);
    });
  });
}
