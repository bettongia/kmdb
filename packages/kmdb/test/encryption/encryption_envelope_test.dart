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

/// Unit tests for [EncryptionEnvelope] — the byte-oriented sibling of
/// [ValueCodec] used for scalar/opaque-byte-blob values that are not
/// `Map<String, dynamic>`-shaped (Encryption confidentiality reconciliation
/// plan, Phase 0/B7).
library;

import 'dart:typed_data';

import 'package:kmdb/src/encryption/encryption_envelope.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> ints) => Uint8List.fromList(ints);

void main() {
  group('EncryptionEnvelope.wrap / unwrap', () {
    test('null provider: round-trips plaintext', () async {
      final payload = _bytes([1, 2, 3, 4, 5]);
      final wrapped = await EncryptionEnvelope.wrap(payload, null);
      final unwrapped = await EncryptionEnvelope.unwrap(wrapped, null);
      expect(unwrapped, equals(payload));
    });

    test(
      'null provider: wire format is [EncryptionFlag.none][bytes]',
      () async {
        final payload = _bytes([9, 8, 7]);
        final wrapped = await EncryptionEnvelope.wrap(payload, null);
        expect(wrapped[0], equals(EncryptionFlag.none.byte));
        expect(wrapped.sublist(1), equals(payload));
      },
    );

    test('null provider: zero-length payload round-trips', () async {
      final payload = Uint8List(0);
      final wrapped = await EncryptionEnvelope.wrap(payload, null);
      // Flag byte alone still makes a valid 1-byte self-describing frame.
      expect(wrapped.length, equals(1));
      expect(wrapped[0], equals(EncryptionFlag.none.byte));
      final unwrapped = await EncryptionEnvelope.unwrap(wrapped, null);
      expect(unwrapped, isEmpty);
    });

    test('provider present: round-trips plaintext via AES-GCM', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final payload = _bytes(List.generate(64, (i) => i));

      final wrapped = await EncryptionEnvelope.wrap(payload, provider);
      final unwrapped = await EncryptionEnvelope.unwrap(wrapped, provider);
      expect(unwrapped, equals(payload));
    });

    test(
      'provider present: wire format is [EncryptionFlag.aesGcm][nonce|ciphertext|tag]',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final payload = _bytes([42, 42, 42]);

        final wrapped = await EncryptionEnvelope.wrap(payload, provider);
        expect(wrapped[0], equals(EncryptionFlag.aesGcm.byte));
        // Ciphertext body must not contain the plaintext verbatim.
        expect(wrapped.sublist(1), isNot(equals(payload)));
      },
    );

    test('provider present: zero-length payload round-trips', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final payload = Uint8List(0);

      final wrapped = await EncryptionEnvelope.wrap(payload, provider);
      final unwrapped = await EncryptionEnvelope.unwrap(wrapped, provider);
      expect(unwrapped, isEmpty);
    });

    test('two wraps of the same payload use distinct nonces', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final payload = _bytes([1, 2, 3]);

      final a = await EncryptionEnvelope.wrap(payload, provider);
      final b = await EncryptionEnvelope.wrap(payload, provider);
      expect(a, isNot(equals(b)));
    });

    test('unwrap of empty bytes throws ArgumentError', () async {
      await expectLater(
        EncryptionEnvelope.unwrap(Uint8List(0), null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unwrap of an unknown flag byte throws ArgumentError', () async {
      final bad = _bytes([0xFF, 1, 2, 3]);
      await expectLater(
        EncryptionEnvelope.unwrap(bad, null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'unwrap of an aesGcm-flagged value with no provider throws StateError',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final payload = _bytes([1, 2, 3]);
        final wrapped = await EncryptionEnvelope.wrap(payload, provider);

        await expectLater(
          EncryptionEnvelope.unwrap(wrapped, null),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'unwrap of a tampered ciphertext throws EncryptionError.badCredentials',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final payload = _bytes([1, 2, 3, 4]);
        final wrapped = await EncryptionEnvelope.wrap(payload, provider);

        // Flip the last byte (part of the GCM tag) to corrupt authentication.
        final corrupted = Uint8List.fromList(wrapped);
        corrupted[corrupted.length - 1] ^= 0xFF;

        await expectLater(
          EncryptionEnvelope.unwrap(corrupted, provider),
          throwsA(
            isA<EncryptionError>().having(
              (e) => e.code,
              'code',
              EncryptionErrorCode.badCredentials,
            ),
          ),
        );
      },
    );

    test(
      'unwrap of a value wrapped with a different DEK fails authentication',
      () async {
        final dekA = await KeyDerivation.generateDek();
        final dekB = await KeyDerivation.generateDek();
        final providerA = AesGcmEncryptionProvider(dekA);
        final providerB = AesGcmEncryptionProvider(dekB);
        final payload = _bytes([5, 6, 7]);

        final wrapped = await EncryptionEnvelope.wrap(payload, providerA);

        await expectLater(
          EncryptionEnvelope.unwrap(wrapped, providerB),
          throwsA(isA<EncryptionError>()),
        );
      },
    );
  });
}
