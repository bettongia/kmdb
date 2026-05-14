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

import 'dart:collection';

import 'package:characters/characters.dart';
import 'package:collection/collection.dart';

import 'lists.dart';
import 'range.dart';

/// Validators are used to validate data against a schema
///
/// The [name] provides a handy string to use in error messages.
///
/// Validators are [call]able classes that usually have that single
/// instance method.
abstract interface class Validator<T> {
  String get name;

  bool call(T input);
}

/// Validates that the input is one of the specified values
class EnumValidator<T> implements Validator<T> {
  /// The allowed values
  Iterable<T> values;

  @override
  final String name = 'enum';

  EnumValidator(Iterable<T> values)
    : values = UnmodifiableListView([...values]);

  @override
  bool call(T input) => values.contains(input);

  @override
  bool operator ==(Object other) {
    if (other is EnumValidator<T>) {
      return hasTheSameElements(other.values, values);
    }
    return false;
  }

  @override
  int get hashCode => Object.hashAllUnordered([name, ...values]);

  Map<String, dynamic> toMap() => {
    'name': name,
    'value': values.map((e) => e.toString()).toList(),
  };
}

/// Validates that the input is equal to the specified value
class ConstValidator<T> implements Validator<T> {
  /// The single allowed value
  T value;

  @override
  final String name = 'const';

  ConstValidator(this.value);

  @override
  bool call(T input) => value == input;

  @override
  bool operator ==(Object other) {
    if (other is ConstValidator<T>) {
      return other.value == value;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, value);

  Map<String, dynamic> toMap() => {'name': name, 'value': value};
}

/// Validates that a value is less than or equal to the specified [max]
///
/// Note that [max] is inclusive.
class Maximum<T extends num> implements Validator<T> {
  /// The (inclusive) maximum allowed value
  final num max;

  @override
  final String name = 'maximum';

  Maximum(this.max);

  @override
  bool call(T input) => maximum(input, max);

  static bool maximum(num input, num max) {
    return input <= max;
  }

  @override
  bool operator ==(Object other) {
    if (other is Maximum<T>) {
      return other.max == max;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, max);

  Map<String, dynamic> toMap() => {'name': name, 'value': max};
}

/// Validates that a value is less than the specified [max]
///
/// Note that [max] is exclusive.
class ExclusiveMaximum<T extends num> implements Validator<T> {
  /// The (exclusive) maximum allowed value
  final num max;

  @override
  final String name = 'exclusiveMaximum';

  ExclusiveMaximum(this.max);

  @override
  bool call(T input) => exclusiveMaximum(input, max);

  bool exclusiveMaximum(num input, num max) {
    return input < max;
  }

  @override
  bool operator ==(Object other) {
    if (other is ExclusiveMaximum<T>) {
      return other.max == max;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, max);

  Map<String, dynamic> toMap() => {'name': name, 'value': max};
}

/// Validates that a value is greater than or equal to the specified [min]
class Minimum<T extends num> implements Validator<T> {
  /// The (inclusive) minimum allowed value
  final T min;

  @override
  final String name = 'minimum';

  Minimum(this.min);

  @override
  bool call(T input) => minimum(input, min);

  bool minimum(num input, num min) {
    return input >= min;
  }

  @override
  bool operator ==(Object other) {
    if (other is Minimum<T>) {
      return other.min == min;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, min);

  Map<String, dynamic> toMap() => {'name': name, 'value': min};
}

/// Validates that a value is greater than the specified [min]
class ExclusiveMinimum<T extends num> implements Validator<T> {
  /// The (exclusive) minimum allowed value
  final T min;

  @override
  final String name = 'exclusiveMinimum';

  ExclusiveMinimum(this.min);

  @override
  bool call(T input) => exclusiveMinimum(input, min);

  bool exclusiveMinimum(num input, num min) {
    return input > min;
  }

  @override
  bool operator ==(Object other) {
    if (other is ExclusiveMinimum<T>) {
      return other.min == min;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, min);

  Map<String, dynamic> toMap() => {'name': name, 'value': min};
}

/// Validates that a value is a multiple of the specified [divisor].
class MultipleOf<T extends num> implements Validator<T> {
  final T divisor;

