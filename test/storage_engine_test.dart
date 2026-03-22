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
  });
}
