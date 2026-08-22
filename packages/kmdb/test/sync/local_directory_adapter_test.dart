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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/sync/local/local_directory_adapter.dart';
import 'package:test/test.dart';

import 'package:kmdb/test_support.dart';

/// Test double for the `_updateWithLock` ordering-probe regression test.
///
/// Overrides the two `@visibleForTesting`/`@protected` seams
/// ([LocalDirectoryAdapter.writeViaTempRename] and
/// [LocalDirectoryAdapter.releaseLock]) to record an ordering [log] and to
/// let the test hold the write open on a [gate] `Completer` while the lock
/// is still held — deterministically proving the lock is not released until
/// the write actually completes.
final class _OrderingProbeAdapter extends LocalDirectoryAdapter {
  _OrderingProbeAdapter(super.rootPath, {required this.gate})
    : super(atomicCas: true);

  /// Held open by the test until it has asserted the lock is not yet
  /// released; completing it lets the write (and thus the unlock) proceed.
  final Completer<void> gate;

  /// Ordering of events observed during a `compareAndSwap` call.
  final List<String> log = [];

  @override
  Future<bool> writeViaTempRename(File file, Uint8List bytes) async {
    log.add('write:start');
    await gate.future;
    final result = await super.writeViaTempRename(file, bytes);
    log.add('write:end');
    return result;
  }

  @override
  Future<void> releaseLock(RandomAccessFile raf) async {
    log.add('unlock');
    await super.releaseLock(raf);
  }
}

