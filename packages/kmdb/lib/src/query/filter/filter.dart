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

/// Base class for all document filters in the KMDB query DSL.
///
/// Filters are immutable, composable predicates evaluated in memory against
/// decoded document maps after an LSM scan (or after an index lookup narrows
/// the candidate set — see §16).
///
/// ## Composition
///
/// ```dart
/// final active = Field('status').equals('active');
/// final urgent = Field('priority').isGreaterThan(3);
/// final combined = Filter.and([active, urgent]);
/// final inverted = Filter.not(active);
/// ```
///
/// ## Evaluation
///
/// Call [evaluate] with a decoded `Map<String, dynamic>` document. Returns
/// `true` when the document matches the filter.
abstract base class Filter {
  const Filter();

  /// Returns `true` if [document] matches this filter.
  bool evaluate(Map<String, dynamic> document);

  /// If this filter is a simple equality predicate (`field == value`) that a
  /// secondary index can answer *completely*, returns the field path and
  /// operand value as a record. Returns `null` for every other case:
  /// composite filters, non-equality field filters, **and** equality filters
  /// that need a transform the index did not apply at write time (notably
  /// `caseSensitive: false`).
  ///
  /// Used by the query engine to identify predicates a secondary index's
  /// exact-token lookup can satisfy without also falling back to an in-memory
  /// scan, and to do so without exposing the private `_FieldFilter` / `_Op`
  /// internals.
  ///
  /// **Contract:** return non-null **only** when an exact-token index lookup
  /// is a complete answer to this predicate — i.e. the index's stored token
  /// for a matching document is byte-identical to the token this predicate
  /// would look up. A predicate that needs any transform the index did not
  /// apply at write time (case folding, accent stripping, Unicode
  /// normalisation, locale-aware comparison, …) **MUST** return `null` so the
  /// query engine falls back to a full scan. Returning non-null for such a
  /// predicate causes the query planner to trust an index answer that silently
  /// omits matching documents — this is the exact defect closed by 0.10.01
  /// WI-11 (SC-15): `equals(value, caseSensitive: false)` indexes an
  /// exact-case token, so it must decline (return `null`) rather than claim
  /// index-answerability.
  (String path, Object? value)? get equalityPredicate => null;

  // ── Composition ─────────────────────────────────────────────────────────────

  /// Returns a filter that matches documents that match **all** [filters].
  ///
  /// Short-circuits: evaluation stops at the first filter that returns `false`.
  /// Returns a filter that always matches when [filters] is empty.
  static Filter and(List<Filter> filters) => _AndFilter(filters);

  /// Returns a filter that matches documents that match **at least one** of
  /// [filters].
  ///
  /// Short-circuits: evaluation stops at the first filter that returns `true`.
  /// Returns a filter that never matches when [filters] is empty.
  static Filter or(List<Filter> filters) => _OrFilter(filters);

  /// Returns a filter that matches documents that do **not** match [filter].
  static Filter not(Filter filter) => _NotFilter(filter);
}

// ── Composite filters ──────────────────────────────────────────────────────────

final class _AndFilter extends Filter {
  const _AndFilter(this._filters);
  final List<Filter> _filters;

  @override
  bool evaluate(Map<String, dynamic> document) {
    for (final f in _filters) {
      if (!f.evaluate(document)) return false;
    }
    return true;
  }
}

final class _OrFilter extends Filter {
  const _OrFilter(this._filters);
  final List<Filter> _filters;

  @override
  bool evaluate(Map<String, dynamic> document) {
    for (final f in _filters) {
      if (f.evaluate(document)) return true;
    }
    return false;
  }
}

final class _NotFilter extends Filter {
  const _NotFilter(this._inner);
  final Filter _inner;

  @override
  bool evaluate(Map<String, dynamic> document) => !_inner.evaluate(document);
}
