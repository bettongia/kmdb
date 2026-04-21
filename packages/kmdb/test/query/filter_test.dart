// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:kmdb/src/query/filter/field_filter.dart';
import 'package:kmdb/src/query/filter/filter.dart';
import 'package:test/test.dart';

void main() {
  // ── Equality & comparison ────────────────────────────────────────────────────

  group('Field.equals', () {
    test('matches exact value', () {
      expect(Field('x').equals(42).evaluate({'x': 42}), isTrue);
    });
    test('does not match different value', () {
      expect(Field('x').equals(42).evaluate({'x': 43}), isFalse);
    });
    test('does not match missing field', () {
      expect(Field('x').equals(42).evaluate({}), isFalse);
    });
    test('numeric coercion: int 1 == double 1.0', () {
      expect(Field('x').equals(1).evaluate({'x': 1.0}), isTrue);
      expect(Field('x').equals(1.0).evaluate({'x': 1}), isTrue);
    });
    test('matches null explicitly', () {
      expect(Field('x').equals(null).evaluate({'x': null}), isTrue);
    });
    test('does not match null against non-null', () {
      expect(Field('x').equals(null).evaluate({'x': 0}), isFalse);
    });
  });

  group('Field.notEquals', () {
    test('matches different value', () {
      expect(Field('x').notEquals(1).evaluate({'x': 2}), isTrue);
    });
    test('does not match equal value', () {
      expect(Field('x').notEquals(1).evaluate({'x': 1}), isFalse);
    });
    test('missing field is not equal to anything', () {
      expect(Field('x').notEquals(1).evaluate({}), isTrue);
    });
  });

  group('comparison operators', () {
    final doc = {'score': 5};
    test('isGreaterThan', () {
      expect(Field('score').isGreaterThan(4).evaluate(doc), isTrue);
      expect(Field('score').isGreaterThan(5).evaluate(doc), isFalse);
    });
    test('isLessThan', () {
      expect(Field('score').isLessThan(6).evaluate(doc), isTrue);
      expect(Field('score').isLessThan(5).evaluate(doc), isFalse);
    });
    test('isGreaterThanOrEqualTo', () {
      expect(Field('score').isGreaterThanOrEqualTo(5).evaluate(doc), isTrue);
      expect(Field('score').isGreaterThanOrEqualTo(6).evaluate(doc), isFalse);
    });
    test('isLessThanOrEqualTo', () {
      expect(Field('score').isLessThanOrEqualTo(5).evaluate(doc), isTrue);
      expect(Field('score').isLessThanOrEqualTo(4).evaluate(doc), isFalse);
    });
    test('isBetween inclusive', () {
      expect(Field('score').isBetween(3, 7).evaluate(doc), isTrue);
      expect(Field('score').isBetween(5, 5).evaluate(doc), isTrue);
      expect(Field('score').isBetween(6, 10).evaluate(doc), isFalse);
    });
    test('missing field returns false for comparisons', () {
      expect(Field('x').isGreaterThan(0).evaluate({}), isFalse);
    });
    test('string comparison', () {
      expect(
        Field('name').isGreaterThan('alice').evaluate({'name': 'bob'}),
        isTrue,
      );
    });
  });

  // ── Set membership ────────────────────────────────────────────────────────────

  group('Field.isIn / isNotIn', () {
    test('isIn matches when value is in list', () {
      expect(Field('x').isIn([1, 2, 3]).evaluate({'x': 2}), isTrue);
    });
    test('isIn does not match when value is absent', () {
      expect(Field('x').isIn([1, 2, 3]).evaluate({'x': 4}), isFalse);
    });
    test('isIn returns false for missing field', () {
      expect(Field('x').isIn([1, 2]).evaluate({}), isFalse);
    });
    test('isNotIn matches when value is not in list', () {
      expect(Field('x').isNotIn([1, 2]).evaluate({'x': 3}), isTrue);
    });
    test('isNotIn returns true for missing field', () {
      expect(Field('x').isNotIn([1]).evaluate({}), isTrue);
    });
  });

  // ── Null / existence ──────────────────────────────────────────────────────────

  group('isNull / isNotNull', () {
    test('isNull matches missing field', () {
      expect(Field('x').isNull().evaluate({}), isTrue);
    });
    test('isNull matches explicit null', () {
      expect(Field('x').isNull().evaluate({'x': null}), isTrue);
    });
    test('isNull does not match non-null value', () {
      expect(Field('x').isNull().evaluate({'x': 0}), isFalse);
    });
    test('isNotNull matches present non-null value', () {
      expect(Field('x').isNotNull().evaluate({'x': 1}), isTrue);
    });
    test('isNotNull does not match missing field', () {
      expect(Field('x').isNotNull().evaluate({}), isFalse);
    });
    test('isNotNull does not match explicit null', () {
      expect(Field('x').isNotNull().evaluate({'x': null}), isFalse);
    });
  });

  // ── Boolean ───────────────────────────────────────────────────────────────────

  group('isTrue / isFalse', () {
    test('isTrue', () {
      expect(Field('active').isTrue().evaluate({'active': true}), isTrue);
      expect(Field('active').isTrue().evaluate({'active': false}), isFalse);
      expect(Field('active').isTrue().evaluate({'active': 1}), isFalse);
    });
    test('isFalse', () {
      expect(Field('deleted').isFalse().evaluate({'deleted': false}), isTrue);
      expect(Field('deleted').isFalse().evaluate({'deleted': true}), isFalse);
    });
  });

  // ── String operations ─────────────────────────────────────────────────────────

  group('String filters', () {
    final doc = {'title': 'Project Alpha'};
    test('startsWith', () {
      expect(Field('title').startsWith('Project').evaluate(doc), isTrue);
      expect(Field('title').startsWith('Alpha').evaluate(doc), isFalse);
    });
    test('endsWith', () {
      expect(Field('title').endsWith('Alpha').evaluate(doc), isTrue);
      expect(Field('title').endsWith('Project').evaluate(doc), isFalse);
    });
    test('contains (substring)', () {
      expect(Field('title').contains('ject').evaluate(doc), isTrue);
      expect(Field('title').contains('Beta').evaluate(doc), isFalse);
    });
    test('returns false for non-string fields', () {
      expect(Field('x').startsWith('a').evaluate({'x': 42}), isFalse);
    });
  });

  // ── Array operations ──────────────────────────────────────────────────────────

  group('Array filters', () {
    final doc = {
      'tags': ['dart', 'flutter', 'mobile'],
    };
    test('contains (array element)', () {
      expect(Field('tags').contains('dart').evaluate(doc), isTrue);
      expect(Field('tags').contains('web').evaluate(doc), isFalse);
    });
    test('containsAll', () {
      expect(
        Field('tags').containsAll(['dart', 'flutter']).evaluate(doc),
        isTrue,
      );
      expect(Field('tags').containsAll(['dart', 'web']).evaluate(doc), isFalse);
    });
    test('containsAny', () {
      expect(
        Field('tags').containsAny(['web', 'flutter']).evaluate(doc),
        isTrue,
      );
      expect(Field('tags').containsAny(['web', 'ios']).evaluate(doc), isFalse);
    });
    test('returns false for non-list field', () {
      expect(Field('x').containsAll(['a']).evaluate({'x': 'a'}), isFalse);
    });
  });

  // ── Composition ───────────────────────────────────────────────────────────────

  group('Filter.and', () {
    test('matches when all filters match', () {
      final f = Filter.and([Field('a').equals(1), Field('b').equals(2)]);
      expect(f.evaluate({'a': 1, 'b': 2}), isTrue);
    });
    test('does not match if any filter fails', () {
      final f = Filter.and([Field('a').equals(1), Field('b').equals(99)]);
      expect(f.evaluate({'a': 1, 'b': 2}), isFalse);
    });
    test('empty list matches everything', () {
      expect(Filter.and([]).evaluate({'x': 1}), isTrue);
    });
    test('short-circuits on first failure', () {
      var evaluated = 0;
      // Use a custom filter that counts evaluations
      final counter = _CountingFilter(() {
        evaluated++;
        return false;
      });
      Filter.and([counter, counter]).evaluate({});
      expect(evaluated, equals(1));
    });
  });

  group('Filter.or', () {
    test('matches when any filter matches', () {
      final f = Filter.or([Field('x').equals(1), Field('x').equals(2)]);
      expect(f.evaluate({'x': 2}), isTrue);
    });
    test('does not match if no filter matches', () {
      final f = Filter.or([Field('x').equals(1), Field('x').equals(2)]);
      expect(f.evaluate({'x': 3}), isFalse);
    });
    test('empty list never matches', () {
      expect(Filter.or([]).evaluate({'x': 1}), isFalse);
    });
  });

  group('Filter.not', () {
    test('inverts a matching filter', () {
      expect(Filter.not(Field('x').equals(1)).evaluate({'x': 1}), isFalse);
    });
    test('inverts a non-matching filter', () {
      expect(Filter.not(Field('x').equals(1)).evaluate({'x': 2}), isTrue);
    });
  });

  group('nested composition', () {
    test('and/or nesting', () {
      final f = Filter.and([
        Field('status').equals('active'),
        Filter.or([
          Field('priority').isGreaterThan(3),
          Field('dueDate').isNotNull(),
        ]),
      ]);
      expect(
        f.evaluate({'status': 'active', 'priority': 5, 'dueDate': null}),
        isTrue,
      );
      expect(
        f.evaluate({
          'status': 'active',
          'priority': 1,
          'dueDate': '2026-01-01',
        }),
        isTrue,
      );
      expect(f.evaluate({'status': 'active', 'priority': 1}), isFalse);
      expect(f.evaluate({'status': 'archived', 'priority': 5}), isFalse);
    });
  });

  // ── equalityPredicate ──────────────────────────────────────────────────────

  group('equalityPredicate', () {
    test('returns (path, value) for equals filter', () {
      final f = Field('name').equals('Alice');
      expect(f.equalityPredicate, equals(('name', 'Alice')));
    });
    test('returns (path, null) for equals(null)', () {
      final f = Field('x').equals(null);
      expect(f.equalityPredicate, equals(('x', null)));
    });
    test('returns null for isGreaterThan', () {
      expect(Field('x').isGreaterThan(1).equalityPredicate, isNull);
    });
    test('returns null for isLessThan', () {
      expect(Field('x').isLessThan(1).equalityPredicate, isNull);
    });
    test('returns null for contains', () {
      expect(Field('x').contains('a').equalityPredicate, isNull);
    });
    test('returns null for notEquals', () {
      expect(Field('x').notEquals(1).equalityPredicate, isNull);
    });
    test('AndFilter returns null', () {
      final f = Filter.and([Field('x').equals(1), Field('y').equals(2)]);
      expect(f.equalityPredicate, isNull);
    });
    test('OrFilter returns null', () {
      final f = Filter.or([Field('x').equals(1)]);
      expect(f.equalityPredicate, isNull);
    });
    test('NotFilter returns null', () {
      final f = Filter.not(Field('x').equals(1));
      expect(f.equalityPredicate, isNull);
    });
  });
}

// ── Helpers ────────────────────────────────────────────────────────────────────

final class _CountingFilter extends Filter {
  _CountingFilter(this._fn);
  final bool Function() _fn;

  @override
  bool evaluate(Map<String, dynamic> document) => _fn();
}
