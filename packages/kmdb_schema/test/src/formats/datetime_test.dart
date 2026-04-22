// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:kmdb_schema/schema.dart';
import 'package:test/test.dart';

void main() {
  final sfv = StringFormatValidator();

  group('date', () {
    final v = sfv.getValidator('date')!;

    test('valid ISO 8601 dates', () {
      expect(v.function('2026-04-22'), isTrue);
      expect(v.function('2000-01-01'), isTrue);
      expect(v.function('1999-12-31'), isTrue);
    });

    test('rejects datetime strings', () {
      expect(v.function('2026-04-22T10:00:00'), isFalse);
      expect(v.function('2026-04-22T10:00:00Z'), isFalse);
    });

    test('rejects invalid dates', () {
      expect(v.function('not-a-date'), isFalse);
      expect(v.function('2026-13-01'), isFalse);
      expect(v.function(''), isFalse);
    });
  });

  group('date-time', () {
    final v = sfv.getValidator('date-time')!;

    test('valid ISO 8601 datetimes', () {
      expect(v.function('2026-04-22T10:30:00Z'), isTrue);
      expect(v.function('2026-04-22T10:30:00.000Z'), isTrue);
      expect(v.function('2026-04-22T10:30:00+05:30'), isTrue);
    });

    test('accepts date-only strings (DateTime.tryParse accepts them)', () {
      expect(v.function('2026-04-22'), isTrue);
    });

    test('rejects invalid strings', () {
      expect(v.function('not-a-datetime'), isFalse);
      expect(v.function(''), isFalse);
    });
  });

  group('time', () {
    final v = sfv.getValidator('time')!;

    test('valid time strings', () {
      expect(v.function('10:30:00.000'), isTrue);
      expect(v.function('00:00:00.000'), isTrue);
      expect(v.function('23:59:59.999'), isTrue);
    });

    test('rejects invalid time strings', () {
      expect(v.function('10:30:00'), isFalse);
      expect(v.function('not-a-time'), isFalse);
      expect(v.function(''), isFalse);
    });
  });
}
