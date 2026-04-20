# JSONPath Subset for Field Path Selectors

**Status**: Investigated

**PR link**: _pending_

## Problem statement

KMDB supports dot-path notation for field selection in filters and secondary
index definitions, but this support does not extend to the CLI. The `--select`
flag on `scan` and `get` only handles top-level field names, and the notation is
not formally specified anywhere. Specifically:

- The filter DSL and index definitions support nested paths (`address.city`,
  `tags[]`) via `FieldPath.resolve()`.
- The CLI `--select` flag silently ignores the nested portion of a path —
  `--select="name.en"` does not return the `en` child; it looks for a top-level
  key named `name.en` and finds nothing.
- There is no formal syntax specification, making it hard to extend or document
  the system consistently.
- Array fan-out (`tags[]`) is supported in filters and indexes, but positional
  indexing (`tags[0]`) is only partially surfaced and negative indices are not
  supported at all.

This plan formalises the path syntax as a subset of JSONPath (RFC 9535), extends
it with the two missing "minor" features (array wildcard and positional index),
and aligns the CLI `--select` implementation with the rest of the system.

The `$` root sigil is **optional**: bare paths (`address.city`) are treated as
relative paths from the document root — equivalent to `$.address.city` — so
existing usage is fully backward-compatible.

## Open questions

- [x] **Q1: `IndexDefinition` normalisation — migration risk?** No migration
      needed. `$`-prefixed index paths were never documented or accepted as valid
      input, so no existing database can contain a `$`-prefixed index namespace.
      Normalisation is purely additive. Phase 2 will add an explicit note to this
      effect.

- [x] **Q2: `IndexWriter._resolveValues` fan-out detection after `[*]` normalisation?**
      `_resolveValues` uses `path.endsWith('[]')`. Because `_normalise()` rewrites
      `[*]` to `[]` before `FieldPath.resolve()` is called, this guard always sees
      the canonical form. No change needed in `index_writer.dart`.

- [x] **Q3: `--select` output shape for array path selections?**
      Flat-key output: `--select="tags[0]"` → `{"tags[0]": "dart"}`. Re-nesting a
      scalar back into an array structure is ambiguous (what length array?) and
      fragile. Dot-child paths are re-nested (`address.city` → `{"address":
      {"city": "..."}}`); bracket selections use the raw path token as the key.

- [x] **Q4: `$` bare path — valid or error?**
      Treated as an `ArgumentError` at the `FieldPath` level: a bare `$` with no
      child path is not a valid field selector in KMDB's document model. It is also
      rejected in `IndexDefinition` alongside the existing `_`-prefix guard.

- [x] **Q5: Spec citation in `FieldPath` doc comment?**
      Reference §13 (query API), not §16.

## Investigation

### Existing path handling

Path parsing is centralised in a single file:

- **`packages/kmdb/lib/src/query/filter/field_path.dart`** — `FieldPath.resolve(String path, Map<String, dynamic> doc)`. Splits on `.`, then per-segment detects `[N]` (positional) and `[]` (fan-out). Returns a value or the `missing` sentinel. This is the single source of truth used by filters, index writers, and index readers.

- **`packages/kmdb/lib/src/query/filter/field_filter.dart`** — `Field(path)` entry point for the filter DSL; delegates resolution to `FieldPath.resolve()`.

- **`packages/kmdb/lib/src/query/index/index_definition.dart`** — stores the dot-path string as-is; uses it to form the `$index:{ns}:{path}` storage namespace.

- **`packages/kmdb/lib/src/query/index/index_writer.dart`** — calls `FieldPath.resolve()` to extract values at write time; handles array fan-out.

- **`packages/kmdb_cli/lib/src/commands/scan_command.dart`** — `_parseSelect()` / `_project()` handle `--select` but only split on commas and project top-level keys; no dot-path support.

- **`packages/kmdb_cli/lib/src/commands/get_command.dart`** — same limitation.

### Syntax formalisation

The target syntax is a strict, ergonomic subset of RFC 9535:

| Syntax | Example | Meaning |
|---|---|---|
| Identifier | `name` | Top-level field |
| Dot child | `address.city` | Nested field |
| Optional root | `$.address.city` | Same as `address.city` |
| Array wildcard | `tags[*]` or `tags[]` | All elements (fan-out) |
| Positional index | `policies[0]` | Element at index |
| Negative index | `policies[-1]` | Last element |

