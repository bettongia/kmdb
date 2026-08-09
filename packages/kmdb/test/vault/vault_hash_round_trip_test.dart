// Copyright 2026 The Authors
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

// Vault put/getBytes round-trip regression for S-5 (0.10.01): proves the
// swapped `DartSha256`-backed `VaultStore.computeSha256` is correctly wired
// end-to-end through `ingest` (content-address computation) and `getBytes`
// (the S-4 recompute-and-compare check on every read — vault_store.dart's
// `getBytes`), not just correct as a standalone pure function (see
// `vault_hash_kat_test.dart` for the pure-function KATs).
//
// Kept in a separate file from the KAT tests deliberately: this suite is not
// added to the `cicd_web` recipe in `make_cicd.mk`, so it only needs to run
// on the VM. The KAT file's dual-platform (vm + chrome) run is the guard
// against web `int`-semantics divergence; this file's job is proving the
// production ingest/getBytes call sites still behave correctly after the
// swap.

import 'dart:typed_data';

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/vault/media_type_detector.dart';
import 'package:kmdb/src/vault/vault_store.dart';
import 'package:test/test.dart';

/// A [MediaTypeDetector] that always returns an empty match list — media
/// type detection is irrelevant to the hash round-trip under test.
final class _NoOpDetector implements MediaTypeDetector {
  const _NoOpDetector();

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) => [];
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('VaultStore put/getBytes round-trip (S-5 regression)', () {
    late MemoryStorageAdapter adapter;
    late VaultStore store;

    setUp(() {
      adapter = MemoryStorageAdapter();
      store = VaultStore(
        dbDir: '/db',
        adapter: adapter,
        detector: const _NoOpDetector(),
      );
    });

    test('ingest then getBytes returns identical bytes', () async {
      final bytes = _bytes('S-5 round-trip content');
      final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');

      final got = await store.getBytes(ref.sha256);
      expect(got, equals(bytes));
    });

    test(
      'the content address equals VaultStore.computeSha256 of the plaintext',
      () async {
        final bytes = _bytes('S-5 address stability content');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');

        expect(ref.sha256, equals(VaultStore.computeSha256(bytes)));
        // Sanity: the address is a 64-char lower-case hex string (32-byte
        // digest), not merely non-empty.
        expect(ref.sha256, hasLength(64));
        expect(ref.sha256, matches(RegExp('^[0-9a-f]{64}\$')));
      },
    );

    test(
      'getBytes recomputes and compares on every read (S-4): tampering the '
      'stored blob after ingest is detected via the swapped SHA-256',
      () async {
        final bytes = _bytes('S-4 tamper-detection content');
        final ref = await store.ingest(bytes: bytes, hlcTimestamp: 't1');

        // Simulate corruption/substitution of the on-disk blob after ingest
        // — the manifest still claims the original sha256, but the bytes at
        // the blob path no longer hash to it. getBytes must catch this via
        // computeSha256, proving the swap is wired into the production read
        // path (not just exercised as a standalone pure function).
        final blobPath = store.blobPath(ref.sha256);
        // EncryptionFlag.none (0x00) prefix so the substituted bytes parse
        // as a well-formed (unencrypted) EncryptionEnvelope — this test is
        // specifically about the SHA-256 content-address check.
        await adapter.writeFile(
          blobPath,
          Uint8List.fromList([0x00, ..._bytes('attacker-substituted')]),
        );

        await expectLater(
          store.getBytes(ref.sha256),
          throwsA(isA<VaultContentMismatchException>()),
        );
      },
    );

    test(
      'repeated ingest of identical bytes yields the same address',
      () async {
        final bytes = _bytes('S-5 dedup content');
        final ref1 = await store.ingest(bytes: bytes, hlcTimestamp: 't1');
        final ref2 = await store.ingest(bytes: bytes, hlcTimestamp: 't2');

        expect(ref1.sha256, equals(ref2.sha256));
      },
    );
  });
}
