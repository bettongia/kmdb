import 'dart:io';
import 'dart:typed_data';
import 'package:kmdb/src/storage_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('StorageEngine', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kmdb_test_');
      dbPath = p.join(tempDir.path, 'test.db');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('put and get a simple value', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('key1'.codeUnits);
      final value = Uint8List.fromList('value1'.codeUnits);

      await engine.put(key, value);
      final result = await engine.get(key);

      expect(result, equals(value));
      await engine.close();
    });

    test('persists data between sessions', () async {
      final key = Uint8List.fromList('persist_key'.codeUnits);
      final value = Uint8List.fromList('persist_value'.codeUnits);

      // Session 1: Put
      final engine1 = StorageEngine(dbPath);
      await engine1.open();
      await engine1.put(key, value);
      await engine1.close();

      // Session 2: Get
      final engine2 = StorageEngine(dbPath);
      await engine2.open();
      final result = await engine2.get(key);

      expect(result, equals(value));
      await engine2.close();
    });

    test('updates an existing key', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('key1'.codeUnits);
      final value1 = Uint8List.fromList('value1'.codeUnits);
      final value2 = Uint8List.fromList('value2'.codeUnits);

      await engine.put(key, value1);
      await engine.put(key, value2);

      final result = await engine.get(key);
      expect(result, equals(value2));
      await engine.close();
    });

    test('returns null for non-existent key', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('non_existent'.codeUnits);
      final result = await engine.get(key);

      expect(result, isNull);
      await engine.close();
    });

    test('retrieves keys in lexicographical order', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final keys = [
        'c',
        'a',
        'b',
      ].map((k) => Uint8List.fromList(k.codeUnits)).toList();
      for (final key in keys) {
        await engine.put(key, key); // value same as key for simplicity
      }

      final result = await engine.getAll();
      final resultKeys = result
          .map((e) => String.fromCharCodes(e.key))
          .toList();

      expect(resultKeys, equals(['a', 'b', 'c']));
      await engine.close();
    });

    test('performs range queries', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final keys = [
        'a',
        'b',
        'c',
        'd',
        'e',
      ].map((k) => Uint8List.fromList(k.codeUnits)).toList();
      for (final key in keys) {
        await engine.put(key, key);
      }

      // Range [b, d]
      final start = Uint8List.fromList('b'.codeUnits);
      final end = Uint8List.fromList('d'.codeUnits);
      final result = await engine.getRange(start, end);

      final resultKeys = result
          .map((e) => String.fromCharCodes(e.key))
          .toList();
      expect(resultKeys, equals(['b', 'c', 'd']));
      await engine.close();
    });

    test('atomic persistence - data is durable after put', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('atomic_key'.codeUnits);
      final value = Uint8List.fromList('atomic_value'.codeUnits);

      await engine.put(key, value);

      // Simulate "crash" by not closing the engine properly and opening a new one
      // The data should still be there because put() should be durable
      final engine2 = StorageEngine(dbPath);
      await engine2.open();
      final result = await engine2.get(key);

      expect(result, equals(value));
      await engine2.close();
    });

    test('compact() cleans up duplicate entries on disk', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('key1'.codeUnits);
      await engine.put(key, Uint8List.fromList('v1'.codeUnits));
      await engine.put(key, Uint8List.fromList('v2'.codeUnits));

      final sizeBefore = await File(dbPath).length();
      await engine.compact();
      final sizeAfter = await File(dbPath).length();

      expect(sizeAfter, lessThan(sizeBefore));

      final result = await engine.get(key);
      expect(result, equals(Uint8List.fromList('v2'.codeUnits)));

      await engine.close();
    });

    test('corruption detection - ignores corrupted entries', () async {
      final engine = StorageEngine(dbPath);
      await engine.open();

      final key = Uint8List.fromList('safe_key'.codeUnits);
      await engine.put(key, Uint8List.fromList('safe_value'.codeUnits));
      await engine.close();

      // Manually corrupt the file by flipping a bit in the data
      final file = File(dbPath);
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 0xFF;
      await file.writeAsBytes(bytes);

      final engine2 = StorageEngine(dbPath);
      await engine2.open();
      // The corrupted entry should be ignored
      final result = await engine2.get(key);
      expect(result, isNull);
      await engine2.close();
    });
  });
}
