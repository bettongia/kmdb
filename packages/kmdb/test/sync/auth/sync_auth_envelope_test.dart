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
import 'package:kmdb/src/sync/auth/sync_auth_envelope.dart';
import 'package:kmdb/src/sync/auth/sync_auth_exception.dart';
import 'package:kmdb/src/sync/auth/sync_authenticator.dart';
import 'package:test/test.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

/// A [SyncAuthenticator] whose [mac] always returns the wrong length — used
/// to exercise [SyncAuthEnvelope.wrap]'s defensive contract check, which is
/// not reachable through the well-behaved [DefaultSyncAuthenticator].
final class _BadLengthAuthenticator implements SyncAuthenticator {
  const _BadLengthAuthenticator();

  @override
  Future<Uint8List> mac(SyncArtifactClass artifactClass, Uint8List message) =>
      Future.value(Uint8List(4)); // wrong length: SyncAuthEnvelope expects 16

  @override
  Future<bool> verify(
    SyncArtifactClass artifactClass,
    Uint8List message,
    Uint8List mac,
  ) => Future.value(false);
}

void main() {
  group('SyncAuthEnvelope — every artefact class (Phase 4 forged-artefact '
      'matrix)', () {
    for (final artifactClass in SyncArtifactClass.values) {
      test('$artifactClass: round-trips a genuine artefact and rejects a '
          'forged one', () async {
        final auth = DefaultSyncAuthenticator(_key(artifactClass.index + 10));
        final payload = Uint8List.fromList(
          'payload-for-$artifactClass'.codeUnits,
        );
        const path = 'some/logical/path';

        // Genuine: wrapped and unwrapped under the same authenticator/class
        // round-trips cleanly.
        final wrapped = await SyncAuthEnvelope.wrap(
          payload,
          auth,
          artifactClass: artifactClass,
          relativePath: path,
        );
        final unwrapped = await SyncAuthEnvelope.unwrap(
          wrapped,
          auth,
          artifactClass: artifactClass,
          relativePath: path,
        );
        expect(unwrapped, equals(payload));

        // Forged: raw, un-enveloped bytes (an attacker without the
        // sync-set key cannot produce a valid envelope at all) are
        // rejected with SyncAuthException, not silently accepted.
        await expectLater(
          SyncAuthEnvelope.unwrap(
            payload,
            auth,
            artifactClass: artifactClass,
            relativePath: path,
          ),
          throwsA(isA<SyncAuthException>()),
        );
      });
    }
  });

  group('SyncAuthEnvelope', () {
    test('wrap throws StateError when the SyncAuthenticator returns a MAC of '
        'the wrong length (defensive contract check)', () async {
      final payload = Uint8List.fromList('x'.codeUnits);
      await expectLater(
        SyncAuthEnvelope.wrap(
          payload,
          const _BadLengthAuthenticator(),
          artifactClass: SyncArtifactClass.sstable,
          relativePath: 'sstables/x.sst',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('wrap/unwrap round-trips the payload', () async {
      final auth = DefaultSyncAuthenticator(_key(1));
      final payload = Uint8List.fromList('sstable-bytes'.codeUnits);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.sstable,
        relativePath: 'sstables/a1b2c3d4-0-1.sst',
      );
      expect(wrapped.length, SyncAuthEnvelope.kHeaderLength + payload.length);
      expect(wrapped.sublist(0, 3), SyncAuthEnvelope.kMagic);
      expect(wrapped[3], SyncAuthEnvelope.kVersion);

      final unwrapped = await SyncAuthEnvelope.unwrap(
        wrapped,
        auth,
        artifactClass: SyncArtifactClass.sstable,
        relativePath: 'sstables/a1b2c3d4-0-1.sst',
      );
      expect(unwrapped, equals(payload));
    });

    test('round-trips an empty payload', () async {
      final auth = DefaultSyncAuthenticator(_key(2));
      final payload = Uint8List(0);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.hwm,
        relativePath: 'highwater/a1b2c3d4.hwm',
      );
      final unwrapped = await SyncAuthEnvelope.unwrap(
        wrapped,
        auth,
        artifactClass: SyncArtifactClass.hwm,
        relativePath: 'highwater/a1b2c3d4.hwm',
      );
      expect(unwrapped, isEmpty);
    });

    test('unwrap throws SyncAuthException on missing/short envelope', () async {
      final auth = DefaultSyncAuthenticator(_key(3));
      final tooShort = Uint8List(5);
      await expectLater(
        SyncAuthEnvelope.unwrap(
          tooShort,
          auth,
          artifactClass: SyncArtifactClass.sstable,
          relativePath: 'sstables/x.sst',
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('unwrap throws SyncAuthException on a legacy un-enveloped file '
        '(R-5)', () async {
      final auth = DefaultSyncAuthenticator(_key(4));
      // Simulates a pre-sync-auth SSTable: plain bytes, no envelope header.
      final legacyBytes = Uint8List.fromList(List.generate(64, (i) => i % 256));
      await expectLater(
        SyncAuthEnvelope.unwrap(
          legacyBytes,
          auth,
          artifactClass: SyncArtifactClass.sstable,
          relativePath: 'sstables/legacy.sst',
        ),
        throwsA(
          isA<SyncAuthException>().having(
            (e) => e.message,
            'message',
            contains('remote pair'),
          ),
        ),
      );
    });

    test('unwrap throws SyncAuthException on a bad MAC', () async {
      final auth = DefaultSyncAuthenticator(_key(5));
      final payload = Uint8List.fromList('data'.codeUnits);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.lease,
        relativePath: '.consolidation-lease',
      );
      // Flip a bit in the MAC region (offset 4..19).
      final tampered = Uint8List.fromList(wrapped)..[10] ^= 0xff;
      await expectLater(
        SyncAuthEnvelope.unwrap(
          tampered,
          auth,
          artifactClass: SyncArtifactClass.lease,
          relativePath: '.consolidation-lease',
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('unwrap throws SyncAuthException when the payload was tampered '
        'after MAC computation', () async {
      final auth = DefaultSyncAuthenticator(_key(6));
      final payload = Uint8List.fromList('original'.codeUnits);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.vaultManifest,
        relativePath: 'vault/ab/cdef/manifest.json',
      );
      final tampered = Uint8List.fromList(wrapped);
      tampered[SyncAuthEnvelope.kHeaderLength] ^= 0xff; // flip a payload byte
      await expectLater(
        SyncAuthEnvelope.unwrap(
          tampered,
          auth,
          artifactClass: SyncArtifactClass.vaultManifest,
          relativePath: 'vault/ab/cdef/manifest.json',
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('path-relocation is rejected: a valid envelope for one path does '
        'not verify at a different path', () async {
      final auth = DefaultSyncAuthenticator(_key(7));
      final payload = Uint8List.fromList('relocatable?'.codeUnits);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.sstable,
        relativePath: 'sstables/deviceA-0-1.sst',
      );
      await expectLater(
        SyncAuthEnvelope.unwrap(
          wrapped,
          auth,
          artifactClass: SyncArtifactClass.sstable,
          relativePath: 'sstables/deviceB-0-1.sst',
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('cross-class replay is rejected: an envelope valid for one '
        'artefact class does not verify under another', () async {
      final auth = DefaultSyncAuthenticator(_key(8));
      final payload = Uint8List.fromList('cross-class'.codeUnits);
      const path = 'shared-path'; // same literal path, different classes
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.sstable,
        relativePath: path,
      );
      await expectLater(
        SyncAuthEnvelope.unwrap(
          wrapped,
          auth,
          artifactClass: SyncArtifactClass.lease,
          relativePath: path,
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('a bad version byte is rejected the same way as a missing '
        'envelope', () async {
      final auth = DefaultSyncAuthenticator(_key(9));
      final payload = Uint8List.fromList('versioned'.codeUnits);
      final wrapped = await SyncAuthEnvelope.wrap(
        payload,
        auth,
        artifactClass: SyncArtifactClass.hwm,
        relativePath: 'highwater/x.hwm',
      );
      final futureVersion = Uint8List.fromList(wrapped)..[3] = 0x02;
      await expectLater(
        SyncAuthEnvelope.unwrap(
          futureVersion,
          auth,
          artifactClass: SyncArtifactClass.hwm,
          relativePath: 'highwater/x.hwm',
        ),
        throwsA(isA<SyncAuthException>()),
      );
    });
  });
}
