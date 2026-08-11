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

import 'package:kmdb/src/sync/auth/default_sync_authenticator.dart';
import 'package:kmdb/src/sync/auth/sync_artifact_class.dart';
import 'package:test/test.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

void main() {
  group('DefaultSyncAuthenticator', () {
    test('rejects a root key of the wrong length', () {
      expect(
        () => DefaultSyncAuthenticator(Uint8List(31)),
        throwsArgumentError,
      );
      expect(
        () => DefaultSyncAuthenticator(Uint8List(33)),
        throwsArgumentError,
      );
    });

    test('mac produces a deterministic 16-byte output', () async {
      final auth = DefaultSyncAuthenticator(_key(1));
      final message = Uint8List.fromList('hello world'.codeUnits);
      final mac1 = await auth.mac(SyncArtifactClass.sstable, message);
      final mac2 = await auth.mac(SyncArtifactClass.sstable, message);
      expect(mac1.length, 16);
      expect(mac1, equals(mac2));
    });

    test('verify accepts a correct MAC and rejects a tampered one', () async {
      final auth = DefaultSyncAuthenticator(_key(2));
      final message = Uint8List.fromList('payload-bytes'.codeUnits);
      final mac = await auth.mac(SyncArtifactClass.hwm, message);

      expect(await auth.verify(SyncArtifactClass.hwm, message, mac), isTrue);

      final tampered = Uint8List.fromList(mac)..[0] ^= 0xff;
      expect(
        await auth.verify(SyncArtifactClass.hwm, message, tampered),
        isFalse,
      );
    });

    test('verify rejects a MAC of the wrong length', () async {
      final auth = DefaultSyncAuthenticator(_key(3));
      final message = Uint8List.fromList('x'.codeUnits);
      final shortMac = Uint8List(4);
      expect(
        await auth.verify(SyncArtifactClass.lease, message, shortMac),
        isFalse,
      );
    });

    test(
      'different artefact classes produce different MACs for the same message '
      '(domain separation)',
      () async {
        final auth = DefaultSyncAuthenticator(_key(4));
        final message = Uint8List.fromList('same-bytes'.codeUnits);
        final macs = <SyncArtifactClass, Uint8List>{};
        for (final cls in SyncArtifactClass.values) {
          macs[cls] = await auth.mac(cls, message);
        }
        // Every pairwise MAC must differ — domain separation via distinct
        // HKDF info labels.
        final all = macs.values.toList();
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            expect(all[i], isNot(equals(all[j])));
          }
        }
      },
    );

    test('a MAC computed under one authenticator does not verify under a '
        "different authenticator's root key", () async {
      final authA = DefaultSyncAuthenticator(_key(5));
      final authB = DefaultSyncAuthenticator(_key(6));
      final message = Uint8List.fromList('cross-key'.codeUnits);
      final mac = await authA.mac(SyncArtifactClass.sstable, message);
      expect(
        await authB.verify(SyncArtifactClass.sstable, message, mac),
        isFalse,
      );
    });

    test('sub-key derivation is memoized (same class reuses the cached '
        'future)', () async {
      final auth = DefaultSyncAuthenticator(_key(7));
      final message = Uint8List.fromList('memo'.codeUnits);
      // Fire concurrent calls for the same class — should not throw and
      // should produce identical output (deterministic derivation, whether
      // memoized or not; this asserts correctness under concurrency).
      final results = await Future.wait([
        auth.mac(SyncArtifactClass.vaultBlob, message),
        auth.mac(SyncArtifactClass.vaultBlob, message),
        auth.mac(SyncArtifactClass.vaultBlob, message),
      ]);
      expect(results[0], equals(results[1]));
      expect(results[1], equals(results[2]));
    });

    test('rootKey is defensively copied at construction', () async {
      final key = _key(8);
      final auth = DefaultSyncAuthenticator(key);
      final message = Uint8List.fromList('defensive'.codeUnits);
      final before = await auth.mac(SyncArtifactClass.lease, message);
      // Mutate the caller's copy after construction.
      key[0] ^= 0xff;
      final after = await auth.mac(SyncArtifactClass.lease, message);
      expect(after, equals(before));
    });

    test(
      'matches the cross-platform known-answer vector consumed by '
      "WebSyncAuthenticator's browser test (web_sync_authenticator_test.dart)",
      () async {
        // This vector is the native side of a cross-implementation
        // compatibility check: a native device (DefaultSyncAuthenticator)
        // and a web device (WebSyncAuthenticator) sharing the same
        // sync-set key must authenticate each other's artefacts
        // identically. If this test's expected value ever needs updating,
        // web_sync_authenticator_test.dart's matching test must be updated
        // to the same value.
        final auth = DefaultSyncAuthenticator(_key(6));
        final message = Uint8List.fromList('cross-impl'.codeUnits);
        final mac = await auth.mac(SyncArtifactClass.vaultBlob, message);
        expect(
          mac,
          equals(const [
            20,
            1,
            152,
            185,
            144,
            247,
            207,
            161,
            32,
            219,
            146,
            11,
            241,
            191,
            247,
            107,
          ]),
        );
      },
    );
  });
}
