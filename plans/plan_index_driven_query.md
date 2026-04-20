# Index-Driven Query Execution

**Status**: Investigated

**PR link**: _pending_

## Problem statement

KMDB has a complete secondary index infrastructure (`IndexManager`, `IndexReader`,
`IndexWriter`) but the query engine ignores it entirely. `KmdbQuery._execute()`
always performs a full namespace scan followed by in-memory filter evaluation,
regardless of how many indexes are declared and current on the collection.

This plan wires equality-predicate filters to the existing index infrastructure
so that a query on an indexed field fetches only the matching document keys from
the index rather than scanning every document in the namespace. Range, string,
and array predicates remain full-scan (future work).

Alongside the execution improvement, we add an `--explain` flag to the CLI
`scan` command (and extend `search` with equivalent output) that reports the
query plan actually used: which filters were index-accelerated, which fell back
to a full scan, and the resulting selectivity counts.

## Open questions

_None — all questions resolved. See investigation notes below._

## Investigation

### Current execution path

`KmdbQuery._execute()` (`packages/kmdb/lib/src/query/kmdb_query.dart`, lines
293–349):

1. Calls `_collection.database.cache.scan()` — full namespace scan.
2. Decodes every document.
3. Evaluates all filters in-memory via `filter.evaluate()`.
4. Sorts and paginates in-memory.

There is no code that consults `IndexManager` or `IndexReader` at any point.

### Index infrastructure (already complete)

| Class | File | Role |
|---|---|---|
| `IndexManager` | `packages/kmdb/lib/src/query/index/index_manager.dart` | Lifecycle, state tracking, write interception |
| `IndexReader` | `packages/kmdb/lib/src/query/index/index_reader.dart` | Equality lookup via `lookupByValue()` |
| `IndexWriter` | `packages/kmdb/lib/src/query/index/index_writer.dart` | Sort-order-preserving hex encoding |
| `IndexDefinition` | `packages/kmdb/lib/src/query/index/index_definition.dart` | Declares field path |
| `IndexState` | `packages/kmdb/lib/src/query/index/index_manager.dart` | Status: undefined/building/current/stale |

`IndexReader.lookupByValue(store:, definition:, value:)` (lines 37–51) scans the
dedicated `$index:{ns}:{path}:{hexEncodedValue}` namespace and returns the
document keys whose indexed field equals `value`. This is the only lookup
supported; range scans are a future addition (the hex encoding already preserves
sort order for when that is implemented).

### Filter class hierarchy (actual implementation)

All filters live under `packages/kmdb/lib/src/query/filter/`. The hierarchy is:

- `Filter` — abstract base; `evaluate(doc)` returns bool.
- `AndFilter`, `OrFilter`, `NotFilter` — composites (public).
- `_FieldFilter` — **single private concrete class** in `field_filter.dart` with a
  private `_Op` enum. All field predicates (equality, range, string, array) are
  variants of `_Op`. `Field('path').equals(v)` constructs `_FieldFilter(path, _Op.eq, v)`.

Because `_FieldFilter` and `_Op` are private to the `filter` library, code in
`kmdb_query.dart` cannot inspect them with a type test. **There is no `EqualFilter`
subclass.**

**Resolution (Q1):** Add a nullable getter `(String path, Object? value)? get equalityPredicate`
to the abstract `Filter` class. `_FieldFilter` implements it returning non-null
only when `_op == _Op.eq`. All other `Filter` subclasses return null. This keeps
`_FieldFilter` and `_Op` private while giving the query engine a clean inspection
point with no structural refactor.

### Index activation on the query path

`IndexManager` exposes two state-read methods:

- `getState(ns, path)` — reads persisted state only; does not trigger builds.
- `getOrActivate(ns, path)` — also transitions `undefined` → `building` (schedules
  build) and detects generation mismatch for `current` → `stale` + rebuild.

