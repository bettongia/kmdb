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

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_native.dart';

void main() {
  late Directory tempDir;
  late StorageAdapterNative adapter;

  String p(String name) => '${tempDir.path}/$name';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'kmdb_native_adapter_test_',
    );
    adapter = StorageAdapterNative();
  });

  tearDown(() async {
    await adapter.releaseLock(p('LOCK'));
    await tempDir.delete(recursive: true);
  });

  group('readFile / writeFile', () {
    test('round-trips bytes', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      await adapter.writeFile(p('foo'), data);
      expect(await adapter.readFile(p('foo')), equals([1, 2, 3]));
    });

    test('writeFile replaces existing content', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([1, 2]));
      await adapter.writeFile(p('foo'), Uint8List.fromList([9]));
      expect(await adapter.readFile(p('foo')), equals([9]));
    });

    test('readFile throws StorageException for missing file', () async {
      expect(
        () => adapter.readFile(p('missing')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('readFileRange', () {
    test('returns correct slice', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([0, 1, 2, 3, 4]));
      expect(await adapter.readFileRange(p('foo'), 1, 3), equals([1, 2, 3]));
    });

    test('reads from start', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange(p('foo'), 0, 2), equals([10, 20]));
    });

    test('reads to end', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange(p('foo'), 1, 2), equals([20, 30]));
    });

    test('throws on out-of-bounds range', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([1, 2, 3]));
      expect(
        () => adapter.readFileRange(p('foo'), 2, 5),
        throwsA(isA<StorageException>()),
      );
    });

    test('throws for missing file', () async {
      expect(
        () => adapter.readFileRange(p('missing'), 0, 1),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('appendFile', () {
    test('creates file on first append', () async {
      await adapter.appendFile(p('wal'), Uint8List.fromList([1, 2]));
      expect(await adapter.readFile(p('wal')), equals([1, 2]));
    });

    test('appends to existing content', () async {
      await adapter.appendFile(p('wal'), Uint8List.fromList([1, 2]));
      await adapter.appendFile(p('wal'), Uint8List.fromList([3, 4]));
      expect(await adapter.readFile(p('wal')), equals([1, 2, 3, 4]));
    });

    test('multiple appends accumulate in order', () async {
      for (var i = 0; i < 5; i++) {
        await adapter.appendFile(p('wal'), Uint8List.fromList([i]));
      }
      expect(await adapter.readFile(p('wal')), equals([0, 1, 2, 3, 4]));
    });
  });

  group('deleteFile', () {
    test('removes the file', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([1]));
      await adapter.deleteFile(p('foo'));
      expect(await adapter.fileExists(p('foo')), isFalse);
    });

    test('no-op for missing file', () async {
      await expectLater(adapter.deleteFile(p('missing')), completes);
    });
  });

  group('fileExists', () {
    test('true for written file', () async {
      await adapter.writeFile(p('foo'), Uint8List(0));
      expect(await adapter.fileExists(p('foo')), isTrue);
    });

    test('false for missing file', () async {
      expect(await adapter.fileExists(p('missing')), isFalse);
    });

    test('false after deletion', () async {
      await adapter.writeFile(p('foo'), Uint8List(0));
      await adapter.deleteFile(p('foo'));
      expect(await adapter.fileExists(p('foo')), isFalse);
    });
  });

  group('fileSize', () {
    test('returns byte length', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await adapter.fileSize(p('foo')), equals(5));
    });

    test('zero for empty file', () async {
      await adapter.writeFile(p('foo'), Uint8List(0));
      expect(await adapter.fileSize(p('foo')), equals(0));
    });

    test('throws for missing file', () async {
      expect(
        () => adapter.fileSize(p('missing')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('listFiles', () {
    test('returns file names in directory', () async {
      final sub = '${tempDir.path}/sst';
      await adapter.createDirectory(sub);
      await adapter.writeFile('$sub/a.sst', Uint8List(0));
      await adapter.writeFile('$sub/b.sst', Uint8List(0));
      final names = await adapter.listFiles(sub);
      expect(names, containsAll(['a.sst', 'b.sst']));
    });

    test('filters by extension', () async {
      final sub = '${tempDir.path}/sst';
      await adapter.createDirectory(sub);
      await adapter.writeFile('$sub/a.sst', Uint8List(0));
      await adapter.writeFile('$sub/b.log', Uint8List(0));
      final names = await adapter.listFiles(sub, extension: '.sst');
      expect(names, equals(['a.sst']));
    });

    test('does not include files from subdirectories', () async {
      final sub = '${tempDir.path}/sst';
      final deep = '$sub/deep';
      await adapter.createDirectory(deep);
      await adapter.writeFile('$sub/top.sst', Uint8List(0));
      await adapter.writeFile('$deep/nested.sst', Uint8List(0));
      final names = await adapter.listFiles(sub, extension: '.sst');
      expect(names, equals(['top.sst']));
    });

    test('empty list for missing directory', () async {
      expect(await adapter.listFiles(p('nonexistent')), isEmpty);
    });
  });

  group('renameFile', () {
    test('moves content to new path', () async {
      await adapter.writeFile(p('tmp'), Uint8List.fromList([42]));
      await adapter.renameFile(p('tmp'), p('current'));
      expect(await adapter.fileExists(p('tmp')), isFalse);
      expect(await adapter.readFile(p('current')), equals([42]));
    });

    test('throws for missing source', () async {
      expect(
        () => adapter.renameFile(p('missing'), p('dest')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('createDirectory', () {
    test('creates directory and intermediate parents', () async {
      final nested = '${tempDir.path}/a/b/c';
      await adapter.createDirectory(nested);
      expect(await Directory(nested).exists(), isTrue);
    });

    test('is idempotent — no error if directory already exists', () async {
      await adapter.createDirectory(tempDir.path);
      await expectLater(adapter.createDirectory(tempDir.path), completes);
    });
  });

  group('syncFile', () {
    test('completes without error on existing file', () async {
      await adapter.writeFile(p('foo'), Uint8List.fromList([1]));
      await expectLater(adapter.syncFile(p('foo')), completes);
    });

    test('throws StorageException for missing file', () async {
      expect(
        () => adapter.syncFile(p('missing')),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('syncDir', () {
    test('completes without error', () async {
      await expectLater(adapter.syncDir(tempDir.path), completes);
    });
  });

  group('acquireLock / releaseLock', () {
    test('acquires lock successfully', () async {
      await expectLater(adapter.acquireLock(p('LOCK')), completes);
    });

    test('same adapter re-acquiring the same lock is a no-op', () async {
      await adapter.acquireLock(p('LOCK'));
      // _lockHandles already contains the key — must not throw.
      await expectLater(adapter.acquireLock(p('LOCK')), completes);
    });

    test('releaseLock on unheld path is a no-op', () async {
      await expectLater(adapter.releaseLock(p('LOCK')), completes);
    });

    test('lock can be re-acquired by a new adapter after release', () async {
      await adapter.acquireLock(p('LOCK'));
      await adapter.releaseLock(p('LOCK'));
      final adapter2 = StorageAdapterNative();
      await expectLater(adapter2.acquireLock(p('LOCK')), completes);
      await adapter2.releaseLock(p('LOCK'));
    });
  });
}
