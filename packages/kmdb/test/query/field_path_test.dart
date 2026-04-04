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
}
