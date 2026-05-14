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

import 'dart:convert';

import 'package:kmdb_cli/src/output/document_formatter.dart';
import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:test/test.dart';

void main() {
  final docs = [
    {'id': 'aaa', 'name': 'Alice', 'score': 10},
    {'id': 'bbb', 'name': 'Bob', 'score': 20},
  ];

  String capture(OutputMode mode) {
    final buf = StringBuffer();
    DocumentFormatter.format(docs, mode, sink: buf);
    return buf.toString();
  }

  group('DocumentFormatter — json', () {
    test('produces a JSON array', () {
      final out = capture(OutputMode.json);
      final decoded = json.decode(out);
      expect(decoded, isA<List>());
      expect(decoded, hasLength(2));
      expect(decoded[0]['name'], equals('Alice'));
    });

    test('is indented', () {
      final out = capture(OutputMode.json);
      expect(out, contains('\n  '));
    });
  });

  group('DocumentFormatter — compact', () {
    test('produces a single-line JSON array', () {
      final out = capture(OutputMode.compact).trim();
      expect(out.contains('\n'), isFalse);
      final decoded = json.decode(out);
      expect(decoded, hasLength(2));
    });
  });

  group('DocumentFormatter — ndjson', () {
    test('produces one JSON object per line', () {
      final out = capture(OutputMode.ndjson);
      final lines = out.trim().split('\n');
      expect(lines, hasLength(2));
      expect(json.decode(lines[0])['name'], equals('Alice'));
      expect(json.decode(lines[1])['name'], equals('Bob'));
    });
  });

  group('DocumentFormatter — table', () {
    test('includes header row', () {
      final out = capture(OutputMode.table);
      expect(out, contains('id'));
      expect(out, contains('name'));
      expect(out, contains('score'));
    });

    test('includes data values', () {
      final out = capture(OutputMode.table);
      expect(out, contains('Alice'));
      expect(out, contains('Bob'));
    });

    test('prints (no results) for empty list', () {
      final buf = StringBuffer();
      DocumentFormatter.format([], OutputMode.table, sink: buf);
      expect(buf.toString(), contains('(no results)'));
    });
  });

  group('DocumentFormatter — csv', () {
    test('produces header and data rows', () {
      final out = capture(OutputMode.csv);
      final lines = out.trim().split('\n');
      expect(lines.length, greaterThanOrEqualTo(3)); // header + 2 data
      expect(lines[0], contains('id'));
      expect(lines[0], contains('name'));
    });

    test('escapes commas in values', () {
      final buf = StringBuffer();
      DocumentFormatter.format(
        [
          {'id': 'x', 'note': 'hello, world'},
        ],
        OutputMode.csv,
        sink: buf,
      );
      expect(buf.toString(), contains('"hello, world"'));
    });

    test('escapes double-quotes in values', () {
      final buf = StringBuffer();
      DocumentFormatter.format(
        [
          {'id': 'x', 'note': 'say "hi"'},
        ],
        OutputMode.csv,
        sink: buf,
      );
      expect(buf.toString(), contains('"say ""hi"""'));
    });

    test('produces no output for empty list', () {
      final buf = StringBuffer();
      DocumentFormatter.format([], OutputMode.csv, sink: buf);
      expect(buf.toString(), isEmpty);
    });
  });

  group('DocumentFormatter — line', () {
    test('produces field = value lines', () {
      final out = capture(OutputMode.line);
      expect(out, contains('name = Alice'));
      expect(out, contains('score = 10'));
    });

    test('separates documents with blank line', () {
      final out = capture(OutputMode.line);
      // Two docs → one blank line between them.
      expect(out, contains('\n\n'));
    });
  });

  group('OutputMode.fromString', () {
    for (final name in ['json', 'compact', 'ndjson', 'table', 'csv', 'line']) {
      test('parses "$name"', () {
        expect(() => OutputMode.fromString(name), returnsNormally);
      });
    }

    test('is case-insensitive', () {
      expect(OutputMode.fromString('JSON'), equals(OutputMode.json));
      expect(OutputMode.fromString('Table'), equals(OutputMode.table));
    });

    test('throws ArgumentError for unknown mode', () {
      expect(() => OutputMode.fromString('xml'), throwsA(isA<ArgumentError>()));
    });
  });
}
