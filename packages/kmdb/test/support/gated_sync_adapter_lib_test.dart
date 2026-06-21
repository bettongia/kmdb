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

// Tests for the lib/ copy of GatedSyncAdapter
// (package:kmdb/src/test_support/gated_sync_adapter.dart).
//
// This file is distinct from test/support/gated_sync_adapter.dart (the local
// test-dir duplicate used by sync_cancellation_integration_test.dart). It
// exercises the barrier-control API, pass-through behaviour, idempotency, and
// cancellation propagation of the lib/ version to ensure that version is
// covered in the kmdb package's own test process.

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/test_support.dart';
import 'package:test/test.dart';

void main() {
  // ── Pass-through without a barrier ───────────────────────────────────────────

  group('GatedSyncAdapter — pass-through (no barrier)', () {
    late GatedSyncAdapter gated;
    late MemorySyncAdapter inner;

    setUp(() {
      inner = MemorySyncAdapter();
      gated = GatedSyncAdapter(inner);
    });

    test('list delegates to inner adapter', () async {
      await inner.upload('dir/file.sst', Uint8List.fromList([1]));
      final files = await gated.list('dir');
      expect(files, contains('file.sst'));
    });

    test('download delegates to inner adapter', () async {
      await inner.upload('path/f.bin', Uint8List.fromList([42]));
      final bytes = await gated.download('path/f.bin');
      expect(bytes, equals(Uint8List.fromList([42])));
    });

    test('upload delegates to inner adapter', () async {
      await gated.upload('path/u.bin', Uint8List.fromList([99]));
      final bytes = await inner.download('path/u.bin');
      expect(bytes, equals(Uint8List.fromList([99])));
    });

    test('delete delegates to inner adapter', () async {
      await inner.upload('path/d.bin', Uint8List.fromList([1]));
      await gated.delete('path/d.bin');
      expect(await inner.download('path/d.bin'), isNull);
    });

    test('compareAndSwap delegates to inner adapter', () async {
      final result = await gated.compareAndSwap(
        'path/c.bin',
        Uint8List.fromList([1]),
        ifMatchEtag: null,
      );
      expect(result, isTrue);
      expect(
        await inner.download('path/c.bin'),
        equals(Uint8List.fromList([1])),
      );
    });

    test('getEtag delegates to inner adapter', () async {
      await inner.upload('path/e.bin', Uint8List.fromList([7]));
      final etag = await gated.getEtag('path/e.bin');
      expect(etag, equals(await inner.getEtag('path/e.bin')));
    });

    test('providesAtomicCas delegates to inner adapter', () {
      expect(gated.providesAtomicCas, equals(inner.providesAtomicCas));
    });
  });

  // ── Barrier control ─────────────────────────────────────────────────────────

  group('GatedSyncAdapter — barrier control', () {
    late GatedSyncAdapter gated;
    late MemorySyncAdapter inner;

    setUp(() {
      inner = MemorySyncAdapter();
      gated = GatedSyncAdapter(inner);
    });

    test('holdList() blocks until releaseList() unblocks', () async {
      gated.holdList();

      var completed = false;
      final future = gated.list('dir').then((v) {
        completed = true;
        return v;
      });

      // Give the Future a chance to run — it should remain blocked.
      await Future<void>.value();
      expect(completed, isFalse);

      gated.releaseList();
      await future;
      expect(completed, isTrue);
    });

    test('holdDownload() blocks until releaseDownload() unblocks', () async {
      gated.holdDownload();
      var completed = false;
      final future = gated.download('f').then((v) {
        completed = true;
        return v;
      });
      await Future<void>.value();
      expect(completed, isFalse);
      gated.releaseDownload();
      await future;
      expect(completed, isTrue);
    });

    test('holdUpload() blocks until releaseUpload() unblocks', () async {
      gated.holdUpload();
      var completed = false;
      final future = gated
          .upload('f', Uint8List(0))
          .then((_) => completed = true);
      await Future<void>.value();
      expect(completed, isFalse);
      gated.releaseUpload();
      await future;
      expect(completed, isTrue);
    });

    test('holdDelete() blocks until releaseDelete() unblocks', () async {
      gated.holdDelete();
      var completed = false;
      final future = gated.delete('f').then((_) => completed = true);
      await Future<void>.value();
      expect(completed, isFalse);
      gated.releaseDelete();
      await future;
      expect(completed, isTrue);
    });

    test(
      'holdCompareAndSwap() blocks until releaseCompareAndSwap() unblocks',
      () async {
        gated.holdCompareAndSwap();
        var completed = false;
        final future = gated
            .compareAndSwap('f', Uint8List(0), ifMatchEtag: null)
            .then((v) {
              completed = true;
              return v;
            });
        await Future<void>.value();
        expect(completed, isFalse);
        gated.releaseCompareAndSwap();
        await future;
        expect(completed, isTrue);
      },
    );

    test('holdGetEtag() blocks until releaseGetEtag() unblocks', () async {
      gated.holdGetEtag();
      var completed = false;
      final future = gated.getEtag('f').then((v) {
        completed = true;
        return v;
      });
      await Future<void>.value();
      expect(completed, isFalse);
      gated.releaseGetEtag();
      await future;
      expect(completed, isTrue);
    });

    test('releaseList() is idempotent — calling twice does not throw', () {
      gated.holdList();
      gated.releaseList();
      expect(() => gated.releaseList(), returnsNormally);
    });

    test('releasing one barrier does not release others', () async {
      gated.holdList();
      gated.holdDownload();

      var listDone = false;
      var downloadDone = false;

      final listFuture = gated.list('dir').then((_) => listDone = true);
      final downloadFuture = gated
          .download('f')
          .then((_) => downloadDone = true);

      await Future<void>.value();
      expect(listDone, isFalse);
      expect(downloadDone, isFalse);

      // Release only list.
      gated.releaseList();
      await listFuture;
      expect(listDone, isTrue);
      // Download should still be blocked.
      expect(downloadDone, isFalse);

      // Release download to clean up.
      gated.releaseDownload();
      await downloadFuture;
      expect(downloadDone, isTrue);
    });
  });

  // ── Cancellation via SyncContext ─────────────────────────────────────────────

  group('GatedSyncAdapter — cancellation via SyncContext', () {
    late GatedSyncAdapter gated;

    setUp(() {
      gated = GatedSyncAdapter(MemorySyncAdapter());
    });

    test(
      'cancelling token while list() is blocked throws SyncCancelledException',
      () async {
        final token = CancellationToken();
        final ctx = SyncContext(cancel: token);
        gated.holdList();

        final future = gated.list('dir', ctx: ctx);
        // Allow the barrier await to start.
        await Future<void>.value();

        token.cancel();

        // The exception must be delivered to the future, not synchronously.
        await expectLater(future, throwsA(isA<SyncCancelledException>()));
      },
    );

    test(
      'cancelling token while download() is blocked throws SyncCancelledException',
      () async {
        final token = CancellationToken();
        final ctx = SyncContext(cancel: token);
        gated.holdDownload();

        final future = gated.download('f', ctx: ctx);
        await Future<void>.value();
        token.cancel();

        await expectLater(future, throwsA(isA<SyncCancelledException>()));
      },
    );

    test(
      'after cancel wakes the barrier, the delegate is NOT called (no upload)',
      () async {
        final inner = MemorySyncAdapter();
        gated = GatedSyncAdapter(inner);
        final token = CancellationToken();
        final ctx = SyncContext(cancel: token);
        gated.holdUpload();

        final future = gated.upload(
          'test/file.bin',
          Uint8List.fromList([1, 2, 3]),
          ctx: ctx,
        );
        await Future<void>.value();
        token.cancel();

        await expectLater(future, throwsA(isA<SyncCancelledException>()));
        // The delegate was NOT called because cancellation happened before
        // the barrier was released.
        expect(await inner.download('test/file.bin'), isNull);
      },
    );

    test(
      'barrier without SyncContext blocks until released (no cancellation path)',
      () async {
        gated.holdList();
        var done = false;
        final future = gated.list('dir').then((_) => done = true);

        await Future<void>.value();
        expect(done, isFalse);

        gated.releaseList();
        await future;
        expect(done, isTrue);
      },
    );
  });
}
