// Copyright 2026 The KMDB Authors.
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

import 'dart:convert';

import 'package:kmdb/kmdb.dart';

/// Parses a JSON filter expression into a [Filter].
///
/// The expression format mirrors the Filter DSL hierarchy:
///
/// ```json
/// // Logical combinators
/// {"and": [...]}
/// {"or":  [...]}
/// {"not": {...}}
///
/// // Field comparison
/// {"field": "status",       "op": "eq",         "value": "active"}
/// {"field": "score",        "op": "gt",         "value": 3}
/// {"field": "tags",         "op": "containsAll","value": ["dart","flutter"]}
/// {"field": "address.city", "op": "isNull"}
/// {"field": "score",        "op": "between",    "value": [1, 10]}
/// ```
///
/// Supported [op] strings:
/// `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `between`,
/// `in`, `notIn`,
/// `isNull`, `isNotNull`, `isTrue`, `isFalse`,
/// `startsWith`, `endsWith`, `contains`,
/// `containsAll`, `containsAny`.
///
/// The optional `"insensitive": true` key enables case-insensitive matching
/// for string ops (`eq`, `startsWith`, `endsWith`, `contains`).
/// It has no effect on non-string values or other operators.
abstract final class FilterParser {
  FilterParser._();

  /// Parses [jsonString] as a JSON filter expression and returns a [Filter].
  ///
  /// Throws [FormatException] for invalid JSON.
  /// Throws [ArgumentError] for unrecognised structure or unknown operators.
  static Filter parse(String jsonString) {
    final dynamic raw = json.decode(jsonString);
    return _fromJson(raw);
  }

  static Filter _fromJson(dynamic node) {
    if (node is! Map<String, dynamic>) {
      throw ArgumentError(
        'Expected a JSON object, got ${node.runtimeType}: $node',
      );
    }

    // Logical combinators.
    if (node.containsKey('and')) {
      final list = _requireList(node['and'], 'and');
      return Filter.and(list.map(_fromJson).toList());
    }
    if (node.containsKey('or')) {
      final list = _requireList(node['or'], 'or');
      return Filter.or(list.map(_fromJson).toList());
    }
    if (node.containsKey('not')) {
      return Filter.not(_fromJson(node['not']));
    }

    // Field comparison.
    final fieldRaw = node['field'];
    final opRaw = node['op'];
    if (fieldRaw == null || opRaw == null) {
      throw ArgumentError(
        'Filter node must have "and"/"or"/"not" or "field"+"op" keys: $node',
      );
    }
    final field = fieldRaw as String;
    final op = opRaw as String;
    final value = node['value'];
    final caseSensitive = !((node['insensitive'] as bool?) ?? false);

    return _buildFieldFilter(field, op, value, caseSensitive: caseSensitive);
  }

  // ignore: long-method
  static Filter _buildFieldFilter(
    String field,
    String op,
    dynamic value, {
    bool caseSensitive = true,
  }) {
    final f = Field(field);
    switch (op) {
      case 'eq':
        return f.equals(value, caseSensitive: caseSensitive);
      case 'ne':
        return f.notEquals(value);
      case 'lt':
        return f.isLessThan(value as Comparable);
      case 'lte':
        return f.isLessThanOrEqualTo(value as Comparable);
      case 'gt':
        return f.isGreaterThan(value as Comparable);
      case 'gte':
        return f.isGreaterThanOrEqualTo(value as Comparable);
      case 'between':
        final bounds = _requireListOf<Object>(value, 'between', 2);
        return f.isBetween(bounds[0], bounds[1]);
      case 'in':
        return f.isIn(_requireList(value, 'in').cast<Object?>());
      case 'notIn':
        return f.isNotIn(_requireList(value, 'notIn').cast<Object?>());
      case 'isNull':
        return f.isNull();
      case 'isNotNull':
        return f.isNotNull();
      case 'isTrue':
        return f.isTrue();
      case 'isFalse':
        return f.isFalse();
      case 'startsWith':
        return f.startsWith(value as String, caseSensitive: caseSensitive);
      case 'endsWith':
        return f.endsWith(value as String, caseSensitive: caseSensitive);
      case 'contains':
        return f.contains(value as Object, caseSensitive: caseSensitive);
      case 'containsAll':
        return f.containsAll(
          _requireList(value, 'containsAll').cast<Object?>(),
        );
      case 'containsAny':
        return f.containsAny(
          _requireList(value, 'containsAny').cast<Object?>(),
        );
      default:
        throw ArgumentError('Unknown filter operator: "$op"');
    }
  }

  static List<dynamic> _requireList(dynamic value, String context) {
    if (value is! List) {
      throw ArgumentError(
        '"$context" requires a JSON array, got ${value.runtimeType}',
      );
    }
    return value;
  }

  static List<T> _requireListOf<T>(dynamic value, String context, int length) {
    final list = _requireList(value, context);
    if (list.length != length) {
      throw ArgumentError(
        '"$context" requires exactly $length elements, got ${list.length}',
      );
    }
    return list.cast<T>();
  }
}
