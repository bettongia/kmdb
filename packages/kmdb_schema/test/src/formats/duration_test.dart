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

const validDurationStrings = [
  'PT1S',
  'PT1M',
  'PT1H',
  'P1D',
  'P1DT',
  'PT5H4M3S',
  'P0Y0M0DT5H4M3S',
  'P0Y0M6DT5H4M3S',
  'P6DT5H4M3S',
  'P6DT4M',
  'PT120S',
];

void main() {
  final validator = StringFormatValidator().getValidator("duration")?.function;
  if (validator == null) {
    throw Exception('Could not find validator');
  }
  group('duration', () {
    for (final str in validDurationStrings) {
      test('Duration: $str', () async {
        expect(validator(str), isTrue);
      });
    }
  });
}
