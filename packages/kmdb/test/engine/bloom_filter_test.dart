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

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/sstable/bloom_filter.dart';

Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('BloomFilter: no false negatives', () {
    test('all inserted keys are found', () {
      final keys = List.generate(1000, (i) => _k('key-$i'));
      final filter = BloomFilter.build(keys);
      for (final k in keys) {
        expect(
          filter.mayContain(k),
          isTrue,
          reason: 'key "${utf8.decode(k)}" should be found',
        );
      }
    });
  });

  group('BloomFilter: false positive rate', () {
    test('FPR is within spec at 10 bits/key over 10K keys', () {
      final inserted = List.generate(10000, (i) => _k('present-$i'));
      final filter = BloomFilter.build(inserted);

      // Test against 10K keys that were definitely NOT inserted.
      var falsePositives = 0;
      for (var i = 0; i < 10000; i++) {
        if (filter.mayContain(_k('absent-$i'))) falsePositives++;
      }
      // Spec target: ~0.8% FPR. Allow up to 2% to avoid flakiness.
      final fpr = falsePositives / 10000;
      expect(fpr, lessThan(0.02), reason: 'FPR was $fpr');
    });
  });

  group('BloomFilter serialisation round-trip', () {
    test('toBytes / fromBytes preserves membership', () {
      final keys = List.generate(100, (i) => _k('entry-$i'));
      final original = BloomFilter.build(keys);
      final restored = BloomFilter.fromBytes(original.toBytes());

      for (final k in keys) {
        expect(restored.mayContain(k), isTrue);
      }
    });

    test('fromBytes throws on empty bytes', () {
      expect(
        () => BloomFilter.fromBytes(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('toBytes includes hashCount as first byte', () {
      final filter = BloomFilter.build([_k('a')]);
      final bytes = filter.toBytes();
      // Default hashCount = 7.
      expect(bytes[0], equals(7));
    });
  });

  group('BloomFilter empty set', () {
    test('empty filter returns false for all queries', () {
      final filter = BloomFilter.build([]);
      expect(filter.mayContain(_k('anything')), isFalse);
    });

    test('empty filter toBytes has length 1 (just hashCount)', () {
      final filter = BloomFilter.build([]);
      expect(filter.toBytes().length, equals(1));
    });
  });

  group('BloomFilter single key', () {
    test('single inserted key is found', () {
      final key = _k('only-key');
      final filter = BloomFilter.build([key]);
      expect(filter.mayContain(key), isTrue);
    });

    test('absent keys mostly return false (single-element FPR sanity)', () {
      // With only 1 key the filter is tiny (16 bits), so FPR can be higher
      // than the 0.8% ideal. We check 500 absent keys and expect fewer than
      // 10% false positives — well above what a correct implementation sees.
      final filter = BloomFilter.build([_k('present')]);
      var fp = 0;
      for (var i = 0; i < 500; i++) {
        if (filter.mayContain(_k('absent-$i'))) fp++;
      }
      expect(fp / 500, lessThan(0.10));
    });
  });
}
