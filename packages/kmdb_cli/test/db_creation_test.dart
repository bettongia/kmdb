import 'dart:io';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:kmdb_cli/db_manager.dart';

void main() {
  group('DatabaseManager', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kmdb_cli_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('creates database file if it does not exist', () async {
      final dbPath = p.join(tempDir.path, 'new_db.db');
      final manager = DatabaseManager();
      
      expect(File(dbPath).existsSync(), isFalse);
      
      await manager.ensureDatabaseExists(dbPath);
      
      expect(File(dbPath).existsSync(), isTrue);
    });

    test('does not overwrite existing database file', () async {
      final dbPath = p.join(tempDir.path, 'existing_db.db');
      final file = File(dbPath);
      await file.writeAsString('existing content');
      
      final manager = DatabaseManager();
      await manager.ensureDatabaseExists(dbPath);
      
      expect(await file.readAsString(), equals('existing content'));
    });
  });
}