  @override
  final String name = 'multipleOf';

  MultipleOf(this.divisor);

  @override
  bool call(num input) => multipleOf(input, divisor);

  bool multipleOf(num input, num divisor) {
    if (divisor == 0) {
      return false;
    }
    return input % divisor == 0;
  }

  @override
  bool operator ==(Object other) {
    if (other is MultipleOf<T>) {
      return other.divisor == divisor;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, divisor);

  Map<String, dynamic> toMap() => {'name': name, 'value': divisor};
}

/// Validates that a value is within the specified [range]
class InRange implements Validator<num> {
  final Range range;

  @override
  final String name = 'inRange';

  InRange(this.range);

  @override
  bool call(num input) => range.contains(input);

  @override
  bool operator ==(Object other) {
    if (other is InRange) {
      return other.range == range;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, range);

  Map<String, dynamic> toMap() => {'name': name, 'value': range.toMap()};
}

/// Validates that a string is not longer than the specified [maximumLength]
class MaximumLength implements Validator<String> {
  final int maximumLength;

  @override
  final String name = 'maximumLength';

  MaximumLength(this.maximumLength);

  @override
  bool call(String input) => maxLength(input, maximumLength);

  static bool maxLength(String input, int maximumLength) {
    return input.characters.length <= maximumLength;
  }

  @override
  bool operator ==(Object other) {
    if (other is MaximumLength) {
      return other.maximumLength == maximumLength;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, maximumLength);

  Map<String, dynamic> toMap() => {'name': name, 'value': maximumLength};
}

/// Validates that a string is exactly the specified [length]
class ExactLength implements Validator<String> {
  final int length;

  @override
  final String name = 'exactLength';

  ExactLength(this.length);

  @override
  bool call(String input) => input.characters.length == length;

  @override
  bool operator ==(Object other) {
    if (other is ExactLength) {
      return other.length == length;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, length);

  Map<String, dynamic> toMap() => {'name': name, 'value': length};
}

/// Validates that a string is not shorter than the specified [minimumLength]
class MinimumLength implements Validator<String> {
  final int minimumLength;

  @override
  final String name = 'minimumLength';

  MinimumLength(this.minimumLength);

  @override
  bool call(String input) => minLength(input, minimumLength);

  bool minLength(String input, int minimumLength) {
    return input.characters.length >= minimumLength;
  }

  @override
  bool operator ==(Object other) {
    if (other is MinimumLength) {
      return other.minimumLength == minimumLength;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, minimumLength);

  Map<String, dynamic> toMap() => {'name': name, 'value': minimumLength};
}

class InRangeLength implements Validator<String> {
  final Range range;

  @override
  final String name = 'inRangeLength';

  InRangeLength(this.range);

  @override
  bool call(String input) => range.contains(input.characters.length);

  @override
  bool operator ==(Object other) {
    if (other is InRangeLength) {
      return other.range == range;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, range);

  Map<String, dynamic> toMap() => {'name': name, 'value': range.toMap()};
}

/// Validates that a string matches the specified [pattern]
class PatternValidator implements Validator<String> {
  final RegExp pattern;

  @override
  final String name = 'pattern';

  PatternValidator(this.pattern);

  PatternValidator.fromString(String pattern) : this(RegExp(pattern));

  @override
  bool call(String input) {
    final match = pattern.firstMatch(input);

    return match != null && match.start == 0 && match.end == input.length;
  }

  @override
  bool operator ==(Object other) {
    if (other is PatternValidator) {
      return other.pattern == pattern;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, pattern);

  Map<String, dynamic> toMap() => {
    'name': name,
    'value': pattern.pattern.toString(),
  };
}

/// Validates that a list has at most [max] items
class MaxItems<T> implements Validator<Iterable<T>> {
  final int max;

  @override
  final String name = 'maxItems';

  MaxItems(this.max);

  @override
  bool call(Iterable input) => maxItems(input, max);

  bool maxItems(Iterable input, int max) => input.length <= max;

  @override
  bool operator ==(Object other) {
    if (other is MaxItems) {
      return other.max == max;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, max);

  Map<String, dynamic> toMap() => {'name': name, 'value': max};
}

/// Validates that a list has at least [min] items
class MinItems<T> implements Validator<Iterable<T>> {
  final int min;

