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

import 'exceptions.dart';
import 'write_validator.dart';

/// Validates that a document contains no top-level keys starting with `_`.
///
/// The `_` prefix is reserved for KMDB system-managed fields (e.g. `_id`).
/// This validator is always registered first in the write pipeline so that
/// reserved-key violations are caught before any I/O is attempted.
///
/// Throws [ReservedFieldException] listing every offending key if any are
/// found. Validation runs before any I/O, so no partial writes occur.
///
/// ## Example
///
/// ```dart
/// const validator = ReservedKeyValidator();
/// validator.validate('contacts', {'name': 'Alice'}); // OK
/// validator.validate('contacts', {'_secret': 'x'});  // throws ReservedFieldException
/// ```
final class ReservedKeyValidator implements WriteValidator {
  /// Creates a [ReservedKeyValidator].
  const ReservedKeyValidator();

  @override
  void validate(String collection, Map<String, dynamic> document) {
    // Collect every top-level key that begins with '_'. Any such key is
    // reserved for KMDB system use (e.g. _id, _rev). User documents must not
    // contain reserved-prefix fields at the top level.
    final offending = document.keys
        .where((k) => k.startsWith('_'))
        .toList(growable: false);

    if (offending.isNotEmpty) {
      throw ReservedFieldException(offending);
    }
  }
}
