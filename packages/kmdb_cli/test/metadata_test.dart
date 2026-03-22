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
