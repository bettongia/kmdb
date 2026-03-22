/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

/// Tests for the [MaintenanceManager] class.
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
