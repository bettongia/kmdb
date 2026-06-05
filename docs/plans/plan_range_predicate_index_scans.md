# Range-predicate index scans

**Status**: Open

**PR link**: _pending_

## Problem statement

Secondary indexes currently accelerate **equality predicates only**
(`Field('x').equals(v)`). Range filters — `isGreaterThan`, `isLessThan`,
`isGreaterThanOrEqualTo`, `isLessThanOrEqualTo`, `isBetween`, and
(case-sensitive) `startsWith` — are always evaluated in-memory after a full
namespace scan, regardless of whether an index exists on the field.

The value encoding in `IndexWriter` is already sort-order-preserving
(big-endian sign-bit-flipped integers, IEEE-754-normalised doubles, UTF-8
strings), so a bounded `KvStore.scan()` over the correct key range can satisfy
range queries directly — fetching only the candidate document keys that fall
within the predicate bounds, then batch-fetching those documents.

**However**, the current storage layout prevents this: index entries are stored
with one namespace **per distinct value** (`$index:{ns}:{path}:{hexValue}`,
key = docKey), not with the value embedded in the key of a single namespace.
`KvStore.scan()` cannot range across namespace names; it can only range over
keys within a single namespace. This is a code-vs-spec divergence — spec §16
already describes the single-namespace layout with compound keys, and
`IndexWriter.encodeValueHex()` even carries a "sort-order prefix for range
scans (future use)" comment. The storage layout must be migrated before range
scans can be implemented.

## Open questions

- [ ] **Q1 — Confirm Option A (storage migration).** The investigation
  recommends migrating to the §16 single-namespace compound-key layout.
  Confirm this is preferred over adding a namespace-range primitive to
  `KvStore`.
- [ ] **Q2 — Mixed int/double fields.** The new range scan (like the current
  equality scan) only captures values whose *encoded type* matches the bound's
  type. A field that stores both `int` and `double` values will miss
  type-mismatched documents in the index pass; the in-memory filter sees only
  the candidate set, so those documents are silently omitted (same limitation
  already present for equality). Is this acceptable for v0.05, documented as a
  known constraint?
- [ ] **Q3 — Case-insensitive `startsWith` exclusion.** Proposed to be
  not index-eligible; it falls back to in-memory evaluation. Confirm.

## Investigation

### The key blocker: index storage layout

The current implementation stores index entries in **one namespace per distinct
value**:

```
namespace : $index:{ns}:{path}:{hexEncodedValue}
key       : {32-char docKey}
value     : (empty)
```

`IndexReader.lookupByValue()` (`index_reader.dart:37`) calls
`IndexWriter.indexNamespaceForValue(definition, value)` to compute the
namespace, then does `store.scan(ns)` with no key bounds — it just collects
every key in that namespace.

Spec §16 (`docs/spec/16_secondary_indexes.md`) describes a different layout:

```
namespace : $index:{ns}:{path}
key       : {hexEncodedValue}\x00{32-char docKey}
value     : (empty)
```

A `KvStore.scan(ns, startKey, endKey)` over this namespace satisfies both
equality (`startKey = E(v)\x00`, `endKey = E(v)\x01`) and range queries
(`startKey = E(lower)`, `endKey = E(upper+ε)`). The null-byte separator
`\x00` is safe because hex encoding only uses `[0-9a-f]` (all codes ≥ 48),
which sort after `\x00` (code 0) and `\x01` (code 1).

Indexes are **device-local, never synced, and rebuilt lazily** (spec §16 §
"Indexes and Sync"), so this storage breaking change requires no migration
machinery — only a one-time cleanup of old-format namespaces on open, followed
by the existing lazy rebuild.

### Affected files and current state

| File | Role | Change scope |
|------|------|-------------|
| `packages/kmdb/lib/src/query/index/index_writer.dart` | Writes/deletes index entries | New key format; remove `indexNamespaceForValue` |
| `packages/kmdb/lib/src/query/index/index_reader.dart` | Equality lookup | Update equality lookup; add `lookupByRange` |
| `packages/kmdb/lib/src/query/index/index_manager.dart` | Lifecycle, intercept, build | Use new format; add old-format cleanup on init |
| `packages/kmdb/lib/src/query/filter/filter.dart` | Base class | Add `rangePredicate` getter (returns null) |
| `packages/kmdb/lib/src/query/filter/field_filter.dart` | `_FieldFilter` implementation | Implement `rangePredicate` for gt/lt/gte/lte/between/startsWith |
| `packages/kmdb/lib/src/query/kmdb_query.dart` | Query execution | Extend `_executeWithPlan()` with range branch |
| `packages/kmdb/lib/src/query/query_plan.dart` | Plan types | Add `rangeScan` to `ScanStrategy`; no `FilterPlan` changes needed (operator is already a free String) |
| `packages/kmdb_cli/lib/src/commands/scan_command.dart` | CLI `--explain` | Refactor to delegate to `explainedGet()` |
| `docs/spec/16_secondary_indexes.md` | Spec | Reconcile key-encoding, query-execution, and eligibility sections |

