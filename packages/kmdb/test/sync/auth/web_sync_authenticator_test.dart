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

// Integration tests for WebSyncAuthenticator. These run exclusively in a
// browser (Chrome/Chromium) where WebCrypto (SubtleCrypto) and IndexedDB are
// available.
//
// Run with: dart test -p chrome test/sync/auth/web_sync_authenticator_test.dart

@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:kmdb/src/sync/auth/sync_artifact_class.dart';
import 'package:kmdb/src/sync/auth/web_sync_authenticator.dart';
import 'package:test/test.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

void main() {
  group('WebSyncAuthenticator', () {
    test('rejects a root key of the wrong length', () async {
      await expectLater(
        WebSyncAuthenticator.importKey(Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('imported key is never extractable (import-only, Q4)', () async {
      final auth = await WebSyncAuthenticator.importKey(_key(1));
      expect(auth.isExtractable, isFalse);
    });

    test('mac is deterministic and 16 bytes', () async {
      final auth = await WebSyncAuthenticator.importKey(_key(2));
      final message = Uint8List.fromList('hello'.codeUnits);
      final mac1 = await auth.mac(SyncArtifactClass.sstable, message);
      final mac2 = await auth.mac(SyncArtifactClass.sstable, message);
      expect(mac1.length, 16);
      expect(mac1, equals(mac2));
    });

    test('verify accepts a correct MAC and rejects a tampered one', () async {
      final auth = await WebSyncAuthenticator.importKey(_key(3));
      final message = Uint8List.fromList('payload'.codeUnits);
      final mac = await auth.mac(SyncArtifactClass.hwm, message);
      expect(await auth.verify(SyncArtifactClass.hwm, message, mac), isTrue);

      final tampered = Uint8List.fromList(mac)..[0] ^= 0xff;
      expect(
        await auth.verify(SyncArtifactClass.hwm, message, tampered),
        isFalse,
      );
    });

    test('verify rejects a MAC of the wrong length', () async {
      final auth = await WebSyncAuthenticator.importKey(_key(4));
      final message = Uint8List.fromList('x'.codeUnits);
      expect(
        await auth.verify(SyncArtifactClass.lease, message, Uint8List(4)),
        isFalse,
      );
    });

    test('different artefact classes produce different MACs (domain '
        'separation)', () async {
      final auth = await WebSyncAuthenticator.importKey(_key(5));
      final message = Uint8List.fromList('same'.codeUnits);
      final sstableMac = await auth.mac(SyncArtifactClass.sstable, message);
      final leaseMac = await auth.mac(SyncArtifactClass.lease, message);
      expect(sstableMac, isNot(equals(leaseMac)));
    });

    test('cross-implementation compatibility: matches a known-answer MAC '
        'produced by DefaultSyncAuthenticator (native) for the same root '
        'key, message, and artefact class', () async {
      // Load-bearing property: a native device (DefaultSyncAuthenticator)
      // and a web device (WebSyncAuthenticator) sharing the same sync-set
      // key must authenticate each other's artefacts identically — both
      // implement HKDF-SHA256 (RFC 5869) sub-key derivation with the same
      // `info` labels, then HMAC-SHA256 (RFC 2104) truncated to 16 bytes.
      // This known-answer vector was captured by running
      // `DefaultSyncAuthenticator(_key(6)).mac(SyncArtifactClass.vaultBlob,
      // utf8.encode('cross-impl'))` natively; see the git history of this
      // file for the exact generation script used.
      const expectedMac = [
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
      ];
      final webAuth = await WebSyncAuthenticator.importKey(_key(6));
      final message = Uint8List.fromList('cross-impl'.codeUnits);
      final webMac = await webAuth.mac(SyncArtifactClass.vaultBlob, message);
      expect(webMac, equals(expectedMac));
    });

    test(
      'persist/loadPersisted round-trips a base key across instances',
      () async {
        final auth = await WebSyncAuthenticator.importKey(_key(7));
        final keyId = 'test-key-${DateTime.now().microsecondsSinceEpoch}';
        await auth.persist(keyId);

        final reloaded = await WebSyncAuthenticator.loadPersisted(keyId);
        expect(reloaded, isNotNull);

        final message = Uint8List.fromList('persisted'.codeUnits);
        final macBefore = await auth.mac(SyncArtifactClass.sstable, message);
        final macAfter = await reloaded!.mac(
          SyncArtifactClass.sstable,
          message,
        );
        expect(macAfter, equals(macBefore));
      },
    );

    test('loadPersisted returns null for an unknown keyId', () async {
      final result = await WebSyncAuthenticator.loadPersisted(
        'never-persisted-${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(result, isNull);
    });
  });
}
