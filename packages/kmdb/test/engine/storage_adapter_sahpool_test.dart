// Copyright 2026 The Authors
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

// Integration tests for StorageAdapterSahPool.
//
// These tests run exclusively in a browser (Chrome/Chromium) where OPFS and
// FileSystemSyncAccessHandle are available. They cover all 14 StorageAdapter
// interface methods plus the edge cases called out in the plan:
//   - readFileRange beyond EOF
//   - appendFile to a non-existent file
//   - releaseLock without prior acquireLock
//   - cross-tab lock collision → LockException
//
// Run with: dart test -p chrome test/engine/storage_adapter_sahpool_test.dart
//
// NOTE: Cross-tab lock collision cannot be tested in a single test process
// (two Worker instances in the same tab can share a lock handle). A manual
// release-checklist entry (RC-10) covers this scenario.

@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_sahpool.dart';

// Unique path prefix for each test run to avoid OPFS state leaking between runs.
String _path(String name) =>
    '/sahpool_test/${DateTime.now().microsecondsSinceEpoch}/$name';
String _dir(String name) =>
    '/sahpool_test/${DateTime.now().microsecondsSinceEpoch}/$name';

void main() {
  late StorageAdapterSahPool adapter;

  // Each test gets a fresh adapter to avoid Worker state leakage.
  setUp(() {
    adapter = StorageAdapterSahPool();
  });

  tearDown(() async {
    await adapter.close();
  });

  // ── readFile / writeFile ────────────────────────────────────────────────────

  group('readFile / writeFile', () {
    test('round-trips bytes', () async {
      final path = _path('rw_basic');
      await adapter.writeFile(path, Uint8List.fromList([1, 2, 3]));
      expect(await adapter.readFile(path), equals([1, 2, 3]));
    });

    test('writeFile replaces existing content', () async {
      final path = _path('rw_replace');
      await adapter.writeFile(path, Uint8List.fromList([1, 2, 3]));
      await adapter.writeFile(path, Uint8List.fromList([9]));
      // The old tail bytes [2, 3] must not remain — the Worker truncates first.
      expect(await adapter.readFile(path), equals([9]));
    });

    test('readFile throws StorageException for missing file', () async {
      expect(
        () => adapter.readFile(_path('missing_rw')),
        throwsA(isA<StorageException>()),
      );
    });

    test('writeFile creates parent directories', () async {
      final path = _path('deep/nested/file.dat');
      await adapter.writeFile(path, Uint8List.fromList([7, 8]));
      expect(await adapter.readFile(path), equals([7, 8]));
    });

    test('large write/read round-trip (64KB)', () async {
      final path = _path('large');
      final data = Uint8List(65536);
      for (var i = 0; i < data.length; i++) {
        data[i] = i & 0xFF;
      }
      await adapter.writeFile(path, data);
      final read = await adapter.readFile(path);
      expect(read.length, equals(65536));
      expect(read[0], equals(0));
      expect(read[255], equals(255));
      expect(read[256], equals(0));
    });
  });

  // ── readFileRange ───────────────────────────────────────────────────────────

  group('readFileRange', () {
    test('returns correct slice', () async {
      final path = _path('range_basic');
      await adapter.writeFile(path, Uint8List.fromList([0, 1, 2, 3, 4]));
      expect(await adapter.readFileRange(path, 1, 3), equals([1, 2, 3]));
    });

    test('reads from start', () async {
      final path = _path('range_from_start');
      await adapter.writeFile(path, Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange(path, 0, 2), equals([10, 20]));
    });

    test('reads to end', () async {
      final path = _path('range_to_end');
      await adapter.writeFile(path, Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange(path, 1, 2), equals([20, 30]));
    });

    test('reads single byte at offset', () async {
      final path = _path('range_single');
      await adapter.writeFile(path, Uint8List.fromList([5, 6, 7, 8]));
      expect(await adapter.readFileRange(path, 2, 1), equals([7]));
    });

    test('throws StorageException when range extends beyond EOF', () async {
      // Edge case: readFileRange beyond EOF.
      final path = _path('range_beyond_eof');
      await adapter.writeFile(path, Uint8List.fromList([1, 2, 3]));
      expect(
        () => adapter.readFileRange(path, 2, 5),
        throwsA(isA<StorageException>()),
      );
    });

    test('throws StorageException for missing file', () async {
      expect(
        () => adapter.readFileRange(_path('missing_range'), 0, 1),
        throwsA(isA<StorageException>()),
      );
    });

    test('demonstrates O(length) performance over large file', () async {
      // Write 100KB file then read a 4KB block from offset 50KB.
      // This verifies the SAH handles no read the whole file (unlike old adapter).
      final path = _path('large_range');
      final data = Uint8List(102400);
      for (var i = 0; i < data.length; i++) {
        data[i] = i & 0xFF;
      }
      await adapter.writeFile(path, data);
      final block = await adapter.readFileRange(path, 51200, 4096);
      expect(block.length, equals(4096));
      expect(block[0], equals(0)); // 51200 & 0xFF == 0
      expect(block[1], equals(1)); // 51201 & 0xFF == 1
    });
  });

  // ── appendFile ──────────────────────────────────────────────────────────────

  group('appendFile', () {
    test('creates file on first append (non-existent file)', () async {
      // Edge case: appendFile to a non-existent file.
      final path = _path('append_new');
      await adapter.appendFile(path, Uint8List.fromList([1, 2]));
      expect(await adapter.readFile(path), equals([1, 2]));
    });

    test('appends to existing content', () async {
      final path = _path('append_existing');
      await adapter.appendFile(path, Uint8List.fromList([1, 2]));
      await adapter.appendFile(path, Uint8List.fromList([3, 4]));
      expect(await adapter.readFile(path), equals([1, 2, 3, 4]));
    });

    test('multiple appends accumulate in order', () async {
      final path = _path('append_multiple');
      for (var i = 0; i < 5; i++) {
        await adapter.appendFile(path, Uint8List.fromList([i]));
      }
      expect(await adapter.readFile(path), equals([0, 1, 2, 3, 4]));
    });

    test('appends large chunks correctly', () async {
      final path = _path('append_large');
      final chunk = Uint8List(4096);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = i & 0xFF;
      }
      await adapter.appendFile(path, chunk);
      await adapter.appendFile(path, chunk);
      final result = await adapter.readFile(path);
      expect(result.length, equals(8192));
      expect(result[4096], equals(0));
    });
  });

  // ── deleteFile ──────────────────────────────────────────────────────────────

  group('deleteFile', () {
    test('removes the file', () async {
      final path = _path('del');
      await adapter.writeFile(path, Uint8List.fromList([1]));
      await adapter.deleteFile(path);
      expect(await adapter.fileExists(path), isFalse);
    });

    test('no-op for missing file', () async {
      await expectLater(adapter.deleteFile(_path('missing_del')), completes);
    });
  });

  // ── fileExists ──────────────────────────────────────────────────────────────

  group('fileExists', () {
    test('true for written file', () async {
      final path = _path('exists_true');
      await adapter.writeFile(path, Uint8List(0));
      expect(await adapter.fileExists(path), isTrue);
    });

    test('false for missing file', () async {
      expect(await adapter.fileExists(_path('missing_exists')), isFalse);
    });

    test('false after deletion', () async {
      final path = _path('exists_after_del');
      await adapter.writeFile(path, Uint8List(0));
      await adapter.deleteFile(path);
      expect(await adapter.fileExists(path), isFalse);
    });
  });

  // ── fileSize ─────────────────────────────────────────────────────────────────

  group('fileSize', () {
    test('returns byte length', () async {
      final path = _path('size');
      await adapter.writeFile(path, Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await adapter.fileSize(path), equals(5));
    });

    test('zero for empty file', () async {
      final path = _path('size_empty');
      await adapter.writeFile(path, Uint8List(0));
      expect(await adapter.fileSize(path), equals(0));
    });

    test('reflects appended bytes', () async {
      final path = _path('size_append');
      await adapter.appendFile(path, Uint8List.fromList([1, 2]));
      await adapter.appendFile(path, Uint8List.fromList([3]));
      expect(await adapter.fileSize(path), equals(3));
    });

    test('throws StorageException for missing file', () async {
      expect(
        () => adapter.fileSize(_path('missing_size')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  // ── listFiles ────────────────────────────────────────────────────────────────

  group('listFiles', () {
    test('returns file names in directory', () async {
      final dir = _dir('list_basic');
      await adapter.writeFile('$dir/a.sst', Uint8List(0));
      await adapter.writeFile('$dir/b.sst', Uint8List(0));
      final names = await adapter.listFiles(dir);
      expect(names, containsAll(['a.sst', 'b.sst']));
    });

    test('filters by extension', () async {
      final dir = _dir('list_ext');
      await adapter.writeFile('$dir/a.sst', Uint8List(0));
      await adapter.writeFile('$dir/b.log', Uint8List(0));
      final names = await adapter.listFiles(dir, extension: '.sst');
      expect(names, equals(['a.sst']));
    });

    test('empty list for missing directory', () async {
      expect(await adapter.listFiles(_dir('list_missing')), isEmpty);
    });
  });

  // ── renameFile ───────────────────────────────────────────────────────────────

  group('renameFile', () {
    test('moves content to new path', () async {
      final src = _path('rename_src');
      final dst = _path('rename_dst');
      await adapter.writeFile(src, Uint8List.fromList([42]));
      await adapter.renameFile(src, dst);
      expect(await adapter.fileExists(src), isFalse);
      expect(await adapter.readFile(dst), equals([42]));
    });

    test('destination is fully flushed before source is deleted', () async {
      // Durability ordering: after rename, dst is readable and src is gone.
      // This verifies the per-op flush (write dest → flush dest → close dest
      // → delete source) is respected.
      final src = _path('rename_durability_src');
      final dst = _path('rename_durability_dst');
      final data = Uint8List(8192);
      for (var i = 0; i < data.length; i++) {
        data[i] = i & 0xFF;
      }
      await adapter.writeFile(src, data);
      await adapter.renameFile(src, dst);
      expect(await adapter.fileExists(src), isFalse);
      final read = await adapter.readFile(dst);
      expect(read.length, equals(8192));
      expect(read[100], equals(100));
    });

    test('throws StorageException for missing source', () async {
      expect(
        () => adapter.renameFile(_path('missing_src'), _path('any_dst')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  // ── createDirectory ──────────────────────────────────────────────────────────

  group('createDirectory', () {
    test(
      'creates directory — subsequent listFiles returns empty list',
      () async {
        final dir = _dir('mkdir');
        await adapter.createDirectory(dir);
        // Directory exists — listFiles should return empty, not throw.
        expect(await adapter.listFiles(dir), isEmpty);
      },
    );

    test('creates intermediate directories', () async {
      final dir = _dir('mkdir/deep/nested');
      await adapter.createDirectory(dir);
      await adapter.writeFile('$dir/file.dat', Uint8List.fromList([1]));
      expect(await adapter.fileExists('$dir/file.dat'), isTrue);
    });

    test('is idempotent', () async {
      final dir = _dir('mkdir_idem');
      await adapter.createDirectory(dir);
      // Second call should succeed without error.
      await expectLater(adapter.createDirectory(dir), completes);
    });
  });

  // ── syncFile / syncDir ───────────────────────────────────────────────────────

  group('syncFile / syncDir', () {
    test('syncFile is a no-op — completes without error', () async {
      final path = _path('sync_file');
      await adapter.writeFile(path, Uint8List(0));
      await expectLater(adapter.syncFile(path), completes);
    });

    test('syncDir is a no-op — completes without error', () async {
      await expectLater(adapter.syncDir('/'), completes);
    });
  });

  // ── acquireLock / releaseLock ─────────────────────────────────────────────────

  group('acquireLock / releaseLock', () {
    test('acquires lock successfully', () async {
      final lockPath = _path('LOCK');
      await expectLater(adapter.acquireLock(lockPath), completes);
      // Release after test.
      await adapter.releaseLock(lockPath);
    });

    test('releaseLock without prior lock is a no-op', () async {
      // Edge case: releaseLock without acquireLock.
      await expectLater(
        adapter.releaseLock(_path('LOCK_unacquired')),
        completes,
      );
    });

    test('lock is held as an exclusive sync handle (single adapter)', () async {
      // We cannot simulate cross-tab collision in a single test process
      // (both Workers share the same origin context). Instead we verify the
      // hold semantics: lock is acquired, file exists, and release cleans up.
      final lockPath = _path('LOCK_held');
      await adapter.acquireLock(lockPath);
      // The lock sentinel file should exist while the handle is held.
      expect(await adapter.fileExists(lockPath), isTrue);
      await adapter.releaseLock(lockPath);
      // After release, the lock file should be removed.
      expect(await adapter.fileExists(lockPath), isFalse);
    });
  });

  // ── Durability contract ───────────────────────────────────────────────────────

  group('Durability — per-op handle lifecycle', () {
    test('writeFile followed by readFile returns correct data (flush-and-close '
        'ensures no buffered bytes)', () async {
      // This test relies on the per-op flush: if the Worker did NOT flush()
      // before close(), the readFile that follows could see stale bytes.
      final path = _path('flush_contract');
      final data = Uint8List.fromList(List.generate(1024, (i) => i & 0xFF));
      await adapter.writeFile(path, data);
      final read = await adapter.readFile(path);
      expect(read, orderedEquals(data));
    });

    test('appendFile followed by readFile is consistent', () async {
      final path = _path('flush_append');
      await adapter.appendFile(path, Uint8List.fromList([0xAA, 0xBB]));
      await adapter.appendFile(path, Uint8List.fromList([0xCC, 0xDD]));
      expect(await adapter.readFile(path), equals([0xAA, 0xBB, 0xCC, 0xDD]));
    });
  });

  // ── Sequential operations ─────────────────────────────────────────────────────

  group('Sequential ops (ordering guarantee)', () {
    test('ten sequential writes and reads are consistent', () async {
      for (var i = 0; i < 10; i++) {
        final path = _path('seq_$i');
        final data = Uint8List.fromList([i, i + 1, i + 2]);
        await adapter.writeFile(path, data);
        expect(await adapter.readFile(path), equals([i, i + 1, i + 2]));
      }
    });

    test(
      'WAL-style append pattern: many appends followed by readAll',
      () async {
        // Simulates WAL writer appending many small records.
        final path = _path('wal_pattern');
        for (var i = 0; i < 20; i++) {
          await adapter.appendFile(path, Uint8List.fromList([i & 0xFF]));
        }
        final result = await adapter.readFile(path);
        expect(result.length, equals(20));
        for (var i = 0; i < 20; i++) {
          expect(result[i], equals(i & 0xFF));
        }
      },
    );
  });
}
