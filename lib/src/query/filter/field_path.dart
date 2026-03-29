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

/// Resolves a dot-notation path against a decoded document map.
///
/// Supports the following path forms (spec §16):
///
/// | Syntax | Resolves to |
/// | ------ | ----------- |
/// | `"city"` | `doc['city']` — top-level field |
/// | `"address.city"` | `doc['address']['city']` — nested object field |
/// | `"tags[0]"` | `doc['tags'][0]` — specific array element |
/// | `"tags[]"` | All elements of `doc['tags']` — fan-out, returns `List` |
/// | `"meta.stats.views"` | Deeply nested field |
///
/// Returns the [missing] sentinel when any segment in the path is absent or
/// a parent value is not a [Map] or [List] as required.
///
/// ## Example
///
/// ```dart
/// final doc = {'address': {'city': 'London'}};
/// final value = FieldPath.resolve('address.city', doc); // 'London'
/// final absent = FieldPath.resolve('address.zip', doc); // missing
/// ```
abstract final class FieldPath {
  FieldPath._();

  /// Resolves [path] against [doc] and returns the field value.
  ///
  /// Returns [missing] when the path cannot be resolved. Returns a [List] for
  /// fan-out paths ending with `[]`. Never throws for absent fields — use
  /// `value == missing` to test.
  static Object? resolve(String path, Map<String, dynamic> doc) {
    // Split on dot, then handle bracket notation within each segment.
    final rawSegments = path.split('.');
    return _resolveSegments(rawSegments, doc);
  }

  static Object? _resolveSegments(
      List<String> segments, Object? current) {
    for (final raw in segments) {
      if (current == null || current == missing) return missing;

      // Check for array access: "tags[0]" or "tags[]"
      final bracketIdx = raw.indexOf('[');
      if (bracketIdx != -1) {
        final fieldName = bracketIdx == 0 ? null : raw.substring(0, bracketIdx);
        final inner = raw.substring(bracketIdx + 1, raw.length - 1); // strip [ ]

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
          // Specific index access.
          final idx = int.tryParse(inner);
          if (idx == null) return missing;
          if (arrayValue is! List || idx < 0 || idx >= arrayValue.length) {
            return missing;
          }
          current = arrayValue[idx];
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
