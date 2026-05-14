// Copyright 2026 The Authors
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

import 'package:kmdb_schema/schema.dart' show StringFormatValidator;
import 'package:test/test.dart';

// Refer to https://en.wikipedia.org/wiki/Roman_numerals
void main() {
  final validator = StringFormatValidator()
      .getValidator("roman-numeral")
      ?.function;
  if (validator == null) {
    throw Exception('Could not find validator');
  }
  group('Invalid parameters', () {
    test('Empty string', () async {
      expect(validator(''), isFalse);
    });

    test('Invalid type', () async {
      expect(validator('1'), isFalse);
    });

    test('Invalid string', () async {
      expect(validator('Z'), isFalse);
    });
  });

  group('Single numerals', () {
    test('I', () async {
      expect(validator('I'), isTrue);
    });

    test('V', () async {
      expect(validator('V'), isTrue);
    });

    test('X', () async {
      expect(validator('X'), isTrue);
    });

    test('L', () async {
      expect(validator('L'), isTrue);
    });

    test('C', () async {
      expect(validator('C'), isTrue);
    });

    test('D', () async {
      expect(validator('D'), isTrue);
    });

    test('M', () async {
      expect(validator('M'), isTrue);
    });
  });

  group('Standard form', () {
    test('ii', () async {
      expect(validator('ii'), isTrue);
    });

    test('iii', () async {
      expect(validator('iii'), isTrue);
    });

    test('iv', () async {
      expect(validator('iv'), isTrue);
    });

    test('XXXIX', () async {
      expect(validator('XXXIX'), isTrue);
    });

    test('CCXLVI', () async {
      expect(validator('CCXLVI'), isTrue);
    });

    test('DCCLXXXIX', () async {
      expect(validator('DCCLXXXIX'), isTrue);
    });

    test('MMCDXXI', () async {
      expect(validator('MMCDXXI'), isTrue);
    });

    test('CLX', () async {
      expect(validator('CLX'), isTrue);
    });

    test('MMMCMXCIX', () async {
      expect(validator('MMMCMXCIX'), isTrue);
    });
  });

  group('Additive form', () {
    test('iiii', () async {
      expect(validator('iiii'), isTrue);
    });

    test('viiii', () async {
      expect(validator('viiii'), isTrue);
    });

    test('XXIIII', () async {
      expect(validator('XXIIII'), isTrue);
    });
  });

  group(
    'Other forms that are not supported but pass because the validator is simplistic',
    () {
      test('XIIX', () async {
        expect(validator('XIIX'), isTrue);
      });
    },
  );
}
