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

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

void main() {
  group('KeyCodec.generate()', () {
    test('returns 32-character lowercase hex', () {
      final key = KeyCodec.generate();
      expect(key.length, equals(32));
      expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
      // UUIDv7 version 7
      expect(key[12], equals('7'));
      // UUIDv7 variant 2 (8, 9, a, or b)
      expect(['8', '9', 'a', 'b'], contains(key[16]));
    });

    test('successive keys are unique', () {
      final keys = {for (var i = 0; i < 100; i++) KeyCodec.generate()};
      expect(keys.length, equals(100));
    });

    test('keys generated in different milliseconds are time-ordered', () {
      final k1 = KeyCodec.generate();
      String k2;
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      do {
        k2 = KeyCodec.generate();
      } while (k2.compareTo(k1) <= 0 && DateTime.now().isBefore(deadline));
      expect(k2.compareTo(k1) > 0, isTrue);
    });
  });

  group('KeyCodec.keyToBytes / bytesToKey', () {
    test('round-trips a valid UUIDv7 hex key', () {
      final key = '00000000000070008000000000000000';
      expect(KeyCodec.bytesToKey(KeyCodec.keyToBytes(key)), equals(key));
    });

    test('strips hyphens from UUID-format input', () {
      const uuid = '00000000-0000-7000-8000-000000000000';
      final bytes = KeyCodec.keyToBytes(uuid);
      expect(bytes.length, equals(16));
    });

    test('keyToBytes throws on wrong length', () {
      expect(
        () => KeyCodec.keyToBytes('tooshort'),
        throwsA(isA<FormatException>()),
      );
    });

    test('keyToBytes throws on invalid version', () {
      // version 6 instead of 7
      const invalid = '00000000000060008000000000000000';
      expect(
        () => KeyCodec.keyToBytes(invalid),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('version 7 required'),
          ),
        ),
      );
    });

    test('keyToBytes throws on invalid variant', () {
      // variant 0 (bits 00) instead of variant 2 (bits 10)
      const invalid = '00000000000070000000000000000000';
      expect(
        () => KeyCodec.keyToBytes(invalid),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('variant 2 required'),
          ),
        ),
      );
    });

    test('bytesToKey throws on wrong byte count', () {
      expect(
        () => KeyCodec.bytesToKey(Uint8List(10)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Internal key encoding', () {
    const hlc = Hlc(0x017F8A0B1C00, 0x0042);
    const namespace = 'contacts';
    final userKey = KeyCodec.keyToBytes('00000000000070008000000000000000');

    test('encodeInternalKey produces correct length', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.put,
      );
      expect(internal.length, equals(34));
    });

    test('decodes namespace correctly', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.put,
      );
      expect(KeyCodec.decodeNamespace(internal), equals(namespace));
    });

    test('decodes user key correctly', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.put,
      );
      expect(KeyCodec.decodeUserKey(internal), equals(userKey));
    });

    test('decodes HLC correctly', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.put,
      );
      expect(KeyCodec.decodeHlc(internal), equals(hlc));
    });

    test('decodes RecordType put', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.put,
      );
      expect(KeyCodec.decodeRecordType(internal), equals(RecordType.put));
    });

    test('decodes RecordType delete', () {
      final internal = KeyCodec.encodeInternalKey(
        namespace,
        userKey,
        hlc,
        RecordType.delete,
      );
      expect(KeyCodec.decodeRecordType(internal), equals(RecordType.delete));
    });

    test(
      'higher HLC produces greater internal key bytes for same user key',
      () {
        final lower = KeyCodec.encodeInternalKey(
          namespace,
          userKey,
          const Hlc(100, 0),
          RecordType.put,
        );
        final higher = KeyCodec.encodeInternalKey(
          namespace,
          userKey,
          const Hlc(200, 0),
          RecordType.put,
        );
        final hlcOffset = 1 + namespace.length + 16;
        for (var i = 0; i < 8; i++) {
          if (lower[hlcOffset + i] != higher[hlcOffset + i]) {
            expect(higher[hlcOffset + i] > lower[hlcOffset + i], isTrue);
            break;
          }
        }
      },
    );

    test('namespace exceeding 255 bytes throws', () {
      final longNs = 'x' * 256;
      expect(
        () => KeyCodec.encodeInternalKey(longNs, userKey, hlc, RecordType.put),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('encodeNamespace produces correct length-prefixed bytes', () {
      final encoded = KeyCodec.encodeNamespace('tasks');
      expect(encoded[0], equals(5));
      expect(String.fromCharCodes(encoded.sublist(1)), equals('tasks'));
    });
  });

  group('RecordType', () {
    test('put byte is 0x01', () => expect(RecordType.put.byte, equals(0x01)));
    test(
      'delete byte is 0x02',
      () => expect(RecordType.delete.byte, equals(0x02)),
    );

    test('fromByte round-trips', () {
      expect(RecordType.fromByte(0x01), equals(RecordType.put));
      expect(RecordType.fromByte(0x02), equals(RecordType.delete));
    });

    test('fromByte throws on unknown byte', () {
      expect(() => RecordType.fromByte(0xFF), throwsA(isA<ArgumentError>()));
    });
  });

  group('SequentialKeyGenerator', () {
    test('produces incrementing keys', () {
      final gen = SequentialKeyGenerator();
      final k1 = gen.next();
      final k2 = gen.next();
      expect(k1, isNot(equals(k2)));
      expect(k2.compareTo(k1) > 0, isTrue);
    });

    test('reset restarts from given value', () {
      final gen = SequentialKeyGenerator(start: 5);
      gen.next(); // 5
      gen.next(); // 6
      gen.reset();
      expect(gen.next(), equals('00000000000070008000000000000000'));
    });

    test('produces valid UUIDv7 structural bits', () {
      final gen = SequentialKeyGenerator();
      final key = gen.next();
      expect(() => KeyCodec.keyToBytes(key), returnsNormally);
    });
  });
}
