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

/// Describes the high-level strategy used to execute a query (spec §16).
enum ScanStrategy {
  /// Every document in the namespace was decoded and evaluated against filters.
  fullScan,

  /// One or more equality filters were satisfied via secondary index lookups.
  /// The candidate set was narrowed to the index intersection before any
  /// in-memory filter evaluation took place.
  indexScan,
}

/// Per-filter execution detail within a [QueryPlan].
///
/// Records whether a given filter predicate was accelerated by a secondary
/// index or fell back to in-memory evaluation over the full candidate set.
final class FilterPlan {
  /// Creates a [FilterPlan].
  const FilterPlan({
    required this.fieldPath,
    required this.operator,
    required this.indexUsed,
    this.indexStatus,
  });

  /// The dot-notation field path targeted by this filter (e.g. `address.city`).
  final String fieldPath;

  /// The operator used by this filter (e.g. `'eq'`, `'gt'`, `'contains'`).
  final String operator;

  /// Whether a secondary index was used to evaluate this filter.
  final bool indexUsed;

  /// The index lifecycle status at query time: `'current'`, `'building'`,
  /// `'stale'`, or `'none'` (no index declared). `null` when [indexUsed] is
  /// `true` (the index was current by definition).
  final String? indexStatus;
}

/// Execution metadata produced by [KmdbQuery.explainedGet].
///
/// Captures what the query engine actually did: which strategy was chosen,
/// how each filter was evaluated, and how many documents passed each stage of
/// the pipeline.
///
/// ## `documentsScanned` semantics
///
/// - [ScanStrategy.fullScan]: total number of documents decoded from the
///   namespace before any filter evaluation.
/// - [ScanStrategy.indexScan]: number of documents fetched by key after the
///   index key-set intersection — always ≤ the full namespace size.
final class QueryPlan {
  /// Creates a [QueryPlan].
  const QueryPlan({
    required this.strategy,
    required this.filters,
    required this.documentsScanned,
    required this.documentsMatched,
    required this.documentsReturned,
    required this.sorted,
  });

  /// The high-level execution strategy chosen for this query.
  final ScanStrategy strategy;

  /// Per-filter execution details, in the order filters were evaluated.
  final List<FilterPlan> filters;

  /// Number of documents examined before in-memory filter evaluation.
  ///
  /// For [ScanStrategy.fullScan] this is the total namespace document count.
  /// For [ScanStrategy.indexScan] this is the size of the intersected key set.
  final int documentsScanned;

  /// Number of documents that passed all in-memory filters.
  final int documentsMatched;

  /// Number of documents returned to the caller after offset and limit.
  final int documentsReturned;

  /// Whether an in-memory sort was applied (i.e. `orderBy` was specified).
  final bool sorted;
}
