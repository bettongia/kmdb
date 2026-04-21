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

final List<String> testData = [
  'test@example.com',
  'test#1@example.com',
  'test@example',
];

final List<String> failData = [
  '',
  'example.com',
  'test(at)example',
  'test,1@example',
  '123456789123456789123456789@xyz',
];

void main() {
  final validator = StringFormatValidator().getValidator("email")?.function;
  if (validator == null) {
    throw Exception('Could not find validator');
  }
  group('email', () {
    for (var email in testData) {
      test('Email: $email', () async {
        expect(validator(email), isTrue);
      });
    }

    for (var email in failData) {
      test('Bad email: $email', () async {
        expect(validator(email), isFalse);
      });
    }
  });
}
