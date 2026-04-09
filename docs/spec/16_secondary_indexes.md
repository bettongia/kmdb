# Secondary Indexes

## Purpose

Secondary indexes allow the Query Layer to answer equality and range queries on
document fields without scanning the entire namespace. Indexes are maintained by
the Query Layer, stored as ordinary KV entries in reserved `$index` system
namespaces, and built lazily on first query. The storage engine knows nothing
about indexes — they are a pure application-level concern using the same
`put`/`delete` API as user data.

## Index Entry Key Encoding

An index entry's key encodes both the indexed field value and the document key
so that a prefix scan on the value returns all matching document keys:

```
[encodedValue][0x00][documentKey]
```

| Field type | Encoding |
| :--------- | :------- |
| String | UTF-8 bytes + `0x00` separator |
| Number (int/double) | Big-endian fixed-width bytes — preserves sort order for range queries |
| Boolean | `0x00` (false) or `0x01` (true) |
| Null / missing | No index entry written |

Index entry **values** are empty `Uint8List` — the key encodes everything needed.

### Array Fan-Out

When a dot-path ends with `[]`, one index entry is written per array element:

```
// Index path: "tags[]"
// Document: { tags: ['dart', 'flutter'] }
// Index entries written:
//   $index:contacts:tags[] → "dart\x00{docKey}"  → []
//   $index:contacts:tags[] → "flutter\x00{docKey}" → []
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

When a query includes a filter on an indexed field:

1. Look up the index in `$meta`. If `current`, use the index.
2. Perform a prefix scan on `$index:{ns}:{path}` with the encoded filter value
   as the prefix, collecting matching document keys.
3. Fetch each document by key (likely from the session cache).
4. Apply any remaining in-memory filters (for compound `where` clauses).
5. Sort, limit, and offset.

If the index is `building` or `stale`, fall back to a full namespace scan and
apply all filters in memory.

## Indexes and Sync

Index state and index entries are **device-local** and are **never synced**:

- `$meta` (where index status is stored as `index:{namespace}:{path}`) is a
  system namespace prefixed with `$`. The sync engine filters out all
  `$`-prefixed namespaces during SSTable upload, so index state never leaves the
  device.
- `$index:*` namespaces (where index entries are stored) are also `$`-prefixed
  and are therefore excluded from sync by the same rule.

When a device receives SSTables via `pull` or `sync`, documents arrive in user
namespaces and are indexed locally on the next query that uses the index:

- Indexes that were `current` before the pull may transition to `stale` if the
  incoming SSTables modified documents in the indexed namespace. A `stale` index
  is automatically rebuilt on the next query.
- If incoming SSTables contain tombstones that delete every document in an
  indexed collection, the CLI's post-pull cleanup (`purgeOrphanedIndexes`)
  detects this and cascades the same cleanup as `collections delete`: it purges
  `$index:*` entries, removes the index definitions from `local/config.json`,
  and unregisters the now-empty collection from `$meta`.

This design keeps index management simple and deterministic: each device
independently maintains its own indexes based on the documents it holds.
