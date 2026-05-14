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

import 'schema_rule.dart';

/// Parses a JSON Schema subset map into a [SchemaRule] tree.
///
/// The supported keyword set is defined in spec §25 (`schemaModelVersion: 1`).
/// Unknown keywords are silently ignored so that schemas written by a newer
/// KMDB version can be partially interpreted by an older one.
///
/// Example:
/// ```dart
/// final rule = SchemaParser().parse({
///   'required': ['name', 'email'],
///   'properties': {
///     'name': {'type': 'string', 'minLength': 1},
///     'email': {'type': 'string', 'format': 'email'},
///     'age': {'type': 'integer', 'minimum': 0},
///   },
/// });
/// final violations = rule.validate({'name': 'Alice'}, '');
/// // → [{path: 'email', message: 'required field is missing'}]
/// ```
final class SchemaParser {
  /// Parses [schema] into a [SchemaRule] tree.
  ///
  /// Returns a [CompositeRule] whose child rules correspond to each recognised
  /// JSON Schema keyword present in [schema]. An empty schema produces a
  /// [CompositeRule] with no children, which always validates successfully.
  SchemaRule parse(Map<String, dynamic> schema) {
    final rules = <SchemaRule>[];

    // type
    final type = schema['type'];
    if (type is String) {
      rules.add(TypeRule(type));
    }

    // required
    final required = schema['required'];
    if (required is List) {
      rules.add(RequiredRule(List<String>.from(required)));
    }

    // enum
    final enumValues = schema['enum'];
    if (enumValues is List) {
      rules.add(EnumRule(List<dynamic>.from(enumValues)));
    }

    // numeric constraints
    final minimum = schema['minimum'] as num?;
    final maximum = schema['maximum'] as num?;
    final exclusiveMinimum = schema['exclusiveMinimum'] as num?;
    final exclusiveMaximum = schema['exclusiveMaximum'] as num?;
    if (minimum != null ||
        maximum != null ||
        exclusiveMinimum != null ||
        exclusiveMaximum != null) {
      rules.add(
        NumericRule(
          minimum: minimum,
          maximum: maximum,
          exclusiveMinimum: exclusiveMinimum,
          exclusiveMaximum: exclusiveMaximum,
        ),
      );
    }

    // string constraints
    final minLength = schema['minLength'] as int?;
    final maxLength = schema['maxLength'] as int?;
    final patternStr = schema['pattern'] as String?;
    if (minLength != null || maxLength != null || patternStr != null) {
      rules.add(
        StringRule(
          minLength: minLength,
          maxLength: maxLength,
          pattern: patternStr != null ? RegExp(patternStr) : null,
        ),
      );
    }

    // format
    final format = schema['format'] as String?;
    if (format != null) {
      rules.add(FormatRule(format));
    }

    // properties — parse each sub-schema recursively
    final propertiesRaw = schema['properties'];
    Map<String, SchemaRule>? parsedProperties;
    if (propertiesRaw is Map) {
      parsedProperties = {
        for (final entry in propertiesRaw.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key as String: parse(entry.value as Map<String, dynamic>),
      };
      rules.add(PropertiesRule(parsedProperties));
    }

    // additionalProperties: false — only active when properties are declared
    if (schema['additionalProperties'] == false && parsedProperties != null) {
      rules.add(AdditionalPropertiesRule(parsedProperties.keys.toSet()));
    }

    // array constraints
    final minItems = schema['minItems'] as int?;
    final maxItems = schema['maxItems'] as int?;
    final itemsRaw = schema['items'];
    SchemaRule? itemsRule;
    if (itemsRaw is Map<String, dynamic>) {
      itemsRule = parse(itemsRaw);
    }
    if (minItems != null || maxItems != null || itemsRule != null) {
      rules.add(
        ArrayRule(minItems: minItems, maxItems: maxItems, items: itemsRule),
      );
    }

    return CompositeRule(rules);
  }
}
