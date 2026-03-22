import 'dart:io';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:kmdb_cli/maintenance_manager.dart';

void main() {
  group('MaintenanceManager', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kmdb_maintenance_test_');
      dbPath = p.join(tempDir.path, 'test.db');
      await File(dbPath).create();
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('compact executes successfully', () async {
      final manager = MaintenanceManager();
      // This should not throw
      await manager.compact(dbPath);
    });

    test('checkIntegrity returns true for a valid database', () async {
      final manager = MaintenanceManager();
      final isValid = await manager.checkIntegrity(dbPath);
      expect(isValid, isTrue);
    });

    test('backup creates a backup file', () async {
      final manager = MaintenanceManager();
      final backupPath = p.join(tempDir.path, 'test.db.bak');
      await manager.backup(dbPath, backupPath);
      expect(File(backupPath).existsSync(), isTrue);
    });
  });
}
