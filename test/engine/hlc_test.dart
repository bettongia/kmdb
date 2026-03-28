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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/sync/hlc_clock.dart';

void main() {
  // ── Hlc value type ────────────────────────────────────────────────────────

  group('Hlc encoding', () {
    test('encodes and decodes round-trip', () {
      const hlc = Hlc(1000, 5);
      expect(Hlc.fromEncoded(hlc.encoded), equals(hlc));
    });

    test('encoded packs physical into upper 48 bits', () {
      const hlc = Hlc(1, 0);
      expect(hlc.encoded, equals(1 << 16));
    });

    test('encoded packs logical into lower 16 bits', () {
      const hlc = Hlc(0, 7);
      expect(hlc.encoded, equals(7));
    });

    test('toHex produces 16-character uppercase string', () {
      const hlc = Hlc(0x017F8A0B1C, 0x0042);
      expect(hlc.toHex().length, equals(16));
      expect(hlc.toHex(), equals(hlc.toHex().toUpperCase()));
    });

    test('toPhysicalHex produces 12-character uppercase string', () {
      const hlc = Hlc(0x017F8A0B1C00, 99);
      expect(hlc.toPhysicalHex().length, equals(12));
    });

    test('fromHex round-trips 16-char hex', () {
      const original = Hlc(0x017F8A0B1C00, 0x0012);
      final hex = original.toHex();
      expect(Hlc.fromHex(hex), equals(original));
    });

    test('fromHex accepts 12-char hex (physical only, logical = 0)', () {
      final hlc = Hlc.fromHex('017F8A0B1C00');
      expect(hlc.physicalMs, equals(0x017F8A0B1C00));
      expect(hlc.logical, equals(0));
    });

    test('fromHex throws on invalid length', () {
      expect(() => Hlc.fromHex('ABCD'), throwsA(isA<FormatException>()));
    });

    test('zero value encodes and decodes', () {
      const hlc = Hlc(0, 0);
      expect(hlc.encoded, equals(0));
      expect(Hlc.fromEncoded(0), equals(hlc));
    });

    test('max physical value encodes correctly', () {
      const maxPhysical = 0xFFFFFFFFFFFF;
      const hlc = Hlc(maxPhysical, 0xFFFF);
      expect(Hlc.fromEncoded(hlc.encoded), equals(hlc));
    });
  });

  group('Hlc ordering', () {
    test('later physical > earlier physical', () {
      const a = Hlc(100, 0);
      const b = Hlc(200, 0);
      expect(a < b, isTrue);
      expect(b > a, isTrue);
    });

    test('same physical, higher logical is greater', () {
      const a = Hlc(100, 1);
      const b = Hlc(100, 2);
      expect(a < b, isTrue);
    });

    test('same physical and logical are equal', () {
      const a = Hlc(100, 5);
      const b = Hlc(100, 5);
      expect(a == b, isTrue);
      expect(a.compareTo(b), equals(0));
    });

    test('compareTo returns negative for lesser', () {
      expect(const Hlc(1, 0).compareTo(const Hlc(2, 0)), isNegative);
    });

    test('compareTo returns positive for greater', () {
      expect(const Hlc(2, 0).compareTo(const Hlc(1, 0)), isPositive);
    });

    test('sorted list orders correctly', () {
      final hlcs = [
        const Hlc(200, 0),
        const Hlc(100, 5),
        const Hlc(100, 0),
        const Hlc(300, 0),
      ]..sort();
      expect(hlcs, equals([
        const Hlc(100, 0),
        const Hlc(100, 5),
        const Hlc(200, 0),
        const Hlc(300, 0),
      ]));
    });
  });

  // ── HlcClock ──────────────────────────────────────────────────────────────

  group('HlcClock.now()', () {
    test('returns monotonically increasing values', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      final t1 = clock.now();
      final t2 = clock.now(); // same wall clock value → logical increments
      expect(t2 > t1, isTrue);
    });

    test('advances physical when wall clock advances', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      clock.now(); // t=1000, logical=0
      wall = 2000;
      final t = clock.now();
      expect(t.physicalMs, equals(2000));
      expect(t.logical, equals(0));
    });

    test('increments logical on wall clock regression', () {
      var wall = 2000;
      final clock = HlcClock(wallClock: () => wall);
      clock.now(); // physical=2000, logical=0
      wall = 1000; // clock goes backward
      final t = clock.now();
      // Physical stays at 2000, logical increments.
      expect(t.physicalMs, equals(2000));
      expect(t.logical, equals(1));
    });

    test('always strictly greater than previous', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      Hlc? prev;
      for (var i = 0; i < 100; i++) {
        if (i == 50) wall = 2000;
        final t = clock.now();
        if (prev != null) expect(t > prev, isTrue);
        prev = t;
      }
    });
  });

  group('HlcClock.update()', () {
    test('adopts remote physical when remote is newest', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      clock.now(); // local = (1000, 0)
      final remote = const Hlc(1500, 3);
      final result = clock.update(remote);
      // Remote physical (1500) > local (1000) and wall (1000):
      // adopt remote physical, increment remote logical.
      expect(result.physicalMs, equals(1500));
      expect(result.logical, equals(4));
    });

    test('keeps local physical when local is newest', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      clock.now(); // local = (1000, 0)
      final result = clock.update(const Hlc(500, 99));
      // Local physical (1000) > remote (500) and wall (1000): keep local.
      expect(result.physicalMs, equals(1000));
      expect(result.logical, equals(1));
    });

    test('takes max logical when physical times are equal', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      clock.now(); // local = (1000, 0)
      final result = clock.update(const Hlc(1000, 7));
      // Same physical: max(0, 7) + 1 = 8.
      expect(result.physicalMs, equals(1000));
      expect(result.logical, equals(8));
    });

    test('advances to wall clock when wall is newest', () {
      var wall = 3000;
      final clock = HlcClock(wallClock: () => wall);
      // Force local to a past time by ticking at a lower wall time.
      // (Simulate a recovered clock from a previous session.)
      final clockOld = HlcClock(wallClock: () => 1000);
      clockOld.now();
      // New clock at wall=3000 receives a remote HLC at 2000.
      final result = clock.update(const Hlc(2000, 5));
      // Wall (3000) > remote (2000) > local initial: advance to wall.
      expect(result.physicalMs, equals(3000));
      expect(result.logical, equals(0));
    });

    test('throws ClockSkewException when remote is too far ahead', () {
      var wall = 1000;
      final clock = HlcClock(
        wallClock: () => wall,
        maxClockSkew: const Duration(seconds: 60),
      );
      // Remote is 120s ahead of wall (exceeds 60s limit).
      final remote = Hlc(wall + 120000, 0);
      expect(
        () => clock.update(remote),
        throwsA(isA<ClockSkewException>()),
      );
    });

    test('accepts remote just within the skew window', () {
      var wall = 100000;
      final clock = HlcClock(
        wallClock: () => wall,
        maxClockSkew: const Duration(seconds: 60),
      );
      final remote = Hlc(wall + 59999, 0); // 1ms under limit
      expect(() => clock.update(remote), returnsNormally);
    });

    test('result is always strictly greater than previous local HLC', () {
      var wall = 1000;
      final clock = HlcClock(wallClock: () => wall);
      Hlc prev = clock.now();
      final remotes = [
        const Hlc(500, 0),
        const Hlc(1000, 5),
        const Hlc(1200, 0),
      ];
      for (final r in remotes) {
        final next = clock.update(r);
        expect(next > prev, isTrue, reason: 'after update with $r');
        prev = next;
      }
    });
  });
}
