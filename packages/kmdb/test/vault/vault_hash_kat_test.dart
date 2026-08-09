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

// Known-answer-value (KAT) regression tests for VaultStore's two content
// hashes: SHA-256 (S-5, 0.10.01) and CRC32C.
//
// This file has NO `@TestOn` annotation so it runs on the VM in the normal
// suite AND is additionally driven on Chrome via `make cicd_web` (mirrors
// `test/encoding/value_codec_test.dart`, the repo's established
// "runs on vm, additionally driven on chrome" pattern). That dual-platform
// run is the point: S-5 replaced a hand-rolled SHA-256 that used `>>>` / `<<`
// / masking arithmetic assuming 64-bit ints — exactly the kind of code where
// web (JS number) `int` semantics could silently diverge. `DartSha256` from
// `package:cryptography` is web-safe, but only a Chrome-executed test proves
// it, rather than merely asserting it.
//
// Only pure functions are exercised here (no `dart:io`, no vault I/O) so the
// file works unmodified on every platform `dart test` supports. The native
// vault put/getBytes round-trip lives in a separate file
// (`vault_hash_round_trip_test.dart`) because the round-trip helper wiring
// this suite uses elsewhere is not exercised on Chrome in CI.
//
// SHA-256 NIST vectors and independent CRC32C values below were computed
// with tools outside this codebase (`shasum -a 256` for SHA-256; a
// stand-alone Castagnoli CRC32C table implementation for CRC32C) so they
// serve as ground truth, not merely a self-consistency check against
// `VaultStore`'s own code.

import 'dart:typed_data';

import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

void main() {
  group('VaultStore.computeSha256 — NIST known-answer vectors', () {
    test('empty input', () {
      expect(
        VaultStore.computeSha256(Uint8List(0)),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc"', () {
      expect(
        VaultStore.computeSha256(Uint8List.fromList('abc'.codeUnits)),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('896-bit NIST two-block vector', () {
      const input = 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq';
      expect(
        VaultStore.computeSha256(Uint8List.fromList(input.codeUnits)),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('one million repetitions of "a"', () {
      final input = Uint8List(1000000)..fillRange(0, 1000000, 0x61); // 'a'
      expect(
        VaultStore.computeSha256(input),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  group(
    'VaultStore.computeSha256 — content-address stability (S-5 regression)',
    () {
      // Fixed arbitrary byte inputs pinned to their expected sha256 hex.
      // These are NOT NIST vectors — they cover non-ASCII/binary content and
      // an all-byte-values input so a regression on non-standard inputs
      // (e.g. a future change to the hex-encoding step) is caught even
      // though the NIST vectors above happen to pass. The expected values
      // were captured from an independent `shasum -a 256` run (not from
      // `VaultStore` itself), so this is a genuine ground-truth pin, not a
      // tautology. Per the plan's scope decision, `DartSha256` was proven
      // byte-identical to the pre-swap hand-rolled implementation, so these
      // values also equal what `main` produced before S-5.
      const vectors = <String, String>{
        'kmdb-vault-hash-regression-1':
            'd04aebea34ec21f259c5b6f97de9ed88ab36dbb42f841eb68de7dfd9b8cd6435',
        'The quick brown fox jumps over the lazy dog':
            'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
      };

      for (final MapEntry(key: input, value: expected) in vectors.entries) {
        test('"$input"', () {
          expect(
            VaultStore.computeSha256(Uint8List.fromList(input.codeUnits)),
            expected,
          );
        });
      }

      test('all 256 byte values (binary, non-UTF-8-safe content)', () {
        final bytes = Uint8List.fromList(List<int>.generate(256, (i) => i));
        expect(
          VaultStore.computeSha256(bytes),
          '40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880',
        );
      });

      test('64 zero bytes', () {
        expect(
          VaultStore.computeSha256(Uint8List(64)),
          'f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b',
        );
      });
    },
  );

  group('VaultStore.computeCrc32cForTest — known-answer vectors', () {
    test('standard Castagnoli check value: "123456789" -> 0xe3069283', () {
      expect(
        VaultStore.computeCrc32cForTest(
          Uint8List.fromList('123456789'.codeUnits),
        ),
        'e3069283',
      );
    });

    test('empty input -> 0x00000000', () {
      expect(VaultStore.computeCrc32cForTest(Uint8List(0)), '00000000');
    });

    test('all 256 byte values', () {
      final bytes = Uint8List.fromList(List<int>.generate(256, (i) => i));
      expect(VaultStore.computeCrc32cForTest(bytes), '9c44184b');
    });

    test('64 zero bytes', () {
      expect(VaultStore.computeCrc32cForTest(Uint8List(64)), '03c8eb67');
    });
  });
}
