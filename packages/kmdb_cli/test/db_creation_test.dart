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

/// Library for testing database management functionalities.

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
