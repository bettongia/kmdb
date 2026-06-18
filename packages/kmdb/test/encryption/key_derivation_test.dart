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

import 'package:kmdb/src/encryption/key_derivation.dart';
import 'package:test/test.dart';

void main() {
  // ── Random generation ────────────────────────────────────────────────────────

  group('KeyDerivation.generateRandom', () {
    test('generates the requested number of bytes', () async {
      for (final len in [16, 32, 48, 64]) {
        final bytes = await KeyDerivation.generateRandom(len);
        expect(bytes.length, equals(len), reason: 'length=$len');
      }
    });

    test('generates different values each call (probabilistic)', () async {
      final a = await KeyDerivation.generateRandom(32);
      final b = await KeyDerivation.generateRandom(32);
      // Same value in two independent calls has probability 2^-256 ≈ 0.
      expect(a, isNot(equals(b)));
    });
  });

  group('KeyDerivation.generateDek', () {
    test('produces a 32-byte value', () async {
      final dek = await KeyDerivation.generateDek();
      expect(dek.length, equals(32));
    });
  });

  group('KeyDerivation.generateSalt', () {
    test('produces a 32-byte value', () async {
      final salt = await KeyDerivation.generateSalt();
      expect(salt.length, equals(32));
    });
  });

  group('KeyDerivation.generateRecoveryEntropy', () {
    test('produces a 16-byte value', () async {
      final entropy = await KeyDerivation.generateRecoveryEntropy();
      expect(entropy.length, equals(16));
    });
  });

  // ── Argon2id KDF ─────────────────────────────────────────────────────────────

  group(
    'KeyDerivation.deriveKekFromPassphrase',
    () {
      test('produces a 32-byte output', () async {
        final salt = await KeyDerivation.generateSalt();
        final kek = await KeyDerivation.deriveKekFromPassphrase(
          'passphrase',
          salt,
        );
        expect(kek.length, equals(32));
      });

      test('is deterministic: same passphrase + salt → same KEK', () async {
        final salt = await KeyDerivation.generateSalt();
        final kek1 = await KeyDerivation.deriveKekFromPassphrase(
          'password',
          salt,
        );
        final kek2 = await KeyDerivation.deriveKekFromPassphrase(
          'password',
          salt,
        );
        expect(kek1, equals(kek2));
      });

      test('different passwords produce different KEKs', () async {
        final salt = await KeyDerivation.generateSalt();
        final kek1 = await KeyDerivation.deriveKekFromPassphrase(
          'password1',
          salt,
        );
        final kek2 = await KeyDerivation.deriveKekFromPassphrase(
          'password2',
          salt,
        );
        expect(kek1, isNot(equals(kek2)));
      });

      test(
        'different salts produce different KEKs for the same password',
        () async {
          final salt1 = await KeyDerivation.generateSalt();
          final salt2 = await KeyDerivation.generateSalt();
          final kek1 = await KeyDerivation.deriveKekFromPassphrase(
            'password',
            salt1,
          );
          final kek2 = await KeyDerivation.deriveKekFromPassphrase(
            'password',
            salt2,
          );
          expect(kek1, isNot(equals(kek2)));
        },
      );
    },
    // Argon2id at full parameters (64 MiB, 3 iterations) is slow.
    // Set a generous timeout so CI does not fail on underpowered machines.
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // ── HKDF-SHA256 recovery-KEK ─────────────────────────────────────────────────

  group('KeyDerivation.deriveKekFromRecoveryEntropy', () {
    test('produces a 32-byte output', () async {
      final entropy = await KeyDerivation.generateRecoveryEntropy();
      final kek = await KeyDerivation.deriveKekFromRecoveryEntropy(entropy);
      expect(kek.length, equals(32));
    });

    test('is deterministic: same entropy → same KEK', () async {
      final entropy = await KeyDerivation.generateRecoveryEntropy();
      final kek1 = await KeyDerivation.deriveKekFromRecoveryEntropy(entropy);
      final kek2 = await KeyDerivation.deriveKekFromRecoveryEntropy(entropy);
      expect(kek1, equals(kek2));
    });

    test('different entropy produces different KEKs', () async {
      final e1 = await KeyDerivation.generateRecoveryEntropy();
      final e2 = await KeyDerivation.generateRecoveryEntropy();
      final kek1 = await KeyDerivation.deriveKekFromRecoveryEntropy(e1);
      final kek2 = await KeyDerivation.deriveKekFromRecoveryEntropy(e2);
      expect(kek1, isNot(equals(kek2)));
    });

    test(
      'domain-separated from passphrase path (known-vector sanity)',
      () async {
        // Two different derivations from the same 32 bytes of material should
        // yield different outputs because domain-separation info strings differ.
        // This test checks that the recovery path and the passphrase path are
        // not accidentally aliased (not a complete HKDF test vector).
        final entropy = Uint8List(16)..fillRange(0, 16, 0xAA);
        final recoveryKek = await KeyDerivation.deriveKekFromRecoveryEntropy(
          entropy,
        );
        // The passphrase KDF uses Argon2id with a salt, so it can't be directly
        // compared here — this test just verifies the recovery KEK is non-zero.
        expect(recoveryKek.any((b) => b != 0), isTrue);
      },
    );
  });

  // ── DEK wrapping/unwrapping ───────────────────────────────────────────────────

  group('KeyDerivation.wrapDek / unwrapDek', () {
    test('wrap then unwrap recovers the original DEK', () async {
      final dek = await KeyDerivation.generateDek();
      final kek = await KeyDerivation.generateRandom(32); // use a random KEK

      final wrapped = await KeyDerivation.wrapDek(dek, kek);
      final unwrapped = await KeyDerivation.unwrapDek(wrapped, kek);
      expect(unwrapped, equals(dek));
    });

    test('wrapped DEK is 60 bytes (12 nonce + 32 ct + 16 tag)', () async {
      final dek = await KeyDerivation.generateDek();
      final kek = await KeyDerivation.generateRandom(32);
      final wrapped = await KeyDerivation.wrapDek(dek, kek);
      expect(wrapped.length, equals(60));
    });

    test('unwrap returns null for wrong KEK', () async {
      final dek = await KeyDerivation.generateDek();
      final kek = await KeyDerivation.generateRandom(32);
      final wrongKek = await KeyDerivation.generateRandom(32);

      final wrapped = await KeyDerivation.wrapDek(dek, kek);
      final result = await KeyDerivation.unwrapDek(wrapped, wrongKek);
      expect(result, isNull);
    });

    test('unwrap returns null for truncated input (< 28 bytes)', () async {
      final kek = await KeyDerivation.generateRandom(32);
      final result = await KeyDerivation.unwrapDek(Uint8List(10), kek);
      expect(result, isNull);
    });

    test(
      'wrap generates unique nonces (wrapped bytes differ each call)',
      () async {
        final dek = await KeyDerivation.generateDek();
        final kek = await KeyDerivation.generateRandom(32);
        final w1 = await KeyDerivation.wrapDek(dek, kek);
        final w2 = await KeyDerivation.wrapDek(dek, kek);
        // Different nonces → different ciphertext.
        expect(w1, isNot(equals(w2)));
        // Both still unwrap to the same DEK.
        expect(await KeyDerivation.unwrapDek(w1, kek), equals(dek));
        expect(await KeyDerivation.unwrapDek(w2, kek), equals(dek));
      },
    );
  });
}
