// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'field_path.dart';
import 'filter.dart';

/// Entry point for field-level filters in the KMDB query DSL.
///
/// Construct a [Field] with a dot-notation path and chain a comparison or
/// predicate method to produce a [Filter]:
///
/// ```dart
/// Field('status').equals('active')
/// Field('address.city').equals('London')
/// Field('tags').containsAll(['dart', 'flutter'])
/// Field('meta.stats.views').isGreaterThan(100)
/// ```
///
/// Dot-notation paths follow the same rules as index definitions (spec §16):
/// - `"city"` — top-level field
/// - `"address.city"` — nested field
/// - `"tags[0]"` — specific array element
/// - `"tags[]"` — fan-out (matches if **any** element satisfies the predicate)
final class Field {
  /// Creates a field selector for [path].
  ///
  /// [path] is a dot-notation field path as described in spec §16.
  const Field(this.path);

  /// The dot-notation path this field selector targets.
  final String path;

  // ── Equality & comparison ──────────────────────────────────────────────────

  /// Matches documents where the field equals [value].
  ///
  /// Set [caseSensitive] to `false` for a case-insensitive string match.
  /// Has no effect when [value] is not a [String].
  Filter equals(Object? value, {bool caseSensitive = true}) =>
      _FieldFilter(path, _Op.eq, value, caseSensitive: caseSensitive);

  /// Matches documents where the field does not equal [value].
  Filter notEquals(Object? value) => _FieldFilter(path, _Op.neq, value);

  /// Matches documents where the field is strictly greater than [value].
  Filter isGreaterThan(Object value) => _FieldFilter(path, _Op.gt, value);

  /// Matches documents where the field is strictly less than [value].
  Filter isLessThan(Object value) => _FieldFilter(path, _Op.lt, value);

  /// Matches documents where the field is greater than or equal to [value].
  Filter isGreaterThanOrEqualTo(Object value) =>
      _FieldFilter(path, _Op.gte, value);

  /// Matches documents where the field is less than or equal to [value].
  Filter isLessThanOrEqualTo(Object value) =>
      _FieldFilter(path, _Op.lte, value);

  /// Matches documents where the field value falls within [[min], [max]]
  /// (inclusive on both ends).
  Filter isBetween(Object min, Object max) =>
      _FieldFilter(path, _Op.between, (min, max));

  // ── Set membership ─────────────────────────────────────────────────────────

  /// Matches documents where the field value is one of [values].
  Filter isIn(List<Object?> values) => _FieldFilter(path, _Op.isIn, values);

  /// Matches documents where the field value is not in [values].
  Filter isNotIn(List<Object?> values) =>
      _FieldFilter(path, _Op.isNotIn, values);

  // ── Null / existence ───────────────────────────────────────────────────────

  /// Matches documents where the field is absent **or** explicitly `null`.
  Filter isNull() => _FieldFilter(path, _Op.isNull, null);

  /// Matches documents where the field is present **and** non-null.
  Filter isNotNull() => _FieldFilter(path, _Op.isNotNull, null);

  // ── Boolean ────────────────────────────────────────────────────────────────

  /// Matches documents where the field is `true`.
  Filter isTrue() => _FieldFilter(path, _Op.isTrue, null);

  /// Matches documents where the field is `false`.
  Filter isFalse() => _FieldFilter(path, _Op.isFalse, null);

  // ── String ────────────────────────────────────────────────────────────────

  /// Matches documents where the (String) field starts with [prefix].
  ///
  /// Set [caseSensitive] to `false` for a case-insensitive match.
  Filter startsWith(String prefix, {bool caseSensitive = true}) =>
      _FieldFilter(path, _Op.startsWith, prefix, caseSensitive: caseSensitive);

  /// Matches documents where the (String) field ends with [suffix].
  ///
  /// Set [caseSensitive] to `false` for a case-insensitive match.
  Filter endsWith(String suffix, {bool caseSensitive = true}) =>
      _FieldFilter(path, _Op.endsWith, suffix, caseSensitive: caseSensitive);

  /// Matches documents where the (String) field contains the given substring, OR
  /// where the array field contains the given element.
  ///
  /// - If the resolved value is a `String`, performs a substring match.
  ///   Set [caseSensitive] to `false` for a case-insensitive substring match.
  /// - If the resolved value is a `List`, checks for element membership.
  ///   [caseSensitive] has no effect for list membership checks.
  Filter contains(Object value, {bool caseSensitive = true}) =>
      _FieldFilter(path, _Op.contains, value, caseSensitive: caseSensitive);

  // ── Array ─────────────────────────────────────────────────────────────────

