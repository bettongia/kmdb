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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/util/varint.dart';

void main() {
  group('Varint.encode / decode round-trip', () {
    final cases = <int>[
      0,
      1,
      127,
      128,
      255,
      300,
      16383,
      16384,
      0x7FFFFFFF,
      0xFFFFFFFF,
      0x1FFFFFFFFFFFFF,
    ];

    for (final v in cases) {
      test('round-trips $v', () {
        final buf = Uint8List(Varint.maxBytes);
        final written = Varint.encode(v, buf, 0);
        expect(written, equals(Varint.encodedLength(v)));
        final (decoded, consumed) = Varint.decode(buf, 0);
        expect(decoded, equals(v));
        expect(consumed, equals(written));
      });
    }
  });

  group('encodedLength', () {
    test('0 → 1 byte', () => expect(Varint.encodedLength(0), equals(1)));
    test('127 → 1 byte', () => expect(Varint.encodedLength(127), equals(1)));
    test('128 → 2 bytes', () => expect(Varint.encodedLength(128), equals(2)));
    test(
      '16383 → 2 bytes',
      () => expect(Varint.encodedLength(16383), equals(2)),
    );
    test(
      '16384 → 3 bytes',
      () => expect(Varint.encodedLength(16384), equals(3)),
    );
  });

  group('encodeToBytes', () {
    test('0 encodes to [0x00]', () {
      expect(Varint.encodeToBytes(0), equals(Uint8List.fromList([0x00])));
    });

    test('300 encodes to correct two bytes', () {
      // 300 = 0b100101100; low 7 bits = 0b0101100 | 0x80 = 0xAC; next = 0x02
      expect(
        Varint.encodeToBytes(300),
        equals(Uint8List.fromList([0xAC, 0x02])),
      );
    });
  });

  group('offset support', () {
    test('encodes and decodes at non-zero offset', () {
      final buf = Uint8List(20);
      buf[5] = 0xFF; // sentinel before
      final written = Varint.encode(1000, buf, 6);
      final (v, n) = Varint.decode(buf, 6);
      expect(v, equals(1000));
      expect(n, equals(written));
      expect(buf[5], equals(0xFF)); // not overwritten
    });
  });

  group('error cases', () {
    test('negative value throws ArgumentError', () {
      final buf = Uint8List(10);
      expect(() => Varint.encode(-1, buf, 0), throwsA(isA<ArgumentError>()));
    });

    test('encodedLength of negative throws ArgumentError', () {
      expect(() => Varint.encodedLength(-1), throwsA(isA<ArgumentError>()));
    });

    test('truncated buffer throws FormatException', () {
      // A varint starting with 0x80 (continuation flag) but no following byte.
      final buf = Uint8List.fromList([0x80]);
      expect(() => Varint.decode(buf, 0), throwsA(isA<FormatException>()));
    });

    test('10-byte varint whose final byte sets the sign bit throws '
        'FormatException instead of decoding to a negative int (S-1/S-3)', () {
      // 9 continuation bytes (all 0xFF, contributing 63 low bits set)
      // followed by a 10th byte with the continuation bit clear and a
      // non-zero low 7 bits — at shift 63 any non-zero contribution would
      // set bit 63 (the sign bit) of the decoded int. Every caller in this
      // codebase treats the result as a length or offset, so a silent
      // negative value here is exactly the S-1 defect: prior to this
      // hardening, `(byte & 0x7F) << 63` overflowed silently and the guard
      // (`shift >= 64`) never fired because it only checked *before*
      // decoding the 10th byte, not the sign-bit contribution itself.
      final buf = Uint8List.fromList([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 9 bytes
        0x01, // 10th byte: continuation bit clear, low bit set
      ]);
      expect(() => Varint.decode(buf, 0), throwsA(isA<FormatException>()));
    });

    test('a 10-byte varint whose final byte is exactly 0x00 still decodes '
        '(no spurious rejection of legitimately-encoded values)', () {
      // A well-formed encoder never emits a trailing zero byte (it would
      // stop one byte earlier), but this confirms the shift-63 guard
      // rejects only a *non-zero* contribution, not the presence of a
      // 10th byte per se.
      final buf = Uint8List.fromList([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 9 bytes
        0x00, // 10th byte: continuation bit clear, zero contribution
      ]);
      final (value, consumed) = Varint.decode(buf, 0);
      expect(consumed, equals(10));
      expect(value, greaterThanOrEqualTo(0));
    });
  });

  group('decodeMany', () {
    test('decodes multiple sequential varints', () {
      final buf = Uint8List(20);
      var pos = 0;
      pos += Varint.encode(10, buf, pos);
      pos += Varint.encode(200, buf, pos);
      pos += Varint.encode(30000, buf, pos);

      final (values, consumed) = Varint.decodeMany(buf, 0, 3);
      expect(values, equals([10, 200, 30000]));
      expect(consumed, equals(pos));
    });
  });
}
