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
