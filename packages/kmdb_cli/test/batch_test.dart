import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:kmdb_cli/batch_runner.dart';

void main() {
  group('BatchRunner', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kmdb_batch_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('processes a stream of commands from stdin', () async {
      final inputStream = Stream.fromIterable(['list-dbs', 'compact']);
      final output = <String>[];
      
      final runner = BatchRunner(onLine: output.add);
      await runner.run(inputStream);

      expect(output, contains('Executing: list-dbs'));
      expect(output, contains('Executing: compact'));
    });

    test('ignores empty lines', () async {
      final inputStream = Stream.fromIterable(['list-dbs', '', 'compact']);
      final output = <String>[];

      final runner = BatchRunner(onLine: output.add);
      await runner.run(inputStream);

      expect(output.length, equals(2));
    });

    test('processes commands from a script file', () async {
      final scriptPath = p.join(tempDir.path, 'script.kmd');
      await File(scriptPath).writeAsString('''
list-dbs
compact
''');
      
      final output = <String>[];
      final runner = BatchRunner(onLine: output.add);
      await runner.runFromFile(scriptPath);

      expect(output, contains('Executing: list-dbs'));
      expect(output, contains('Executing: compact'));
    });
  });
}
