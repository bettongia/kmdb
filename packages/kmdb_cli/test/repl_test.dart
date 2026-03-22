import 'dart:async';
import 'package:test/test.dart';
import 'package:kmdb_cli/repl.dart';

void main() {
  group('REPL', () {
    test('processes a single command', () async {
      final inputStream = Stream.value('list-dbs');
      final output = <String>[];
      
      final repl = REPL(onLine: output.add);
      await repl.run(inputStream);

      expect(output, contains('Processing: list-dbs'));
    });

    test('exits on "exit" command', () async {
      final inputStream = Stream.fromIterable(['list-dbs', 'exit']);
      final output = <String>[];

      final repl = REPL(onLine: output.add);
      await repl.run(inputStream);

      expect(output, contains('Processing: list-dbs'));
      expect(output, isNot(contains('Processing: exit')));
      expect(output, contains('Exiting.'));
    });
  });
}
