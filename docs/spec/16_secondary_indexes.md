# Secondary Indexes

## Purpose

Secondary indexes allow the Query Layer to answer equality and range queries on
document fields without scanning the entire namespace. Indexes are maintained by
the Query Layer, stored as ordinary KV entries in reserved `$index` system
namespaces, and built lazily on first query. The storage engine knows nothing
about indexes — they are a pure application-level concern using the same
`put`/`delete` API as user data.

## Index Entry Key Encoding

> **Note — current implementation vs. aspirational layout.**  
> The compound-key layout described below (`[encodedValue][0x00][documentKey]`)
> is the target design for range-predicate index acceleration and is **not yet
> implemented**. The current implementation uses one namespace per distinct
> value (`$$index:{ns}:{path}:{hexEncodedValue}`, key = docKey UUIDv7), which
> supports equality lookups only. The compound-key layout requires the storage
> engine to support variable-length user keys — a prerequisite tracked in
> [`docs/proposals/range_predicate_index_scans.md`](../proposals/range_predicate_index_scans.md).

An index entry's key encodes both the indexed field value and the document key
so that a bounded scan on the value returns all matching document keys:

```
[encodedValue][0x00][documentKey]
```

| Field type | Encoding |
| :--------- | :------- |
| String | UTF-8 bytes as lowercase hex |
| Number (int) | 8-byte big-endian with sign bit flipped — preserves sort order |
| Number (double) | 8-byte IEEE-754 big-endian with bit adjustment (NaN not indexed) |
| Boolean | `0x00` (false) or `0x01` (true) |
| Null / missing | No index entry written |

The `\x00` separator is safe because hex encoding uses only `[0-9a-f]` (codes
≥ 48), which sort after `\x00` (code 0) and `\x01` (code 1).

Index entry **values** are empty `Uint8List` — the key encodes everything needed.

### Array Fan-Out

When a dot-path ends with `[]`, one index entry is written per array element:

```
// Index path: "tags[]"
// Document: { tags: ['dart', 'flutter'] }
// Index entries written:
//   $$index:contacts:tags[] → "dart\x00{docKey}"  → []
//   $$index:contacts:tags[] → "flutter\x00{docKey}" → []
```

## Dot-Path Syntax

| Syntax | Resolves to |
| :----- | :---------- |
| `"city"` | `doc['city']` — top-level field |
| `"address.city"` | `doc['address']['city']` — nested object field |
| `"tags[0]"` | `doc['tags'][0]` — specific array element |
| `"tags[]"` | All elements of `doc['tags']` — fan-out, one entry per element |
| `"meta.stats.views"` | Deeply nested field |

## Index Lifecycle States

Each index transitions through four states stored in `$meta` under the key
`index:{namespace}:{path}`:

| State | Description | Write path behaviour |
| :---- | :---------- | :------------------- |
| `undefined` | Declared in config; never queried | Invisible to the write path. Zero overhead. |
| `building` | First query triggered a background build | Index entries written for new writes during build. Build handles generation delta on completion. |
| `stale` | Built previously; namespace generation has advanced | Falls back to full-scan for queries. Background rebuild triggered on next query. |
| `current` | Built and generation matches | Index entries maintained on every write. |

### Index Definition Storage

Each index definition is stored in `$meta` as a CBOR map:

```jsonc
{
  "path": "address.city",
  "namespace": "contacts",
  "status": "current",
  "builtThrough": 42,     // namespace generation at last successful build
  "builtAt": "017F8A0B1C00"  // HLC timestamp for diagnostics
}
```

A `current` index has `builtThrough` equal to the current namespace generation
counter. Any mismatch means the index is stale.

## Write Interception

Every document write via the Query Layer follows this sequence, ensuring index
entries are always consistent with the documents that trigger them:

1. Fetch the current version of the document from the Cache Layer (needed to
   remove old index entries).
2. Begin a `WriteBatch`.
3. For each index in `current` or `building` state:
   - Remove old index entries (if the document previously existed).
   - Add new index entries for the updated document values.
4. Add the document put to the batch.
5. Increment the namespace generation counter (`gen:{namespace}`) in the batch.
6. Commit the `WriteBatch` atomically via `KvStore.writeBatch`.

Because all of steps 3–6 are in a single `WriteBatch`, index entries and the
document they reference are always consistent — there is no window where a
document exists without its index entries or vice versa.

This guarantee holds **across a crash** as well as in-process. Under the hood
the batch is serialised as a single WAL batch frame with one checksum and one
fsync (see §7 — *Batch Frame Format*), so a power loss or process kill either
leaves the entire frame durable on disk or leaves it absent: it is never
possible to recover a document without its index entries (or the reverse), and
the namespace generation counter and registry update are folded into the same
frame for the same reason. The in-process side is guaranteed by applying every
memtable mutation synchronously after the single fsync, with no `await` between
mutations — a concurrent reader sees the full batch or none of it (see §18).

## Lazy Index Build

Index definitions are registered at `KmdbDatabase.open()` time but no entries
are written until that index is first queried. On first query:

1. Mark the index status as `building` in `$meta`.
2. Record the current namespace generation as the build start generation.
3. Begin writing new index entries for concurrent writes (write interception
   is active from this point).