void main() {
  // Non-atomic mode (default): conformance suite runs with expectAtomicCas=false.
  // The contention test verifies forward progress only — multiple winners are
  // allowed, which is expected for this mode.
  group('LocalDirectoryAdapter conformance (non-atomic mode)', () {
    late Directory confTempDir;
    setUp(() {
      confTempDir = Directory.systemTemp.createTempSync('lda_conformance_');
    });
    tearDown(() {
      if (confTempDir.existsSync()) confTempDir.deleteSync(recursive: true);
    });
    runSyncAdapterConformance(
      factory: () => LocalDirectoryAdapter(confTempDir.path),
      expectAtomicCas: false,
    );
  });

  // Atomic mode (atomicCas: true): the full conformance suite including the
  // H5 regression guard. The contention test asserts exactly one winner —
  // proving File.create(exclusive: true) and the advisory-lock update path
  // correctly serialise concurrent writers.
  group('LocalDirectoryAdapter conformance (atomic mode)', () {
    late Directory confTempDir;
    setUp(() {
      confTempDir = Directory.systemTemp.createTempSync('lda_atomic_');
    });
    tearDown(() {
      if (confTempDir.existsSync()) confTempDir.deleteSync(recursive: true);
    });
    runSyncAdapterConformance(
      factory: () => LocalDirectoryAdapter(confTempDir.path, atomicCas: true),
      expectAtomicCas: true,
    );
  });

  late Directory tempDir;
  late LocalDirectoryAdapter adapter;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_directory_adapter_');
    adapter = LocalDirectoryAdapter(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ── upload / download ────────────────────────────────────────────────────────

  test('upload and download a file', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await adapter.upload('dir/file.bin', bytes);
    final result = await adapter.download('dir/file.bin');
    expect(result, equals(bytes));
  });

  test('upload creates intermediate directories', () async {
    await adapter.upload('a/b/c/file.bin', Uint8List.fromList([9]));
    expect(File('${tempDir.path}/a/b/c/file.bin').existsSync(), isTrue);
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

  // ── list ─────────────────────────────────────────────────────────────────────

  test('list returns direct children of a directory', () async {
    await adapter.upload('dir/a.sst', Uint8List(0));
    await adapter.upload('dir/b.sst', Uint8List(0));
    // Nested file is not a direct child — expect it to be excluded since list()
    // uses non-recursive Directory.list().
    await adapter.upload('dir/sub/c.sst', Uint8List(0));
    await adapter.upload('other/d.sst', Uint8List(0));

    final files = await adapter.list('dir');
    expect(files, containsAll(['a.sst', 'b.sst']));
    expect(files, isNot(contains('c.sst')));
    expect(files, isNot(contains('d.sst')));
    expect(files.length, equals(2));
  });

  test('list with extension filter returns only matching files', () async {
    await adapter.upload('dir/a.sst', Uint8List(0));
    await adapter.upload('dir/b.hwm', Uint8List(0));
    final files = await adapter.list('dir', extension: '.sst');
    expect(files, equals(['a.sst']));
  });

  test('list returns empty list for non-existent directory', () async {
    final files = await adapter.list('nonexistent');
    expect(files, isEmpty);
  });

  // ── delete ───────────────────────────────────────────────────────────────────

  test('delete removes the file', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    await adapter.delete('f');
    final result = await adapter.download('f');
    expect(result, isNull);
  });

  test('delete is a no-op for missing file', () async {
    await expectLater(adapter.delete('missing'), completes);
  });

  // ── getEtag ──────────────────────────────────────────────────────────────────

  test('getEtag returns null for missing file', () async {
    expect(await adapter.getEtag('missing'), isNull);
  });

  test('getEtag returns a 16-char hex string after upload', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag = await adapter.getEtag('f');
    expect(etag, isNotNull);
    expect(etag, matches(RegExp(r'^[0-9A-F]{16}$')));
  });

  test('getEtag is deterministic for the same content', () async {
    final bytes = Uint8List.fromList([10, 20, 30]);
    await adapter.upload('f1', bytes);
    await adapter.upload('f2', bytes);
    expect(await adapter.getEtag('f1'), equals(await adapter.getEtag('f2')));
  });

  test('getEtag differs for files with different content', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final etag1 = await adapter.getEtag('f');
    await adapter.upload('f', Uint8List.fromList([2]));
    final etag2 = await adapter.getEtag('f');
    expect(etag1, isNot(equals(etag2)));
  });

  test(
    'getEtag differs for files that are the same size but different content',
    () async {
      // Regression: a file-size based approach would return equal ETags here.
      await adapter.upload('f', Uint8List.fromList([0x00]));
      final etag1 = await adapter.getEtag('f');
      await adapter.upload('f', Uint8List.fromList([0xff]));
      final etag2 = await adapter.getEtag('f');
      expect(etag1, isNot(equals(etag2)));
    },
  );

  test('getEtag returns null after delete', () async {
    await adapter.upload('f', Uint8List(1));
    await adapter.delete('f');
    expect(await adapter.getEtag('f'), isNull);
  });

  // ── compareAndSwap: if-none-match semantics ───────────────────────────────────

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

  test('compareAndSwap with null ifMatchEtag fails when file exists', () async {
    await adapter.upload('f', Uint8List.fromList([1]));
    final result = await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([2]),
      ifMatchEtag: null,
    );
    expect(result, isFalse);
    // Original content is unchanged.
    expect(await adapter.download('f'), equals(Uint8List.fromList([1])));
  });

  test(
    'compareAndSwap with null ifMatchEtag creates parent directories',
    () async {
      final result = await adapter.compareAndSwap(
        'deep/nested/f',
        Uint8List.fromList([7]),
        ifMatchEtag: null,
      );
      expect(result, isTrue);
      expect(File('${tempDir.path}/deep/nested/f').existsSync(), isTrue);
    },
  );

  test(
    'compareAndSwap with null ifMatchEtag leaves no temp file on success',
    () async {
      await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([1]),
        ifMatchEtag: null,
      );
      // No .cas-tmp-* files should remain.
      final tmpFiles = tempDir
          .listSync(recursive: true)
          .where((e) => e.path.contains('.cas-tmp-'))
          .toList();
      expect(tmpFiles, isEmpty);
    },
  );

  // ── compareAndSwap: conditional update ────────────────────────────────────────

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
    // File retains the value from the intervening write.
    expect(await adapter.download('f'), equals(Uint8List.fromList([2])));
  });

  test('compareAndSwap with etag fails when file does not exist', () async {
    final result = await adapter.compareAndSwap(
      'f',
      Uint8List.fromList([1]),
      ifMatchEtag: 'nonexistent-etag',
    );
    expect(result, isFalse);
  });

  test(
    'compareAndSwap with matching etag leaves no temp file on success',
    () async {
      await adapter.upload('f', Uint8List.fromList([1]));
      final etag = await adapter.getEtag('f');
      await adapter.compareAndSwap(
        'f',
        Uint8List.fromList([2]),
        ifMatchEtag: etag,
      );
      final tmpFiles = tempDir
          .listSync(recursive: true)
          .where((e) => e.path.contains('.cas-tmp-'))
          .toList();
      expect(tmpFiles, isEmpty);
    },
  );

  test('compareAndSwap updates etag on success', () async {
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

  // ── _updateWithLock unlock/write ordering regression ────────────────────────
  //
  // Regression test for the unlock-ordering bug fixed alongside this test:
  // `_updateWithLock`'s locked `try` block used to `return` the write's
  // future without `await`ing it, so the enclosing `finally` (which unlocks
  // and closes the file handle) ran *before* the write completed. A
  // concurrent cooperating writer could then acquire the lock and begin its
  // own compare-and-write while the first writer's temp-rename was still in
  // flight. A golden-path assertion (write succeeds, bytes correct) passes
  // both before and after the fix, so it cannot guard this — this test
  // instead observes the *ordering* of events via two test-only seams
  // (`writeViaTempRename` / `releaseLock`), gated on a `Completer` so the
  // result is deterministic rather than dependent on I/O scheduling.
  group('LocalDirectoryAdapter _updateWithLock ordering (atomicCas: true)', () {
    late Directory orderingTempDir;
    setUp(() {
      orderingTempDir = Directory.systemTemp.createTempSync('lda_ordering_');
    });
    tearDown(() {
      if (orderingTempDir.existsSync()) {
        orderingTempDir.deleteSync(recursive: true);
      }
    });

    test('unlock is observed only after the write completes, not while it is '
        'still in flight', () async {
      final gate = Completer<void>();
      final probe = _OrderingProbeAdapter(orderingTempDir.path, gate: gate);

      // Seed the file and capture its ETag so compareAndSwap takes the
      // *update* path (_updateWithLock), not create-if-absent.
      await probe.upload('f', Uint8List.fromList([1]));
      final etag = await probe.getEtag('f');

      // Fire compareAndSwap without awaiting: it will reach the gated
      // writeViaTempRename override and suspend there, still holding the
      // advisory lock.
      final future = probe.compareAndSwap(
        'f',
        Uint8List.fromList([2]),
        ifMatchEtag: etag,
      );

      // Pump the event loop until the call reaches the gated write. This
      // bounded poll (not a fixed-count pump) tolerates the real
      // dart:io async file-open/lock/read I/O that precedes the gated
      // call, without over-fitting to a specific number of event-loop
      // turns.
      for (var i = 0; i < 100 && probe.log.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(probe.log, contains('write:start'));

      // The crux of the regression: on the unfixed code (a bare `return`
      // of the write's future, not `return await`), the `finally` block
      // runs immediately once the statement executes — releasing the
      // lock before the write completes — so `unlock` would already be
      // in the log at this point. On the fixed code, `_updateWithLock`
      // is suspended on the `await`, so `finally` (and thus `unlock`)
      // has not run yet.
      expect(
        probe.log,
        isNot(contains('unlock')),
        reason:
            'the advisory lock must not be released before the write '
            'completes',
      );

      // Let the write proceed and complete the call.
      gate.complete();
      final result = await future;

      expect(result, isTrue);
      expect(probe.log, equals(['write:start', 'write:end', 'unlock']));
      expect(await probe.download('f'), equals(Uint8List.fromList([2])));
    });
  });
}
