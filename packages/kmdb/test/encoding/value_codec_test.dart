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

import 'package:betto_zstd/betto_zstd.dart' show ZstdSimple;
import 'package:cbor/cbor.dart';
import 'package:test/test.dart';

import 'package:kmdb/src/encoding/compression_flag.dart';
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/query/filter/field_path.dart';

void main() {
  // On web the Zstd WASM module must be initialised before any codec call.
  // ZstdSimple.init() is a no-op on native, so this is safe on all platforms.
  setUpAll(() async => ZstdSimple.init());
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

  // ── EncryptionFlag ───────────────────────────────────────────────────────────

  group('EncryptionFlag', () {
    test('none byte is 0x00', () => expect(EncryptionFlag.none.byte, 0x00));
    test('aesGcm byte is 0x01', () => expect(EncryptionFlag.aesGcm.byte, 0x01));

    test('fromByte round-trips all known values', () {
      expect(EncryptionFlag.fromByte(0x00), EncryptionFlag.none);
      expect(EncryptionFlag.fromByte(0x01), EncryptionFlag.aesGcm);
    });

    test('fromByte throws on unknown byte', () {
      expect(
        () => EncryptionFlag.fromByte(0xFF),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ── ValueCodec round-trips ───────────────────────────────────────────────────

  group('ValueCodec round-trips', () {
    // Round-trip: encode then decode. Both are async in Phase 12.
    Future<Map<String, dynamic>> roundTrip(Map<String, dynamic> doc) async =>
        ValueCodec.decode(await ValueCodec.encode(doc));

    test('empty map', () async {
      expect(await roundTrip({}), equals({}));
    });

    test('string values', () async {
      final doc = {'name': 'Alice', 'city': 'London'};
      expect(await roundTrip(doc), equals(doc));
    });

    test('integer values', () async {
      final doc = {'count': 42, 'negative': -7};
      expect(await roundTrip(doc), equals(doc));
    });

    test('double values', () async {
      final doc = {'pi': 3.14159, 'zero': 0.0};
      final result = await roundTrip(doc);
      expect(result['pi'], closeTo(3.14159, 1e-10));
      expect(result['zero'], equals(0.0));
    });

    test('boolean values', () async {
      final doc = {'active': true, 'deleted': false};
      expect(await roundTrip(doc), equals(doc));
    });

    test('null values', () async {
      final doc = {'optional': null};
      expect(await roundTrip(doc), equals(doc));
    });

    test('nested map', () async {
      final doc = {
        'address': {'street': '10 Downing St', 'postcode': 'SW1A 2AA'},
      };
      expect(await roundTrip(doc), equals(doc));
    });

    test('list values', () async {
      final doc = {
        'tags': ['dart', 'flutter', 'kmdb'],
        'scores': [1, 2, 3],
      };
      expect(await roundTrip(doc), equals(doc));
    });

    test('mixed nested structure', () async {
      final doc = {
        'id': 1,
        'name': 'Test',
        'meta': {
          'version': 2,
          'flags': [true, false],
        },
        'empty': null,
      };
      expect(await roundTrip(doc), equals(doc));
    });

    test('large document round-trips (triggers compression path)', () async {
      // Build a document large enough to exceed the 64-byte threshold.
      final doc = {for (var i = 0; i < 20; i++) 'field_$i': 'value_$i' * 3};
      expect(await roundTrip(doc), equals(doc));
    });

    test(
      'nested maps decode as Map<String, dynamic> (regression: CBOR toObject returns Map<dynamic, dynamic>)',
      () async {
        // CBOR's toObject() returns Map<dynamic,dynamic> for every level of
        // nesting. Without the deep-cast in _fromCbor, FieldPath.resolve() would
        // hit the `is! Map<String,dynamic>` guard and return `missing` for any
        // path that traverses a nested object (e.g. "name.en").
        final doc = {
          'name': {'en': 'McMurdo', 'fr': 'Base McMurdo'},
          'location': {'latitude': -77.8, 'longitude': 166.7},
        };
        final result = await roundTrip(doc);
        expect(result['name'], isA<Map<String, dynamic>>());
        expect(result['location'], isA<Map<String, dynamic>>());
        // Verify FieldPath can traverse the decoded nested maps.
        expect(FieldPath.resolve('name.en', result), equals('McMurdo'));
        expect(FieldPath.resolve('location.latitude', result), equals(-77.8));
      },
    );

    test(
      'lists containing maps decode inner maps as Map<String, dynamic>',
      () async {
        final doc = {
          'policies': [
            {'id': 1, 'expired': false},
            {'id': 2, 'expired': true},
          ],
        };
        final result = await roundTrip(doc);
        final policies = result['policies'] as List;
        expect(policies[0], isA<Map<String, dynamic>>());
      },
    );
  });

  // ── Wire format (Phase 12 two-byte prefix) ───────────────────────────────────

  group('ValueCodec wire format', () {
    // Phase 12 format: [EncryptionFlag 1B][CompressionFlag 1B][payload]
    // Byte 0 = EncryptionFlag; byte 1 = CompressionFlag.

    test(
      'unencrypted value has EncryptionFlag.none (0x00) at byte 0',
      () async {
        final bytes = await ValueCodec.encode({'x': 1});
        // Byte 0 is EncryptionFlag — must be 0x00 for plaintext.
        expect(bytes[0], equals(EncryptionFlag.none.byte));
      },
    );

    test(
      'small doc (< 64 bytes) has CompressionFlag.none (0x00) at byte 1 when plaintext',
      () async {
        final bytes = await ValueCodec.encode({'x': 1});
        // Byte 0 = EncryptionFlag.none; byte 1 = CompressionFlag.
        expect(bytes[0], equals(EncryptionFlag.none.byte));
        expect(bytes[1], equals(CompressionFlag.none.byte));
      },
    );

    test(
      'large doc has CompressionFlag.zstd (0x01) at byte 1 on native and web',
      () async {
        // A highly repetitive payload compresses well on both native (FFI) and
        // web (WASM). After betto_zstd WASM was wired in (plan_betto_zstd_web_compression),
        // both platforms compress large documents.
        final doc = {
          for (var i = 0; i < 20; i++) 'key_$i': 'value_repeated_$i' * 5,
        };
        final bytes = await ValueCodec.encode(doc);
        // Byte 0 = EncryptionFlag.none (unencrypted).
        expect(bytes[0], equals(EncryptionFlag.none.byte));
        // Byte 1 = CompressionFlag.zstd (compressed).
        expect(bytes[1], equals(CompressionFlag.zstd.byte));
      },
    );

    test(
      'large doc round-trips correctly with Zstd flag (native and web)',
      () async {
        final doc = {
          for (var i = 0; i < 20; i++) 'field_$i': 'hello_world_$i' * 10,
        };
        final encoded = await ValueCodec.encode(doc);
        // Byte 0 = EncryptionFlag.none; byte 1 = CompressionFlag.zstd.
        expect(encoded[0], equals(EncryptionFlag.none.byte));
        expect(encoded[1], equals(CompressionFlag.zstd.byte));
        // Decode must recover the original document exactly.
        expect(await ValueCodec.decode(encoded), equals(doc));
      },
    );

    test(
      'incompressible data falls back to CompressionFlag.none at byte 1',
      () async {
        // Pre-compressed random-looking bytes do not compress further.
        final noise = List.generate(200, (i) => (i * 37 + 13) % 256);
        final doc = {'data': noise};
        final bytes = await ValueCodec.encode(doc);
        // Byte 0 = EncryptionFlag.none.
        expect(bytes[0], equals(EncryptionFlag.none.byte));
        // Byte 1 must be a known CompressionFlag value.
        expect(() => CompressionFlag.fromByte(bytes[1]), returnsNormally);
      },
    );
  });

  // ── Compression behaviour (legacy path) ─────────────────────────────────────

  group('ValueCodec legacy Deflate rejection', () {
    test(
      'legacy Deflate-encoded payload (flag 0x02) throws ArgumentError',
      () async {
        // Deflate (flag 0x02) is no longer supported — clean break.
        final doc = {for (var i = 0; i < 20; i++) 'k$i': 'v' * 10};
        final cborBytes = Uint8List.fromList(cbor.encode(CborValue(doc)));

        // Build an old-style on-disk byte sequence: [EncryptionFlag.none][0x02][raw CBOR].
        // This simulates a legacy byte sequence that a prior build might have written.
        final stored = Uint8List(2 + cborBytes.length);
        stored[0] = 0x00; // EncryptionFlag.none
        stored[1] = 0x02; // legacy Deflate flag byte — unsupported
        stored.setAll(2, cborBytes);

        expect(
          () async => ValueCodec.decode(stored),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  // ── encode output format ─────────────────────────────────────────────────────

  group('ValueCodec.encode output format', () {
    test('encode returns at least 2 bytes', () async {
      final bytes = await ValueCodec.encode({});
      expect(bytes.length, greaterThanOrEqualTo(2));
    });

    test('byte 0 is always a recognised EncryptionFlag', () async {
      final docs = [
        <String, dynamic>{},
        {'x': 1},
        {for (var i = 0; i < 20; i++) 'k$i': 'value_$i' * 5},
      ];
      for (final doc in docs) {
        final bytes = await ValueCodec.encode(doc);
        expect(() => EncryptionFlag.fromByte(bytes[0]), returnsNormally);
      }
    });

    test(
      'byte 1 is always a recognised CompressionFlag for unencrypted values',
      () async {
        final docs = [
          <String, dynamic>{},
          {'x': 1},
          {for (var i = 0; i < 20; i++) 'k$i': 'value_$i' * 5},
        ];
        for (final doc in docs) {
          final bytes = await ValueCodec.encode(doc);
          // Byte 0 = EncryptionFlag.none → byte 1 is the CompressionFlag.
          if (bytes[0] == EncryptionFlag.none.byte) {
            expect(() => CompressionFlag.fromByte(bytes[1]), returnsNormally);
          }
        }
      },
    );
  });

  // ── decode error paths ───────────────────────────────────────────────────────

  group('ValueCodec.decode error paths', () {
    test('throws ArgumentError on empty input', () async {
      expect(
        () async => ValueCodec.decode(Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError on unknown encryption flag byte', () async {
      final bad = Uint8List.fromList([0xFF, 0xA1, 0x60]); // 0xFF is unknown
      expect(() async => ValueCodec.decode(bad), throwsA(isA<ArgumentError>()));
    });

    test(
      'throws ArgumentError on unknown compression flag byte (inside plaintext)',
      () async {
        // Two bytes: EncryptionFlag.none then an unknown CompressionFlag.
        final bad = Uint8List.fromList([0x00, 0x02, 0xDE, 0xAD]);
        expect(
          () async => ValueCodec.decode(bad),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('throws on truncated zstd payload', () async {
      // EncryptionFlag.none, CompressionFlag.zstd (0x01), then garbage.
      // Native throws ZstdException (from betto_zstd FFI); web throws
      // ZstdException (from betto_zstd WASM). The `anything` matcher accepts
      // both — no platform-specific guard needed.
      final bad = Uint8List.fromList([0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF]);
      expect(() async => ValueCodec.decode(bad), throwsA(anything));
    });

    test(
      'throws ArgumentError when encrypted value is decoded without a provider',
      () async {
        // A byte starting with EncryptionFlag.aesGcm (0x01) but no provider
        // supplied should throw a clear, attributable error.
        final fakeEncrypted = Uint8List.fromList([
          0x01, // EncryptionFlag.aesGcm
          ...List.filled(28, 0x42), // fake nonce+ciphertext
        ]);
        expect(
          () async => ValueCodec.decode(fakeEncrypted),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  // ── idempotency ──────────────────────────────────────────────────────────────

  group('ValueCodec idempotency', () {
    test('encoding the same document twice produces identical bytes', () async {
      final doc = {'a': 1, 'b': 'hello'};
      final b1 = await ValueCodec.encode(doc);
      final b2 = await ValueCodec.encode(doc);
      expect(b1, equals(b2));
    });

    test('encoding a large document twice produces identical bytes', () async {
      final doc = {for (var i = 0; i < 20; i++) 'k$i': 'value_$i' * 5};
      final b1 = await ValueCodec.encode(doc);
      final b2 = await ValueCodec.encode(doc);
      expect(b1, equals(b2));
    });
  });
}
