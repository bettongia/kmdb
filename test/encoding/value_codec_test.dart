import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/encoding/compression_flag.dart';
import 'package:kmdb/src/encoding/value_codec.dart';

void main() {
  // ── CompressionFlag ──────────────────────────────────────────────────────────

  group('CompressionFlag', () {
    test('none byte is 0x00', () => expect(CompressionFlag.none.byte, 0x00));
    test('zstd byte is 0x01', () => expect(CompressionFlag.zstd.byte, 0x01));
    test('deflate byte is 0x02',
        () => expect(CompressionFlag.deflate.byte, 0x02));

    test('fromByte round-trips all known values', () {
      expect(CompressionFlag.fromByte(0x00), CompressionFlag.none);
      expect(CompressionFlag.fromByte(0x01), CompressionFlag.zstd);
      expect(CompressionFlag.fromByte(0x02), CompressionFlag.deflate);
    });

    test('fromByte throws on unknown byte', () {
      expect(
        () => CompressionFlag.fromByte(0xFF),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ── ValueCodec round-trips ───────────────────────────────────────────────────

  group('ValueCodec round-trips', () {
    Map<String, dynamic> roundTrip(Map<String, dynamic> doc) =>
        ValueCodec.decode(ValueCodec.encode(doc));

    test('empty map', () {
      expect(roundTrip({}), equals({}));
    });

    test('string values', () {
      final doc = {'name': 'Alice', 'city': 'London'};
      expect(roundTrip(doc), equals(doc));
    });

    test('integer values', () {
      final doc = {'count': 42, 'negative': -7};
      expect(roundTrip(doc), equals(doc));
    });

    test('double values', () {
      final doc = {'pi': 3.14159, 'zero': 0.0};
      final result = roundTrip(doc);
      expect(result['pi'], closeTo(3.14159, 1e-10));
      expect(result['zero'], equals(0.0));
    });

    test('boolean values', () {
      final doc = {'active': true, 'deleted': false};
      expect(roundTrip(doc), equals(doc));
    });

    test('null values', () {
      final doc = {'optional': null};
      expect(roundTrip(doc), equals(doc));
    });

    test('nested map', () {
      final doc = {
        'address': {'street': '10 Downing St', 'postcode': 'SW1A 2AA'},
      };
      expect(roundTrip(doc), equals(doc));
    });

    test('list values', () {
      final doc = {
        'tags': ['dart', 'flutter', 'kmdb'],
        'scores': [1, 2, 3],
      };
      expect(roundTrip(doc), equals(doc));
    });

    test('mixed nested structure', () {
      final doc = {
        'id': 1,
        'name': 'Test',
        'meta': {'version': 2, 'flags': [true, false]},
        'empty': null,
      };
      expect(roundTrip(doc), equals(doc));
    });

    test('large document round-trips (triggers compression path)', () {
      // Build a document large enough to exceed the 64-byte threshold.
      final doc = {
        for (var i = 0; i < 20; i++) 'field_$i': 'value_$i' * 3,
      };
      expect(roundTrip(doc), equals(doc));
    });
  });

  // ── encode output format ─────────────────────────────────────────────────────

  group('ValueCodec.encode output format', () {
    test('small doc starts with 0x00 (no compression)', () {
      final bytes = ValueCodec.encode({'x': 1});
      expect(bytes[0], equals(0x00));
    });

    test('encode returns at least 2 bytes', () {
      final bytes = ValueCodec.encode({});
      expect(bytes.length, greaterThanOrEqualTo(2));
    });

    test('large doc may be compressed (flag 0x00 or 0x02)', () {
      final doc = {
        for (var i = 0; i < 20; i++) 'key_$i': 'value_repeated_$i' * 5,
      };
      final bytes = ValueCodec.encode(doc);
      // Flag must be a known CompressionFlag value.
      expect(
        () => CompressionFlag.fromByte(bytes[0]),
        returnsNormally,
      );
    });
  });

  // ── decode error paths ───────────────────────────────────────────────────────

  group('ValueCodec.decode error paths', () {
    test('throws ArgumentError on empty input', () {
      expect(
        () => ValueCodec.decode(Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError on unknown flag byte', () {
      final bad = Uint8List.fromList([0xFF, 0xA1, 0x60]); // 0xFF is unknown
      expect(
        () => ValueCodec.decode(bad),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws UnsupportedError on Zstd flag (not yet implemented)', () {
      // Manually craft a payload with 0x01 (Zstd) flag.
      final fake = Uint8List.fromList([0x01, 0x00]);
      expect(
        () => ValueCodec.decode(fake),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('throws on truncated deflate payload', () {
      // 0x02 = deflate, followed by garbage bytes that cannot be inflated.
      final bad = Uint8List.fromList([0x02, 0xDE, 0xAD, 0xBE, 0xEF]);
      expect(
        () => ValueCodec.decode(bad),
        throwsA(anything),
      );
    });
  });

  // ── idempotency ──────────────────────────────────────────────────────────────

  group('ValueCodec idempotency', () {
    test('encoding the same document twice produces identical bytes', () {
      final doc = {'a': 1, 'b': 'hello'};
      expect(ValueCodec.encode(doc), equals(ValueCodec.encode(doc)));
    });
  });
}
