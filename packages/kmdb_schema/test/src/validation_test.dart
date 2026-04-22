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
import 'package:kmdb_schema/src/range.dart';

import 'package:test/test.dart';

void main() {
  group('enum', () {
    test('name', () async {
      expect(EnumValidator(['cat', 'dog', 'tiger']).name, 'enum');
    });
    test('valid', () async {
      final e = EnumValidator(['cat', 'dog', 'tiger']);
      expect(e('cat'), isTrue);
      expect(e('dog'), isTrue);
      expect(e('tiger'), isTrue);
    });
    test('not valid', () async {
      final e = EnumValidator(['cat', 'dog', 'tiger']);
      expect(e('rabbit'), isFalse);
      expect(e('karl'), isFalse);
      expect(e('x'), isFalse);
    });
    test('equal', () async {
      final e = EnumValidator(['cat', 'dog', 'tiger']);
      final e1 = e;
      final e2 = EnumValidator(['cat', 'tiger', 'dog']);
      expect(e, equals(e1));
      expect(e, equals(e2));
      expect(e, isNot(EnumValidator(['cat', 'tiger', 'rabbit'])));
      expect(e, isNot(['cat', 'dog', 'tiger']));
      expect(e.hashCode, equals(e1.hashCode));
      expect(e.hashCode, equals(e2.hashCode));
    });

    test('toMap', () async {
      final e = EnumValidator(['cat', 'dog', 'tiger']);
      expect(e.toMap(), {
        'name': 'enum',
        'value': ['cat', 'dog', 'tiger'],
      });
    });
  });

  group('const', () {
    test('name', () async {
      expect(ConstValidator(42).name, 'const');
    });
    test('valid', () async {
      final c = ConstValidator(42);
      expect(c(42), isTrue);
    });
    test('not valid', () async {
      final c = ConstValidator(42);
      expect(c(43), false);
    });
    test('equal', () async {
      final c = ConstValidator(42);
      final c1 = c;
      final c2 = ConstValidator(42);
      expect(c, equals(c1));
      expect(c, equals(c2));
      expect(c, isNot(ConstValidator(43)));
      expect(c, isNot(42));
      expect(c.hashCode, equals(c1.hashCode));
      expect(c.hashCode, equals(c2.hashCode));
      expect(c.hashCode, isNot(ConstValidator(43).hashCode));
      expect(c.hashCode, isNot(43.hashCode));
    });

    test('toMap', () async {
      final c = ConstValidator(42);
      expect(c.toMap(), {'name': 'const', 'value': 42});
    });
  });

  group('maximum', () {
    test('name', () async {
      expect(Maximum(1).name, 'maximum');
    });
    test('valid', () async {
      var max = Maximum(5);
      expect(max(5), isTrue);
      expect(Maximum(5)(3), isTrue);
      expect(Maximum(5)(5), isTrue);
      expect(Maximum(3.14)(3), isTrue);
    });
    test('not valid', () async {
      var max = Maximum(5);
      expect(max(6), isFalse);
      expect(Maximum(5)(6), isFalse);
    });
    test('equal', () async {
      var max = Maximum(5);
      var max1 = max;
      var max2 = Maximum(5);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max, isNot(Maximum(6)));
      expect(max, isNot(ExclusiveMaximum(6)));
      expect(max, isNot(6));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
      expect(max.hashCode, isNot(Maximum(6).hashCode));
    });

    test('toMap', () async {
      var max = Maximum(5);
      expect(max.toMap(), {'name': 'maximum', 'value': 5});
    });
  });

  group('exclusiveMaximum', () {
    test('name', () async {
      expect(ExclusiveMaximum(1).name, 'exclusiveMaximum');
    });
    test('valid', () async {
      var max = ExclusiveMaximum(5);

      expect(max(3), isTrue);

      expect(ExclusiveMaximum(3.14)(3), isTrue);
    });
    test('not valid', () async {
      var max = ExclusiveMaximum(5);
      expect(ExclusiveMaximum(5)(5), isFalse);
      expect(max(6), isFalse);
      expect(ExclusiveMaximum(5)(6), isFalse);
    });
    test('equal', () async {
      var max = ExclusiveMaximum(5);
      var max1 = max;
      var max2 = ExclusiveMaximum(5);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max, isNot(ExclusiveMaximum(6)));
      expect(max, isNot(Maximum(6)));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
      expect(max.hashCode, isNot(ExclusiveMaximum(6).hashCode));
    });

    test('toMap', () async {
      var max = ExclusiveMaximum(5);
      expect(max.toMap(), {'name': 'exclusiveMaximum', 'value': 5});
    });
  });

  group('minimum', () {
    test('name', () async {
      expect(Minimum(1).name, 'minimum');
    });
    test('valid', () async {
      var min = Minimum(5);
      expect(min(5), isTrue);
      expect(Minimum(5)(6), isTrue);
      expect(Minimum(5)(5), isTrue);
      expect(Minimum(3.14)(3.15), isTrue);
    });
    test('not valid', () async {
      var min = Minimum(5);
      expect(min(4), isFalse);
      expect(Minimum(5)(4), isFalse);
    });
    test('equal', () async {
      var min = Minimum(5);
      var min1 = min;
      var min2 = Minimum(5);
      expect(min, equals(min1));
      expect(min, equals(min2));
      expect(min, isNot(Minimum(6)));
      expect(min, isNot(ExclusiveMinimum(6)));
      expect(min, isNot(6));
      expect(min.hashCode, equals(min1.hashCode));
      expect(min.hashCode, equals(min2.hashCode));
      expect(min.hashCode, isNot(Minimum(6).hashCode));
      expect(min.hashCode, isNot(6.hashCode));
    });

    test('toMap', () async {
      var min = Minimum(5);
      expect(min.toMap(), {'name': 'minimum', 'value': 5});
    });
  });

  group('exclusiveMinimum', () {
    test('name', () async {
      expect(ExclusiveMinimum(1).name, 'exclusiveMinimum');
    });
    test('valid', () async {
      var min = ExclusiveMinimum(3);
      expect(min(4), isTrue);
      expect(ExclusiveMinimum(3.14)(3.15), isTrue);
    });
    test('not valid', () async {
      var min = ExclusiveMinimum(5);
      expect(min(1), isFalse);
      expect(min(5), isFalse);
      expect(ExclusiveMinimum(5)(5), isFalse);
    });
    test('equal', () async {
      var min = ExclusiveMinimum(5);
      var min1 = min;
      var min2 = ExclusiveMinimum(5);
      expect(min, equals(min1));
      expect(min, equals(min2));
      expect(min, isNot(ExclusiveMinimum(6)));
      expect(min, isNot(Minimum(6)));
      expect(min.hashCode, equals(min1.hashCode));
      expect(min.hashCode, equals(min2.hashCode));
      expect(min.hashCode, isNot(ExclusiveMinimum(6).hashCode));
      expect(min.hashCode, isNot(6.hashCode));
    });

    test('toMap', () async {
      var min = ExclusiveMinimum(5);
      expect(min.toMap(), {'name': 'exclusiveMinimum', 'value': 5});
    });
  });

  group('multipleOf', () {
    test('name', () async {
      expect(MultipleOf(1).name, 'multipleOf');
    });
    test('valid', () async {
      var multiple = MultipleOf(3);
      expect(multiple(3), isTrue);
      expect(multiple(6), isTrue);
    });
    test('not valid', () async {
      var multiple = MultipleOf(3);
      expect(multiple(2), isFalse);
      expect(multiple(4), isFalse);
    });
    test('equal', () async {
      var multiple = MultipleOf(3);
      var multiple1 = multiple;
      var multiple2 = MultipleOf(3);
      expect(multiple, equals(multiple1));
      expect(multiple, equals(multiple2));
      expect(multiple.hashCode, equals(multiple1.hashCode));
      expect(multiple.hashCode, equals(multiple2.hashCode));
    });

    test('toMap', () async {
      var multiple = MultipleOf(3);
      expect(multiple.toMap(), {'name': 'multipleOf', 'value': 3});
    });
  });

  group('maximumLength', () {
    test('name', () async {
      expect(MaximumLength(1).name, 'maximumLength');
    });
    test('valid', () async {
      var max = MaximumLength(3);
      expect(max('abc'), isTrue);
      expect(MaximumLength(3)('xyz'), isTrue);
    });
    test('not valid', () async {
      var max = MaximumLength(3);
      expect(max('abcd'), isFalse);
      expect(MaximumLength(3)('abcd'), isFalse);
    });
    test('equal', () async {
      var max = MaximumLength(3);
      var max1 = max;
      var max2 = MaximumLength(3);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
    });

    test('toMap', () async {
      var max = MaximumLength(3);
      expect(max.toMap(), {'name': 'maximumLength', 'value': 3});
    });
  });

  group('exactLength', () {
    test('name', () async {
      expect(ExactLength(1).name, 'exactLength');
    });
    test('valid', () async {
      var max = ExactLength(3);
      expect(max('abc'), isTrue);
      expect(ExactLength(3)('xyz'), isTrue);
    });
    test('not valid', () async {
      var max = ExactLength(3);
      expect(max('abcd'), isFalse);
      expect(ExactLength(3)('abcd'), isFalse);
    });
    test('equal', () async {
      var max = ExactLength(3);
      var max1 = max;
      var max2 = ExactLength(3);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
    });

    test('toMap', () async {
      var max = ExactLength(3);
      expect(max.toMap(), {'name': 'exactLength', 'value': 3});
    });
  });

  group('minimumLength', () {
    test('name', () async {
      expect(MinimumLength(1).name, 'minimumLength');
    });
    test('valid', () async {
      var max = MinimumLength(3);
      expect(max('abc'), isTrue);
      expect(max('abcd'), isTrue);
      expect(MinimumLength(3)('xyz'), isTrue);
    });
    test('not valid', () async {
      var max = MinimumLength(3);
      expect(max('ab'), isFalse);
      expect(MinimumLength(3)('ab'), isFalse);
    });
    test('equal', () async {
      var max = MinimumLength(3);
      var max1 = max;
      var max2 = MinimumLength(3);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
    });

    test('toMap', () async {
      var max = MinimumLength(3);
      expect(max.toMap(), {'name': 'minimumLength', 'value': 3});
    });
  });

  group('pattern', () {
    test('name', () async {
      expect(PatternValidator.fromString(r'a').name, 'pattern');
    });
    test('valid', () async {
      expect(PatternValidator.fromString(r'cat')('cat'), isTrue);
      expect(PatternValidator.fromString(r'[bc]at')('bat'), isTrue);
    });
    test('not valid', () async {
      expect(PatternValidator.fromString(r'cat')('rat'), isFalse);
      expect(PatternValidator.fromString(r'[bc]at')('rat'), isFalse);
    });

    test('equal', () async {
      var pattern = PatternValidator.fromString(r'cat');
      var pattern1 = pattern;
      var pattern2 = PatternValidator.fromString(r'cat');
      expect(pattern, equals(pattern1));
      expect(pattern, equals(pattern2));
      expect(pattern.hashCode, equals(pattern1.hashCode));
      expect(pattern.hashCode, equals(pattern2.hashCode));
    });

    test('toMap', () async {
      var pattern = PatternValidator.fromString(r'cat');
      expect(pattern.toMap(), {'name': 'pattern', 'value': r'cat'});
    });

    test('toMap - regex', () async {
      var pattern = PatternValidator(RegExp('[bc]at'));
      expect(pattern.toMap(), {'name': 'pattern', 'value': r'[bc]at'});
    });
  });

  group('inRange', () {
    test('name', () async {
      expect(InRange(Range(start: 1, stop: 5)).name, 'inRange');
    });

    test('valid', () async {
      var inRange = InRange(Range(start: 1, stop: 5));
      expect(inRange(1), isTrue);
      expect(inRange(2), isTrue);
      expect(inRange(3), isTrue);
      expect(inRange(4), isTrue);
      expect(inRange(5), isFalse);
    });

    test('valid - stop inclusive', () async {
      var inRange = InRange(Range(start: 1, stop: 5, stopExclusive: false));
      expect(inRange(1), isTrue);
      expect(inRange(2), isTrue);
      expect(inRange(3), isTrue);
      expect(inRange(4), isTrue);
      expect(inRange(5), isTrue);
    });

    test('equal', () async {
      var inRange = InRange(Range(start: 1, stop: 5));
      var inRange1 = inRange;
      var inRange2 = InRange(Range(start: 1, stop: 5));
      expect(inRange, equals(inRange1));
      expect(inRange, equals(inRange2));
      expect(inRange.hashCode, equals(inRange1.hashCode));
      expect(inRange.hashCode, equals(inRange2.hashCode));
    });

    test('toMap', () async {
      var inRange = InRange(Range(start: 1, stop: 5));
      expect(inRange.toMap(), {
        'name': 'inRange',
        'value': {'start': 1, 'stop': 5, 'step': 1, 'stopExclusive': true},
      });
    });
  });

  group('inRangeLength', () {
    test('name', () async {
      expect(InRangeLength(Range(start: 1, stop: 5)).name, 'inRangeLength');
    });

    test('valid', () async {
      var inRange = InRangeLength(Range(start: 1, stop: 5));
      expect(inRange('a'), isTrue);
      expect(inRange('ab'), isTrue);
      expect(inRange('abc'), isTrue);
      expect(inRange('abcd'), isTrue);
      expect(inRange('abcde'), isFalse);
    });

    test('valid - stop inclusive', () async {
      final inRange = InRangeLength(
        Range(start: 1, stop: 5, stopExclusive: false),
      );
      expect(inRange('a'), isTrue);
      expect(inRange('ab'), isTrue);
      expect(inRange('abc'), isTrue);
      expect(inRange('abcd'), isTrue);
      expect(inRange('abcde'), isTrue);
    });

    test('equal', () async {
      var inRange = InRangeLength(Range(start: 1, stop: 5));
      var inRange1 = inRange;
      var inRange2 = InRangeLength(Range(start: 1, stop: 5));
      expect(inRange, equals(inRange1));
      expect(inRange, equals(inRange2));
      expect(inRange.hashCode, equals(inRange1.hashCode));
      expect(inRange.hashCode, equals(inRange2.hashCode));
    });

    test('toMap', () async {
      var inRange = InRangeLength(Range(start: 1, stop: 5));
      expect(inRange.toMap(), {
        'name': 'inRangeLength',
        'value': {'start': 1, 'stop': 5, 'step': 1, 'stopExclusive': true},
      });
    });
  });

  group('maxItems', () {
    test('name', () async {
      expect(MaxItems(3).name, 'maxItems');
    });
    test('valid', () async {
      var max = MaxItems(3);
      expect(max([]), isTrue);
      expect(max([1, 2, 3]), isTrue);
      expect(max([1, 2]), isTrue);
    });

    test('not valid', () async {
      var max = MaxItems(3);
      expect(max([1, 2, 3, 4]), isFalse);
    });

    test('equal', () async {
      var max = MaxItems(3);
      var max1 = max;
      var max2 = MaxItems(3);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
    });

    test('toMap', () async {
      var max = MaxItems(3);
      expect(max.toMap(), {'name': 'maxItems', 'value': 3});
    });
  });

  group('minItems', () {
    test('name', () async {
      expect(MinItems(3).name, 'minItems');
    });
    test('valid', () async {
      var min = MinItems(3);

      expect(min([1, 2, 3]), isTrue);
      expect(min([1, 2, 3, 4]), isTrue);
    });

    test('not valid', () async {
      var min = MinItems(3);
      expect(min([]), isFalse);
      expect(min([1, 2]), isFalse);
    });

    test('equal', () async {
      var min = MinItems(3);
      var min1 = min;
      var min2 = MinItems(3);
      expect(min, equals(min1));
      expect(min, equals(min2));
      expect(min.hashCode, equals(min1.hashCode));
      expect(min.hashCode, equals(min2.hashCode));
    });

    test('toMap', () async {
      var min = MinItems(3);
      expect(min.toMap(), {'name': 'minItems', 'value': 3});
    });
  });

  group('itemCount', () {
    test('name', () async {
      expect(ItemCount(3).name, 'itemCount');
    });
    test('valid', () async {
      var ic = ItemCount(3);

      expect(ic([1, 2, 3]), isTrue);
      expect(ic([1, 2, 3, 4]), isFalse);
    });

    test('not valid', () async {
      var ic = ItemCount(3);
      expect(ic([]), isFalse);
      expect(ic([1, 2]), isFalse);
    });

    test('equal', () async {
      var ic = ItemCount(3);
      var ic1 = ic;
      var ic2 = ItemCount(3);
      expect(ic, equals(ic1));
      expect(ic, equals(ic2));
      expect(ic.hashCode, equals(ic1.hashCode));
      expect(ic.hashCode, equals(ic2.hashCode));
    });

    test('toMap', () async {
      expect(ItemCount(3).toMap(), {'name': 'itemCount', 'value': 3});
    });
  });

  group('uniqueItems', () {
    test('name', () async {
      expect(UniqueItems().name, 'uniqueItems');
    });
    test('valid', () async {
      var unique = UniqueItems();
      expect(unique([]), isTrue);
      expect(unique(['a', 'b', 'c']), isTrue);
      expect(unique(['a', 'b', 'c', 'd']), isTrue);
    });

    test('not valid', () async {
      var unique = UniqueItems();
      expect(unique(['a', 'b', 'b']), isFalse);
    });
    test('equal', () async {
      var unique = UniqueItems();
      var unique1 = unique;
      var unique2 = UniqueItems();
      expect(unique, equals(unique1));
      expect(unique, equals(unique2));
      expect(unique.hashCode, equals(unique1.hashCode));
      expect(unique.hashCode, equals(unique2.hashCode));
    });

    test('toMap', () async {
      var unique = UniqueItems();
      expect(unique.toMap(), {'name': 'uniqueItems'});
    });
  });

  group('minProperties', () {
    test('name', () async {
      expect(MinProperties(3).name, 'minProperties');
    });
    test('valid', () async {
      var min = MinProperties(2);

      expect(min({'a': 1, 'b': 2}), isTrue);
      expect(min({'a': 1, 'b': 2, 'c': 3}), isTrue);
    });
    test('not valid', () async {
      var min = MinProperties(2);
      expect(min({}), isFalse);
      expect(min({'a': 1}), isFalse);
    });
    test('equal', () async {
      var min = MinProperties(3);
      var min1 = min;
      var min2 = MinProperties(3);
      expect(min, equals(min1));
      expect(min, equals(min2));
      expect(min.hashCode, equals(min1.hashCode));
      expect(min.hashCode, equals(min2.hashCode));
    });

    test('toMap', () async {
      var min = MinProperties(3);
      expect(min.toMap(), {'name': 'minProperties', 'value': 3});
    });
  });

  group('maxProperties', () {
    test('name', () async {
      expect(MaxProperties(3).name, 'maxProperties');
    });
    test('valid', () async {
      var max = MaxProperties(3);
      expect(max({'a': 1, 'b': 2, 'c': 3}), isTrue);
      expect(max({'a': 1, 'b': 2}), isTrue);
      expect(max({}), isTrue);
    });
    test('not valid', () async {
      var max = MaxProperties(3);

      expect(max({'a': 1, 'b': 2, 'c': 3, 'd': 4}), isFalse);
    });
    test('equal', () async {
      var max = MaxProperties(3);
      var max1 = max;
      var max2 = MaxProperties(3);
      expect(max, equals(max1));
      expect(max, equals(max2));
      expect(max.hashCode, equals(max1.hashCode));
      expect(max.hashCode, equals(max2.hashCode));
    });

    test('toMap', () async {
      var max = MaxProperties(3);
      expect(max.toMap(), {'name': 'maxProperties', 'value': 3});
    });
  });

  group('required', () {
    test('name', () async {
      expect(Required([]).name, 'required');
    });

    test('valid', () async {
      final required = Required(['a', 'b']);
      expect(required({'a': 1, 'b': 2}), isTrue);
      expect(required({'a': 1, 'b': 2, 'c': 3}), isTrue);
    });

    test('not valid', () async {
      final required = Required(['a', 'b']);
      expect(required({'a': 1}), isFalse);
      expect(required({'a': 1, 'c': 3}), isFalse);
      expect(required({}), isFalse);
    });

    test('equal', () async {
      final required = Required(['a', 'b']);
      final required1 = required;
      final required2 = Required(['b', 'a']);
      final required3 = Required(['a', 'c']);
      expect(required, equals(required1));
      expect(required, equals(required2));
      expect(required, isNot(required3));
      expect(required.hashCode, equals(required1.hashCode));
      expect(required.hashCode, equals(required2.hashCode));
      expect(required.hashCode, isNot(required3.hashCode));
    });

    test('toMap', () async {
      final required = Required(['a', 'b']);
      expect(required.toMap(), {
        'name': 'required',
        'value': ['a', 'b'],
      });
    });
  });

  group('dependentRequired', () {
    test('name', () async {
      expect(DependentRequired({}).name, 'dependentRequired');
    });

    test('valid', () async {
      final dependent = {
        'x': ['a'],
        'y': ['b', 'c'],
      };

      final validator = DependentRequired(dependent);
      expect(validator({'x': '1', 'a': '2'}), isTrue);

      expect(validator({'y': '1', 'b': '2', 'c': 3}), isTrue);

      expect(validator({'x': '1', 'y': 4, 'a': 1, 'b': '2', 'c': 3}), isTrue);
    });
    test('not valid', () async {
      final dependent = {
        'x': ['a'],
        'y': ['b', 'c'],
      };

      final validator = DependentRequired(dependent);
      expect(validator({'x': '1', 'b': '2'}), isFalse);
      expect(validator({'y': '1', 'a': '2', 'c': 3}), isFalse);
      expect(validator({'x': '1', 'y': 4, 'h': 1, 'b': '2', 'c': 3}), isFalse);
    });

    test('equal', () async {
      final dependent = {
        'x': ['a'],
        'y': ['b', 'c'],
      };

      final validator = DependentRequired(dependent);

      final validator1 = validator;
      final validator2 = DependentRequired(dependent);
      final validator3 = DependentRequired({
        'y': ['c', 'b'],
        'x': ['a'],
      });

      final validator4 = DependentRequired({
        'y': ['c', 'b'],
      });

      final validator5 = DependentRequired({
        'c': ['y', 'b'],
        'a': ['x'],
      });

      expect(validator, equals(validator1));
      expect(validator, equals(validator2));
      expect(validator, equals(validator3));
      expect(validator, isNot(validator4));
      expect(validator.hashCode, equals(validator1.hashCode));
      expect(validator.hashCode, equals(validator2.hashCode));
      expect(validator.hashCode, equals(validator3.hashCode));
      expect(validator.hashCode, isNot(validator4.hashCode));
      expect(validator.hashCode, isNot(validator5.hashCode));
      expect(validator3.hashCode, isNot(validator5.hashCode));
    });

    test('toMap', () async {
      final dependent = {
        'x': ['a'],
        'y': ['b', 'c'],
      };
      final validator = DependentRequired(dependent);
      expect(validator.toMap(), {
        'name': 'dependentRequired',
        'value': {
          'x': ['a'],
          'y': ['b', 'c'],
        },
      });
    });
  });

  group('typeValidator', () {
    test('name', () => expect(TypeValidator('string').name, 'type'));

    test('string', () {
      expect(TypeValidator('string')('hello'), isTrue);
      expect(TypeValidator('string')(42), isFalse);
      expect(TypeValidator('string')(null), isFalse);
    });

    test('number', () {
      expect(TypeValidator('number')(3.14), isTrue);
      expect(TypeValidator('number')(42), isTrue);
      expect(TypeValidator('number')('42'), isFalse);
    });

    test('integer', () {
      expect(TypeValidator('integer')(42), isTrue);
      expect(TypeValidator('integer')(3.14), isFalse);
      expect(TypeValidator('integer')('42'), isFalse);
    });

    test('boolean', () {
      expect(TypeValidator('boolean')(true), isTrue);
      expect(TypeValidator('boolean')(false), isTrue);
      expect(TypeValidator('boolean')(1), isFalse);
    });

    test('array', () {
      expect(TypeValidator('array')([1, 2]), isTrue);
      expect(TypeValidator('array')({}), isFalse);
    });

    test('object', () {
      expect(TypeValidator('object')({'a': 1}), isTrue);
      expect(TypeValidator('object')([]), isFalse);
    });

    test('null', () {
      expect(TypeValidator('null')(null), isTrue);
      expect(TypeValidator('null')(0), isFalse);
      expect(TypeValidator('null')(''), isFalse);
    });

    test('unknown type returns false', () {
      expect(TypeValidator('unknown')(42), isFalse);
    });

    test('equal', () {
      final v = TypeValidator('string');
      expect(v, equals(TypeValidator('string')));
      expect(v, isNot(TypeValidator('number')));
      expect(v.hashCode, equals(TypeValidator('string').hashCode));
    });

    test('toMap', () {
      expect(TypeValidator('string').toMap(), {
        'name': 'type',
        'value': 'string',
      });
    });
  });

  group('propertiesValidator', () {
    test('name', () => expect(PropertiesValidator({}).name, 'properties'));

    test('valid — matching fields pass', () {
      final v = PropertiesValidator({'age': TypeValidator('integer')});
      expect(v({'age': 30, 'name': 'Alice'}), isTrue);
    });

    test('valid — absent field is skipped', () {
      final v = PropertiesValidator({'age': TypeValidator('integer')});
      expect(v({'name': 'Alice'}), isTrue);
    });

    test('not valid — wrong type for present field', () {
      final v = PropertiesValidator({'age': TypeValidator('integer')});
      expect(v({'age': 'thirty'}), isFalse);
    });

    test('equal', () {
      final v1 = PropertiesValidator({'a': TypeValidator('string')});
      final v2 = PropertiesValidator({'a': TypeValidator('string')});
      final v3 = PropertiesValidator({'a': TypeValidator('number')});
      expect(v1, equals(v2));
      expect(v1, isNot(v3));
      expect(v1.hashCode, equals(v2.hashCode));
    });

    test('toMap contains name', () {
      final v = PropertiesValidator({'x': TypeValidator('string')});
      expect((v.toMap()['name']), 'properties');
    });
  });

  group('additionalPropertiesValidator', () {
    test('name', () {
      expect(AdditionalPropertiesValidator(['a']).name, 'additionalProperties');
    });

    test('valid — only allowed keys', () {
      final v = AdditionalPropertiesValidator(['name', 'age']);
      expect(v({'name': 'Alice', 'age': 30}), isTrue);
      expect(v({'name': 'Alice'}), isTrue);
      expect(v({}), isTrue);
    });

    test('not valid — extra key present', () {
      final v = AdditionalPropertiesValidator(['name', 'age']);
      expect(v({'name': 'Alice', 'age': 30, 'extra': true}), isFalse);
    });

    test('equal', () {
      final v1 = AdditionalPropertiesValidator(['a', 'b']);
      final v2 = AdditionalPropertiesValidator(['b', 'a']);
      final v3 = AdditionalPropertiesValidator(['a', 'c']);
      expect(v1, equals(v2));
      expect(v1, isNot(v3));
      expect(v1.hashCode, equals(v2.hashCode));
    });

    test('toMap', () {
      final v = AdditionalPropertiesValidator(['b', 'a']);
      final map = v.toMap();
      expect(map['name'], 'additionalProperties');
      expect(map['value'], ['a', 'b']); // sorted
    });
  });

  group('itemsValidator', () {
    test('name', () {
      expect(ItemsValidator(TypeValidator('string')).name, 'items');
    });

    test('valid — all elements match', () {
      final v = ItemsValidator(TypeValidator('string'));
      expect(v(['a', 'b', 'c']), isTrue);
      expect(v([]), isTrue);
    });

    test('not valid — element type mismatch', () {
      final v = ItemsValidator(TypeValidator('string'));
      expect(v(['a', 42, 'c']), isFalse);
    });

    test('equal', () {
      final v1 = ItemsValidator(TypeValidator('string'));
      final v2 = ItemsValidator(TypeValidator('string'));
      final v3 = ItemsValidator(TypeValidator('number'));
      expect(v1, equals(v2));
      expect(v1, isNot(v3));
      expect(v1.hashCode, equals(v2.hashCode));
    });

    test('toMap', () {
      final v = ItemsValidator(TypeValidator('integer'));
      expect(v.toMap(), {'name': 'items', 'value': 'type'});
    });
  });
}
