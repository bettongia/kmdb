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

import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/versioning/version_entry.dart';
import 'package:test/test.dart';

void main() {
  group('VersionEntry', () {
    // ── Serialisation round-trips ─────────────────────────────────────────────

    test('put-version round-trips via encode/decode', () async {
      final hlc = const Hlc(1000, 0);
      final encoded = await ValueCodec.encode({
        'title': 'Hello',
        'done': false,
      });
      final entry = VersionEntry(hlc: hlc, encodedValue: encoded);

      final bytes = await entry.encode();
      final decoded = await VersionEntry.decode(bytes);

      expect(decoded.hlc, equals(hlc));
      expect(decoded.encodedValue, equals(entry.encodedValue));
      expect(decoded.isDelete, isFalse);
      expect(decoded.promotedFrom, isNull);
    });

    test('delete-version round-trips via encode/decode', () async {
      final hlc = const Hlc(2000, 5);
      final entry = VersionEntry(hlc: hlc, encodedValue: null, isDelete: true);

      final bytes = await entry.encode();
      final decoded = await VersionEntry.decode(bytes);

      expect(decoded.hlc, equals(hlc));
      expect(decoded.encodedValue, isNull);
      expect(decoded.isDelete, isTrue);
      expect(decoded.promotedFrom, isNull);
    });

    test('promoted entry round-trips with promotedFrom set', () async {
      final hlc = const Hlc(3000, 0);
      final promotedFrom = const Hlc(1000, 0);
      final encoded = await ValueCodec.encode({'title': 'Restored'});
      final entry = VersionEntry(
        hlc: hlc,
        encodedValue: encoded,
        promotedFrom: promotedFrom,
      );

      final bytes = await entry.encode();
      final decoded = await VersionEntry.decode(bytes);

      expect(decoded.promotedFrom, equals(promotedFrom));
      expect(decoded.isDelete, isFalse);
    });

    test('fromMap handles missing optional fields gracefully', () {
      // Only the required 'hlc' field is present.
      final map = <String, dynamic>{'hlc': const Hlc(100, 0).encoded};
      final entry = VersionEntry.fromMap(map);
      expect(entry.hlc, equals(const Hlc(100, 0)));
      expect(entry.encodedValue, isNull);
      expect(entry.promotedFrom, isNull);
      expect(entry.isDelete, isFalse);
    });

    test('fromMap throws FormatException for missing hlc', () {
      expect(
        () => VersionEntry.fromMap({
          'encodedValue': [1, 2, 3],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromMap throws FormatException for wrong hlc type', () {
      expect(
        () => VersionEntry.fromMap({'hlc': 'not_an_int'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws FormatException for corrupt bytes', () async {
      // These bytes do not represent a valid ValueCodec-encoded map.
      // EncryptionFlag=0x00, CompressionFlag=0xFF (unknown) → ArgumentError.
      await expectLater(
        VersionEntry.decode(Uint8List.fromList([0x00, 0xFF, 0xAB])),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toMap omits null optional fields', () {
      final entry = VersionEntry(hlc: const Hlc(1, 0), encodedValue: null);
      final map = entry.toMap();
      expect(map.containsKey('encodedValue'), isFalse);
      expect(map.containsKey('promotedFrom'), isFalse);
      expect(map['isDelete'], isFalse);
    });

    test('toMap includes promotedFrom when set', () {
      final entry = VersionEntry(
        hlc: const Hlc(2, 0),
        encodedValue: null,
        promotedFrom: const Hlc(1, 0),
        isDelete: true,
      );
      final map = entry.toMap();
      expect(map['promotedFrom'], equals(const Hlc(1, 0).encoded));
      expect(map['isDelete'], isTrue);
    });

    test('fromMap throws FormatException for non-List encodedValue', () {
      expect(
        () => VersionEntry.fromMap({'hlc': 0, 'encodedValue': 'not_a_list'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromMap throws FormatException for bad promotedFrom type', () {
      expect(
        () => VersionEntry.fromMap({'hlc': 0, 'promotedFrom': 'not_an_int'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('toString includes hlc hex and isDelete', () {
      final entry = VersionEntry(
        hlc: const Hlc(1, 0),
        encodedValue: null,
        isDelete: true,
      );
      final s = entry.toString();
      expect(s, contains('isDelete: true'));
      expect(s, contains('VersionEntry'));
    });

    // ── decodeIsDeleteSync ────────────────────────────────────────────────────

    test('decodeIsDeleteSync returns false for empty bytes', () {
      expect(VersionEntry.decodeIsDeleteSync(Uint8List(0)), isFalse);
    });

    test(
      'decodeIsDeleteSync returns false for encrypted bytes (0x01 prefix)',
      () {
        // Simulate encrypted VersionEntry bytes (first byte = 0x01).
        final encrypted = Uint8List.fromList([0x01, 0x42, 0x43, 0x44]);
        expect(VersionEntry.decodeIsDeleteSync(encrypted), isFalse);
      },
    );

    test(
      'decodeIsDeleteSync returns true for plaintext delete-version entry',
      () async {
        // Build a real plaintext delete-version entry and check decodeIsDeleteSync.
        final entry = VersionEntry(
          hlc: const Hlc(1, 0),
          encodedValue: null,
          isDelete: true,
        );
        final bytes = await entry.encode(); // EncryptionFlag.none prefix
        expect(VersionEntry.decodeIsDeleteSync(bytes), isTrue);
      },
    );

    test(
      'decodeIsDeleteSync returns false for plaintext put-version entry',
      () async {
        final encoded = await ValueCodec.encode({'title': 'Hello'});
        final entry = VersionEntry(hlc: const Hlc(1, 0), encodedValue: encoded);
        final bytes = await entry.encode();
        expect(VersionEntry.decodeIsDeleteSync(bytes), isFalse);
      },
    );

    test('decodeIsDeleteSync returns false for corrupt bytes', () {
      final corrupt = Uint8List.fromList([0x00, 0xFF, 0xAB, 0xCD]);
      expect(VersionEntry.decodeIsDeleteSync(corrupt), isFalse);
    });
  });

  group('DocumentVersion', () {
    test('toString includes id, hlc, and isDelete', () {
      final v = DocumentVersion(
        id: 'mykey',
        hlc: const Hlc(1, 0),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        value: null,
        isDelete: true,
      );
      final s = v.toString();
      expect(s, contains('mykey'));
      expect(s, contains('isDelete: true'));
      expect(s, contains('DocumentVersion'));
    });
  });
}
