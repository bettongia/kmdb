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
import 'package:kmdb_cli/repl.dart';
import 'package:test/test.dart';

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
