import 'package:test/test.dart';
import 'package:kmdb_cli/arg_parser.dart';

void main() {
  group('CommandLineParser', () {
    test('parses database path positional argument', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db']);
      expect(result.dbPath, equals('mydb.db'));
    });

    test('parses --file option', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db', '--file', 'script.kmd']);
      expect(result.scriptFile, equals('script.kmd'));
    });

    test('identifies interactive mode when no commands or file provided', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db']);
      expect(result.isInteractive, isTrue);
    });

    test('identifies batch mode when file is provided', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db', '--file', 'script.kmd']);
      expect(result.isInteractive, isFalse);
    });
  });
}
