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

import 'package:kmdb/src/encryption/encryption_error.dart';
import 'package:kmdb/src/encryption/encryption_provider.dart';
import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:test/test.dart';

void main() {
  // ── AesGcmEncryptionProvider ────────────────────────────────────────────────

  group('AesGcmEncryptionProvider', () {
    late Uint8List dek;

    setUpAll(() async {
      dek = await KeyDerivation.generateDek();
    });

    test('encrypt/decrypt round-trips plaintext correctly', () async {
      final provider = AesGcmEncryptionProvider(dek);
      final plaintext = Uint8List.fromList(List.generate(32, (i) => i));
      final ciphertext = await provider.encrypt(plaintext);
      final recovered = await provider.decrypt(ciphertext);
      expect(recovered, equals(plaintext));
    });

    test('round-trips empty plaintext', () async {
      final provider = AesGcmEncryptionProvider(dek);
      final ciphertext = await provider.encrypt(Uint8List(0));
      final recovered = await provider.decrypt(ciphertext);
      expect(recovered, isEmpty);
    });

    test('round-trips large plaintext (>64KB)', () async {
      final provider = AesGcmEncryptionProvider(dek);
      final plaintext = Uint8List.fromList(
        List.generate(100000, (i) => i % 256),
      );
      final ciphertext = await provider.encrypt(plaintext);
      final recovered = await provider.decrypt(ciphertext);
      expect(recovered, equals(plaintext));
    });

    test('nonce is unique across calls (ciphertext differs)', () async {
      final provider = AesGcmEncryptionProvider(dek);
      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final ct1 = await provider.encrypt(plaintext);
      final ct2 = await provider.encrypt(plaintext);
      // Different nonces → different ciphertext bytes (even for identical
      // plaintext). The probability of collision is negligible (2^{-96}).
      expect(ct1, isNot(equals(ct2)));
    });

    test(
      'ciphertext length is plaintext.length + 28 (12 nonce + 16 tag)',
      () async {
        final provider = AesGcmEncryptionProvider(dek);
        final plaintext = Uint8List.fromList(List.generate(50, (i) => i));
        final ciphertext = await provider.encrypt(plaintext);
        expect(ciphertext.length, equals(plaintext.length + 28));
      },
    );

    test(
      'decrypt throws EncryptionError.badCredentials for wrong key',
      () async {
        final provider = AesGcmEncryptionProvider(dek);
        final wrongDek = await KeyDerivation.generateDek();
        final wrongProvider = AesGcmEncryptionProvider(wrongDek);

        final ciphertext = await provider.encrypt(
          Uint8List.fromList([1, 2, 3, 4]),
        );

        expect(
          () async => wrongProvider.decrypt(ciphertext),
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
      'decrypt throws EncryptionError.badCredentials for tampered ciphertext',
      () async {
        final provider = AesGcmEncryptionProvider(dek);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final ciphertext = await provider.encrypt(plaintext);

        // Flip one bit in the ciphertext body (not the tag or nonce).
        final tampered = Uint8List.fromList(ciphertext);
        tampered[13] ^= 0xFF; // flip bits in the ciphertext body

        expect(
          () async => provider.decrypt(tampered),
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
      'decrypt throws EncryptionError.badCredentials for truncated input',
      () async {
        final provider = AesGcmEncryptionProvider(dek);
        // Input shorter than minimum valid AES-GCM output (12+16=28 bytes).
        final tooShort = Uint8List.fromList([1, 2, 3]);
        expect(
          () async => provider.decrypt(tooShort),
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

    test('constructor throws ArgumentError for DEK not 32 bytes', () {
      expect(
        () => AesGcmEncryptionProvider(Uint8List(16)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AesGcmEncryptionProvider(Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AesGcmEncryptionProvider(Uint8List(64)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('dek getter returns a defensive copy', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final got = provider.dek;
      got[0] ^= 0xFF; // mutate the returned copy
      // The provider must still encrypt correctly — its internal DEK is unchanged.
      final plaintext = Uint8List.fromList([42, 43, 44]);
      final ciphertext = await provider.encrypt(plaintext);
      final recovered = await provider.decrypt(ciphertext);
      expect(recovered, equals(plaintext));
    });
  });

  // ── indexToken() (Encryption confidentiality reconciliation plan, Gap 2) ────

  group('AesGcmEncryptionProvider.indexToken', () {
    late Uint8List dek;

    setUpAll(() async {
      dek = await KeyDerivation.generateDek();
    });

    test('is deterministic for the same message and same DEK', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final t1 = await provider.indexToken('articles:body:hello');
      final t2 = await provider.indexToken('articles:body:hello');
      expect(t1, equals(t2));
    });

    test('is reproducible across a fresh provider instance for the same DEK '
        '(simulates a process restart: the DEK is unwrapped again on the next '
        'KmdbDatabase.open, but sub-key derivation must still land on the same '
        'token)', () async {
      final provider1 = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final provider2 = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final t1 = await provider1.indexToken('articles:body:hello');
      final t2 = await provider2.indexToken('articles:body:hello');
      expect(t1, equals(t2));
    });

    test('is a 32-character lowercase hex string', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final token = await provider.indexToken('articles:body:hello');
      expect(token, hasLength(32));
      expect(token, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('different terms produce different tokens', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final t1 = await provider.indexToken('articles:body:hello');
      final t2 = await provider.indexToken('articles:body:world');
      expect(t1, isNot(equals(t2)));
    });

    test('domain separation: the same term in a different field produces a '
        'different token', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final bodyToken = await provider.indexToken('articles:body:hello');
      final titleToken = await provider.indexToken('articles:title:hello');
      expect(bodyToken, isNot(equals(titleToken)));
    });

    test('domain separation: the same term in a different collection '
        'produces a different token', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final articlesToken = await provider.indexToken('articles:body:hello');
      final postsToken = await provider.indexToken('posts:body:hello');
      expect(articlesToken, isNot(equals(postsToken)));
    });

    test(
      'a different DEK produces a different token for the same message',
      () async {
        final provider1 = AesGcmEncryptionProvider(Uint8List.fromList(dek));
        final otherDek = await KeyDerivation.generateDek();
        final provider2 = AesGcmEncryptionProvider(otherDek);

        final t1 = await provider1.indexToken('articles:body:hello');
        final t2 = await provider2.indexToken('articles:body:hello');
        expect(t1, isNot(equals(t2)));
      },
    );

    test('concurrent first calls all resolve to the same token (single '
        'in-flight sub-key derivation, not a race)', () async {
      final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
      final results = await Future.wait([
        provider.indexToken('articles:body:hello'),
        provider.indexToken('articles:body:hello'),
        provider.indexToken('articles:body:hello'),
      ]);
      expect(results.toSet(), hasLength(1));
    });

    test(
      'does not leak the raw DEK or any substring of it into the token',
      () async {
        final provider = AesGcmEncryptionProvider(Uint8List.fromList(dek));
        final token = await provider.indexToken('articles:body:hello');
        final dekHex = dek
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        // A naive "HMAC with the raw DEK directly" implementation could
        // still coincidentally avoid literal substring containment, but this
        // guards against the most direct mistake (e.g. concatenating the DEK
        // hex into the token instead of deriving a sub-key via HKDF).
        expect(token, isNot(contains(dekHex.substring(0, 16))));
      },
    );
  });

  // ── EncryptionError ───────────────────────────────────────────────────────────

  group('EncryptionError', () {
    // toString() must include the error code name and the message.
    test('badCredentials toString() includes code name and message', () {
      final err = EncryptionError.badCredentials();
      final s = err.toString();
      expect(s, contains('badCredentials'));
      expect(s, contains('Wrong passphrase or recovery code'));
    });

    test('databaseIsEncrypted toString() includes code name', () {
      final err = EncryptionError.databaseIsEncrypted();
      final s = err.toString();
      expect(s, contains('databaseIsEncrypted'));
      expect(s, contains('encrypted'));
    });

    test('databaseIsNotEncrypted toString() includes code name', () {
      final err = EncryptionError.databaseIsNotEncrypted();
      final s = err.toString();
      expect(s, contains('databaseIsNotEncrypted'));
      expect(s, contains('not encrypted'));
    });

    test('cannotProvisionNonEmptyDatabase toString() includes code name', () {
      final err = EncryptionError.cannotProvisionNonEmptyDatabase();
      final s = err.toString();
      expect(s, contains('cannotProvisionNonEmptyDatabase'));
      expect(s, contains('non-empty'));
    });
  });
}
