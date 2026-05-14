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

/// A single JSON Schema validation failure.
///
/// [path] is the dot-notation path to the field that failed (e.g. `'address.city'`,
/// `'tags[0]'`). An empty string means the violation is at the root document
/// level (e.g. a `required` field is missing from the top-level map).
///
/// [message] is a human-readable description of the constraint that was
/// violated, suitable for display in error messages and logs.
final class SchemaViolation {
  /// Creates a [SchemaViolation] at [path] with [message].
  const SchemaViolation({required this.path, required this.message});

  /// Dot-notation path to the offending field, or `''` for root-level violations.
  final String path;

  /// Human-readable description of the violated constraint.
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';

  @override
  bool operator ==(Object other) =>
      other is SchemaViolation &&
      other.path == path &&
      other.message == message;

  @override
  int get hashCode => Object.hash(path, message);
}