**Resolution (Q2):** `_selectIndex` must call `getOrActivate`, not `getState`.
Using `getState` would leave a newly declared index in `undefined` state forever
on the query path (write-path activation via `interceptWrite` only fires on the
next write). `getOrActivate` is the correct entry point — it ensures that the
first query against an unbuilt index kicks off the build, and the caller still
falls back to a full scan for this query.

### `KvStore` access for `IndexReader`

`IndexReader.lookupByValue` requires a `KvStore store` parameter. `KmdbQuery`
can reach `_collection.database.indexManager`, but `IndexManager._store` is
private. Exposing the raw store through `KmdbDatabase` is undesirable.

**Resolution (Q3):** Add a `lookupByValue(IndexDefinition, Object?)` wrapper
method to `IndexManager` that delegates to `IndexReader.lookupByValue` using its
own private `_store`. This keeps the store encapsulated and is the natural home
for index lookup — `IndexManager` already owns all other index operations.
`KmdbQuery` then calls `indexManager.lookupByValue(def, value)` with no
visibility issues.

### `ScanStrategy` enum — naming

The original plan used `hybridScan` to mean "index narrowing + in-memory
residual filter". This collides with the established "hybrid search" concept
(BM25 + vector RRF, §23).

**Resolution (Q4):** Drop `hybridScan`. Use only `fullScan` and `indexScan`.
Any `indexScan` always applies remaining non-indexed filters in-memory after key
fetch — that is implicit, not a third strategy. The `QueryPlan.filters` list
already records per-filter index usage, so the distinction is visible without a
third enum variant.

### Index selection strategy (equality only)

For each query execution, walk the filter list (`_filters`, built by chained
`.where()` calls) and the root filter tree looking for equality predicates at
AND-root level:

1. For each `Filter f` in `_filters`, call `f.equalityPredicate`. If non-null,
   call `indexManager.getOrActivate(ns, path)`. If state is `current`, the
   index is eligible.
2. For each eligible equality predicate, call `indexManager.lookupByValue(def, value)`
   → `List<String>` of document keys.
3. If multiple eligible predicates, **intersect** the key sets (start with
   smallest, short-circuit to empty on intersection).
4. Fetch only those documents by key via `cache.get()`.
5. Apply all remaining filters in-memory on the narrowed candidate set.
6. Sort and paginate as today.

Fall back to full scan when:
- No equality predicate with a `current` index exists.
- The index is in `building` or `stale` state (`getOrActivate` still schedules
  the build but returns non-current state — caller falls back).
- `indexManager.lookupByValue()` throws (defensive try/catch).

Note: equality predicates inside `OrFilter` or `NotFilter` branches are **not**
eligible — extracting them would require union/complement strategies. Only
predicates in `_filters` (implicit AND) or direct children of a root `AndFilter`
are considered.

### Key design decisions

**`stale` and `building` indexes are not used.** A stale index may be missing
entries; using it would silently return incorrect results. Fall back to full scan
and log a debug message for observability.

**No public API changes to terminals.** `get()`, `first()`, `stream()`,
`watch()`, `count()` signatures are unchanged. The index path is an internal
optimisation. Only `explainedGet()` is new.

**`_filters` list is the primary inspection target** (not a single root `AndFilter`).
Multiple `.where()` calls accumulate in `_filters` as an implicit AND. The
`equalityPredicate` getter is called on each element of `_filters` directly —
no tree traversal needed for the common case.

### `QueryPlan` — shared execution metadata

```dart
enum ScanStrategy { fullScan, indexScan }

final class FilterPlan {
  final String fieldPath;
  final String operator;       // 'eq', 'gt', 'contains', etc.
  final bool indexUsed;
  final String? indexStatus;   // 'current', 'building', 'stale', 'none'
}

final class QueryPlan {
  final ScanStrategy strategy;
  final List<FilterPlan> filters;
  /// For fullScan: total documents in namespace.
  /// For indexScan: documents fetched by key after index intersection.
  final int documentsScanned;
  /// Documents remaining after all in-memory filters applied.
  final int documentsMatched;
  /// Documents returned after offset/limit.
  final int documentsReturned;
  final bool sorted;
}
```

