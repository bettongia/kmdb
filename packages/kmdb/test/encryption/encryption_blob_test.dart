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
import 'package:kmdb/src/encryption/encryption_blob.dart';
import 'package:test/test.dart';

void main() {
  // ── EncryptionBlob encode/decode round-trip ──────────────────────────────────

  group('EncryptionBlob', () {
    final salt = Uint8List.fromList(List.generate(32, (i) => i));
    final wrappedP = Uint8List.fromList(List.generate(60, (i) => i + 1));
    final wrappedR = Uint8List.fromList(List.generate(60, (i) => i + 2));

    test('encode/decode round-trips all fields', () {
      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedP,
        wrappedDekRecovery: wrappedR,
        argon2Memory: 65536,
        argon2Iterations: 3,
        argon2Parallelism: 1,
      );

      final bytes = blob.encode();
      final decoded = EncryptionBlob.decode(bytes);

      expect(decoded.argon2Salt, equals(salt));
      expect(decoded.wrappedDekPassphrase, equals(wrappedP));
      expect(decoded.wrappedDekRecovery, equals(wrappedR));
      expect(decoded.argon2Memory, equals(65536));
      expect(decoded.argon2Iterations, equals(3));
      expect(decoded.argon2Parallelism, equals(1));
    });

    test('kVersion is 1', () {
      expect(EncryptionBlob.kVersion, equals(1));
    });

    test('default KDF params match KeyDerivation constants', () {
      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedP,
        wrappedDekRecovery: wrappedR,
      );
      // Defaults from the constructor should match KeyDerivation.
      expect(blob.argon2Memory, equals(65536));
      expect(blob.argon2Iterations, equals(3));
      expect(blob.argon2Parallelism, equals(1));
    });

    test('encode produces a non-empty byte array', () {
      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedP,
        wrappedDekRecovery: wrappedR,
      );
      final bytes = blob.encode();
      expect(bytes, isNotEmpty);
    });

    test('decode throws FormatException for non-CBOR input', () {
      expect(
        () => EncryptionBlob.decode(Uint8List.fromList([0xFF, 0xFF])),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws FormatException when required fields are missing', () {
      // Encode an empty CBOR map — valid CBOR but missing all required fields.
      final emptyMap = Uint8List.fromList(cbor.encode(CborMap({})));
      expect(
        () => EncryptionBlob.decode(emptyMap),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws FormatException for non-map CBOR', () {
      // A CBOR integer is valid CBOR but not a map.
      final cborInt = Uint8List.fromList(cbor.encode(const CborSmallInt(42)));
      expect(
        () => EncryptionBlob.decode(cborInt),
        throwsA(isA<FormatException>()),
      );
    });

    test('encode is idempotent', () {
      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedP,
        wrappedDekRecovery: wrappedR,
      );
      final b1 = blob.encode();
      final b2 = blob.encode();
      expect(b1, equals(b2));
    });
  });
}
