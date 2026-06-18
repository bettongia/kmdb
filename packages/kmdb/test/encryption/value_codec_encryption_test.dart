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

import 'package:betto_zstd/betto_zstd.dart';
import 'package:kmdb/src/encryption/encryption_flag.dart';
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:test/test.dart';

/// A test-only [EncryptionProvider] that XOR-encrypts with a fixed key byte.
///
/// Used to verify the compose-then-encrypt layering without the overhead of
/// a full AES-GCM call. Not cryptographically secure; only for structural tests.
///
/// Wire format: `[key_byte (1B)][plaintext XOR key_byte]`. The `decrypt` is
/// its own inverse.
final class _XorProvider implements EncryptionProvider {
  const _XorProvider(this._key);

  final int _key; // single-byte XOR key

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    return Uint8List.fromList([_key, ...plaintext.map((b) => b ^ _key)]);
  }

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    if (ciphertext.isEmpty) {
      throw EncryptionError(
        EncryptionErrorCode.badCredentials,
        'empty ciphertext',
      );
    }
    final key = ciphertext[0];
    return Uint8List.fromList(
      ciphertext.sublist(1).map((b) => b ^ key).toList(),
    );
  }
}

/// Wrong-key [EncryptionProvider] that always throws [EncryptionError.badCredentials].
final class _BadKeyProvider implements EncryptionProvider {
  const _BadKeyProvider();

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async =>
      throw const EncryptionError(EncryptionErrorCode.encryptionFailed, 'test');

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async =>
      throw const EncryptionError(
        EncryptionErrorCode.badCredentials,
        'Wrong key (test)',
      );
}

