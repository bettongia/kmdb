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
import 'package:kmdb/src/sync/auth/sync_auth_exception.dart';
import 'package:kmdb/src/sync/auth/sync_authenticating_adapter.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:test/test.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

void main() {
  group('SyncAuthenticatingAdapter.classifyPath', () {
    test('classifies .sst, .hwm, and .consolidation-lease paths', () {
      expect(
        SyncAuthenticatingAdapter.classifyPath('sstables/a-0-1.sst'),
        SyncArtifactClass.sstable,
      );
      expect(
        SyncAuthenticatingAdapter.classifyPath('highwater/a1b2c3d4.hwm'),
        SyncArtifactClass.hwm,
      );
      expect(
        SyncAuthenticatingAdapter.classifyPath('.consolidation-lease'),
        SyncArtifactClass.lease,
      );
      expect(
        SyncAuthenticatingAdapter.classifyPath(
          'kmdb-sync/.consolidation-lease',
        ),
        SyncArtifactClass.lease,
      );
    });

    test('throws ArgumentError for an unrecognised path shape', () {
      expect(
        () => SyncAuthenticatingAdapter.classifyPath('vault/ab/cd/blob'),
        throwsArgumentError,
      );
    });
  });

  group('SyncAuthenticatingAdapter', () {
    late MemorySyncAdapter inner;
    late SyncAuthenticatingAdapter adapter;

    setUp(() {
      inner = MemorySyncAdapter();
      adapter = SyncAuthenticatingAdapter(
        inner,
        DefaultSyncAuthenticator(_key(1)),
      );
    });

    test('upload envelopes bytes before storing; the stored bytes are not '
        'plaintext', () async {
      final payload = Uint8List.fromList('hello'.codeUnits);
      await adapter.upload('sstables/a-0-1.sst', payload);

      // The underlying adapter must have received enveloped bytes, not the
      // raw payload.
      final rawStored = await inner.download('sstables/a-0-1.sst');
      expect(rawStored, isNotNull);
      expect(rawStored, isNot(equals(payload)));
      expect(rawStored!.length, greaterThan(payload.length));
    });

    test(
      'download round-trips a payload uploaded through the same adapter',
      () async {
        final payload = Uint8List.fromList('round-trip'.codeUnits);
        await adapter.upload('highwater/a1b2c3d4.hwm', payload);
        final downloaded = await adapter.download('highwater/a1b2c3d4.hwm');
        expect(downloaded, equals(payload));
      },
    );

    test(
      'download returns null for a missing file (not an exception)',
      () async {
        final result = await adapter.download('sstables/missing.sst');
        expect(result, isNull);
      },
    );

    test('download throws SyncAuthException for a forged (raw, un-enveloped) '
        'file', () async {
      // Simulate an attacker who can write the sync folder directly,
      // bypassing the authenticating adapter entirely.
      await inner.upload(
        'sstables/forged.sst',
        Uint8List.fromList('attacker-controlled bytes'.codeUnits),
      );
      await expectLater(
        adapter.download('sstables/forged.sst'),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test('download throws SyncAuthException for a file authenticated under '
        "a different sync-set's key", () async {
      final otherAdapter = SyncAuthenticatingAdapter(
        inner,
        DefaultSyncAuthenticator(_key(99)),
      );
      await otherAdapter.upload(
        'sstables/other-key.sst',
        Uint8List.fromList('bytes'.codeUnits),
      );
      await expectLater(
        adapter.download('sstables/other-key.sst'),
        throwsA(isA<SyncAuthException>()),
      );
    });

    test(
      'list delegates unchanged and is unaffected by envelope framing',
      () async {
        await adapter.upload(
          'sstables/a-0-1.sst',
          Uint8List.fromList('x'.codeUnits),
        );
        await adapter.upload(
          'sstables/b-0-1.sst',
          Uint8List.fromList('y'.codeUnits),
        );
        final listed = await adapter.list('sstables', extension: '.sst');
        expect(listed.toSet(), {'a-0-1.sst', 'b-0-1.sst'});
      },
    );

    test('getEtag delegates unchanged', () async {
      await adapter.upload(
        '.consolidation-lease',
        Uint8List.fromList('lease'.codeUnits),
      );
      final etag = await adapter.getEtag('.consolidation-lease');
      final innerEtag = await inner.getEtag('.consolidation-lease');
      expect(etag, equals(innerEtag));
      expect(etag, isNotNull);
    });

    test('compareAndSwap envelopes newBytes before delegating, and the '
        'stored value round-trips through download', () async {
      final ok = await adapter.compareAndSwap(
        '.consolidation-lease',
        Uint8List.fromList('lease-payload'.codeUnits),
        ifMatchEtag: null,
      );
      expect(ok, isTrue);
      final roundTripped = await adapter.download('.consolidation-lease');
      expect(
        roundTripped,
        equals(Uint8List.fromList('lease-payload'.codeUnits)),
      );
    });

    test('compareAndSwap fails the same way as the delegate on an ETag '
        'mismatch', () async {
      await adapter.compareAndSwap(
        '.consolidation-lease',
        Uint8List.fromList('first'.codeUnits),
        ifMatchEtag: null,
      );
      final wrongEtagResult = await adapter.compareAndSwap(
        '.consolidation-lease',
        Uint8List.fromList('second'.codeUnits),
        ifMatchEtag: 'bogus-etag',
      );
      expect(wrongEtagResult, isFalse);
    });

    test('providesAtomicCas delegates unchanged', () {
      expect(adapter.providesAtomicCas, inner.providesAtomicCas);
    });

    test('delete delegates unchanged', () async {
      await adapter.upload(
        'sstables/a-0-1.sst',
        Uint8List.fromList('x'.codeUnits),
      );
      await adapter.delete('sstables/a-0-1.sst');
      expect(await adapter.download('sstables/a-0-1.sst'), isNull);
    });
  });
}