### Sort-order encoding (existing, unchanged)

`IndexWriter` (`index_writer.dart:136–184`) already encodes values in
sort-order-preserving hex:

- **int** → 8-byte big-endian with sign bit flipped (`bytes[0] ^= 0x80`):
  negatives sort before positives lexicographically.
- **double** → 8-byte IEEE-754 big-endian with bit adjustment (all bits
  flipped for negatives, sign bit only for positives). NaN excluded (returns
  null — not indexed).
- **String** → UTF-8 bytes as lowercase hex. Sort order matches Unicode
  codepoint order for valid UTF-8.
- **bool** → 1 byte (`0x00` false, `0x01` true) as 2-char hex.

The public `IndexWriter.encodeValueHex(v)` method already exposes this
encoding. `IndexReader.lookupByRange()` will call it to derive `startKey` and
`endKey`.

### Key format for the new layout

```
compound key = "${E(v)}\x00${docKey}"
```

- `E(v)` = `IndexWriter.encodeValueHex(v)` (variable-length hex string, no
  null bytes because hex only uses `[0-9a-f]`)
- `\x00` = null separator character (code 0, sorts before all hex chars)
- `docKey` = 32-char hex UUIDv7

**Key range per value V** = `["${E(V)}\x00", "${E(V)}\x01")`.  
Because docKeys use `[0-9a-f]` (codes 48–102), and `\x01` (code 1) < `'0'`
(code 48), all compound keys for value V lie strictly within this half-open
range. `\x01` as the exclusive upper bound safely terminates the per-value
bucket without needing a fixed key length.

### `rangePredicate` return type

```dart
/// If this filter is a range predicate on a single field, returns the
/// predicate details as a record; returns null for all other filter types.
({
  String path,
  Object? lower,
  bool lowerInclusive,
  Object? upper,
  bool upperInclusive,
  String op,           // 'gt' | 'lt' | 'gte' | 'lte' | 'between' | 'startsWith'
})? get rangePredicate => null;
```

Mapping from `_Op` to range record (in `_FieldFilter`):

| `_Op` | `lower` | `lowerInclusive` | `upper` | `upperInclusive` | `op` |
|-------|---------|-----------------|---------|-----------------|------|
| `gt` | `_operand` | false | null | — | `'gt'` |
| `lt` | null | — | `_operand` | false | `'lt'` |
| `gte` | `_operand` | true | null | — | `'gte'` |
| `lte` | null | — | `_operand` | true | `'lte'` |
| `between` | `(_operand as (Object,Object)).$1` | true | `.$2` | true | `'between'` |
| `startsWith` (caseSensitive=true only) | `_operand` | true | (computed) | false | `'startsWith'` |

Case-insensitive `startsWith` returns `null` (not range-eligible; falls back
to in-memory evaluation). `endsWith` and `contains` are also not eligible.

### `IndexReader.lookupByRange()` design

```dart
static Future<List<String>> lookupByRange({
  required KvStore store,
  required IndexDefinition definition,
  required Object? lower,
  required bool lowerInclusive,
  required Object? upper,
  required bool upperInclusive,
}) async
```

Key computation:

- **`startKey`**: if `lower == null` → null (unbounded). Otherwise
  `E(lower)` + (if `lowerInclusive` then `'\x00'` else `'\x01'`).
  - For inclusive lower: start at `"${E(lower)}\x00"` which is the first
    compound key for value `lower`.
  - For exclusive lower: start at `"${E(lower)}\x01"` which is just past
    all compound keys for value `lower`.
- **`endKey`**: if `upper == null` → null (unbounded). Otherwise
  `E(upper)` + (if `upperInclusive` then `'\x01'` else `'\x00'`).
  - For inclusive upper: end at `"${E(upper)}\x01"` (exclusive) which is
    just past all compound keys for value `upper`.
  - For exclusive upper: end at `"${E(upper)}\x00"` (exclusive) which is
    before any compound keys for value `upper`.
- **`startsWith` special case**: `lower = prefix` (inclusive), `upper` =
  computed from the UTF-8 bytes of prefix with the last byte incremented by
  1 (then re-encoded as hex). This is valid because UTF-8 never produces
  byte `0xFF`, so the increment is always defined. If the last byte of the
  UTF-8 encoding is `0xFF` (impossible for valid UTF-8), fall through to
  in-memory evaluation.