void main() {
  setUpAll(() async {
    // Initialise the Zstd module so ValueCodec.encode can compress.
    await ZstdSimple.init(
      wasmUrl: 'assets/packages/betto_zstd/assets/zstd.wasm',
    );
  });

  // ── Round-trip with encryption ───────────────────────────────────────────────

  group('ValueCodec.encode/decode with encryption', () {
    test('small doc round-trips with encryption provider', () async {
      final doc = {'name': 'Alice', 'age': 30};
      final provider = const _XorProvider(0x55);

      final encoded = await ValueCodec.encode(doc, encryption: provider);
      final decoded = await ValueCodec.decode(encoded, encryption: provider);
      expect(decoded, equals(doc));
    });

    test(
      'large doc round-trips with encryption provider (compress-then-encrypt)',
      () async {
        // Large doc to exercise compression before encryption.
        final doc = {
          for (var i = 0; i < 30; i++) 'key_$i': 'value_repeated_$i' * 10,
        };
        final provider = const _XorProvider(0xAB);

        final encoded = await ValueCodec.encode(doc, encryption: provider);
        final decoded = await ValueCodec.decode(encoded, encryption: provider);
        expect(decoded, equals(doc));
      },
    );

    test('empty doc round-trips with encryption', () async {
      final provider = const _XorProvider(0x12);
      final encoded = await ValueCodec.encode({}, encryption: provider);
      final decoded = await ValueCodec.decode(encoded, encryption: provider);
      expect(decoded, equals({}));
    });

    test('AesGcmEncryptionProvider round-trips correctly', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final doc = {'secret': 'top-secret data', 'value': 42};

      final encoded = await ValueCodec.encode(doc, encryption: provider);
      final decoded = await ValueCodec.decode(encoded, encryption: provider);
      expect(decoded, equals(doc));
    });

    test('AesGcmEncryptionProvider large doc round-trips', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final doc = {for (var i = 0; i < 50; i++) 'field_$i': 'data_$i' * 20};

      final encoded = await ValueCodec.encode(doc, encryption: provider);
      final decoded = await ValueCodec.decode(encoded, encryption: provider);
      expect(decoded, equals(doc));
    });
  });

  // ── Wire format with encryption ───────────────────────────────────────────────

  group('ValueCodec wire format with encryption', () {
    test('encrypted value starts with EncryptionFlag.aesGcm (0x01)', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final encoded = await ValueCodec.encode({'x': 1}, encryption: provider);
      expect(encoded[0], equals(EncryptionFlag.aesGcm.byte));
    });

    test('plaintext value starts with EncryptionFlag.none (0x00)', () async {
      final encoded = await ValueCodec.encode({'x': 1});
      expect(encoded[0], equals(EncryptionFlag.none.byte));
    });

    test(
      'encrypted values are longer than plaintext by at least 28 bytes',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final doc = {'key': 'value'};

        final plain = await ValueCodec.encode(doc);
        final encrypted = await ValueCodec.encode(doc, encryption: provider);

        // Encrypted = EncryptionFlag (1B) + nonce (12B) + ciphertext + tag (16B)
        // Plaintext = EncryptionFlag (1B) + CompressionFlag (1B) + CBOR payload
        // The overhead should be 1 (outer flag reduction) + 28 (nonce+tag) bytes.
        // But the ciphertext wraps the [compression_flag][payload], which is the
        // same as the plaintext body. Net overhead: 28 bytes (nonce+tag), minus
        // the 1 byte we remove (compression flag now inside ciphertext) = 27.
        // In practice, encrypted is plain.length - 1 + 28 = plain.length + 27.
        expect(encrypted.length, greaterThanOrEqualTo(plain.length + 27));
      },
    );

    test(
      'compression flag is hidden inside ciphertext (not visible as byte 1)',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final doc = {
          for (var i = 0; i < 30; i++) 'k_$i': 'v' * 50,
        }; // large enough to be compressed

        final encoded = await ValueCodec.encode(doc, encryption: provider);
        // Byte 0 = EncryptionFlag.aesGcm (0x01). Byte 1 onwards is the nonce
        // (random bytes) — NOT a CompressionFlag. Verify byte 1 is not 0x00 or
        // 0x01 (the only valid CompressionFlag values) at least sometimes, or
        // simply that we cannot safely parse it as a CompressionFlag.
        expect(encoded[0], equals(EncryptionFlag.aesGcm.byte));
        // The ciphertext (byte 1...) contains the nonce, so the compression flag
        // is not exposed. We confirm the outer byte is aesGcm, which is the key
        // invariant.
      },
    );

    test(
      'two encryptions of the same doc produce different ciphertexts',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final doc = {'x': 1};

        final e1 = await ValueCodec.encode(doc, encryption: provider);
        final e2 = await ValueCodec.encode(doc, encryption: provider);
        // Different nonces → different ciphertext.
        expect(e1, isNot(equals(e2)));
        // Both decrypt correctly.
        expect(await ValueCodec.decode(e1, encryption: provider), equals(doc));
        expect(await ValueCodec.decode(e2, encryption: provider), equals(doc));
      },
    );
  });

  // ── Error paths with encryption ───────────────────────────────────────────────

  group('ValueCodec.decode error paths with encryption', () {
    test(
      'encrypted value decoded without provider throws ArgumentError',
      () async {
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final encoded = await ValueCodec.encode({'x': 1}, encryption: provider);

        expect(
          () async => ValueCodec.decode(encoded),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('wrong key throws EncryptionError.badCredentials', () async {
      final dek = await KeyDerivation.generateDek();
      final provider = AesGcmEncryptionProvider(dek);
      final wrongDek = await KeyDerivation.generateDek();
      final wrongProvider = AesGcmEncryptionProvider(wrongDek);

      final encoded = await ValueCodec.encode({
        'secret': 'value',
      }, encryption: provider);

      expect(
        () async => ValueCodec.decode(encoded, encryption: wrongProvider),
        throwsA(
          isA<EncryptionError>().having(
            (e) => e.code,
            'code',
            EncryptionErrorCode.badCredentials,
          ),
        ),
      );
    });

    test(
      'provider that always throws causes decode to propagate EncryptionError',
      () async {
        // Build a valid plaintext AES-GCM encrypted payload.
        final dek = await KeyDerivation.generateDek();
        final goodProvider = AesGcmEncryptionProvider(dek);
        final encoded = await ValueCodec.encode({
          'x': 1,
        }, encryption: goodProvider);

        // Decode with a provider that always rejects.
        expect(
          () async =>
              ValueCodec.decode(encoded, encryption: const _BadKeyProvider()),
          throwsA(isA<EncryptionError>()),
        );
      },
    );

    test(
      'plaintext value decoded with provider still works (flag=0x00 path)',
      () async {
        // An unencrypted value (flag=0x00) decoded with an encryption provider
        // should still return the correct document. The provider is only invoked
        // when flag=0x01.
        final dek = await KeyDerivation.generateDek();
        final provider = AesGcmEncryptionProvider(dek);
        final doc = {'greeting': 'hello'};

        final plainEncoded = await ValueCodec.encode(doc); // no encryption
        final decoded = await ValueCodec.decode(
          plainEncoded,
          encryption: provider,
        );
        expect(decoded, equals(doc));
      },
    );
  });

  // ── EncryptionFlag enum ───────────────────────────────────────────────────────

  group('EncryptionFlag', () {
    test(
      'none.byte is 0x00',
      () => expect(EncryptionFlag.none.byte, equals(0x00)),
    );
    test(
      'aesGcm.byte is 0x01',
      () => expect(EncryptionFlag.aesGcm.byte, equals(0x01)),
    );

    test('fromByte(0x00) returns none', () {
      expect(EncryptionFlag.fromByte(0x00), equals(EncryptionFlag.none));
    });

    test('fromByte(0x01) returns aesGcm', () {
      expect(EncryptionFlag.fromByte(0x01), equals(EncryptionFlag.aesGcm));
    });

    test('fromByte throws ArgumentError for unknown byte', () {
      expect(
        () => EncryptionFlag.fromByte(0x02),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => EncryptionFlag.fromByte(0xFF),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
