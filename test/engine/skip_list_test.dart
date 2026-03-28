import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/memtable/skip_list.dart';

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  group('SkipList.put / get', () {
    test('put and retrieve a value', () {
      final sl = SkipList();
      sl.put(b([1]), b([10]));
      expect(sl.get(b([1])), equals(b([10])));
    });

    test('get returns null for absent key', () {
      final sl = SkipList();
      expect(sl.get(b([42])), isNull);
    });

    test('overwrite updates value', () {
      final sl = SkipList();
      sl.put(b([1]), b([10]));
      sl.put(b([1]), b([20]));
      expect(sl.get(b([1])), equals(b([20])));
      expect(sl.length, equals(1));
    });

    test('length tracks unique keys', () {
      final sl = SkipList();
      sl.put(b([1]), b([0]));
      sl.put(b([2]), b([0]));
      sl.put(b([1]), b([1])); // overwrite
      expect(sl.length, equals(2));
    });

    test('isEmpty / not isEmpty', () {
      final sl = SkipList();
      expect(sl.isEmpty, isTrue);
      sl.put(b([1]), b([0]));
      expect(sl.isEmpty, isFalse);
    });
  });

  group('SkipList.scan ordering', () {
    test('returns entries in ascending lexicographic order', () {
      final sl = SkipList();
      sl.put(b([3]), b([30]));
      sl.put(b([1]), b([10]));
      sl.put(b([2]), b([20]));
      final entries = sl.scan().toList();
      expect(entries.map((e) => e.key[0]), equals([1, 2, 3]));
    });

    test('scan with start bound', () {
      final sl = SkipList();
      for (var i = 1; i <= 5; i++) {
        sl.put(b([i]), b([i * 10]));
      }
      final entries = sl.scan(start: b([3])).toList();
      expect(entries.map((e) => e.key[0]), equals([3, 4, 5]));
    });

    test('scan with end bound (exclusive)', () {
      final sl = SkipList();
      for (var i = 1; i <= 5; i++) {
        sl.put(b([i]), b([i * 10]));
      }
      final entries = sl.scan(end: b([4])).toList();
      expect(entries.map((e) => e.key[0]), equals([1, 2, 3]));
    });

    test('scan with both start and end', () {
      final sl = SkipList();
      for (var i = 1; i <= 5; i++) {
        sl.put(b([i]), b([i * 10]));
      }
      final entries = sl.scan(start: b([2]), end: b([4])).toList();
      expect(entries.map((e) => e.key[0]), equals([2, 3]));
    });

    test('scan on empty list yields nothing', () {
      final sl = SkipList();
      expect(sl.scan().toList(), isEmpty);
    });
  });

  group('SkipList multi-byte keys', () {
    test('longer prefix sorts correctly', () {
      final sl = SkipList();
      sl.put(b([0x00, 0x02]), b([2]));
      sl.put(b([0x00, 0x01]), b([1]));
      sl.put(b([0x01]), b([3]));
      final keys = sl.scan().map((e) => e.key).toList();
      expect(keys[0], equals(b([0x00, 0x01])));
      expect(keys[1], equals(b([0x00, 0x02])));
      expect(keys[2], equals(b([0x01])));
    });

    test('prefix is not a valid key match for longer key', () {
      final sl = SkipList();
      sl.put(b([0x01, 0x02]), b([99]));
      expect(sl.get(b([0x01])), isNull);
    });
  });

  group('SkipList large dataset', () {
    test('1000 sequential keys inserted in random order stay sorted', () {
      final sl = SkipList();
      final keys = List.generate(1000, (i) => b([i >> 8, i & 0xFF]));
      // Insert in shuffled order using a simple deterministic shuffle.
      final shuffled = [...keys];
      for (var i = shuffled.length - 1; i > 0; i--) {
        final j = (i * 6364136223846793005 + 1442695040888963407) %
            (shuffled.length);
        final tmp = shuffled[i];
        shuffled[i] = shuffled[j.abs()];
        shuffled[j.abs()] = tmp;
      }
      for (final k in shuffled) {
        sl.put(k, k);
      }
      final result = sl.scan().toList();
      expect(result.length, equals(1000));
      for (var i = 0; i < result.length - 1; i++) {
        expect(
          SkipList.compareKeys(result[i].key, result[i + 1].key),
          lessThan(0),
        );
      }
    });
  });
}