  @override
  final String name = 'minItems';

  MinItems(this.min);

  @override
  bool call(Iterable input) => minItems(input, min);

  bool minItems(Iterable input, int min) => input.length >= min;

  @override
  bool operator ==(Object other) {
    if (other is MinItems) {
      return other.min == min;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, min);

  Map<String, dynamic> toMap() => {'name': name, 'value': min};
}

/// Validates that a list has [count] items
class ItemCount<T> implements Validator<Iterable<T>> {
  final int count;

  @override
  final String name = 'itemCount';

  ItemCount(this.count);

  @override
  bool call(Iterable<T> input) => countItems(input, count);

  bool countItems(Iterable input, int count) => input.length == count;

  @override
  bool operator ==(Object other) {
    if (other is ItemCount) {
      return other.count == count;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, count);

  Map<String, dynamic> toMap() => {'name': name, 'value': count};
}

/// Validates that a list has a unique set of items
class UniqueItems<T> implements Validator<Iterable<T>> {
  @override
  final String name = 'uniqueItems';

  @override
  bool call(Iterable input) => uniqueItems(input);

  bool uniqueItems(Iterable input) => input.length == input.toSet().length;

  @override
  bool operator ==(Object other) => other is UniqueItems;

  @override
  int get hashCode => name.hashCode; // I'm not convinced

  Map<String, dynamic> toMap() => {'name': name};
}

/// Validates that a map has at least [min] key/value pairs
class MinProperties implements Validator<Map> {
  final int min;

  @override
  final String name = 'minProperties';

  MinProperties(this.min);

  @override
  bool call(Map input) => input.length >= min;

  @override
  bool operator ==(Object other) {
    if (other is MinProperties) {
      return other.min == min;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, min);

  Map<String, dynamic> toMap() => {'name': name, 'value': min};
}

/// Validates that a map has at most [max] key/value pairs
class MaxProperties implements Validator<Map> {
  final int max;

  @override
  final String name = 'maxProperties';

  MaxProperties(this.max);

  @override
  bool call(Map input) => input.length <= max;

