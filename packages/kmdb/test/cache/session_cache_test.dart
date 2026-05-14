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

import 'dart:typed_data';

import 'package:kmdb/src/cache/session_cache.dart';
import 'package:test/test.dart';

Uint8List _bytes(int value) => Uint8List.fromList([value]);

void main() {
  group('SessionCache', () {
    late SessionCache cache;

    setUp(() => cache = SessionCache(maxObjects: 10));

    test('get returns null on miss', () {
      expect(cache.get('ns', 'key', 1), isNull);
    });

    test('put then get returns stored bytes', () {
      cache.put('ns', 'key', 1, _bytes(42));
      expect(cache.get('ns', 'key', 1), equals(_bytes(42)));
    });

    test('get returns null when generation does not match', () {
      cache.put('ns', 'key', 1, _bytes(42));
      expect(cache.get('ns', 'key', 2), isNull);
    });

    test('put overwrites entry for same namespace+key', () {
      cache.put('ns', 'key', 1, _bytes(1));
      cache.put('ns', 'key', 2, _bytes(2));
      expect(cache.get('ns', 'key', 2), equals(_bytes(2)));
      expect(cache.get('ns', 'key', 1), isNull);
    });

    test('different namespaces are independent', () {
      cache.put('ns1', 'key', 1, _bytes(10));
      cache.put('ns2', 'key', 1, _bytes(20));
      expect(cache.get('ns1', 'key', 1), equals(_bytes(10)));
      expect(cache.get('ns2', 'key', 1), equals(_bytes(20)));
    });

    test('different keys within same namespace are independent', () {
      cache.put('ns', 'k1', 1, _bytes(1));
      cache.put('ns', 'k2', 1, _bytes(2));
      expect(cache.get('ns', 'k1', 1), equals(_bytes(1)));
      expect(cache.get('ns', 'k2', 1), equals(_bytes(2)));
    });

    test('length reflects entries held', () {
      expect(cache.length, 0);
      cache.put('ns', 'k1', 1, _bytes(1));
      expect(cache.length, 1);
      cache.put('ns', 'k2', 1, _bytes(2));
      expect(cache.length, 2);
    });

    group('evictNamespace', () {
      test('removes entries with old generation', () {
        cache.put('ns', 'k1', 1, _bytes(1));
        cache.put('ns', 'k2', 1, _bytes(2));
        cache.evictNamespace('ns', 2); // new generation is 2
        expect(cache.get('ns', 'k1', 1), isNull);
        expect(cache.get('ns', 'k2', 1), isNull);
      });

      test('preserves entries matching current generation', () {
        cache.put('ns', 'k1', 2, _bytes(1));
        cache.put('ns', 'k2', 1, _bytes(2)); // stale
        cache.evictNamespace('ns', 2);
        expect(cache.get('ns', 'k1', 2), equals(_bytes(1)));
        expect(cache.get('ns', 'k2', 1), isNull);
      });

      test('only evicts the target namespace', () {
        cache.put('ns1', 'k1', 1, _bytes(1));
        cache.put('ns2', 'k1', 1, _bytes(2));
        cache.evictNamespace('ns1', 2);
        expect(cache.get('ns1', 'k1', 1), isNull);
        expect(cache.get('ns2', 'k1', 1), equals(_bytes(2)));
      });

      test('no-op on empty cache', () {
        expect(() => cache.evictNamespace('ns', 1), returnsNormally);
      });
    });

    group('evictNamespaceAll', () {
      test('removes all entries for namespace regardless of generation', () {
        cache.put('ns', 'k1', 1, _bytes(1));
        cache.put('ns', 'k2', 2, _bytes(2));
        cache.evictNamespaceAll('ns');
        expect(cache.get('ns', 'k1', 1), isNull);
        expect(cache.get('ns', 'k2', 2), isNull);
      });

      test('does not touch other namespaces', () {
        cache.put('other', 'k', 1, _bytes(99));
        cache.put('ns', 'k', 1, _bytes(1));
        cache.evictNamespaceAll('ns');
        expect(cache.get('other', 'k', 1), equals(_bytes(99)));
      });
    });

    test('clear removes all entries', () {
      cache.put('ns', 'k', 1, _bytes(1));
      cache.clear();
      expect(cache.length, 0);
      expect(cache.get('ns', 'k', 1), isNull);
    });

    test('LRU eviction occurs when maxObjects is reached', () {
      final small = SessionCache(maxObjects: 2);
      small.put('ns', 'k1', 1, _bytes(1));
      small.put('ns', 'k2', 1, _bytes(2));
      small.put('ns', 'k3', 1, _bytes(3)); // evicts k1
      expect(small.get('ns', 'k1', 1), isNull);
      expect(small.get('ns', 'k2', 1), equals(_bytes(2)));
      expect(small.get('ns', 'k3', 1), equals(_bytes(3)));
    });

    test(
      'namespace prefix does not match entries with prefix-extended names',
      () {
        // 'ns' should not match 'ns_extended'
        cache.put('ns_extended', 'k', 1, _bytes(5));
        cache.evictNamespaceAll('ns');
        expect(cache.get('ns_extended', 'k', 1), equals(_bytes(5)));
      },
    );
  });
}
