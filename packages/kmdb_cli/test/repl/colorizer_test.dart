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

import 'package:kmdb_cli/src/repl/colorizer.dart';
import 'package:test/test.dart';

void main() {
  group('Colorizer disabled', () {
    late Colorizer c;

    setUp(() => c = Colorizer(enabled: false));

    test('error returns text unchanged', () {
      expect(c.error('oops'), 'oops');
    });

    test('field returns text unchanged', () {
      expect(c.field('name'), 'name');
    });

    test('muted returns text unchanged', () {
      expect(c.muted('(1 ms)'), '(1 ms)');
    });

    test('bold returns text unchanged', () {
      expect(c.bold('Title'), 'Title');
    });

    test('info returns text unchanged', () {
      expect(c.info('hint'), 'hint');
    });

    test('success returns text unchanged', () {
      expect(c.success('ok'), 'ok');
    });
  });

  group('Colorizer enabled', () {
    late Colorizer c;

    setUp(() => c = Colorizer(enabled: true));

    test('error wraps with ANSI red', () {
      final result = c.error('oops');
      expect(result, startsWith('\x1b[31m'));
      expect(result, endsWith('\x1b[0m'));
      expect(result, contains('oops'));
    });

    test('field wraps with ANSI yellow', () {
      final result = c.field('name');
      expect(result, startsWith('\x1b[33m'));
      expect(result, endsWith('\x1b[0m'));
      expect(result, contains('name'));
    });

    test('muted wraps with ANSI dim', () {
      final result = c.muted('(1 ms)');
      expect(result, startsWith('\x1b[2m'));
      expect(result, endsWith('\x1b[0m'));
    });

    test('bold wraps with ANSI bold', () {
      final result = c.bold('Title');
      expect(result, startsWith('\x1b[1m'));
      expect(result, endsWith('\x1b[0m'));
    });

    test('info wraps with ANSI cyan', () {
      final result = c.info('hint');
      expect(result, startsWith('\x1b[36m'));
      expect(result, endsWith('\x1b[0m'));
    });

    test('success wraps with ANSI green', () {
      final result = c.success('ok');
      expect(result, startsWith('\x1b[32m'));
      expect(result, endsWith('\x1b[0m'));
    });
  });
}