Collect `docKey` from each entry by stripping the encoded-value prefix:
the docKey is the 32 chars after the null separator. Since `\x00` does not
appear in either the hex-encoded value or the hex docKey, splitting on the
first `\x00` is unambiguous.

### `_executeWithPlan()` extension

After the existing equality-predicate loop, add a parallel range-predicate
loop. A filter is range-eligible if:

1. Its `rangePredicate` is non-null.
2. An index is `current` for `(ns, path)`.
3. At least one bound (`lower` or `upper`) is non-null and its
   `IndexWriter.encodeValueHex(bound)` returns non-null (i.e., bound is
   indexable).

Range-eligible filters produce a candidate key set via
`IndexReader.lookupByRange()`. Key sets from range and equality lookups are
intersected as usual. `FilterPlan.operator` is set to the `op` string from
`rangePredicate` (`'gt'`, `'lt'`, etc.). The in-memory re-evaluation pass
(lines 449–453) is preserved unchanged — it guards against encoding
edge-cases and concurrent index mutations.

When both equality and range predicates exist on the same field, the equality
predicate takes precedence (it produces a smaller or equal candidate set
since it's a degenerate case of a range).

If `eligible` is empty (no indexable predicates), fall through to
`_fullScan()` as today.

### `ScanStrategy` extension

Add `rangeScan` to the enum:

```dart
enum ScanStrategy { fullScan, indexScan, rangeScan }
```

When a range predicate drove the index selection, use `rangeScan`. If the
winning set was a mix of equality and range predicates, use `indexScan`
(equality wins).

### CLI `--explain` refactor

`scan_command.dart` contains a hand-rolled index-selection reimplementation
(lines ~81–230 and `_writePlan` at ~329) that only handles a single top-level
equality predicate and does not call `explainedGet()`. As part of this plan,
replace the hand-rolled selection logic with a call to `explainedGet()`,
rendering the returned `QueryPlan`. This removes the duplicated logic and
makes `--explain` automatically reflect range-scan decisions.

### Old-format namespace cleanup (migration)

On `IndexManager` init (or `_initDefinition()`), scan
`allStoredNamespaces()` (which the manager already uses in `removeIndex`)
for namespaces matching `^\\$index:[^:]+:[^:]+:.+$` (i.e., `$index:` prefix
with three or more colons — the old per-value format). Drop any such
namespaces via `store.writeBatch([...deletes...])` or the equivalent. After
cleanup, the existing `IndexStatus.undefined` path triggers a lazy rebuild
on first query, as today.

### `KvStore.scan()` interface (unchanged)

`kv_store.dart:65–70`:
```dart
Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey});
```
`startKey` inclusive, `endKey` exclusive, both nullable. No changes needed.

### Limitations (to document in spec §16)

1. **Type homogeneity.** Range index scans only capture values whose encoded
   type matches the bound's type. A field that mixes `int` and `double` values
   will miss type-mismatched documents in the index pass. This is the same
   pre-existing limitation as equality index scans.
2. **Case-insensitive `startsWith`.** Not range-index-eligible; falls back to
   in-memory evaluation after a full scan (or equality index scan if another
   predicate is eligible).
3. **`endsWith` / `contains`** are never range-eligible.

## Implementation plan

### Step 1 — Migrate `IndexWriter` to compound-key format

- [ ] Remove `indexNamespaceForValue()` (or mark `@Deprecated` and keep for
  the cleanup pass; delete after step 3).
- [ ] Change `IndexWriter.write()` to use `definition.indexNamespace` (the
  single namespace) with key `"${E(v)}\x00${docKey}"`. Keep
  `encodeValueHex()` public for use in `IndexReader`.
- [ ] Change `IndexWriter.remove()` accordingly.
- [ ] Unit-test: round-trip write + read a set of int, double, string, and
  bool values; confirm sort order is preserved in the compound key space.

### Step 2 — Migrate `IndexReader` to compound-key format + add `lookupByRange`

- [ ] Update `lookupByRange`'s equality lookup to use the new key range
  `[E(v)\x00, E(v)\x01)` within the single namespace.
- [ ] Add `lookupByRange({store, definition, lower, lowerInclusive, upper,
  upperInclusive})` as described in the investigation.
- [ ] Extract docKey from compound key by splitting on `\x00` (position
  `key.indexOf('\x00') + 1`).
- [ ] Unit-test: range scan for gt/lt/gte/lte/between/startsWith; edge cases
  include: unbounded lower, unbounded upper, single-document range, empty
  range, mixed negative and positive ints, doubles near zero, multi-byte
  UTF-8 string prefix.

### Step 3 — `IndexManager` init cleanup + write interception update

- [ ] Add `_dropLegacyIndexNamespaces()` to `IndexManager`: scan
  `allStoredNamespaces()` for old-format `$index:*:*:*` namespaces; batch-
  delete all their entries; log the cleanup at `kmdb.index` level.
- [ ] Call `_dropLegacyIndexNamespaces()` during `IndexManager` init (before
  any `getOrActivate` calls are possible).
- [ ] Update `_buildIndex()` to write compound-key entries using the new
  `IndexWriter`.
- [ ] Update `interceptWrite()` to use the new `IndexWriter` format.
- [ ] Update `removeIndex()`: the single namespace is now `definition.
  indexNamespace`; delete all entries from it (one namespace, not N
  per-value namespaces).
- [ ] Unit-test: legacy-format namespaces are detected and removed on init;
  subsequent `get()` triggers a rebuild; post-rebuild equality queries still
  work.

### Step 4 — `Filter.rangePredicate` introspection

- [ ] Add `rangePredicate` getter to `Filter` base class (returns null).
- [ ] Implement `rangePredicate` on `_FieldFilter` for `gt`, `lt`, `gte`,
  `lte`, `between`, and case-sensitive `startsWith` as per the table in the
  investigation.
- [ ] Unit-test each operator; confirm `equalityPredicate` and
  `rangePredicate` are mutually exclusive on `_FieldFilter`.

### Step 5 — Extend `_executeWithPlan()` with range branch

- [ ] After the equality-predicate loop, add a range-predicate loop that
  calls `IndexReader.lookupByRange()` for each range-eligible filter.
- [ ] Intersect range key sets with equality key sets (smallest-first, as
  today).
- [ ] Add `rangeScan` to `ScanStrategy`.
- [ ] Populate `FilterPlan.operator` with the op string from `rangePredicate`
  (`'gt'`, `'lt'`, etc.); `indexUsed: true` when the range index was used.
- [ ] Unit-test: queries using each range operator against an indexed field
  use `ScanStrategy.rangeScan` and scan fewer documents than `fullScan`;
  combined equality + range query uses the equality index and reports
  `indexScan`.

### Step 6 — CLI `--explain` refactor

- [ ] Remove the hand-rolled index-selection logic in `scan_command.dart`
  (lines ~81–230); replace with a call to `collection.where(...).explainedGet()`.
- [ ] Render the returned `QueryPlan` via `_writePlan` (update or reuse as
  needed to handle `rangeScan` strategy and range op names).
- [ ] Update `scan_command_test.dart` to cover `--explain` output for range
  predicates.

### Step 7 — Tests (integration)

- [ ] `range_index_test.dart` (new file): end-to-end tests that open a
  collection with a declared index, write ~200 documents with varied numeric
  and string field values (including negatives, zeros, NaN-adjacent doubles,
  multi-byte Unicode strings), and verify:
  - Each range operator returns the correct document set.
  - `explainedGet()` reports `rangeScan` (not `fullScan`) when the index is
    current.
  - A newly opened collection with stale legacy-format index namespaces
    cleans them up and rebuilds correctly.
  - A query combining an equality predicate and a range predicate on two
    different indexed fields uses the intersection approach.
  - A query on a non-indexed field falls back to `fullScan`.
- [ ] Crash-safety: write documents, cut power mid-index-build (use
  `FaultyStorageAdapter`), reopen — confirm the index is in `building` or
  `undefined` state and is rebuilt clean (no stale entries from the
  interrupted build).

### Step 8 — Spec and doc comments

- [ ] `docs/spec/16_secondary_indexes.md`:
  - Update "Index Entry Key Encoding" section to describe the compound key
    format.
  - Update "Query Execution with Indexes" section to cover range predicate
    eligibility and `IndexReader.lookupByRange`.
  - Update "Index eligibility" section (currently says range predicates are
    "always evaluated in-memory").
  - Add limitations section (type homogeneity, case-insensitive startsWith).
- [ ] Update doc comments on `IndexWriter`, `IndexReader`, `IndexDefinition`,
  `Filter.equalityPredicate`, `Filter.rangePredicate`, `ScanStrategy`,
  `FilterPlan`.
- [ ] Update `IndexManager._buildIndex()` and `interceptWrite()` doc
  comments.

### Step 9 — Pre-commit gate

- [ ] `cd packages/kmdb && dart test` — all tests pass.
- [ ] `cd packages/kmdb_cli && dart test` — all tests pass.
- [ ] `make analyze` — clean.
- [ ] `make pre_commit` — clean.
- [ ] Coverage remains ≥ 90%.

## Summary

_Pending implementation._
