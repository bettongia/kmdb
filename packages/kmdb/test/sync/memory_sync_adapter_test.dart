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

import 'dart:typed_data';

import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:test/test.dart';

import 'package:kmdb/test_support.dart';

void main() {
  group('MemorySyncAdapter conformance', () {
    runSyncAdapterConformance(
      factory: MemorySyncAdapter.new,
      expectAtomicCas: true,
    );
  });

  group('MemorySyncAdapter', () {
    late MemorySyncAdapter adapter;

    setUp(() {
      adapter = MemorySyncAdapter();
    });

    // ── upload / download ────────────────────────────────────────────────────

    test('upload and download a file', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await adapter.upload('dir/file.bin', bytes);
      final result = await adapter.download('dir/file.bin');
      expect(result, equals(bytes));
    });

    test('download returns null for missing file', () async {
      final result = await adapter.download('missing.bin');
      expect(result, isNull);
    });

    test('upload overwrites existing content', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      await adapter.upload('f', Uint8List.fromList([2, 3]));
      final result = await adapter.download('f');
      expect(result, equals(Uint8List.fromList([2, 3])));
    });

    test('download returns a copy, not the internal buffer', () async {
      final original = Uint8List.fromList([10, 20]);
      await adapter.upload('f', original);
      final downloaded = await adapter.download('f');
      downloaded![0] = 99; // mutate the copy
      final again = await adapter.download('f');
      expect(again![0], equals(10)); // original unchanged
    });

    // ── list ─────────────────────────────────────────────────────────────────

    test('list returns direct children of a directory', () async {
      await adapter.upload('dir/a.sst', Uint8List(0));
      await adapter.upload('dir/b.sst', Uint8List(0));
      await adapter.upload('dir/sub/c.sst', Uint8List(0)); // nested — excluded
      await adapter.upload(
        'other/d.sst',
        Uint8List(0),
      ); // different dir — excluded

      final files = await adapter.list('dir');
      expect(files, containsAll(['a.sst', 'b.sst']));
      expect(files, isNot(contains('c.sst')));
      expect(files, isNot(contains('d.sst')));
      expect(files.length, equals(2));
    });

    test('list with extension filter', () async {
      await adapter.upload('dir/a.sst', Uint8List(0));
      await adapter.upload('dir/b.hwm', Uint8List(0));
      final files = await adapter.list('dir', extension: '.sst');
      expect(files, equals(['a.sst']));
    });

    test('list returns empty list for non-existent directory', () async {
      final files = await adapter.list('nonexistent');
      expect(files, isEmpty);
    });

    test('list handles trailing slash in remoteDir', () async {
      await adapter.upload('dir/x.sst', Uint8List(0));
      final files = await adapter.list('dir/');
      expect(files, contains('x.sst'));
    });

    // ── delete ───────────────────────────────────────────────────────────────

    test('delete removes the file', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      await adapter.delete('f');
      final result = await adapter.download('f');
      expect(result, isNull);
    });

    test('delete is a no-op for missing file', () async {
      // Should not throw.
      await expectLater(adapter.delete('missing'), completes);
    });

    // ── getEtag ──────────────────────────────────────────────────────────────

    test('getEtag returns null for missing file', () async {
      expect(await adapter.getEtag('missing'), isNull);
    });

    test('getEtag returns a string after upload', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag = await adapter.getEtag('f');
      expect(etag, isNotNull);
      expect(etag, isA<String>());
    });

    test('getEtag changes after upload', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag1 = await adapter.getEtag('f');
      await adapter.upload('f', Uint8List.fromList([2]));
      final etag2 = await adapter.getEtag('f');
      expect(etag1, isNot(equals(etag2)));
    });

    test('getEtag returns null after delete', () async {
      await adapter.upload('f', Uint8List(1));
      await adapter.delete('f');
      expect(await adapter.getEtag('f'), isNull);
    });

    // ── compareAndSwap: if-none-match semantics ───────────────────────────────

    test(
      'compareAndSwap with null ifMatchEtag succeeds when file absent',
      () async {
        final bytes = Uint8List.fromList([42]);
        final result = await adapter.compareAndSwap(
          'f',
          bytes,
          ifMatchEtag: null,
        );
        expect(result, isTrue);
        expect(await adapter.download('f'), equals(bytes));
      },
    );

    test(
      'compareAndSwap with null ifMatchEtag fails when file exists',
      () async {
        await adapter.upload('f', Uint8List.fromList([1]));
        final result = await adapter.compareAndSwap(
          'f',
          Uint8List.fromList([2]),
          ifMatchEtag: null,
        );
        expect(result, isFalse);
        // Original content unchanged.
        expect(await adapter.download('f'), equals(Uint8List.fromList([1])));
      },
    );

    // ── compareAndSwap: conditional update ────────────────────────────────────

    test('compareAndSwap with matching etag succeeds', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag = await adapter.getEtag('f');
      final newBytes = Uint8List.fromList([99]);
      final result = await adapter.compareAndSwap(
        'f',
        newBytes,
        ifMatchEtag: etag,
      );
      expect(result, isTrue);
      expect(await adapter.download('f'), equals(newBytes));
    });

    test('compareAndSwap with stale etag fails', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final staleEtag = await adapter.getEtag('f');
      // Another writer updates the file.
      await adapter.upload('f', Uint8List.fromList([2]));
      // Now try with the stale etag.
      final result = await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([3]),
        ifMatchEtag: staleEtag,
      );
      expect(result, isFalse);
      // File has the value from the intervening write.
      expect(await adapter.download('f'), equals(Uint8List.fromList([2])));
    });

    test('compareAndSwap with etag fails when file does not exist', () async {
      final result = await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([1]),
        ifMatchEtag: '1',
      );
      expect(result, isFalse);
    });

    test('compareAndSwap increments etag on success', () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag1 = await adapter.getEtag('f');
      await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([2]),
        ifMatchEtag: etag1,
      );
      final etag2 = await adapter.getEtag('f');
      expect(etag1, isNot(equals(etag2)));
    });

    // ── clear ────────────────────────────────────────────────────────────────

    test('clear removes all files', () async {
      await adapter.upload('a', Uint8List(1));
      await adapter.upload('b', Uint8List(1));
      adapter.clear();
      expect(adapter.fileCount, equals(0));
      expect(await adapter.download('a'), isNull);
    });

    test('containsFile returns correct value', () async {
      expect(adapter.containsFile('x'), isFalse);
      await adapter.upload('x', Uint8List(1));
      expect(adapter.containsFile('x'), isTrue);
      await adapter.delete('x');
      expect(adapter.containsFile('x'), isFalse);
    });

    // ── atomic CAS invariant ──────────────────────────────────────────────────

    test(
      'concurrent CAS: only one write wins when both see absent file',
      () async {
        // Simulate two writers racing to create the same file.
        // Since Dart is single-threaded, we interleave by calling both
        // compareAndSwap before awaiting — but since the Futures complete
        // synchronously in memory, the first to await wins.
        final r1 = adapter.compareAndSwap(
          'lease',
          Uint8List.fromList([1]),
          ifMatchEtag: null,
        );
        final r2 = adapter.compareAndSwap(
          'lease',
          Uint8List.fromList([2]),
          ifMatchEtag: null,
        );
        final results = await Future.wait([r1, r2]);
        // Exactly one should succeed.
        final successes = results.where((r) => r).length;
        expect(successes, equals(1));
      },
    );
  });
}
