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

import 'package:kmdb_schema/schema.dart';
import 'package:test/test.dart';

void main() {
  // ── fromMap ───────────────────────────────────────────────────────────────────

  group('JsonSchemaValidator.fromMap', () {
    test('valid doc passes — no violations returned', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string'},
        },
      });
      final violations = validator.validate({
        'name': 'Alice',
        'email': 'a@b.com',
      });
      expect(violations, isEmpty);
    });

    test('missing required field returns a violation', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['name'],
        'properties': {
          'name': {'type': 'string'},
        },
      });
      final violations = validator.validate({'email': 'a@b.com'});
      expect(violations, isNotEmpty);
      expect(violations.first.path, 'name');
    });

    test('empty schema — everything passes', () {
      final validator = JsonSchemaValidator.fromMap({});
      final violations = validator.validate({'anything': 42});
      expect(violations, isEmpty);
    });

    test('multiple missing required fields — all violations returned', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['name', 'email', 'age'],
      });
      final violations = validator.validate(<String, dynamic>{});
      expect(violations.length, 3);
      final paths = violations.map((v) => v.path).toSet();
      expect(paths, containsAll(['name', 'email', 'age']));
    });

    test('type violation returned', () {
      final validator = JsonSchemaValidator.fromMap({
        'properties': {
          'age': {'type': 'integer'},
        },
      });
      final violations = validator.validate({'age': 'not-a-number'});
      expect(violations, isNotEmpty);
      expect(violations.first.path, 'age');
    });
  });

  // ── fromJson ──────────────────────────────────────────────────────────────────

  group('JsonSchemaValidator.fromJson', () {
    test('valid JSON schema string compiles and validates', () {
      final json = jsonEncode({
        'required': ['title'],
        'properties': {
          'title': {'type': 'string'},
        },
      });
      final validator = JsonSchemaValidator.fromJson(json);
      final violations = validator.validate({'title': 'Hello'});
      expect(violations, isEmpty);
    });

    test('valid JSON schema — missing field produces violation', () {
      final json = jsonEncode({
        'required': ['title'],
      });
      final validator = JsonSchemaValidator.fromJson(json);
      final violations = validator.validate(<String, dynamic>{});
      expect(violations, isNotEmpty);
      expect(violations.first.path, 'title');
    });

    test('malformed JSON throws FormatException', () {
      expect(
        () => JsonSchemaValidator.fromJson('{bad json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('non-object root (array) throws FormatException', () {
      expect(
        () => JsonSchemaValidator.fromJson('[{"type": "string"}]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('JSON object'),
          ),
        ),
      );
    });

    test('non-object root (string scalar) throws FormatException', () {
      expect(
        () => JsonSchemaValidator.fromJson('"just a string"'),
        throwsA(isA<FormatException>()),
      );
    });

    test('non-object root (number) throws FormatException', () {
      expect(
        () => JsonSchemaValidator.fromJson('42'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ── validate — all violations in one pass ────────────────────────────────────

  group('validate — all violations in one pass', () {
    test('returns every violation found, not just the first', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['a', 'b', 'c'],
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'integer'},
          'c': {'type': 'boolean'},
        },
      });
      // All three required fields are missing.
      final violations = validator.validate(<String, dynamic>{});
      expect(violations.length, 3);
    });

    test('violations carry path and message', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['name'],
      });
      final violations = validator.validate(<String, dynamic>{});
      expect(violations.first.path, isNotEmpty);
      expect(violations.first.message, isNotEmpty);
    });

    test('valid document returns empty list', () {
      final validator = JsonSchemaValidator.fromMap({
        'required': ['id'],
        'properties': {
          'id': {'type': 'string'},
        },
      });
      final violations = validator.validate({'id': 'abc'});
      expect(violations, isEmpty);
    });
  });
}
