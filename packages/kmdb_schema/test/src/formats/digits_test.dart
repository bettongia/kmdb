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

import 'package:kmdb_schema/schema.dart';
import 'package:test/test.dart';

void main() {
  final validator = StringFormatValidator()
      .getValidator("digit-string")
      ?.function;
  if (validator == null) {
    throw Exception('Could not find validator');
  }
  group('DigitString', () {
    for (var str in ['9789295055124', '9789295055123']) {
      test('DigitString is valid: $str', () async {
        expect(validator(str), isTrue);
      });
    }

    for (var str in ['9789X295055124', '97892950😀55123']) {
      test('DigitString is not valid: $str', () async {
        expect(validator(str), isFalse);
      });
    }
  });
}