  /// Matches documents where the (List) field contains **all** of [values].
  Filter containsAll(List<Object?> values) =>
      _FieldFilter(path, _Op.containsAll, values);

  /// Matches documents where the (List) field contains **at least one** of
  /// [values].
  Filter containsAny(List<Object?> values) =>
      _FieldFilter(path, _Op.containsAny, values);
}

// ── Operation enum ─────────────────────────────────────────────────────────────

enum _Op {
  eq,
  neq,
  gt,
  lt,
  gte,
  lte,
  between,
  isIn,
  isNotIn,
  isNull,
  isNotNull,
  isTrue,
  isFalse,
  startsWith,
  endsWith,
  contains,
  containsAll,
  containsAny,
}

// ── FieldFilter implementation ─────────────────────────────────────────────────

final class _FieldFilter extends Filter {
  const _FieldFilter(
    this._path,
    this._op,
    this._operand, {
    this.caseSensitive = true,
  });

  final String _path;
  final _Op _op;
  final Object? _operand;
  final bool caseSensitive;

  @override
  (String, Object?)? get equalityPredicate =>
      _op == _Op.eq ? (_path, _operand) : null;

  @override
  bool evaluate(Map<String, dynamic> document) {
    final value = FieldPath.resolve(_path, document);

    switch (_op) {
      case _Op.isNull:
        // Matches missing fields AND explicit null.
        return value == missing || value == null;

      case _Op.isNotNull:
        return value != missing && value != null;

      case _Op.isTrue:
        return value == true;

      case _Op.isFalse:
        return value == false;

      case _Op.eq:
        if (value == missing) return false;
        if (!caseSensitive && value is String && _operand is String) {
          return value.toLowerCase() == _operand.toLowerCase();
        }
        return _coercedEquals(value, _operand);

      case _Op.neq:
        if (value == missing) return true; // absent ≠ anything
        return !_coercedEquals(value, _operand);

      case _Op.gt:
        final cmp = _compare(value, _operand);
        return cmp != null && cmp > 0;

      case _Op.lt:
        final cmp = _compare(value, _operand);
        return cmp != null && cmp < 0;

      case _Op.gte:
        final cmp = _compare(value, _operand);
        return cmp != null && cmp >= 0;

      case _Op.lte:
        final cmp = _compare(value, _operand);
        return cmp != null && cmp <= 0;

      case _Op.between:
        final (min, max) = _operand as (Object, Object);
        final cmpMin = _compare(value, min);
        final cmpMax = _compare(value, max);
        return cmpMin != null && cmpMax != null && cmpMin >= 0 && cmpMax <= 0;

      case _Op.isIn:
        if (value == missing) return false;
        final list = _operand as List<Object?>;
        return list.any((v) => _coercedEquals(value, v));

      case _Op.isNotIn:
        if (value == missing) return true;
        final list = _operand as List<Object?>;
        return !list.any((v) => _coercedEquals(value, v));

      case _Op.startsWith:
        if (value is! String) return false;
        final swPrefix = _operand as String;
        return caseSensitive
            ? value.startsWith(swPrefix)
            : value.toLowerCase().startsWith(swPrefix.toLowerCase());

      case _Op.endsWith:
        if (value is! String) return false;
        final ewSuffix = _operand as String;
        return caseSensitive
            ? value.endsWith(ewSuffix)
            : value.toLowerCase().endsWith(ewSuffix.toLowerCase());

      case _Op.contains:
        if (value is String) {
          final cSubstr = _operand as String;
          return caseSensitive
              ? value.contains(cSubstr)
              : value.toLowerCase().contains(cSubstr.toLowerCase());
        }
        if (value is List) return value.any((e) => _coercedEquals(e, _operand));
        return false;

      case _Op.containsAll:
        if (value is! List) return false;
        final required = _operand as List<Object?>;
        return required.every((v) => value.any((e) => _coercedEquals(e, v)));

      case _Op.containsAny:
        if (value is! List) return false;
        final any = _operand as List<Object?>;
        return any.any((v) => value.any((e) => _coercedEquals(e, v)));
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// Compares [a] with [b] and returns a negative, zero, or positive integer.
  ///
  /// Returns `null` when the types are not comparable (e.g. comparing a String
  /// to a number). Handles `num` coercion so that `int` and `double` compare
  /// correctly.
  static int? _compare(Object? a, Object? b) {
    if (a == missing || a == null || b == null) return null;
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    return null;
  }

  /// Equality check with numeric coercion (int 1 == double 1.0).
  static bool _coercedEquals(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return a == b;
  }
}
