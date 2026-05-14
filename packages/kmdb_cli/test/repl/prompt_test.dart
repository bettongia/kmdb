// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:kmdb_cli/src/repl/prompt.dart';
import 'package:test/test.dart';

void main() {
  group('Prompt.build', () {
    test('default prompt without collection', () {
      expect(Prompt.build(dbName: 'mydb'), 'kmdb[mydb]> ');
    });

    test('prompt with active collection', () {
      expect(
        Prompt.build(dbName: 'mydb', collection: 'notes'),
        'kmdb[mydb:notes]> ',
      );
    });

    test('empty collection treated as no collection', () {
      expect(Prompt.build(dbName: 'mydb', collection: ''), 'kmdb[mydb]> ');
    });
  });

  group('Prompt.dbNameFrom', () {
    test('strips .kmdb extension', () {
      expect(Prompt.dbNameFrom('/data/mydb.kmdb'), 'mydb');
    });

    test('returns last path component without extension', () {
      expect(Prompt.dbNameFrom('/home/user/project/notes.kmdb'), 'notes');
    });

    test('no extension: returns last component', () {
      expect(Prompt.dbNameFrom('/data/mydb'), 'mydb');
    });

    test('bare name returns as-is', () {
      expect(Prompt.dbNameFrom('mydb'), 'mydb');
    });
  });

  group('Prompt.continuation', () {
    test('is the expected string', () {
      expect(Prompt.continuation, '   ...> ');
    });
  });
}
