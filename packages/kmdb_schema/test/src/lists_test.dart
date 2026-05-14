// Copyright 2024 The Authors.
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

import 'package:kmdb_schema/src/lists.dart';
import 'package:test/test.dart';

void main() {
  group('hasTheSameElements', () {
    var matchingTests = [
      ('empty', [], []),
      ('single', ['x'], ['x']),
      ('double', ['x', 'y'], ['x', 'y']),
      ('double swapped', ['x', 'y'], ['y', 'x']),
      ('repeated', ['x', 'y', 'y'], ['y', 'y', 'x']),
    ];

    for (var testEntry in matchingTests) {
      test('Matching: ${testEntry.$1}', () async {
        expect(hasTheSameElements(testEntry.$2, testEntry.$3), isTrue);
      });
    }

    var nonMatchingTests = [
      ('single', ['x'], ['y']),
      ('uneven', ['x'], ['y', 'z']),
    ];

    for (var testEntry in nonMatchingTests) {
      test('Non-matching: ${testEntry.$1}', () async {
        expect(hasTheSameElements(testEntry.$2, testEntry.$3), isFalse);
      });
    }
  });

  group('isSubList', () {
    var matchingTests = [
      ('empty', [], []),
      ('single', ['x'], ['x']),
      ('double', ['x', 'y'], ['x', 'y']),
      ('double swapped', ['x', 'y'], ['y', 'x']),
      ('repeated', ['x', 'y', 'y'], ['y', 'y', 'x']),
      ('sublist - 1 item', ['x'], ['x', 'y']),
      ('sublist - 2 items', ['x', 'z'], ['x', 'y', 'z']),
      ('sublist - 3 items, 1 repeat', ['x', 'x', 'z'], ['x', 'y', 'x', 'z']),
    ];

    for (var testEntry in matchingTests) {
      test('Matching: ${testEntry.$1}', () async {
        expect(isSubList(testEntry.$2, testEntry.$3), isTrue);
      });
    }

    var nonMatchingTests = [
      ('single', ['x'], ['y']),
      ('uneven', ['x'], ['y', 'z']),
      ('sublist - 2 items', ['x', 'q'], ['x', 'y', 'z']),
    ];

    for (var testEntry in nonMatchingTests) {
      test('Non-matching: ${testEntry.$1}', () async {
        expect(isSubList(testEntry.$2, testEntry.$3), isFalse);
      });
    }
  });
}
