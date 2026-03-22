import 'package:test/test.dart';
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

    test('parses list-dbs subcommand', () {
      final parser = CommandLineParser();
      final result = parser.parse(['list-dbs']);
      expect(result.subcommand, equals('list-dbs'));
    });

    test('parses list-namespaces subcommand', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db', 'list-namespaces']);
      expect(result.subcommand, equals('list-namespaces'));
    });

    test('parses list-indexes subcommand', () {
      final parser = CommandLineParser();
      final result = parser.parse(['mydb.db', 'list-indexes']);
      expect(result.subcommand, equals('list-indexes'));
    });
  });
}
