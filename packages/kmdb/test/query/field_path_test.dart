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

import 'package:kmdb/src/query/filter/field_path.dart';
import 'package:test/test.dart';

void main() {
  // ── Top-level fields ──────────────────────────────────────────────────────────

  group('top-level field', () {
    test('resolves present string field', () {
      expect(FieldPath.resolve('city', {'city': 'London'}), equals('London'));
    });
    test('resolves present int field', () {
      expect(FieldPath.resolve('count', {'count': 42}), equals(42));
    });
    test('returns missing for absent field', () {
      expect(FieldPath.resolve('city', {}), equals(missing));
    });
    test('returns explicit null (not missing)', () {
      expect(FieldPath.resolve('city', {'city': null}), isNull);
    });
  });

  // ── Nested fields ─────────────────────────────────────────────────────────────

  group('nested field (dot notation)', () {
    test('resolves one level deep', () {
      expect(
        FieldPath.resolve('address.city', {
          'address': <String, dynamic>{'city': 'Paris'},
        }),
        equals('Paris'),
      );
    });
    test('resolves two levels deep', () {
      expect(
        FieldPath.resolve('meta.stats.views', {
          'meta': <String, dynamic>{
            'stats': <String, dynamic>{'views': 100},
          },
        }),
        equals(100),
      );
    });
    test('returns missing when intermediate is absent', () {
      expect(FieldPath.resolve('address.city', {}), equals(missing));
    });
    test('returns missing when intermediate is not a map', () {
      expect(
        FieldPath.resolve('address.city', {'address': 'flat'}),
        equals(missing),
      );
    });
  });

  // ── Array index access ────────────────────────────────────────────────────────

  group('array index access', () {
    test('resolves specific index', () {
      expect(
        FieldPath.resolve('tags[0]', {
          'tags': ['dart', 'flutter'],
        }),
        equals('dart'),
      );
    });
    test('resolves index 1', () {
      expect(
        FieldPath.resolve('tags[1]', {
          'tags': ['dart', 'flutter'],
        }),
        equals('flutter'),
      );
    });
    test('returns missing for out-of-bounds index', () {
      expect(
        FieldPath.resolve('tags[5]', {
          'tags': ['dart'],
        }),
        equals(missing),
      );
    });
    test('returns missing when field is not an array', () {
      expect(FieldPath.resolve('x[0]', {'x': 'hello'}), equals(missing));
    });
    test('returns missing when array field absent', () {
      expect(FieldPath.resolve('tags[0]', {}), equals(missing));
    });
  });

  // ── Array fan-out ─────────────────────────────────────────────────────────────

  group('array fan-out ([])', () {
    test('returns all elements as a List', () {
      expect(
        FieldPath.resolve('tags[]', {
          'tags': ['dart', 'flutter'],
        }),
        equals(['dart', 'flutter']),
      );
    });
    test('returns empty list for empty array', () {
      expect(FieldPath.resolve('tags[]', {'tags': <dynamic>[]}), equals([]));
    });
    test('returns missing when field is absent', () {
      expect(FieldPath.resolve('tags[]', {}), equals(missing));
    });
    test('returns missing when field is not a list', () {
      expect(FieldPath.resolve('tags[]', {'tags': 'dart'}), equals(missing));
    });
  });

  // ── missing sentinel semantics ───────────────────────────────────────────────

  group('missing sentinel', () {
    test('missing is not null', () {
      expect(missing, isNotNull);
    });
    test('missing == missing', () {
      // Same const singleton — identity equality.
      expect(identical(missing, missing), isTrue);
    });
  });

  // ── Optional root sigil ($.) ──────────────────────────────────────────────────

  group(r'optional root sigil ($.)', () {
    test(r'$.address.city equals address.city', () {
      final doc = {
        'address': <String, dynamic>{'city': 'London'},
      };
      expect(
        FieldPath.resolve(r'$.address.city', doc),
        equals(FieldPath.resolve('address.city', doc)),
      );
    });

    test(r'$.name resolves top-level field', () {
      expect(FieldPath.resolve(r'$.name', {'name': 'Alice'}), equals('Alice'));
    });

    test(r'$.name works identically to name (regression)', () {
      final doc = {'name': 'Bob', 'age': 30};
      expect(
        FieldPath.resolve(r'$.name', doc),
        equals(FieldPath.resolve('name', doc)),
      );
    });

    test(r'bare $ throws ArgumentError', () {
      expect(() => FieldPath.resolve(r'$', {'name': 'x'}), throwsArgumentError);
    });

    test(r'bare $ via normalisePath throws ArgumentError', () {
      expect(() => FieldPath.normalisePath(r'$'), throwsArgumentError);
    });

    test(
      r'double-dollar $$foo is NOT normalised (left as-is, returns missing)',
      () {
        // r'$$foo' should not be treated as a root sigil — it is not stripped.
        // The map key r'$$foo' would never be present in a real doc, so this
        // returns missing.
        expect(FieldPath.resolve(r'$$foo', {'foo': 'ok'}), equals(missing));
      },
    );

    test(r'normalisePath strips $. prefix', () {
      expect(
        FieldPath.normalisePath(r'$.address.city'),
        equals('address.city'),
      );
    });

    test(r'$[0] strips to [0], which returns missing on a Map root', () {
      // After stripping r'$', we get '[0]'. The parser treats this as a
      // segment with no field name and a positional index on the document
      // root, which is a Map — so the result is missing.
      expect(FieldPath.resolve(r'$[0]', {'a': 1}), equals(missing));
    });
  });

  // ── Array wildcard [*] ────────────────────────────────────────────────────────

  group('array wildcard [*]', () {
    test('tags[*] equals tags[]', () {
      final doc = {
        'tags': ['dart', 'flutter'],
      };
      expect(
        FieldPath.resolve('tags[*]', doc),
        equals(FieldPath.resolve('tags[]', doc)),
      );
    });

    test('tags[*] returns all elements as a List', () {
      expect(
        FieldPath.resolve('tags[*]', {
          'tags': ['a', 'b', 'c'],
        }),
        equals(['a', 'b', 'c']),
      );
    });

    test('tags[*] returns empty list for empty array', () {
      expect(FieldPath.resolve('tags[*]', {'tags': <dynamic>[]}), equals([]));
    });

    test('tags[*] returns missing when field is absent', () {
      expect(FieldPath.resolve('tags[*]', {}), equals(missing));
    });
  });

  // ── Negative array indices ────────────────────────────────────────────────────

  group('negative array indices', () {
    test('items[-1] returns the last element', () {
      expect(
        FieldPath.resolve('items[-1]', {
          'items': [10, 20, 30],
        }),
        equals(30),
      );
    });

    test('items[-2] returns the second-to-last element', () {
      expect(
        FieldPath.resolve('items[-2]', {
          'items': [10, 20, 30],
        }),
        equals(20),
      );
    });

    test('items[-3] returns the first element of a 3-element list', () {
      expect(
        FieldPath.resolve('items[-3]', {
          'items': [10, 20, 30],
        }),
        equals(10),
      );
    });

    test('negative index out-of-range returns missing', () {
      expect(
        FieldPath.resolve('items[-4]', {
          'items': [10, 20, 30],
        }),
        equals(missing),
      );
    });

    test('negative index on empty list returns missing', () {
      expect(
        FieldPath.resolve('items[-1]', {'items': <dynamic>[]}),
        equals(missing),
      );
    });

    test('negative index on non-list returns missing', () {
      expect(
        FieldPath.resolve('items[-1]', {'items': 'not-a-list'}),
        equals(missing),
      );
    });

    test('negative index when field absent returns missing', () {
      expect(FieldPath.resolve('items[-1]', {}), equals(missing));
    });
  });

  // ── Combined: root sigil with array access ────────────────────────────────────

  group(r'combined: root sigil with array access', () {
    test(r'$.tags[0] resolves correctly', () {
      expect(
        FieldPath.resolve(r'$.tags[0]', {
          'tags': ['dart', 'flutter'],
        }),
        equals('dart'),
      );
    });

    test(r'$.tags[-1] resolves to last element', () {
      expect(
        FieldPath.resolve(r'$.tags[-1]', {
          'tags': ['dart', 'flutter'],
        }),
        equals('flutter'),
      );
    });

    test(r'$.tags[*] returns all elements', () {
      expect(
        FieldPath.resolve(r'$.tags[*]', {
          'tags': ['x', 'y'],
        }),
        equals(['x', 'y']),
      );
    });
  });

  // ── Regression: bare paths continue to work unchanged ─────────────────────────

  group('regression: bare paths (no dollar) continue to work', () {
    test('simple field', () {
      expect(FieldPath.resolve('name', {'name': 'Alice'}), equals('Alice'));
    });
    test('nested dot path', () {
      expect(
        FieldPath.resolve('a.b.c', {
          'a': <String, dynamic>{
            'b': <String, dynamic>{'c': 42},
          },
        }),
        equals(42),
      );
    });
    test('positional array index', () {
      expect(
        FieldPath.resolve('x[1]', {
          'x': [10, 20],
        }),
        equals(20),
      );
    });
    test('fan-out', () {
      expect(
        FieldPath.resolve('x[]', {
          'x': [1, 2, 3],
        }),
        equals([1, 2, 3]),
      );
    });
  });
}
