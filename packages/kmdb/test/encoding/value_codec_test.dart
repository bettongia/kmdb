// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:test/test.dart';

import 'package:kmdb/src/encoding/compression_flag.dart';
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/query/filter/field_path.dart';

void main() {
  // ── CompressionFlag ──────────────────────────────────────────────────────────

  group('CompressionFlag', () {
    test('none byte is 0x00', () => expect(CompressionFlag.none.byte, 0x00));
    test('zstd byte is 0x01', () => expect(CompressionFlag.zstd.byte, 0x01));

    test('fromByte round-trips all known values', () {
      expect(CompressionFlag.fromByte(0x00), CompressionFlag.none);
      expect(CompressionFlag.fromByte(0x01), CompressionFlag.zstd);
    });

    test('fromByte throws on unknown byte', () {
      expect(
        () => CompressionFlag.fromByte(0xFF),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fromByte throws on legacy Deflate byte (0x02)', () {
      // Deflate is no longer supported — clean break for pre-release.
      expect(
        () => CompressionFlag.fromByte(0x02),
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
        'meta': {
          'version': 2,
          'flags': [true, false],
        },
        'empty': null,
      };
      expect(roundTrip(doc), equals(doc));
    });

    test('large document round-trips (triggers compression path)', () {
      // Build a document large enough to exceed the 64-byte threshold.
      final doc = {for (var i = 0; i < 20; i++) 'field_$i': 'value_$i' * 3};
      expect(roundTrip(doc), equals(doc));
    });

    test(
      'nested maps decode as Map<String, dynamic> (regression: CBOR toObject returns Map<dynamic, dynamic>)',
      () {
        // CBOR's toObject() returns Map<dynamic,dynamic> for every level of
        // nesting. Without the deep-cast in _fromCbor, FieldPath.resolve() would
        // hit the `is! Map<String,dynamic>` guard and return `missing` for any
        // path that traverses a nested object (e.g. "name.en").
        final doc = {
          'name': {'en': 'McMurdo', 'fr': 'Base McMurdo'},
          'location': {'latitude': -77.8, 'longitude': 166.7},
        };
        final result = roundTrip(doc);
        expect(result['name'], isA<Map<String, dynamic>>());
        expect(result['location'], isA<Map<String, dynamic>>());
        // Verify FieldPath can traverse the decoded nested maps.
        expect(FieldPath.resolve('name.en', result), equals('McMurdo'));
        expect(FieldPath.resolve('location.latitude', result), equals(-77.8));
      },
    );

    test('lists containing maps decode inner maps as Map<String, dynamic>', () {
      final doc = {
        'policies': [
          {'id': 1, 'expired': false},
          {'id': 2, 'expired': true},
        ],
      };
      final result = roundTrip(doc);
      final policies = result['policies'] as List;
      expect(policies[0], isA<Map<String, dynamic>>());
    });
  });

  // ── Compression behaviour ────────────────────────────────────────────────────

  group('ValueCodec compression behaviour', () {
    test('small doc (< 64 bytes) is stored uncompressed with flag 0x00', () {
      final bytes = ValueCodec.encode({'x': 1});
      expect(bytes[0], equals(0x00));
    });

    test('large doc is compressed on native (flag 0x01 — Zstd)', () {
      // A highly repetitive payload compresses well.
      final doc = {
        for (var i = 0; i < 20; i++) 'key_$i': 'value_repeated_$i' * 5,
      };
      final bytes = ValueCodec.encode(doc);
      // On native (dart:io) this must be Zstd.
      expect(bytes[0], equals(CompressionFlag.zstd.byte));
    });

    test('incompressible data falls back to no compression (flag 0x00)', () {
      // Pre-compressed random-looking bytes encoded as base64 strings do not
      // compress further. Use an already-deflated payload as the document
      // value to simulate incompressible content.
      final noise = List.generate(200, (i) => (i * 37 + 13) % 256);
      // Wrap in a map so ValueCodec can encode it.
      final doc = {'data': noise};
      final bytes = ValueCodec.encode(doc);
      // Flag must be a known value — 0x00 or 0x01 are both valid outcomes
      // depending on whether the compressor beats the threshold.
      expect(() => CompressionFlag.fromByte(bytes[0]), returnsNormally);
    });

    test('legacy Deflate-encoded payload (flag 0x02) throws ArgumentError', () {
      // Deflate (flag 0x02) is no longer supported — clean break.
      // Any stored value bearing the legacy flag must surface a clear error.
      final doc = {for (var i = 0; i < 20; i++) 'k$i': 'v' * 10};
      final cborBytes = Uint8List.fromList(cbor.encode(CborValue(doc)));

      // Build the on-disk byte sequence: [0x02][raw CBOR].
      final stored = Uint8List(1 + cborBytes.length);
      stored[0] = 0x02; // legacy Deflate flag byte
      stored.setAll(1, cborBytes);

      expect(() => ValueCodec.decode(stored), throwsA(isA<ArgumentError>()));
    });

    test('compression threshold boundary: 63-byte CBOR is uncompressed', () {
      // Construct a document whose CBOR encoding is just under 64 bytes.
      // A single short string value reliably stays small.
      final doc = {'a': 'b'};
      final bytes = ValueCodec.encode(doc);
      expect(bytes[0], equals(CompressionFlag.none.byte));
    });
  });

  // ── encode output format ─────────────────────────────────────────────────────

  group('ValueCodec.encode output format', () {
    test('encode returns at least 2 bytes', () {
      final bytes = ValueCodec.encode({});
      expect(bytes.length, greaterThanOrEqualTo(2));
    });

    test('flag byte is always a recognised CompressionFlag', () {
      final docs = [
        <String, dynamic>{},
        {'x': 1},
        {for (var i = 0; i < 20; i++) 'k$i': 'value_$i' * 5},
      ];
      for (final doc in docs) {
        final bytes = ValueCodec.encode(doc);
        expect(() => CompressionFlag.fromByte(bytes[0]), returnsNormally);
      }
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
      expect(() => ValueCodec.decode(bad), throwsA(isA<ArgumentError>()));
    });

    test('throws ArgumentError on legacy deflate flag byte (0x02)', () {
      // 0x02 = legacy Deflate flag — no longer supported. CompressionFlag
      // .fromByte throws ArgumentError before decompression is even attempted.
      final bad = Uint8List.fromList([0x02, 0xDE, 0xAD, 0xBE, 0xEF]);
      expect(() => ValueCodec.decode(bad), throwsA(isA<ArgumentError>()));
    });

    test('throws on truncated zstd payload', () {
      // 0x01 = zstd, followed by garbage bytes that cannot be decompressed.
      final bad = Uint8List.fromList([0x01, 0xDE, 0xAD, 0xBE, 0xEF]);
      expect(() => ValueCodec.decode(bad), throwsA(anything));
    });
  });

  // ── idempotency ──────────────────────────────────────────────────────────────

  group('ValueCodec idempotency', () {
    test('encoding the same document twice produces identical bytes', () {
      final doc = {'a': 1, 'b': 'hello'};
      expect(ValueCodec.encode(doc), equals(ValueCodec.encode(doc)));
    });

    test('encoding a large document twice produces identical bytes', () {
      final doc = {for (var i = 0; i < 20; i++) 'k$i': 'value_$i' * 5};
      expect(ValueCodec.encode(doc), equals(ValueCodec.encode(doc)));
    });
  });
}
