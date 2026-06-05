# Proposal: Range-predicate Index Scans

**Status:** Deferred — see [Decision](#decision-and-rationale)

**Related spec:** §16 Secondary Indexes (`docs/spec/16_secondary_indexes.md`)

**Related roadmap:** v0.04 (`docs/roadmap/0_04.md`)

---

## Problem

Secondary indexes currently accelerate **equality predicates only**
(`Field('x').equals(v)`). Range filters — `isGreaterThan`, `isLessThan`,
`isGreaterThanOrEqualTo`, `isLessThanOrEqualTo`, `isBetween`, and
(case-sensitive) `startsWith` — are always evaluated in-memory after a full
namespace scan, regardless of whether an index exists on the field.

The value encoding in `IndexWriter` is already sort-order-preserving
(big-endian sign-bit-flipped integers, IEEE-754-normalised doubles, UTF-8
strings), so a bounded `KvStore.scan()` over the correct key range can
satisfy range queries directly — fetching only the candidate document keys
that fall within the predicate bounds, then batch-fetching those documents.

The same infrastructure gap blocks **case-insensitive `startsWith`** index
support: a lowercased variant of the index value would need an ordered
keyspace to be range-scannable.

---

## Investigation

### The right approach: compound keys

The correct layout for range-scannable indexes is a single namespace per
field with a compound key embedding both the encoded value and the document
key:

```
namespace : $index:{ns}:{path}
key       : {hexEncodedValue}\x00{32-char docKey}
```

A `KvStore.scan(ns, startKey, endKey)` over this namespace satisfies both
equality (`startKey = E(v)\x00`, `endKey = E(v)\x01`) and range queries
(`startKey = E(lower)`, `endKey = E(upper+ε)`). This is the production
standard — IndexedDB on LevelDB (structurally identical to KMDB: a document
store built on an LSM) uses precisely this layout for its secondary index
cursors and `IDBKeyRange` queries.

`IndexWriter.encodeValueHex()` already produces sort-order-preserving hex:

- **int** → 8-byte big-endian with sign bit flipped
- **double** → 8-byte IEEE-754 big-endian with bit adjustment (NaN excluded)
- **String** → UTF-8 bytes as lowercase hex
- **bool** → 1 byte (`0x00` false, `0x01` true)

The encoding is the right one. The seam (`encodeValueHex`'s "sort-order
prefix for range scans (future use)" comment) already marks where the
compound key would be assembled.

### The engine blocker

The current storage engine cannot store a compound key. `KeyCodec.keyToBytes`
(`engine/util/key_codec.dart:79`) enforces that every user key is **exactly
32 hex characters** and conforms to UUIDv7 (version 7, variant 2).
`KeyCodec.encodeInternalKey` (`key_codec.dart:156`) hard-codes a 16-byte
user key slot. The internal key layout is fixed-width:

```
[nsLen 1B][ns NB][userKey 16B][hlc 8B][type 1B]
```

The merge-iterator sort order, SSTable format, WAL format, compaction, and
crash-recovery paths all depend on this fixed width. Adding variable-length
user keys is a deep change to the most invariant-laden part of the codebase.

The existing equality index scheme works precisely because stored keys are
always real UUIDv7 docKeys. The FTS inverted index (`$fts:`) follows the
same constraint — it pushes the variable part (the term) into the namespace
name and keeps the key a UUIDv7 docId.

Spec §16's "Index Entry Key Encoding" section describes the compound-key
layout as if it were implemented. It is not — it is aspirational. See §16
for the explicit caveat.

### Alternatives considered

**Namespace-range primitive on `KvStore`** — rejected. Would require changes
across all storage adapters and leaks storage-layout concerns into the wrong
layer.

**Bucketed namespace-per-prefix** — keep keys as UUIDv7 docIds, partition
values into coarse sortable bucket namespaces, scan-and-merge. Avoids engine
changes but adds real complexity and only prunes coarsely; in-memory
re-evaluation still does all fine filtering. Net improvement is marginal.

**Pluggable index access method** (like PostgreSQL's index AM interface) —
rejected. This is a server-database pattern with no second consumer in KMDB.
The two backends (namespace-per-value and compound-key) have incompatible
capabilities, so the abstraction would leak immediately. ObjectBox, Isar,
Realm, and SQLite are all homogeneous — they do not ship pluggable index AMs.

**Separate on-disk B-tree for index data** — rejected. Adds a second mutable
on-disk format with its own WAL, crash-recovery, fsync ordering, and
fault-injection test surface. Contradicts KMDB's central invariant that
immutable SSTables are the sync-safe storage primitive. The LSM can hold the
compound key once variable-length user keys are supported; no second storage
engine is needed.

### Limitations of the compound-key approach (when implemented)

**Type homogeneity.** Range index scans capture only values whose encoded
type matches the bound's type. Fields declared as `"type": "integer"` in the
collection schema are safe — only `int` values can be stored. The risk is
limited to `"type": "number"` fields and schemaless collections, where
`json.decode` may produce `int` or `double` for the same semantic value
depending on decimal-point presence in the source JSON. This is the same
pre-existing limitation as equality index scans; correctness (no false
positives) is preserved by the mandatory in-memory re-evaluation pass.

**Case-insensitive `startsWith`.** Not range-index-eligible with the
standard compound-key layout — it requires a separate index namespace storing
lowercased values, and a new `IndexDefinition` parameter to declare a
case-insensitive index at definition time. This is a separate, follow-on
concern that shares the same engine prerequisite.

**`endsWith` / `contains`** are never range-eligible regardless of key layout.

---

## Decision and rationale

**Deferred.** Range-predicate index acceleration is not being implemented
at this time. The reasoning:

1. **Scale doesn't justify it yet.** KMDB targets local-first applications
   with collections of roughly 10,000 documents (bibliographic data and
   similar). At this scale, full-namespace scan plus in-memory predicate
   evaluation is comfortably within the §18 P99 latency targets. The
   same argument that justifies evaluating case-insensitive `startsWith`
   in-memory applies to range predicates generally.

2. **Deferring does not inflate the future cost.** The engine change
   (variable-length user keys) is the same engineering effort whenever
   it is done. Index *data* rebuild is cheap regardless — secondary indexes
   are device-local, never synced, and rebuilt lazily from source documents.
   There is no multi-device migration to coordinate.

3. **The engine change deserves its own plan.** Widening the internal key
   layout touches the merge-iterator sort order, SSTable/WAL format,
   compaction, and crash recovery. It warrants a storage-format-version
   bump and its own fault-injection durability testing — the same standard
   the v0.02.01 hardening track set. Bundling it into a range-index plan
   would underscope the engine work.

4. **The seam is already in place.** `IndexWriter.encodeValueHex()` is
   public and already produces the right encoding. When the engine supports
   variable-length user keys, `IndexReader.lookupByRange()` and the
   `_executeWithPlan()` range branch can be added with minimal design work.
   The encoding analysis in this proposal transfers directly.

---

## Future path

When either of the following trigger conditions is met, resume this work:

- **Scale trigger:** collection sizes credibly approach a scale where full
  scan plus in-memory eval breaches §18 P99 targets.
- **Engine trigger:** variable-length user keys are needed for an independent
  reason — at which point range indexes and case-insensitive `startsWith`
  both come nearly for free and should be bundled in.

**Recommended implementation sequence when triggered:**

1. **Engine plan (prerequisite):** widen the internal key layout to
   length-prefix the user key; relax UUIDv7 validation for `$`-prefixed
   system namespaces; assign a storage-format-version bump; write full
   fault-injection durability tests.

2. **Index storage migration:** change `IndexWriter.write()` to use
   `definition.indexNamespace` (single namespace) with compound key
   `"${E(v)}\x00${docKey}"`; update `IndexWriter.remove()` symmetrically;
   remove `indexNamespaceForValue()`; update `IndexReader.lookupByValue()`
   to use the new key range `[E(v)\x00, E(v)\x01)`.

3. **`IndexReader.lookupByRange()`:** add range lookup using start/end key
   bounds derived from `encodeValueHex(lower/upper)` plus inclusive/exclusive
   suffix bytes (`\x00`/`\x01`). Handle `startsWith` as prefix-range
   (last UTF-8 byte incremented). Extract docKey by splitting compound key
   on `\x00`.

4. **`Filter.rangePredicate` introspection:** add getter to `Filter` base
   class (returns null); implement on `_FieldFilter` for `gt`, `lt`, `gte`,
   `lte`, `between`, and case-sensitive `startsWith`.

5. **`_executeWithPlan()` extension:** after the existing equality-predicate
   loop, add a range-predicate loop calling `IndexReader.lookupByRange()`;
   intersect key sets; add `ScanStrategy.rangeScan`.

6. **CLI `--explain` refactor:** replace the hand-rolled index-selection
   logic in `scan_command.dart` (lines ~81–230) with a call to
   `collection.where(...).explainedGet()`.

7. **Case-insensitive `startsWith`** (optional, same plan): add
   `caseInsensitive: true` to `IndexDefinition`; store lowercased value in a
   second index namespace; gate queries on that flag.