  @override
  bool operator ==(Object other) {
    if (other is MaxProperties) {
      return other.max == max;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(name, max);

  Map<String, dynamic> toMap() => {'name': name, 'value': max};
}

/// Validates that a map contains all of the specified [properties]
class Required implements Validator<Map> {
  final List<String> properties;

  @override
  final String name = 'required';

  Required(Iterable properties)
    : properties = UnmodifiableListView([...properties]);

  @override
  bool call(Map input) => isSubList(properties, input.keys.toList());

  @override
  bool operator ==(Object other) {
    if (other is Required) {
      return hasTheSameElements(other.properties, properties);
    }
    return false;
  }

  @override
  int get hashCode => Object.hashAllUnordered([name, ...properties]);

  Map<String, dynamic> toMap() => {'name': name, 'value': properties};
}

/// Validates that a value matches one of the JSON Schema [type] strings.
///
/// Supported types: `string`, `number`, `integer`, `boolean`, `array`,
/// `object`, `null`.
class TypeValidator implements Validator<dynamic> {
  /// The expected JSON Schema type string.
  final String type;

  @override
  final String name = 'type';

  TypeValidator(this.type);

  @override
  bool call(dynamic input) {
    return switch (type) {
      'string' => input is String,
      'number' => input is num,
      'integer' => input is int,
      'boolean' => input is bool,
      'array' => input is List,
      'object' => input is Map,
      'null' => input == null,
      _ => false,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is TypeValidator && other.type == type;

  @override
  int get hashCode => Object.hash(name, type);

  Map<String, dynamic> toMap() => {'name': name, 'value': type};
}

/// Validates each entry in a map against a per-key [Validator].
///
/// Only validates keys that are present in the map — absent keys are ignored
/// (use [Required] to enforce presence). Any key in [properties] not present
/// in the input map is silently skipped.
class PropertiesValidator implements Validator<Map> {
  /// Per-field validators keyed by field name.
  final Map<String, Validator<dynamic>> properties;

  @override
  final String name = 'properties';

  PropertiesValidator(Map<String, Validator<dynamic>> properties)
    : properties = Map.unmodifiable(properties);

  @override
  bool call(Map input) {
    for (final MapEntry(:key, value: validator) in properties.entries) {
      if (!input.containsKey(key)) continue;
      if (!validator(input[key])) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! PropertiesValidator) return false;
    if (other.properties.length != properties.length) return false;
    for (final entry in properties.entries) {
      if (other.properties[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered([
    name,
    ...properties.entries.map((e) => Object.hash(e.key, e.value)),
  ]);

  Map<String, dynamic> toMap() => {
    'name': name,
    'value': {for (final e in properties.entries) e.key: e.value.toString()},
  };
}

/// Validates that a map contains no keys outside [allowedProperties].
///
/// Corresponds to `additionalProperties: false` in JSON Schema. Keys not
/// listed in [allowedProperties] cause validation to fail.
class AdditionalPropertiesValidator implements Validator<Map> {
  /// The complete set of permitted property names.
  final Set<String> allowedProperties;

  @override
  final String name = 'additionalProperties';

  AdditionalPropertiesValidator(Iterable<String> allowed)
    : allowedProperties = Set.unmodifiable(Set<String>.from(allowed));

  @override
  bool call(Map input) {
    for (final key in input.keys) {
      if (!allowedProperties.contains(key)) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! AdditionalPropertiesValidator) return false;
    if (other.allowedProperties.length != allowedProperties.length) {
      return false;
    }
    return other.allowedProperties.containsAll(allowedProperties);
  }

  @override
  int get hashCode => Object.hashAllUnordered([name, ...allowedProperties]);

  Map<String, dynamic> toMap() => {
    'name': name,
    'value': allowedProperties.toList()..sort(),
  };
}

/// Validates that every element in an iterable satisfies [itemValidator].
///
/// Corresponds to `items` in JSON Schema. An empty iterable always passes.
class ItemsValidator<T> implements Validator<Iterable<T>> {
  /// The validator applied to each element.
  final Validator<T> itemValidator;

  @override
  final String name = 'items';

  ItemsValidator(this.itemValidator);

  @override
  bool call(Iterable<T> input) => input.every(itemValidator.call);

  @override
  bool operator ==(Object other) =>
      other is ItemsValidator && other.itemValidator == itemValidator;

  @override
  int get hashCode => Object.hash(name, itemValidator);

  Map<String, dynamic> toMap() => {'name': name, 'value': itemValidator.name};
}

/// Validates that, if a map has a specified key then it also has
/// a set of dependent keys.
///
/// For example:
///
/// if [properties] is
///
/// ```dart
/// {
///   'x': ['a'],
///   'y': ['b', 'c'],
/// }
/// ```
///
/// Then if [input] has `x` and `y` then it must also have keys `a`, `b`, and `c`.
///
/// ... or if [input] only has `x` then it must also have keys `a`.
///
/// ... or if [input] only has `y` then it must also have keys `b` and `c`.
///
class DependentRequired implements Validator<Map> {
  final Map<String, List<String>> properties;

  @override
  final String name = 'dependentRequired';

  DependentRequired(Map<String, List<String>> properties)
    : properties = UnmodifiableMapView({
        ...properties.map((k, v) => MapEntry(k, UnmodifiableListView(v))),
      });

  @override
  bool call(Map input) {
    for (final MapEntry(:key, :value) in properties.entries) {
      if (input.containsKey(key)) {
        if (!isSubList(value, input.keys.toList())) return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is DependentRequired) {
      if (properties.length != other.properties.length) return false;
      if (!hasTheSameElements(properties.keys, other.properties.keys)) {
        return false;
      }
      for (final entry in properties.entries) {
        if (!hasTheSameElements(entry.value, other.properties[entry.key]!)) {
          return false;
        }
      }
      return true;
    }

    return false;
  }

  @override
  int get hashCode {
    final pairs = <(String, String)>[];
    for (final entry in properties.entries) {
      pairs.addAll([for (final v in entry.value) (entry.key, v)]);
    }
    return Object.hashAllUnordered([name, ...pairs]);
  }

  Map<String, dynamic> toMap() => {'name': name, 'value': properties};
}
