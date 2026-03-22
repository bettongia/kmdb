/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:typed_data';
import 'package:kmdb/src/storage_format.dart';
import 'package:test/test.dart';

void main() {
  group('StorageFormat', () {
    test('serializes and deserializes a single key-value pair', () {
      final key = Uint8List.fromList('key1'.codeUnits);
      final value = Uint8List.fromList('value1'.codeUnits);

      final encoded = StorageFormat.encodeEntry(key, value);
      final decoded = StorageFormat.decodeEntry(encoded);

      expect(decoded.key, equals(key));
      expect(decoded.value, equals(value));
    });

    test('detects corruption', () {
      final key = Uint8List.fromList('key1'.codeUnits);
      final value = Uint8List.fromList('value1'.codeUnits);
      final encoded = StorageFormat.encodeEntry(key, value);

      // Corrupt the data
      encoded[encoded.length - 1] ^= 0xFF;

      expect(() => StorageFormat.decodeEntry(encoded), throwsException);
    });

    test('serializes and deserializes multiple entries', () {
      final entries = [
        MapEntry(
          Uint8List.fromList('k1'.codeUnits),
          Uint8List.fromList('v1'.codeUnits),
        ),
        MapEntry(
          Uint8List.fromList('k2'.codeUnits),
          Uint8List.fromList('v2'.codeUnits),
        ),
      ];

      final encoded = StorageFormat.encodeEntries(entries);
      final decoded = StorageFormat.decodeEntries(encoded);

      expect(decoded.length, equals(2));
      expect(decoded[0].key, equals(entries[0].key));
      expect(decoded[0].value, equals(entries[0].value));
      expect(decoded[1].key, equals(entries[1].key));
      expect(decoded[1].value, equals(entries[1].value));
    });
  });
}
