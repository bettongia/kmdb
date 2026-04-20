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

import 'package:kmdb_util/util.dart';
import 'package:test/test.dart';

void main() {
  test('Error: step <= 0', () async {
    expect(() => Range(stop: 10, step: 0), throwsA(isA<ArgumentError>()));
    expect(() => Range(stop: 10, step: -1), throwsA(isA<ArgumentError>()));
  });

  test('Empty range: start and stop are the same', () async {
    final r = range(start: 10, stop: 10);
    expect(r.toList(), []);
  });

  test('Start and stop are the same but stopExclusive is false', () async {
    final r = range(start: 10, stop: 10, stopExclusive: false);
    expect(r.toList(), [10]);
  });

  test('Basic usage', () async {
    final r = range(stop: 10);
    expect(r.toList(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('Basic usage - double', () async {
    final r = range(start: 1.1, stop: 5);

    expect(r.toList(), [1.1, 2.1, 3.1, 4.1]);
  });

  test('Basic usage - start 1, stop 5', () async {
    final r = range(start: 1, stop: 5);

    expect(r.toList(), [1, 2, 3, 4]);
  });

  test('Basic usage - start 1, stop 2, step 0.1', () async {
    final r = range(start: 1, stop: 2, step: 0.1);

    final actual = r.toList();
    final expected = [1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9];

    expect(actual, hasLength(10));
    expect(expected, hasLength(10));

    for (var i = 0; i < actual.length; i++) {
      expect(expected[i], closeTo(actual[i], 0.01));
    }
  });

  test('Basic usage - range function', () async {
    final list = <num>[];
    for (var i in range(stop: 10)) {
      list.add(i);
    }
    expect(list, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('Basic usage', () async {
    final list = <num>[];
    final range = Range(stop: 10);
    for (var i in range.generate()) {
      list.add(i);
    }
    expect(list, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('Basic usage - list', () async {
    final range = Range(stop: 10);

    expect(range.toList(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });

  test('Basic usage, step=2', () async {
    final r = range(stop: 10, step: 2);
    expect(r.toList(), [0, 2, 4, 6, 8]);
  });

  test('Basic usage, stopExclusive=false', () async {
    final r = range(stop: 10, stopExclusive: false);
    expect(r.toList(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  test('Basic usage - reverse', () async {
    final r = range(start: 9, stop: -1, step: 1);
    expect(r.toList(), [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
  });

  test('Basic usage - reverse, step=2', () async {
    final r = range(start: 9, stop: -1, step: 2);
    expect(r.toList(), [9, 7, 5, 3, 1]);
  });

  test('Basic usage,stopExclusive=false', () async {
    final r = range(start: 9, stop: 0, step: 1, stopExclusive: false);
    expect(r.toList(), [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]);
  });

  test('Basic usage, step=2', () async {
    final r = range(start: 10, stop: 0, step: 2);

    expect(r.toList(), [10, 8, 6, 4, 2]);
  });

  test('Basic usage,stopExclusive=false, step=2', () async {
    final r = range(start: 10, stop: 0, step: 2, stopExclusive: false);

    expect(r.toList(), [10, 8, 6, 4, 2, 0]);
  });

  test('equals', () async {
    final r = Range(stop: 10);
    expect(r, equals(Range(stop: 10)));
    expect(r, isNot(Range(stop: 11)));
  });

  test('hashCode', () async {
    final r = Range(stop: 10);

    expect(r.hashCode, Range(stop: 10).hashCode);
    expect(r.hashCode, isNot(Range(stop: 11).hashCode));
  });

  test('contains', () async {
    final r = Range(stop: 10);
    expect(r.contains(5), isTrue);
    expect(r.contains(11), isFalse);
    expect(r.contains(3.5), isFalse);

    expect(Range(stop: 10, stopExclusive: true).contains(10), isFalse);
    expect(Range(stop: 10, stopExclusive: true).contains(9), isTrue);
  });

  test('contains - ratings', () async {
    final r = Range(start: 0, stop: 5, step: 0.5, stopExclusive: false);
    expect(r.contains(0), isTrue);
    expect(r.contains(0.5), isTrue);
    expect(r.contains(1), isTrue);
    expect(r.contains(1.5), isTrue);
    expect(r.contains(2), isTrue);
    expect(r.contains(2.5), isTrue);
    expect(r.contains(3), isTrue);
    expect(r.contains(3.5), isTrue);
    expect(r.contains(4), isTrue);
    expect(r.contains(4.5), isTrue);
    expect(r.contains(5), isTrue);

    expect(r.contains(0.1), isFalse);
    expect(r.contains(2.6), isFalse);
    expect(r.contains(5.5), isFalse);
  });
  group('Mapper', () {
    test('basic', () async {
      final r = Range(stop: 10);
      expect(r.toMap(), {
        'start': 0,
        'stop': 10,
        'step': 1,
        'stopExclusive': true,
      });
    });

    test('full config', () async {
      final r = Range(start: 25, stop: 10, step: 5, stopExclusive: false);
      expect(r.toMap(), {
        'start': 25,
        'stop': 10,
        'step': 5,
        'stopExclusive': false,
      });
    });
  });
}