`FieldPath` already supports `[]` fan-out and `[N]` positional access. The
changes required are:

1. Strip a leading `$.` (or bare `$`) before any further processing — this makes
   the root sigil optional without breaking existing paths.
2. Accept `[*]` as a synonym for `[]` (fan-out).
3. Support negative indices (e.g. `[-1]`) by converting to `list.length + index`.

### CLI `--select` gap

`scan_command.dart` and `get_command.dart` pass the comma-split tokens straight
to `Map.keys` projection. They need to call `FieldPath.resolve()` per token and
build the output document as follows:

- **Dot-child paths** (`address.city`) are re-nested: output is
  `{"address": {"city": "..."}}`.
- **Bracket selections** (`tags[0]`, `tags[]`) use the raw path token as a flat
  key: output is `{"tags[0]": "dart"}` or `{"tags[]": [...]}`. Re-nesting a
  scalar back into an array structure is ambiguous (what length array?) so the
  flat-key form is used for all bracket selections.

### Roadmap items (not in scope)

The following RFC 9535 features are intentionally deferred:

- **Filter expressions** — `$.policies[?(@.expired == true)]`. These overlap
  heavily with the existing Filter DSL and require a mini expression parser.
  Implementing them inside the path syntax would duplicate logic and risk
  inconsistency; the right approach is to design a unified expression layer
  first.

- **Recursive descent** — `$..name` (matches `name` at any depth). Useful but
  adds O(depth × fields) traversal cost with non-obvious semantics for index
  fan-out. Deferred until there is a concrete use-case.

- **Cross-document / cross-collection references** — A future "foreign key"
  mechanism (e.g. `orders[*].customerId -> customers`) would need path syntax to
  describe the join key on both sides. The path grammar defined here is designed
  to be composable with such a feature: a reference expression could be expressed
  as two paths plus a join operator, with each individual path using this subset.
  No grammar changes are needed now, but this should be revisited when
  cross-collection queries are designed.

## Implementation plan

### Phase 1 — Formalise and extend `FieldPath` (core library)

- [ ] Add a `_normalise(String path)` private helper that strips a leading `$.`
      or bare `$.` prefix (exactly one `$`; `$$foo` must not become `foo`) and
      rewrites `[*]` → `[]`, so downstream code is unaffected.
- [ ] Throw `ArgumentError` for a bare `$` with no child path (e.g. `$` or
      `$` followed immediately by a comma or end-of-string).
- [ ] Call `_normalise()` at the top of `FieldPath.resolve()`.
- [ ] Add support for negative indices: in the `_resolveSegments()` positional
      branch, if `index < 0`, resolve as `list[list.length + index]`.
- [ ] Update `FieldPath` doc comments with the complete supported syntax table
      and a reference to spec §13 (query API).
- [ ] Write tests covering:
  - `$.address.city` equals `address.city`
  - `tags[*]` equals `tags[]`
  - `items[-1]` returns the last element
  - `items[-2]` returns the second-to-last element
  - Negative index out-of-range returns `missing`
  - Paths with no leading `$` continue to work (regression)
  - `$$foo` is NOT normalised (double-`$` is rejected or passed through as-is)
  - `$[0]` strips to `[0]`, which resolves to `missing` on a Map root
  - Bare `$` throws `ArgumentError`

### Phase 2 — Propagate to index definitions

- [ ] Update `IndexDefinition` to normalise its stored path via `FieldPath`
      normalisation (so `$.address.city` and `address.city` refer to the same
      index). Also reject a bare `$` path alongside the existing `_`-prefix guard.
- [ ] Add an explicit note in the `IndexDefinition` doc comment confirming that
      `$`-prefixed paths were never previously valid input, so no existing database
      can contain a `$`-prefixed index namespace — normalisation is purely
      additive, no migration needed.
- [ ] Confirm that `index_writer.dart`'s `_resolveValues` fan-out check
      (`path.endsWith('[]')`) works unchanged after normalisation — since
      `_normalise()` rewrites `[*]` to `[]` before `resolve()` is called, the
      guard always sees the canonical form. Add a comment to this effect.
- [ ] Write a test that defines an index with a `$`-prefixed path and queries it
      successfully, confirming the normalised namespace is used.

### Phase 3 — Fix CLI `--select` / `--fields`

