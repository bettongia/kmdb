// Copyright 2026 The Authors.
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

import 'schema_parser.dart';
import 'schema_rule.dart';
import 'schema_violation.dart';

/// A compiled JSON Schema validator that validates Dart maps against a schema.
///
/// [JsonSchemaValidator] is a convenience wrapper around [SchemaParser] that
/// accepts either a `Map<String, dynamic>` or a JSON string, compiles the
/// schema at construction time, and exposes a single [validate] call.
///
/// This type is intended for non-KMDB consumers who need to validate documents
/// against a JSON Schema without understanding the internal [SchemaRule]
/// hierarchy.
///
/// Example:
/// ```dart
/// final validator = JsonSchemaValidator.fromMap({
///   'required': ['name', 'email'],
///   'properties': {
///     'name': {'type': 'string', 'minLength': 1},
///     'email': {'type': 'string', 'format': 'email'},
///   },
/// });
///
/// final violations = validator.validate({'name': 'Alice'});
/// // → [SchemaViolation(path: 'email', message: 'required field is missing')]
/// ```
final class JsonSchemaValidator {
  /// Compiles [schema] into a validator.
  ///
  /// [schema] must be a JSON Schema subset map. Unknown keywords are silently
  /// ignored. An empty map produces a validator that always passes.
  JsonSchemaValidator.fromMap(Map<String, dynamic> schema)
    : _rule = SchemaParser().parse(schema);

  /// Parses [json] as a JSON Schema string and compiles it into a validator.
  ///
  /// Throws [FormatException] if [json] is not valid JSON or if the decoded
  /// value is not a JSON object (e.g. an array or a scalar).
  ///
  /// Example:
  /// ```dart
  /// final validator = JsonSchemaValidator.fromJson(
  ///   '{"required": ["name"], "properties": {"name": {"type": "string"}}}',
  /// );
  /// ```
  factory JsonSchemaValidator.fromJson(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      rethrow;
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'JSON Schema must be a JSON object, '
        'got ${decoded.runtimeType}',
        json,
      );
    }
    return JsonSchemaValidator.fromMap(decoded);
  }

  /// The compiled rule tree produced by [SchemaParser].
  final SchemaRule _rule;

  /// Validates [document] against the compiled schema.
  ///
  /// Returns a list of every [SchemaViolation] found. An empty list means the
  /// document is valid. All violations are collected in a single pass so callers
  /// can surface every error at once.
  ///
  /// Example:
  /// ```dart
  /// final violations = validator.validate({'email': 'bob@example.com'});
  /// for (final v in violations) {
  ///   print(v); // e.g. "name: required field is missing"
  /// }
  /// ```
  List<SchemaViolation> validate(Map<String, dynamic> document) {
    return _rule.validate(document, '');
  }
}
