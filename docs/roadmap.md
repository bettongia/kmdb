---
title: KMDB Feature Roadmap
subtitle: Ideas, unfilfilled
toc-title: "Contents"
...

# Command line interface REPL (Low priority)

Implement interactive REPL in the CLI that allows users to interact with the KMDB database in an interactive way.

# SAHPool OPFS (High priority)

Migrate `StorageAdapterWeb` from async File System API to
  Sync Access Handles in a dedicated Web Worker for 3–4× throughput.

# Performance Benchmarks (High priority)

Create a performance benchmarking suite that can measure the performance of single- and multi-device use of KMDB.

`benchmark/` directory validating P99 targets from
  §18 (Concurrency):
  - Put / Delete (no flush): P99 < 5ms
  - Put (flush + compact): P99 < 200ms
  - Get (memtable): P99 < 1ms
  - Get (single-file mode): P99 < 2ms
  - Scan (100 results): P99 < 10ms
  - Database open: P99 < 100ms

# Encryption (medium priority)

Look at encryption options for the local and shared data.

Consider Per-platform secure storage (iOS Keychain, Android SharedPreferences, web `localStorage`, desktop app-data dir) injectable via a `PlatformIdStore` interface; default falls back to `$meta`.

Consider encryption at the value level in the KV store. This will need to be very user-friendly and could follow an approach of the user selecting their own salt rather than approaches such as managing PGP keys. The approach needs to work in the environment where the user understands little about encryption and won't store things like private keys right next to the KMDB data in their chosen storage location (e.g. local directory or Google Drive)

# Cloud Adapter: Google Drive (medium priority)

Directly connect to Google Drive for storing sync objects such as the SSTables etc. It's likely that the Encryption roadmap item should be combined with this.

- Drive REST API + `If-Match` ETag
- `GcsAdapter` (GCS JSON API), implements `SyncStorageAdapter`
- Each adapter lives under `lib/src/sync/cloud/`.

# Cloud Adapter: Apple iCloud (low priority)

Directly connect to iCloud for storing sync objects such as the SSTables etc.

- Each adapter lives under `lib/src/sync/cloud/`.
- `ICloudAdapter` (CloudKit record change tags), implements `SyncStorageAdapter`

# Cloud Adapter: Google Cloud Storage (low priority)

GCS will be the first object store adapter.

# Collection Schemas (medium priority)

Allow collections to declare an optional schema that acts as an **admission gate**
on writes. Records already in the database are not retroactively validated; schema
enforcement begins from the point the schema is registered at `open()`.

## Structural validation

Schema is expressed as a JSON Schema subset and translated internally to a
Dart-native rule tree. The JSON Schema surface is the authoring interface only —
the internal representation is independent.

**Supported subset (v1):**

| Keyword | Scope |
|---|---|
| `type` | string, number, integer, boolean, array, object, null |
| `required` | array of required field names |
| `properties` | per-field constraint objects |
| `additionalProperties: false` | disallow undeclared fields |
| `enum` | allowed value list |
| `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` | numeric |
| `minLength` / `maxLength` | string |
| `pattern` | regex, string |
| `format` | surface-only: email, uri, date, date-time, uuid |
| `minItems` / `maxItems` | array |
| `items` | array element type |

Out of scope: `$ref`, `allOf`/`anyOf`/`oneOf`/`not`, `if`/`then`/`else`, recursive schemas.