- [ ] Refactor `_project()` in `scan_command.dart` to call `FieldPath.resolve()`
      per selected token and re-nest the result into the output document (e.g.
      `--select="id,address.city"` → `{"id": "...", "address": {"city": "..."}}`).
- [ ] Apply the same fix to `get_command.dart`.
- [ ] Handle the case where a selected path resolves to `missing` — omit the key
      from the output document (consistent with existing filter behaviour).
- [ ] Update the `--select` / `--fields` help text in both commands to document
      the full syntax (dot-paths, optional `$.`, array access).
- [ ] Write CLI integration tests covering:
  - `--select="id,address.city"` on nested documents → re-nested output
  - `--select="tags[0]"` → flat key `{"tags[0]": value}` output
  - `--select="tags[]"` → flat key `{"tags[]": [...]}` output
  - `--select="$.name"` works identically to `--select="name"`
  - `--select` with a path that does not exist omits the key gracefully

### Phase 4 — Documentation

- [ ] Update `docs/spec/13_query_api.md` with the formal path syntax table.
- [ ] Update the user guide (`docs/user_guide/README.md`) scan command examples
      to show dot-path `--select` usage.
- [ ] Add a note to `docs/roadmap.md` for the deferred items (filter
      expressions, recursive descent, cross-collection references).

## Summary

_To be completed after implementation._

---

## Review

**Reviewer:** Plan Reviewer Agent
**Date:** 2026-04-20

### Problem Statement Assessment

The problem is real and worth solving. The inconsistency between the filter DSL
(which supports dot-paths and array access via `FieldPath.resolve()`) and the
CLI `--select` implementation (which only does top-level key projection) is a
genuine usability gap. A user who learns `address.city` works in `--filter` will
reasonably expect it to work in `--select` too, and discovering it does not is
surprising.

The scope is tight and appropriate. The plan resists the temptation to implement
full JSONPath and instead limits itself to what the codebase already half-
supports. That is the right call.

### Proposed Solution Assessment

**Strengths**

- The normalisation-at-entry approach (`_normalise()` called once at the top of
  `FieldPath.resolve()`) is clean and keeps all downstream consumers — filters,
  index writers, index readers, the CLI — automatically covered without any
  per-callsite changes.
- Treating `[*]` as a synonym for `[]` is a low-risk ergonomic win that aligns
  the existing internal notation with the RFC 9535 spelling.
- Negative indexing (`[-1]`) is a tiny, well-scoped change with a clear
  implementation path (`list.length + index`) and a clear contract (out-of-range
  returns `missing`).
- The deferred items (filter expressions, recursive descent, cross-collection
  references) are correctly identified as out-of-scope and the rationale is sound.
- Backward-compatible: bare paths continue to work exactly as before.

**Concerns**

1. **`IndexDefinition` normalisation has a subtle storage-layer consequence.**
   The `indexNamespace` getter embeds `path` verbatim:
   `$index:{namespace}:{path}`. If a `$`-prefixed path is passed at `open()`
   time and then normalised before storage, any existing SSTable data written
   with an un-normalised path would be permanently unreachable. The plan notes
   "no functional changes expected", but this is only true for databases opened
   after the change. This is not a migration issue for new users, but if any
   existing data has been indexed under a `$`-prefixed path (unlikely in
   practice, but possible), those entries would be orphaned. The plan should
   explicitly acknowledge this and confirm whether a migration or a warning on
   un-normalised input is needed. Given how unlikely real-world `$`-prefixed
   index definitions are, a simple note that normalisation is applied at
   definition time and any pre-existing `$`-prefixed index namespace is
   effectively renamed is sufficient — but it must be stated.

2. **`IndexWriter._resolveValues` fan-out detection uses `path.endsWith('[]')`.**
   After `[*]` is normalised to `[]`, this check continues to work correctly. 
   However, the plan should explicitly call out that `_resolveValues` does not
   need to change, and why: normalisation runs in `FieldPath.resolve()` before
   `_resolveValues` inspects the path, so the `endsWith('[]')` guard always sees
   the canonical form. This is not a gap in the plan — just a detail worth
   confirming in the implementation checklist so it is not overlooked during
   code review.

