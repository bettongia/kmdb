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

/// Layer 1 of the formal write pipeline: admission-gate validation.
///
/// A [WriteValidator] is called before any I/O when a document is written to a
/// [KmdbCollection]. Validators run in registration order; if any validator
/// throws, the write is aborted and no partial I/O has occurred.
///
/// ## Implementing a validator
///
/// ```dart
/// final class RequiredFieldValidator implements WriteValidator {
///   const RequiredFieldValidator(this._fields);
///   final List<String> _fields;
///
///   @override
///   void validate(String collection, Map<String, dynamic> document) {
///     for (final field in _fields) {
///       if (!document.containsKey(field)) {
///         throw ArgumentError('Missing required field: $field');
///       }
///     }
///   }
/// }
/// ```
///
/// See also:
/// - [WriteAugmentor] — Layer 2: adds extra entries to the [WriteBatch].
abstract interface class WriteValidator {
  /// Validates [document] before it is written to [collection].
  ///
  /// Throws to abort the write. Called before any I/O — no partial write
  /// can occur if a validator throws.
  ///
  /// The [document] passed here is the fully-decoded map as produced by
  /// [KmdbCodec.encode]; the `_id` field has already been removed. Validators
  /// should not mutate the document.
  void validate(String collection, Map<String, dynamic> document);
}
