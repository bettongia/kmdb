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

import 'package:kmdb/src/engine/util/xxhash.dart';

void main() {
  // Official XXH64 test vectors from the xxHash reference implementation.
  // Source: https://github.com/Cyan4973/xxHash/blob/dev/cli/xsum_sanity_check.c
  group('official test vectors (seed = 0)', () {
    test('empty input → 0xEF46DB3751D8E999', () {
      final hash = XxHash64.digest(Uint8List(0));
      expect(XxHash64.toHex(hash), equals('EF46DB3751D8E999'));
    });

    test('1 byte (0x00) → 0xE934A84ADB052768', () {
      final hash = XxHash64.digest(Uint8List.fromList([0x00]));
      expect(XxHash64.toHex(hash), equals('E934A84ADB052768'));
    });

    test('"a" → 0xD24EC4F1A98C6E5B', () {
      final hash = XxHash64.digest(Uint8List.fromList(utf8.encode('a')));
      expect(XxHash64.toHex(hash), equals('D24EC4F1A98C6E5B'));
    });

    test('"test" (4 bytes) → 0x4FDCCA5DDB678139', () {
      final hash = XxHash64.digest(Uint8List.fromList(utf8.encode('test')));
      expect(XxHash64.toHex(hash), equals('4FDCCA5DDB678139'));
    });

    test('24 bytes → exercises the 8-byte tail path', () {
      // "123456789012345678901234" — 24 bytes, no 32-byte stripe, two 8-byte
      // chunks, one 4-byte chunk, no single-byte tail.
      final data = Uint8List.fromList(utf8.encode('123456789012345678901234'));
      final hash = XxHash64.digest(data);
      expect(XxHash64.toHex(hash), equals('F74E1B016D7342D0'));
    });

    test('32 bytes → exercises the 32-byte stripe path', () {
      // Exactly one stripe of 32 bytes.
      final data = Uint8List.fromList(
        utf8.encode('12345678901234567890123456789012'),
      );
      final hash = XxHash64.digest(data);
      expect(XxHash64.toHex(hash), equals('40FD1AA52D98274C'));
    });

    test('64 bytes → two full stripes', () {
      final data = Uint8List.fromList(
        utf8.encode(
          '1234567890123456789012345678901234567890123456789012345678901234',
        ),
      );
      final hash = XxHash64.digest(data);
      expect(XxHash64.toHex(hash), equals('D011332221B7885A'));
    });
  });

  group('non-zero seed', () {
    test('empty input with seed=1 → different from seed=0', () {
      final h0 = XxHash64.digest(Uint8List(0));
      final h1 = XxHash64.digest(Uint8List(0), seed: 1);
      expect(h0, isNot(equals(h1)));
    });

    test('"test" with seed=0x02CC5D05 → 0xA71C05D6C79CA84E', () {
      final hash = XxHash64.digest(
        Uint8List.fromList(utf8.encode('test')),
        seed: 0x02CC5D05,
      );
      expect(XxHash64.toHex(hash), equals('A71C05D6C79CA84E'));
    });
  });

  group('determinism and collision resistance', () {
    test('same input always produces the same hash', () {
      final data = Uint8List.fromList(utf8.encode('hello world'));
      final h1 = XxHash64.digest(data);
      final h2 = XxHash64.digest(data);
      expect(h1, equals(h2));
    });

    test('different inputs produce different hashes', () {
      final hashes = <int>{};
      for (var i = 0; i < 1000; i++) {
        final data = Uint8List.fromList(utf8.encode('item-$i'));
        hashes.add(XxHash64.digest(data));
      }
      // All 1000 distinct inputs should produce distinct hashes.
      expect(hashes.length, equals(1000));
    });

    test('single-bit difference produces a different hash', () {
      final a = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);
      final b = Uint8List.fromList([0x01, 0x00, 0x00, 0x00]);
      expect(XxHash64.digest(a), isNot(equals(XxHash64.digest(b))));
    });
  });

  group('double-hashing (Bloom filter usage)', () {
    test('h2 = digest(key, seed: h1) differs from h1', () {
      final key = Uint8List.fromList(utf8.encode('bloom-key'));
      final h1 = XxHash64.digest(key);
      final h2 = XxHash64.digest(key, seed: h1);
      expect(h1, isNot(equals(h2)));
    });
  });

  group('toHex', () {
    test('zero → 16 zeros', () {
      expect(XxHash64.toHex(0), equals('0000000000000000'));
    });

    test('negative int (high bit set) formats correctly', () {
      // -1 in signed 64-bit = 0xFFFFFFFFFFFFFFFF unsigned
      expect(XxHash64.toHex(-1), equals('FFFFFFFFFFFFFFFF'));
    });

    test('known value formats with padding', () {
      // 0xEF46DB3751D8E999 as signed = -1202052685726069351
      expect(
        XxHash64.toHex(XxHash64.digest(Uint8List(0))),
        equals('EF46DB3751D8E999'),
      );
    });
  });
}
