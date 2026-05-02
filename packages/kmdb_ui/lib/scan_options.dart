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

/// Immutable value object that describes how to scan a collection.
///
/// [ScanOptions] is passed to [CollectionProvider] to drive
/// [KmdbCollection.where] / [KmdbCollection.all] on the server side, replacing
/// the former full-scan-then-filter-in-memory pattern.
///
/// All fields are optional:
/// - [filterText] — a simple case-insensitive substring filter applied across
///   all document fields. Maps to a [Filter] passed to [KmdbQuery.where].
/// - [orderByField] — the document field to sort by (dot-path supported).
/// - [descending] — whether to sort descending. Defaults to false.
/// - [limit] — maximum number of documents to return. Null means no limit.
/// - [offset] — number of leading documents to skip. Defaults to 0.
class ScanOptions {
  /// A case-insensitive substring that all returned documents must contain
  /// somewhere in their string representation.
  ///
  /// When null or empty, no text filter is applied.
  final String? filterText;

  /// Field path to order results by (e.g. `'name'` or `'address.city'`).
  ///
  /// When null, the natural insertion order (key order) is used.
  final String? orderByField;

  /// Whether to sort [orderByField] in descending order. Ignored when
  /// [orderByField] is null.
  final bool descending;

  /// Maximum number of documents to return.
  ///
  /// Null means return all matching documents (up to server default).
  final int? limit;

  /// Number of documents to skip from the start of the sorted result set.
  final int offset;

  /// Creates a [ScanOptions] value object.
  const ScanOptions({
    this.filterText,
    this.orderByField,
    this.descending = false,
    this.limit,
    this.offset = 0,
  });

  /// Returns a copy of this [ScanOptions] with the given fields replaced.
  ScanOptions copyWith({
    String? filterText,
    String? orderByField,
    bool? descending,
    int? limit,
    int? offset,
    bool clearFilterText = false,
    bool clearOrderByField = false,
    bool clearLimit = false,
  }) {
    return ScanOptions(
      filterText: clearFilterText ? null : (filterText ?? this.filterText),
      orderByField: clearOrderByField
          ? null
          : (orderByField ?? this.orderByField),
      descending: descending ?? this.descending,
      limit: clearLimit ? null : (limit ?? this.limit),
      offset: offset ?? this.offset,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScanOptions &&
      other.filterText == filterText &&
      other.orderByField == orderByField &&
      other.descending == descending &&
      other.limit == limit &&
      other.offset == offset;

  @override
  int get hashCode =>
      Object.hash(filterText, orderByField, descending, limit, offset);
}
