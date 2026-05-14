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

import 'package:kmdb_cli/src/filter/filter_parser.dart';
import 'package:test/test.dart';

void main() {
  group('FilterParser', () {
    final doc = {
      'status': 'active',
      'score': 42,
      'city': 'London',
      'tags': ['dart', 'flutter'],
      'address': {'city': 'London'},
    };

    // ── Field comparisons ──────────────────────────────────────────────────

    test('eq matches equal value', () {
      final f = FilterParser.parse(
        '{"field":"status","op":"eq","value":"active"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('eq does not match unequal value', () {
      final f = FilterParser.parse(
        '{"field":"status","op":"eq","value":"inactive"}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('ne matches unequal value', () {
      final f = FilterParser.parse(
        '{"field":"status","op":"ne","value":"inactive"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('gt matches greater value', () {
      final f = FilterParser.parse('{"field":"score","op":"gt","value":10}');
      expect(f.evaluate(doc), isTrue);
    });

    test('gt does not match when equal', () {
      final f = FilterParser.parse('{"field":"score","op":"gt","value":42}');
      expect(f.evaluate(doc), isFalse);
    });

    test('gte matches equal value', () {
      final f = FilterParser.parse('{"field":"score","op":"gte","value":42}');
      expect(f.evaluate(doc), isTrue);
    });

    test('lt matches lesser value', () {
      final f = FilterParser.parse('{"field":"score","op":"lt","value":100}');
      expect(f.evaluate(doc), isTrue);
    });

    test('lte matches equal value', () {
      final f = FilterParser.parse('{"field":"score","op":"lte","value":42}');
      expect(f.evaluate(doc), isTrue);
    });

    test('between matches value in range', () {
      final f = FilterParser.parse(
        '{"field":"score","op":"between","value":[1,100]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('between does not match value outside range', () {
      final f = FilterParser.parse(
        '{"field":"score","op":"between","value":[50,100]}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    // ── Set membership ─────────────────────────────────────────────────────

    test('in matches value in list', () {
      final f = FilterParser.parse(
        '{"field":"status","op":"in","value":["active","pending"]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('notIn matches value not in list', () {
      final f = FilterParser.parse(
        '{"field":"status","op":"notIn","value":["inactive","pending"]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    // ── Null / existence ───────────────────────────────────────────────────

    test('isNull matches absent field', () {
      final f = FilterParser.parse('{"field":"missing","op":"isNull"}');
      expect(f.evaluate(doc), isTrue);
    });

    test('isNotNull matches present field', () {
      final f = FilterParser.parse('{"field":"status","op":"isNotNull"}');
      expect(f.evaluate(doc), isTrue);
    });

    test('isTrue matches true field', () {
      final f = FilterParser.parse('{"field":"active","op":"isTrue"}');
      expect(f.evaluate({'active': true}), isTrue);
      expect(f.evaluate({'active': false}), isFalse);
    });

    test('isFalse matches false field', () {
      final f = FilterParser.parse('{"field":"active","op":"isFalse"}');
      expect(f.evaluate({'active': false}), isTrue);
    });

    // ── String ops ─────────────────────────────────────────────────────────

    test('startsWith matches prefix', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"startsWith","value":"Lon"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    // ── Case-insensitive string ops ────────────────────────────────────────

    test('eq with insensitive:true matches different case', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"eq","value":"london","insensitive":true}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('eq with insensitive:true does not match wrong value', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"eq","value":"paris","insensitive":true}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('eq without insensitive flag is case-sensitive', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"eq","value":"london"}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('startsWith with insensitive:true matches different case', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"startsWith","value":"LON","insensitive":true}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('endsWith with insensitive:true matches different case', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"endsWith","value":"DON","insensitive":true}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('contains with insensitive:true matches different case', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"contains","value":"OND","insensitive":true}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('insensitive:false is the same as omitting the key', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"startsWith","value":"LON","insensitive":false}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('endsWith matches suffix', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"endsWith","value":"don"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('contains matches substring', () {
      final f = FilterParser.parse(
        '{"field":"city","op":"contains","value":"ond"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    // ── Array ops ──────────────────────────────────────────────────────────

    test('containsAll matches all elements present', () {
      final f = FilterParser.parse(
        '{"field":"tags","op":"containsAll","value":["dart","flutter"]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('containsAll fails if one element missing', () {
      final f = FilterParser.parse(
        '{"field":"tags","op":"containsAll","value":["dart","java"]}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('containsAny matches any element present', () {
      final f = FilterParser.parse(
        '{"field":"tags","op":"containsAny","value":["java","dart"]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    // ── Logical combinators ────────────────────────────────────────────────

    test('and matches when all sub-filters match', () {
      final f = FilterParser.parse(
        '{"and":[{"field":"status","op":"eq","value":"active"},{"field":"score","op":"gt","value":10}]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('and fails when one sub-filter fails', () {
      final f = FilterParser.parse(
        '{"and":[{"field":"status","op":"eq","value":"active"},{"field":"score","op":"gt","value":100}]}',
      );
      expect(f.evaluate(doc), isFalse);
    });

    test('or matches when at least one sub-filter matches', () {
      final f = FilterParser.parse(
        '{"or":[{"field":"status","op":"eq","value":"inactive"},{"field":"score","op":"eq","value":42}]}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    test('not inverts the filter', () {
      final f = FilterParser.parse(
        '{"not":{"field":"status","op":"eq","value":"active"}}',
      );
      expect(f.evaluate(doc), isFalse);
      expect(f.evaluate({'status': 'inactive'}), isTrue);
    });

    // ── Nested dot-path ────────────────────────────────────────────────────

    test('nested dot-path resolves correctly', () {
      final f = FilterParser.parse(
        '{"field":"address.city","op":"eq","value":"London"}',
      );
      expect(f.evaluate(doc), isTrue);
    });

    // ── Error cases ────────────────────────────────────────────────────────

    test('unknown operator throws ArgumentError', () {
      expect(
        () => FilterParser.parse('{"field":"x","op":"regex","value":".*"}'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invalid JSON throws FormatException', () {
      expect(
        () => FilterParser.parse('{bad json}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing field+op keys throws ArgumentError', () {
      expect(
        () => FilterParser.parse('{"foo":"bar"}'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('between requires exactly 2 elements', () {
      expect(
        () => FilterParser.parse(
          '{"field":"score","op":"between","value":[1,2,3]}',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