`KmdbQuery` exposes:

```dart
Future<(List<T>, QueryPlan)> explainedGet();
```

The existing terminal methods call the new internal `_executeWithPlan()` and
discard the plan.

### CLI `--explain` flag

The `scan` command gains `--explain` (bool flag):

```
Query plan
  Strategy : index scan
  Filters  : name = "Alice"   [index: current]
             age > 30         [full scan]
  Scanned  : 3 documents (of 10000 total)
  Matched  : 3
  Returned : 3
```

For JSON output, the plan is injected as a `_explain` top-level key.

The `search` command already returns `SearchResult` with `SearchMetadata` — its
`--explain` output mirrors that existing structure with no new library types.

### Files to create or modify

| Action | File |
|---|---|
| New | `packages/kmdb/lib/src/query/query_plan.dart` |
| Modify | `packages/kmdb/lib/src/query/filter/filter.dart` (add `equalityPredicate` getter) |
| Modify | `packages/kmdb/lib/src/query/filter/field_filter.dart` (implement getter) |
| Modify | `packages/kmdb/lib/src/query/index/index_manager.dart` (add `lookupByValue` wrapper) |
| Modify | `packages/kmdb/lib/src/query/kmdb_query.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart` (expose `explainedGet`) |
| Modify | `packages/kmdb_cli/lib/src/commands/scan_command.dart` |
| Modify | `packages/kmdb_cli/lib/src/commands/search_command.dart` |
| New tests | `packages/kmdb/test/query/index_query_test.dart` |
| New tests | `packages/kmdb_cli/test/explain_test.dart` |
| Modify | `docs/spec/13_query_api.md` |
| Modify | `docs/spec/16_secondary_indexes.md` |
| Modify | `docs/user_guide/README.md` |

## Implementation plan

### Phase 1 — Filter introspection (`equalityPredicate` getter)

- [ ] Add `(String path, Object? value)? get equalityPredicate` to abstract
      `Filter` in `filter.dart` with a default implementation returning `null`.
- [ ] Override in `_FieldFilter` in `field_filter.dart`: return `(path, operand)`
      when `_op == _Op.eq`, otherwise `null`.
- [ ] Write unit tests in an existing or new filter test file:
  - `Field('x').equals(1).equalityPredicate` returns `('x', 1)`
  - `Field('x').isGreaterThan(1).equalityPredicate` returns `null`
  - `AndFilter`, `OrFilter`, `NotFilter` all return `null` (default)

### Phase 2 — `IndexManager.lookupByValue` wrapper

- [ ] Add `Future<List<String>> lookupByValue(IndexDefinition def, Object? value)`
      to `IndexManager` that delegates to `IndexReader.lookupByValue(store: _store, ...)`.
- [ ] Add doc comment explaining this is the correct entry point from query code
      (encapsulates the private `_store`).
- [ ] Write a unit test confirming it returns correct document keys for a known
      index entry.

### Phase 3 — `QueryPlan` value types

- [ ] Create `packages/kmdb/lib/src/query/query_plan.dart` with:
  - `ScanStrategy` enum (`fullScan`, `indexScan`)
  - `FilterPlan` (`fieldPath`, `operator`, `indexUsed`, `indexStatus`)
  - `QueryPlan` (`strategy`, `filters`, `documentsScanned`, `documentsMatched`,
    `documentsReturned`, `sorted`) with precise doc comments on `documentsScanned`
    semantics for each strategy
  - License header with year 2026
  - Full doc comments on all public members

### Phase 4 — Index selection logic in `KmdbQuery`

