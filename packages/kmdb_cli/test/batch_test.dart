import 'dart:async';
import 'package:test/test.dart';
import 'package:kmdb_cli/batch_runner.dart';

void main() {
  group('BatchRunner', () {
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
  });
}