4. Scan the entire namespace in batches of 200 documents, writing index entries
   for each.
5. On completion: if the namespace generation matches the build start generation,
   mark `status = current` and `builtThrough = currentGeneration`. If the
   generation advanced during the build (concurrent writes arrived), mark
   `status = stale` — a subsequent query triggers a delta rebuild.

During the build, queries on this index fall back to full-scan (correct but
slower). The `onIndexReady` callback fires when the index reaches `current`.

## Interrupted Build Recovery

If the process is killed during an index build, the `$meta` entry shows
`status = building` on next open. The Query Layer reports this via the
`onIndexRebuildRequired` callback. The application decides whether to complete
the build before the first query or defer it. Until rebuilt, queries on the
affected index fall back to full-scan.

## Query Execution with Indexes

`KmdbQuery._executeWithPlan()` implements index selection at query time. It
returns a `QueryPlan` alongside the result set, capturing which strategy was
used and the per-stage document counts.

### Index eligibility

Only **equality predicates** (`Field('x').equals(v)`) that are at the AND-root
of the query are eligible for index acceleration. Specifically:

- Each `Filter` added via a chained `.where()` call is checked individually via
  `Filter.equalityPredicate`. A non-null result signals an equality predicate on
  a known field path with a concrete value.
- Equality predicates nested inside `OrFilter` or `NotFilter` are **not**
  eligible — using them would require union/complement key-set operations that
  are out of scope for this iteration.
- Range, string, and array predicates (e.g. `isGreaterThan`, `contains`,
  `startsWith`) are always evaluated in-memory.

### Selection sequence

For each eligible equality predicate:

1. Call `IndexManager.getOrActivate(namespace, path)`.
   - `undefined` → triggers a background build; returns `building` → full scan
     for this query.
   - `building` or `stale` → full scan for this query; background rebuild may
     already be running.
   - `current` → index is usable; proceed to lookup.
2. Call `IndexManager.lookupByValue(definition, value)` → `List<String>` of
   matching document keys (wraps `IndexReader.lookupByValue` using the private
   store reference).
3. If multiple eligible predicates, **intersect** the key sets starting from the
   smallest (short-circuits to empty if any intersection is empty).
4. Fetch each document in the intersection by key via `CacheLayer.get()` (warms
   the session cache; bypasses index namespaces).
5. Apply **all** filters in-memory on the narrowed candidate set — including the
   indexed predicates, which are cheap to re-evaluate and guard against any race
   on the index.
6. Sort, limit, and offset as usual.

`IndexReader.lookupByValue` failures are caught defensively; the query falls
back to a full namespace scan with a debug log entry.

### Fallback to full scan

The query falls back to a full namespace scan when:

- No equality predicate with a `current` index exists.
- Any index is in `building` or `stale` state.
- `lookupByValue` throws an unexpected error.
- The intersected key set is empty (fetch phase is skipped; result is empty
  without doing a full scan).

### `QueryPlan` — execution metadata

Every call to `KmdbQuery.explainedGet()` returns a `(List<T>, QueryPlan)` pair.
`QueryPlan` captures:

| Field | Description |
| :---- | :---------- |
| `strategy` | `ScanStrategy.fullScan` or `ScanStrategy.indexScan` |
| `filters` | Per-filter `FilterPlan` list: field path, operator, `indexUsed`, `indexStatus` |
| `documentsScanned` | Namespace size (full scan) or intersection size (index scan) |
| `documentsMatched` | After all in-memory filters |
| `documentsReturned` | After offset/limit |
| `sorted` | `true` when in-memory sort was applied |

For `ScanStrategy.fullScan`, `documentsScanned` is the total number of documents
decoded from the namespace before any filter evaluation. For
`ScanStrategy.indexScan`, it is the size of the intersected key set — always ≤
the full namespace size.

## Indexes and Sync

Index state and index entries are **device-local** and are **never synced**:

- `$meta` (where index status is stored as `index:{namespace}:{path}`) is a
  system namespace prefixed with `$`. The sync engine filters out all
  `$`-prefixed namespaces during SSTable upload, so index state never leaves the
  device.
- `$$index:*` namespaces (where index entries are stored) use the `$$`
  (double-dollar) local-only prefix. At flush time these entries are written to
  a `.local.sst` file that `SyncEngine.push` never uploads (see §8, §6, §12).

When a device receives SSTables via `pull` or `sync`, documents arrive in user
namespaces and are indexed locally on the next query that uses the index:

- Indexes that were `current` before the pull may transition to `stale` if the
  incoming SSTables modified documents in the indexed namespace. A `stale` index
  is automatically rebuilt on the next query.
- If incoming SSTables contain tombstones that delete every document in an
  indexed collection, the CLI's post-pull cleanup (`purgeOrphanedIndexes`)
  detects this and cascades the same cleanup as `collections delete`: it purges
  `$$index:*` entries, removes the index definitions from `local/config.json`,
  and unregisters the now-empty collection from `$meta`.

This design keeps index management simple and deterministic: each device
independently maintains its own indexes based on the documents it holds.
