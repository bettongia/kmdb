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

import 'package:kmdb/src/sync/auth/sync_set_key.dart';
import 'package:test/test.dart';

void main() {
  group('SyncSetKey', () {
    test('generate produces a 32-byte root key and a non-empty syncSetId', () {
      final key = SyncSetKey.generate();
      expect(key.rootKey.length, 32);
      expect(key.syncSetId, isNotEmpty);
    });

    test('generate produces distinct keys on each call', () {
      final a = SyncSetKey.generate();
      final b = SyncSetKey.generate();
      expect(a.rootKey, isNot(equals(b.rootKey)));
      expect(a.syncSetId, isNot(equals(b.syncSetId)));
    });

    test('rejects a root key of the wrong length', () {
      expect(
        () => SyncSetKey(rootKey: Uint8List(31), syncSetId: 'id'),
        throwsArgumentError,
      );
    });

    test(
      'encode throws ArgumentError when syncSetId exceeds 255 UTF-8 bytes',
      () {
        final key = SyncSetKey(rootKey: Uint8List(32), syncSetId: 'x' * 256);
        expect(key.encode, throwsArgumentError);
      },
    );

    test('encode/decode round-trips', () {
      final key = SyncSetKey.generate();
      final decoded = SyncSetKey.decode(key.encode());
      expect(decoded, equals(key));
      expect(decoded.rootKey, equals(key.rootKey));
      expect(decoded.syncSetId, equals(key.syncSetId));
    });

    test('decode throws FormatException on empty bytes', () {
      expect(() => SyncSetKey.decode(Uint8List(0)), throwsFormatException);
    });

    test('decode throws FormatException on the wrong total length', () {
      final key = SyncSetKey.generate();
      final truncated = Uint8List.sublistView(
        key.encode(),
        0,
        key.encode().length - 1,
      );
      expect(() => SyncSetKey.decode(truncated), throwsFormatException);
    });

    test('decode throws FormatException on invalid UTF-8 in the syncSetId '
        'region', () {
      // Craft bytes with idLen=1 but an invalid lone continuation byte.
      final bytes = Uint8List(1 + 1 + SyncSetKey.kRootKeyLength)
        ..[0] = 1
        ..[1] = 0x80; // invalid standalone UTF-8 byte
      expect(() => SyncSetKey.decode(bytes), throwsFormatException);
    });

    test('equality and hashCode are content-based', () {
      final key = SyncSetKey.generate();
      final copy = SyncSetKey(rootKey: key.rootKey, syncSetId: key.syncSetId);
      expect(copy, equals(key));
      expect(copy.hashCode, equals(key.hashCode));

      final different = SyncSetKey.generate();
      expect(different, isNot(equals(key)));
    });

    test('toString does not leak raw key bytes', () {
      final key = SyncSetKey.generate();
      final str = key.toString();
      expect(str, contains(key.syncSetId));
      expect(str, isNot(contains(key.rootKey.toString())));
    });
  });
}