Schemas are registered at `KmdbDatabase.open()` alongside index definitions:

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  schemas: [
    CollectionSchema(
      collection: 'contacts',
      jsonSchema: {
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string', 'format': 'email'},
        },
      },
    ),
  ],
);
```

Validation runs synchronously in the write path (before the `WriteBatch` is
committed), following the same interceptor pattern used by secondary indexes, FTS,
and vector indexes. A `SchemaValidationException` carries the full list of
violations so UI forms can surface all errors at once rather than one at a time.

## Sync behaviour

Schema enforcement is a **per-device, per-write** guarantee. Incoming SSTables
from other devices are applied directly to the LSM and are never re-validated
against the local schema. This is a fundamental consequence of KMDB's offline-first
sync model: the admission gate cannot be applied retroactively to data that was
written on another device before the schema was activated (or under a looser
schema version).

Applications that require data conformance guarantees across all devices should
treat schema validation as defence-in-depth on local writes, not as a
database-wide invariant.

## Unique constraints (follow-on)

Unique constraints (e.g. requiring that an `email` field is unique within a
collection) are deliberately deferred from the initial schema implementation.

Local uniqueness enforcement (backed by a secondary index pre-write check) is
straightforward, but uniqueness across devices in an offline-first system is a
distributed systems problem. Two devices can independently write documents with
the same unique-field value while offline; both writes are valid locally; the
constraint is violated in the merged state after sync.

Options being considered:

- **Soft enforcement:** enforce uniqueness locally on each device write; provide a
  `collection.findConstraintViolations()` method for the application to call
  post-sync and resolve violations (merge, delete, surface to user).
- **Field-as-key:** use the unique field as the document key (e.g. store contacts
  by `email` rather than UUIDv7). LWW naturally collapses concurrent writes to
  one winner; no separate constraint mechanism is required. This is an
  architectural decision made at design time, not a runtime constraint.
- **Online coordination:** require an online check before committing; breaks
  offline writes and is not aligned with KMDB's local-first model.

Soft enforcement with post-sync violation detection is the preferred direction.

# Document version history & conflict resolution (low priority)

KMDB currently uses Last-Write-Wins (LWW) via HLC timestamps to resolve
conflicts during sync compaction. This is correct and deterministic, but silent:
when two devices independently edit the same document, the lower-timestamp write
is discarded without the application being informed.

A future version could maintain a lightweight version lineage per document —
similar to CouchDB's revision model — so that a "fork" (two writes both
descended from the same base version) is detectable rather than silently
resolved. This would enable:

- **Conflict surfacing:** an `onConflict` callback or `conflicts()` query that
  exposes document pairs where LWW had to choose, letting the application decide
  whether the outcome is correct.
- **Version inspection:** access to the discarded version for a configurable
  retention window, so the user or application can cherry-pick fields from the
  losing write.
- **Guided merge UI:** for applications like note-taking or contact management,
  the ability to present both versions to the user and let them accept, reject,
  or hand-merge changes field by field.

The implementation would likely store a compact ancestry token (e.g. a
`{deviceId, hlc}` pair) alongside each document write. The merge iterator during
compaction could detect a fork when two entries for the same key have ancestry
tokens that share a common ancestor but diverge, rather than one being a direct
descendant of the other.

This is complementary to (not a replacement for) the `MergeOperator` escape
hatch, which is better suited to programmable CRDT-style merges (counters,
sets).

References:

- [CouchDB conflict model](https://docs.couchdb.org/en/stable/replication/conflicts.html)
- [Vector clocks (Lamport)](https://en.wikipedia.org/wiki/Vector_clock)

# Full-text search (medium priority)

Support traditional full-text search and vector-based searches.

References:

- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [Postgres Full Text Search](https://www.postgresql.org/docs/current/textsearch.html)

# Range-predicate index scans (medium priority)

Secondary indexes currently accelerate **equality predicates** only
(`Field('x').equals(v)`). Range filters (`isGreaterThan`, `isLessThan`,
`isBetween`, `startsWith`) are always evaluated in-memory after a full
namespace scan.

Because index entry keys are encoded with sort-order-preserving big-endian
bytes for numbers and UTF-8 for strings (see §16), a prefix- or range-bounded
`KvStore.scan()` over the `$index:` namespace could satisfy range queries
directly — fetching only the candidate document keys that fall within the
predicate bounds, then batch-fetching those documents.

Planned extension points:

- `Filter.rangePredicate` introspection — analogous to `equalityPredicate`
  but returning `(path, lower, upper, inclusive flags)`.
- `IndexReader.lookupByRange()` — wraps `KvStore.scan()` with encoded
  start/end keys derived from the predicate bounds.
- `_executeWithPlan()` in `KmdbQuery` — extend index-selection loop to
  consider range predicates when `equalityPredicate` returns null.
- `FilterPlan.operator` — extend to carry the range operator name so
  `explainedGet()` / `--explain` can report `gt`, `lt`, `between`, etc.

String `startsWith` can be implemented as a range scan using the prefix as the
lower bound and `prefix + '￿'` (or byte `0xFF`) as the exclusive upper
bound, following the standard prefix-range trick.

# JSONPath — Deferred Extensions (low priority)

KMDB currently supports a subset of RFC 9535 (JSONPath) for field path
selectors (see spec §13). The following extensions were explicitly deferred
from the initial implementation:

## Filter expressions

`$.policies[?(@.expired == true)]` — in-path filter predicates that select
array elements matching a condition. These overlap heavily with the existing
Filter DSL and require a unified expression layer design to avoid duplicating
logic and risking inconsistency. The right approach is to design a shared
expression evaluator first, then surface it in both the path syntax and the
Filter DSL.

## Recursive descent

`$..name` — matches `name` at any depth in the document tree. Useful for
deeply nested or schema-less documents, but adds O(depth × fields) traversal
cost with non-obvious semantics for index fan-out (how many entries per
document? depth-bounded?). Deferred until there is a concrete use-case with
known performance requirements.

## Cross-collection / cross-document references

A future "foreign key" or join mechanism (e.g.
`orders[*].customerId -> customers`) would need path syntax to describe the
join key on both sides. The path grammar defined in §13 is designed to be
composable with such a feature: a reference expression could be expressed as
two paths plus a join operator, with each individual path using the existing
subset. No grammar changes are needed now, but this should be revisited when
cross-collection query design is planned.

---

<!-- prettier-ignore-start -->
KMDB Documentation © 2026 by The KMDB Authors is licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
![](https://mirrors.creativecommons.org/presskit/icons/cc.svg){width=1em height=1em}
![](https://mirrors.creativecommons.org/presskit/icons/by.svg){width=1em height=1em}
<!-- prettier-ignore-end -->
