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
import 'package:test/test.dart';
import 'package:kmdb_cli/metadata_manager.dart';

void main() {
  group('MetadataManager', () {
    test('listDatabases returns current database path', () async {
      final manager = MetadataManager();
      final dbs = await manager.listDatabases('mydb.db');
      expect(dbs, contains('mydb.db'));
    });

    test('listNamespaces returns a list of namespaces', () async {
      final manager = MetadataManager();
      final namespaces = await manager.listNamespaces('mydb.db');
      // For now, it might be empty or have a default
      expect(namespaces, isA<List<String>>());
    });

    test('listIndexes returns a list of indexes', () async {
      final manager = MetadataManager();
      final indexes = await manager.listIndexes('mydb.db');
      expect(indexes, isA<List<String>>());
    });
  });
}