3. **Re-nesting logic for `--select` in Phase 3 is underspecified.**
   `FieldPath.resolve('address.city', doc)` returns `'London'`, but the plan
   says the output should be `{"address": {"city": "London"}}`. The plan names
   this re-nesting requirement but does not describe how to reconstruct the
   nested output map from a flat path string. This is non-trivial: splitting on
   `.` and building nested maps works for simple dot-paths but breaks for array
   selections (`tags[0]` — should the output be `{"tags": ["dart"]}` or
   `{"tags[0]": "dart"}`?). The plan should define the output shape for array
   selections in `--select` before implementation starts, because the two
   reasonable choices (`{"tags": ["dart"]}` vs `{"tags[0]": "dart"}`) have
   meaningfully different implementation paths. The simpler and more consistent
   option would be to use the path itself as a flat key in the output (`"tags[0]":
   "dart"`) rather than attempting to reconstruct a nested structure — this avoids
   rebuilding array structure from a scalar value.

4. **`$ alone returns the full document` test case is unusual.** A bare `$` as a
   path is valid RFC 9535 (it selects the root node), but supporting it in a
   context where KMDB paths are always field selectors is an edge case with no
   practical use. It should still be handled gracefully (return the doc or
   `missing`, consistently), but the test expectation should be documented in the
   plan. If `$` returns the full document, using it as a `--select` path or
   index definition is confusing. Given that index definitions forbid paths
   starting with `_`, consider whether `$` alone should be treated as invalid
   input rather than silently returning the root.

5. **The spec reference is wrong.** The plan cites "spec §16" for path syntax in
   the `FieldPath` doc comment. Section 16 covers secondary indexes. The path
   syntax is better documented as spec §13 (query API) or as its own subsection.
   The plan should fix this citation when updating doc comments (Phase 1).

### Architecture Fit

The change is almost entirely contained within `field_path.dart` and the two
CLI command files. It sits at the lowest layer of the query stack and propagates
upward cleanly through the existing call graph. There is no impact on the storage
engine, sync protocol, WAL, or SSTable format. The cache layer and reactivity
machinery are untouched. This is exactly the right scope for the change.

The `indexNamespace` embedding concern (point 1 above) is the only place where
a storage-layer artefact is affected, and only when a user passes a `$`-prefixed
path to `IndexDefinition` — an input that has never previously been documented as
valid.

### Risk and Edge Cases

- **Double-`$` stripping.** `_normalise` must not strip more than one leading
  `$`. Input `$$foo` should not become `foo`. The test suite should include this
  case.
- **`$` followed by a bracket, not a dot.** `$[0]` is valid JSONPath (root array
  index), but it is not meaningful in KMDB's document model where the root is
  always a Map. `_normalise` stripping `$` from `$[0]` would leave `[0]`, which
  the current parser would treat as a segment with no field name and a positional
  index on the document root — returning `missing` since the root is a Map, not a
  List. This is the correct outcome. The plan should confirm this is tested.
- **Negative index on a non-list.** Already handled by the existing `is! List`
  guard. No new risk here.
- **Empty path after stripping.** `_normalise('$')` should return `''` or be
  treated as a special case. What does `resolve('', doc)` return? The current
  `split('.')` on an empty string yields `['']`, and `doc['']` will be `missing`
  unless the document has an empty-string key. This is probably fine but worth a
  test.

### Recommendations

1. **Address the re-nesting output shape ambiguity before implementing Phase 3.**
   Define what `--select="tags[0]"` outputs and add that definition to the plan.
   Suggest adopting flat-key output (`"tags[0]": value`) for array selections
   rather than attempting structural reconstruction.

2. **Add the `IndexDefinition` normalisation caveat to Phase 2.** Note that
   `indexNamespace` is constructed from the normalised path and that pre-existing
   databases with `$`-prefixed index definitions (if any) would see their index
   namespace change. Confirm this is a non-issue given the feature was never
   documented or supported.

3. **Add three missing test cases:** double-`$` input, `$[0]` input, and empty
   path after normalisation. These guard the normaliser against edge inputs.

4. **Fix the spec citation** in the `FieldPath` doc comment update (Phase 1):
   reference §13 or add a new §13.x subsection, not §16.

5. **Decide on `$` bare path handling** at the `IndexDefinition` level. Either
   reject it (like `_`-prefixed paths) or document the behaviour. Leaving it
   silently accepted but meaningless is a maintenance hazard.

The plan is well-scoped and well-investigated. The implementation is
straightforward once the re-nesting output shape is resolved. Address points 1
and 2 before starting implementation; the others can be handled inline.