- [ ] Add private `_executeWithPlan()` to `KmdbQuery<T>`:
  1. For each filter in `_filters`, call `equalityPredicate`. Collect eligible
     ones (non-null path + `getOrActivate` returns `current`).
  2. If eligible set is non-empty:
     - Call `indexManager.lookupByValue()` per eligible filter.
     - Intersect key lists (shortest first). If intersection is empty, skip
       document fetch entirely — return early with empty result + `indexScan` plan.
     - Fetch documents by key via `cache.get()` (bypasses full scan).
     - Set `strategy = ScanStrategy.indexScan`.
  3. Else: full namespace scan as today; `strategy = ScanStrategy.fullScan`.
  4. Wrap `indexManager.lookupByValue()` call in try/catch — on any error, log
     debug and fall back to full scan.
  5. Apply remaining in-memory filters, sort, paginate.
  6. Build and return `QueryPlan`.
- [ ] Update `_execute()` to delegate to `_executeWithPlan()` and discard plan.
- [ ] Add `Future<(List<T>, QueryPlan)> explainedGet()` to `KmdbQuery<T>`.
- [ ] Expose `explainedGet()` from `KmdbCollection<T>` via the query builder.

### Phase 5 — Tests (core library)

New file `packages/kmdb/test/query/index_query_test.dart`:

- [ ] Full scan when no index declared — `strategy == fullScan`
- [ ] Full scan when index declared but status is `building`
- [ ] Full scan when index declared but status is `stale`
- [ ] Index scan for single equality filter on `current` index — correct results returned
- [ ] Index scan with two equality filters on two `current` indexes — key sets
      intersected, only documents matching both returned
- [ ] One indexed equality filter + one non-indexed filter (e.g. `isGreaterThan`)
      — `indexScan` strategy, non-indexed filter applied in-memory on narrowed set
- [ ] Equality filter inside `OrFilter` — NOT eligible; falls back to full scan
- [ ] Equality filter inside `NotFilter` — NOT eligible; falls back to full scan
- [ ] Multiple chained `.where()` calls (implicit AND) — both equality predicates
      activate their respective indexes: `.where(Field('a').equals(1)).where(Field('b').equals(2))`
- [ ] `QueryPlan` fields accurate: `documentsScanned`, `documentsMatched`,
      `documentsReturned`, `sorted`
- [ ] Index intersection yields empty set — returns empty result, `indexScan`
      strategy, no full scan fallback
- [ ] `null` equality value — `lookupByValue` returns empty (not indexable);
      falls back to full scan gracefully
- [ ] Empty collection — no panic, zero-result `QueryPlan`
- [ ] `lookupByValue` throws — falls back to full scan without propagating

### Phase 6 — CLI `--explain` flag

- [ ] Add `--explain` bool flag to `ScanCommand`
- [ ] After `explainedGet()` call, format `QueryPlan`:
  - Table/default: prepend human-readable plan header block
  - JSON: inject `_explain` key at top level of the response object
  - IDs format: prepend plan block as a comment-style header
- [ ] Add `--explain` bool flag to `SearchCommand`; render `SearchMetadata` in
      the same style
- [ ] Update help text for both commands to document `--explain`

### Phase 7 — CLI Tests

New file `packages/kmdb_cli/test/explain_test.dart`:

- [ ] `scan --explain` on collection with no indexes — reports full scan
- [ ] `scan --explain` on collection with current index on filtered field —
      reports index scan with correct strategy and counts
- [ ] `scan --explain --format=json` — `_explain` key present and parseable
- [ ] `search --explain` — `SearchMetadata` rendered correctly
- [ ] `--explain` with no `--filter` flag — full scan reported, zero filter rows

### Phase 8 — Documentation

- [ ] Update `docs/spec/16_secondary_indexes.md` — add section describing index
      selection: eligibility criteria (equality + AND-root + current), intersection
      strategy, fallback conditions, `getOrActivate` call sequence
- [ ] Update `docs/spec/13_query_api.md` — document `explainedGet()`, `QueryPlan`,
      `FilterPlan`, `ScanStrategy`
- [ ] Update `docs/user_guide/README.md` — add `--explain` examples for `scan`
      and `search`
- [ ] Update `docs/roadmap.md` — add future work item for range-predicate index
      scans (prefix iteration using sort-order-preserving hex keys)

## Summary

_To be completed after implementation._
