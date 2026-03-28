import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';

void main() {
  late MemoryStorageAdapter adapter;

  setUp(() {
    adapter = MemoryStorageAdapter();
    MemoryStorageAdapter.releaseAllLocks();
  });

  tearDown(() => MemoryStorageAdapter.releaseAllLocks());

  group('readFile / writeFile', () {
    test('round-trips bytes', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      await adapter.writeFile('/db/foo', data);
      expect(await adapter.readFile('/db/foo'), equals([1, 2, 3]));
    });

    test('writeFile replaces existing content', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([1, 2]));
      await adapter.writeFile('/db/foo', Uint8List.fromList([9]));
      expect(await adapter.readFile('/db/foo'), equals([9]));
    });

    test('readFile throws StorageException for missing file', () async {
      expect(
        () => adapter.readFile('/db/missing'),
        throwsA(isA<StorageException>()),
      );
    });

    test('returned bytes are a copy — mutations do not affect stored data',
        () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([1, 2, 3]));
      final result = await adapter.readFile('/db/foo');
      result[0] = 99;
      expect(await adapter.readFile('/db/foo'), equals([1, 2, 3]));
    });
  });

  group('readFileRange', () {
    test('returns correct slice', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([0, 1, 2, 3, 4]));
      expect(await adapter.readFileRange('/db/foo', 1, 3), equals([1, 2, 3]));
    });

    test('reads from start', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange('/db/foo', 0, 2), equals([10, 20]));
    });

    test('reads to end', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([10, 20, 30]));
      expect(await adapter.readFileRange('/db/foo', 1, 2), equals([20, 30]));
    });

    test('throws on out-of-bounds range', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([1, 2, 3]));
      expect(
        () => adapter.readFileRange('/db/foo', 2, 5),
        throwsA(isA<StorageException>()),
      );
    });

    test('throws for missing file', () async {
      expect(
        () => adapter.readFileRange('/db/missing', 0, 1),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('appendFile', () {
    test('creates file on first append', () async {
      await adapter.appendFile('/db/wal', Uint8List.fromList([1, 2]));
      expect(await adapter.readFile('/db/wal'), equals([1, 2]));
    });

    test('appends to existing content', () async {
      await adapter.appendFile('/db/wal', Uint8List.fromList([1, 2]));
      await adapter.appendFile('/db/wal', Uint8List.fromList([3, 4]));
      expect(await adapter.readFile('/db/wal'), equals([1, 2, 3, 4]));
    });

    test('multiple appends accumulate in order', () async {
      for (var i = 0; i < 5; i++) {
        await adapter.appendFile('/db/wal', Uint8List.fromList([i]));
      }
      expect(await adapter.readFile('/db/wal'), equals([0, 1, 2, 3, 4]));
    });
  });

  group('deleteFile', () {
    test('removes the file', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([1]));
      await adapter.deleteFile('/db/foo');
      expect(await adapter.fileExists('/db/foo'), isFalse);
    });

    test('no-op for missing file', () async {
      await expectLater(adapter.deleteFile('/db/missing'), completes);
    });
  });

  group('fileExists', () {
    test('true for written file', () async {
      await adapter.writeFile('/db/foo', Uint8List(0));
      expect(await adapter.fileExists('/db/foo'), isTrue);
    });

    test('false for missing file', () async {
      expect(await adapter.fileExists('/db/missing'), isFalse);
    });

    test('false after deletion', () async {
      await adapter.writeFile('/db/foo', Uint8List(0));
      await adapter.deleteFile('/db/foo');
      expect(await adapter.fileExists('/db/foo'), isFalse);
    });
  });

  group('fileSize', () {
    test('returns byte length', () async {
      await adapter.writeFile('/db/foo', Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await adapter.fileSize('/db/foo'), equals(5));
    });

    test('zero for empty file', () async {
      await adapter.writeFile('/db/foo', Uint8List(0));
      expect(await adapter.fileSize('/db/foo'), equals(0));
    });

    test('throws for missing file', () async {
      expect(
        () => adapter.fileSize('/db/missing'),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('listFiles', () {
    test('returns file names in directory', () async {
      await adapter.writeFile('/db/sst/a.sst', Uint8List(0));
      await adapter.writeFile('/db/sst/b.sst', Uint8List(0));
      final names = await adapter.listFiles('/db/sst');
      expect(names, containsAll(['a.sst', 'b.sst']));
    });

    test('filters by extension', () async {
      await adapter.writeFile('/db/sst/a.sst', Uint8List(0));
      await adapter.writeFile('/db/sst/b.log', Uint8List(0));
      final names = await adapter.listFiles('/db/sst', extension: '.sst');
      expect(names, equals(['a.sst']));
    });

    test('does not include files from subdirectories', () async {
      await adapter.writeFile('/db/sst/sub/deep.sst', Uint8List(0));
      await adapter.writeFile('/db/sst/top.sst', Uint8List(0));
      final names = await adapter.listFiles('/db/sst');
      expect(names, equals(['top.sst']));
    });

    test('empty list for missing directory', () async {
      expect(await adapter.listFiles('/db/nonexistent'), isEmpty);
    });

    test('works with and without trailing slash on dirPath', () async {
      await adapter.writeFile('/db/sst/a.sst', Uint8List(0));
      expect(await adapter.listFiles('/db/sst'), equals(['a.sst']));
      expect(await adapter.listFiles('/db/sst/'), equals(['a.sst']));
    });
  });

  group('renameFile', () {
    test('moves content to new path', () async {
      await adapter.writeFile('/db/tmp', Uint8List.fromList([42]));
      await adapter.renameFile('/db/tmp', '/db/current');
      expect(await adapter.fileExists('/db/tmp'), isFalse);
      expect(await adapter.readFile('/db/current'), equals([42]));
    });

    test('throws for missing source', () async {
      expect(
        () => adapter.renameFile('/db/missing', '/db/dest'),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('lock / unlock', () {
    test('acquires lock successfully', () async {
      await expectLater(adapter.acquireLock('/db/LOCK'), completes);
    });

    test('second acquire on same path throws LockException', () async {
      await adapter.acquireLock('/db/LOCK');
      final adapter2 = MemoryStorageAdapter();
      expect(
        () => adapter2.acquireLock('/db/LOCK'),
        throwsA(isA<LockException>()),
      );
    });

    test('lock can be re-acquired after release', () async {
      await adapter.acquireLock('/db/LOCK');
      await adapter.releaseLock('/db/LOCK');
      final adapter2 = MemoryStorageAdapter();
      await expectLater(adapter2.acquireLock('/db/LOCK'), completes);
    });

    test('releaseLock on unheld path is a no-op', () async {
      await expectLater(adapter.releaseLock('/db/LOCK'), completes);
    });
  });

  group('syncFile / syncDir / createDirectory', () {
    test('syncFile is a no-op', () async {
      await adapter.writeFile('/db/foo', Uint8List(0));
      await expectLater(adapter.syncFile('/db/foo'), completes);
    });

    test('syncDir is a no-op', () async {
      await expectLater(adapter.syncDir('/db/'), completes);
    });

    test('createDirectory is a no-op', () async {
      await expectLater(adapter.createDirectory('/db/sst/'), completes);
    });
  });
}
