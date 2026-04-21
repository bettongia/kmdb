// Copyright 2026 The KMDB Authors
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

/// Sentinel value returned by [FieldPath.resolve] when a field is absent from
/// a document.
///
/// Distinct from `null` so that `isNull()` can match both explicit `null`
/// values and missing fields, while `isNotNull()` requires presence AND
/// non-null (spec §13, "Missing vs Null Semantics").
const Object missing = _Missing._();

/// Internal singleton used as the missing-field sentinel.
final class _Missing {
  const _Missing._();

  @override
  String toString() => '<missing>';
}

/// Resolves a JSONPath-subset path against a decoded document map.
///
/// KMDB supports an ergonomic subset of RFC 9535 (JSONPath). The full
/// supported syntax is documented in spec §13 (Query API):
///
/// | Syntax              | Example               | Resolves to                  |
/// | ------------------- | --------------------- | ---------------------------- |
/// | Identifier          | `name`                | Top-level field              |
/// | Dot child           | `address.city`        | Nested object field          |
/// | Optional root sigil | `$.address.city`      | Same as `address.city`       |
/// | Array wildcard      | `tags[*]` or `tags[]` | All elements — fan-out       |
/// | Positional index    | `tags[0]`             | Element at index 0           |
/// | Negative index      | `tags[-1]`            | Last element                 |
/// | Deep nested         | `meta.stats.views`    | Deeply nested field          |
///
/// The leading `$.` prefix (or bare `$` followed immediately by `[`) is
/// optional and stripped during normalisation, so `$.address.city` and
/// `address.city` are equivalent. `[*]` is a synonym for `[]` (fan-out) —
/// both return a [List] of all array elements.
///
/// Returns the [missing] sentinel when any segment in the path is absent or
/// a parent value is not a [Map] or [List] as required.
///
/// Throws [ArgumentError] for a bare `$` with no child path — `$` alone is
/// not a valid field selector in KMDB's document model.
///
/// ## Example
///
/// ```dart
/// final doc = {'address': {'city': 'London'}, 'tags': ['dart', 'flutter']};
/// FieldPath.resolve('address.city', doc);   // 'London'
/// FieldPath.resolve('$.address.city', doc); // 'London' (same)
/// FieldPath.resolve('tags[-1]', doc);       // 'flutter'
/// FieldPath.resolve('tags[*]', doc);        // ['dart', 'flutter']
/// FieldPath.resolve('address.zip', doc);    // missing
/// ```
abstract final class FieldPath {
  FieldPath._();

  /// Resolves [path] against [doc] and returns the field value.
  ///
  /// Returns [missing] when the path cannot be resolved. Returns a [List] for
  /// fan-out paths ending with `[]`. Never throws for absent fields — use
  /// `value == missing` to test.
  ///
  /// Throws [ArgumentError] if [path] is a bare `$` with no child path.
  static Object? resolve(String path, Map<String, dynamic> doc) {
    // Normalise the path: strip optional leading "$." prefix, rewrite "[*]"
    // to "[]", and reject a bare "$".
    final normPath = _normalise(path);
    // Split on dot, then handle bracket notation within each segment.
    final rawSegments = normPath.split('.');
    return _resolveSegments(rawSegments, doc);
  }

  /// Normalises [path] and returns the canonical form.
  ///
  /// This is the same normalisation applied internally by [resolve]. Exposed
  /// so that [IndexDefinition] and other callers can store the canonical path
  /// and compute consistent storage namespaces.
  ///
  /// Throws [ArgumentError] if [path] is a bare `$`.
  static String normalisePath(String path) => _normalise(path);

  /// Normalises [path] by stripping an optional leading `$.` prefix and
  /// rewriting `[*]` to `[]`.
  ///
  /// Rules:
  /// - `$.address.city` → `address.city`
  /// - `$[0]` → `[0]`  (strips `$` when followed immediately by `[`)
  /// - `tags[*]` → `tags[]`
  /// - `$$foo` is NOT normalised — only a single leading `$` is treated as
  ///   the root sigil; double-`$` is left as-is and will not resolve.
  /// - A bare `$` (with nothing after it) throws [ArgumentError] because
  ///   it has no field path meaning in KMDB's document model.
  static String _normalise(String path) {
    var result = path;

    // Handle the leading `$` sigil: only a single leading `$` qualifies as a
    // root sigil. `$$foo` must not be normalised.
    if (result.startsWith(r'$') && !result.startsWith(r'$$')) {
      if (result == r'$') {
        // Bare `$` with no child — invalid in KMDB's field-selector context.
        throw ArgumentError.value(
          path,
          'path',
          "A bare '\$' is not a valid field path. "
              "Provide a child path, e.g. '\$.address.city'.",
        );
      }
      if (result.startsWith(r'$.')) {
        // Strip the "$." prefix: "$.address.city" → "address.city"
        result = result.substring(2);
      } else if (result.startsWith(r'$[')) {
        // "$[0]" → "[0]": strip only the "$", keep the bracket expression.
        // This produces a bare "[0]" segment which resolves to missing since
        // the document root is always a Map, not a List — the correct outcome.
        result = result.substring(1);
      }
      // Any other "$"-prefixed form (e.g. "$foo" without a dot) is left
      // as-is — it will simply fail to resolve against a Map root.
    }

    // Rewrite "[*]" to "[]" everywhere in the path so downstream code always
    // sees the canonical fan-out notation. This means IndexWriter's
    // `path.endsWith('[]')` fan-out check always sees the canonical form
    // regardless of whether the user supplied `[*]` or `[]`.
    result = result.replaceAll('[*]', '[]');

    return result;
  }

  static Object? _resolveSegments(List<String> segments, Object? current) {
    for (final raw in segments) {
      if (current == null || current == missing) return missing;

      // Check for array access: "tags[0]", "tags[-1]", or "tags[]"
      final bracketIdx = raw.indexOf('[');
      if (bracketIdx != -1) {
        final fieldName = bracketIdx == 0 ? null : raw.substring(0, bracketIdx);
        final inner = raw.substring(
          bracketIdx + 1,
          raw.length - 1,
        ); // strip [ ]

        // Resolve the field first if there is one
        Object? arrayValue = current;
        if (fieldName != null) {
          if (arrayValue is! Map<String, dynamic>) return missing;
          arrayValue = (arrayValue)[fieldName] ?? missing;
          if (!arrayValue.isActualValue) return missing;
        }

        if (inner.isEmpty) {
          // Fan-out: return all elements as a List.
          if (arrayValue is! List) return missing;
          return arrayValue;
        } else {
          // Specific index access — supports negative indices.
          final idx = int.tryParse(inner);
          if (idx == null) return missing;
          if (arrayValue is! List) return missing;

          // Resolve negative indices: -1 is the last element, -2 is second-
          // to-last, etc. Out-of-range (including beyond the negative bound)
          // returns missing.
          final resolvedIdx = idx < 0 ? arrayValue.length + idx : idx;
          if (resolvedIdx < 0 || resolvedIdx >= arrayValue.length) {
            return missing;
          }
          current = arrayValue[resolvedIdx];
          continue;
        }
      }

      // Plain field access.
      if (current is! Map<String, dynamic>) return missing;
      final next = current[raw];
      // Distinguish absent key from explicit null.
      if (!current.containsKey(raw)) return missing;
      current = next;
    }
    return current;
  }
}

extension _MissingCheck on Object? {
  bool get isActualValue => this != missing;
}
