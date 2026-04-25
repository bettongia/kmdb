---
title: KMDB Primer
subtitle: A Developer's Guide
toc-title: "Contents"
...


This guide walks you through the architecture and design of KMDB. Read it before
diving into the code. It explains *why* things work the way they do, not just
*what* they are.

# The Central Constraint: Sync Without a Server

Everything in KMDB flows from one core requirement: **multi-device sync via
commodity cloud storage** (Google Drive, iCloud, etc.) without a central server.

This rules out the obvious choice — SQLite. A SQLite database is a single mutable
file. If two devices each write to it independently, cloud storage creates a
conflict copy (`database (1).db`) with no automated resolution. You're left with
data loss.

**KMDB's solution: never mutate files.** The storage engine only ever *creates*
new files. Once written, a file is immutable. Cloud storage handles file creation
atomically and safely — exactly the property we need. Two devices can each create
new files independently, and syncing becomes a simple matter of each device
downloading the other's files.

This is the Log-Structured Merge-tree (LSM) design, and it shapes every layer of
the system.

---

# The Layered Stack

```
Application
    ↓
Query Layer       — KmdbCollection<T> API, filter DSL, reactive watch(),
                    search(), VaultRef interception
    ↓
Cache Layer       — session object cache + materialised views ($cache)
    ↓
KvStore           — public LSM API boundary (untyped bytes, String keys)
    ↓
Storage Engine    — WAL + memtable + SSTables + compaction
    ↓
Platform Layer    — dart:io (native) | OPFS (web) | HashMap (tests)

    ┌──────────────────────────┐   ┌──────────────────────────┐
    │  Text Search Subsystem   │   │  Vault Subsystem         │
    │  (native-only, §20–23)   │   │  (native-only, §24)      │
    │                          │   │                          │
    │  FtsManager  (BM25)      │   │  VaultStore              │
    │  VecManager  (vectors)   │   │  VaultGc                 │
    │  HybridManager (RRF)     │   │  VaultStorageAdapter     │
    │                          │   │                          │
    │  $fts: / $vec: in KvStore│   │  vault/ directory + $vault│
    │  never synced            │   │  ref-counts in KvStore   │
    └──────────────────────────┘   └──────────────────────────┘
```

Both subsystems sit alongside the main vertical stack. They use KvStore and the
Platform Layer but are not part of SSTable sync. Work from the bottom up when
debugging storage issues. Work from the top down when adding new features to the
query API.

---

# Layer 1: The Platform Abstraction

[lib/src/engine/platform/storage_adapter_interface.dart](lib/src/engine/platform/storage_adapter_interface.dart)

All file I/O goes through a single `StorageAdapter` interface. This has one
concrete implementation per platform:

- **Native:**
  [storage_adapter_native.dart](lib/src/engine/platform/storage_adapter_native.dart)
  — wraps `dart:io`
- **Web:**
  [storage_adapter_web.dart](lib/src/engine/platform/storage_adapter_web.dart) —
  uses the Origin Private File System (OPFS) API
- **Tests:**
  [storage_adapter_memory.dart](lib/src/engine/platform/storage_adapter_memory.dart)
  — a `HashMap<String, Uint8List>` in memory

The payoff: the entire engine above this layer has zero platform conditionals.
Tests run against the same code paths as production, using the memory adapter
for speed and the native adapter for integration tests.

When writing tests, use `MemoryStorageAdapter` unless you're specifically
testing file system behavior.

---

# Layer 2: The Storage Engine

This is the heart of the system. It implements the LSM write and read paths.

## Write Path

Every write follows this sequence:

```
put(key, value)
    ↓
1. WAL append + fsync   → durability
2. Memtable insert      → in-memory sorted buffer
3. (on size threshold)
   SSTable flush        → immutable file on disk
4. Manifest update      → records the new SSTable
```

**Step 1 is the commit point.** Once the WAL entry is fsynced, the write is
durable even if the process crashes immediately after. Everything that follows
is an optimization to make reads fast.

Key files:

- [wal_writer.dart](lib/src/engine/wal/wal_writer.dart) — WAL append and fsync
- [memtable.dart](lib/src/engine/memtable/memtable.dart) — the 64 KB in-memory
  write buffer
- [skip_list.dart](lib/src/engine/memtable/skip_list.dart) — the skip list that
  keeps memtable entries sorted
- [sstable_writer.dart](lib/src/engine/sstable/sstable_writer.dart) — builds
  immutable SSTable files
- [lsm_engine.dart](lib/src/engine/kvstore/lsm_engine.dart) — orchestrates the
  above

## The Memtable and Why Skip Lists

The memtable uses a skip list rather than a sorted array or a red-black tree.
Skip lists give O(log n) insert and O(log n) lookup with a simple implementation
that works well in a single-threaded async environment. Since Dart is
single-isolate, we don't need the lock-free properties skip lists offer in
multi-threaded systems — the choice is purely about implementation simplicity.

## SSTable Layout

When the memtable exceeds 64 KB, it flushes to an SSTable (`.sst` file) on disk.
An SSTable contains:

- **Data blocks** (4 KB each): sorted key-value pairs
- **Bloom filter block**: a compact bitset per file, 10 bits per key (~0.8%
  false-positive rate)
- **Index block**: one entry per data block pointing to its offset
- **Footer**: offsets to the above blocks + XXH64 checksum

The Bloom filter is critical for read performance. For any `get()` that misses
(the key doesn't exist), without Bloom filters the engine would have to open and
scan every SSTable. With Bloom filters, it can skip a file in microseconds if
the filter says the key is definitely absent.

See: [bloom_filter.dart](lib/src/engine/sstable/bloom_filter.dart),
[sstable_reader.dart](lib/src/engine/sstable/sstable_reader.dart)

## The Level Structure and Compaction

New SSTables land at Level 0. L0 files can have overlapping key ranges (because
they're just flushed memtables, in order of arrival). The engine periodically
compacts them into L1 and L2, where files within a level are non-overlapping.

```
L0: [file A] [file B] [file C]  ← overlapping keys, newest-first read
L1: [----] [----] [----]        ← non-overlapping, sorted
L2: [------] [--------] [--]    ← non-overlapping, sorted
```

**Key design decision:** compaction is _synchronous on the write path_, not a
background process. When a compaction trigger fires, the `put()` call blocks
until compaction completes before returning. This simplifies the concurrency
model considerably — no background isolate, no coordination, no possibility of
reads racing against a half-compacted state.

**Single-file shortcut:** If the entire database is ≤ 512 KB, everything is
compacted into one L2 file. For small databases (the common case in a
local-first app), most reads then become: one Bloom filter check + one disk
read.

See: [compaction_job.dart](lib/src/engine/compaction/compaction_job.dart),
[merge_iterator.dart](lib/src/engine/compaction/merge_iterator.dart)

## Read Path

A `get(key)` checks locations in order, returning on first hit:

1. Active memtable
2. Frozen memtable (being flushed)
3. L0 SSTables, newest-first (Bloom filter first, then disk read)
4. L1 SSTables (at most one file due to non-overlapping ranges)
5. L2 SSTables (at most one file)

Each level's Bloom filter prevents unnecessary disk reads for absent keys.

## The Manifest

The `MANIFEST` file is the database's source of truth: a log of which SSTables
exist at which level. On startup, the engine reads the Manifest to reconstruct
the level structure before accepting any operations.

The Manifest uses an append-only format (`VersionEdit` records). Each record is
`[XXH64 8B][length 4B][CBOR payload]`. This means partial writes (from a crash
mid-write) are detectable via checksum mismatch.

See: [manifest_writer.dart](lib/src/engine/manifest/manifest_writer.dart),
[version_edit.dart](lib/src/engine/manifest/version_edit.dart)

## Crash Recovery

[crash_recovery.dart](lib/src/engine/kvstore/crash_recovery.dart)

On `open()`, the engine runs through a recovery sequence:

1. **Acquire LOCK file** — prevents two processes opening the same database
2. **Read CURRENT** — identifies the active Manifest file
3. **Replay Manifest** — reconstructs the level structure
4. **Delete orphan SSTables** — files written to disk but not committed to the
   Manifest are deleted
5. **Replay WAL** — re-applies any log entries newer than the highest sequence
   number in the Manifest, restoring the memtable to its pre-crash state

The recovery sequence handles the most dangerous crash scenario: a flush that
wrote the SSTable file but crashed before updating the Manifest. Step 4 detects
this via the orphan check and cleans up.

---

# Layer 3: The KvStore Interface

[lib/src/engine/kvstore/kv_store.dart](lib/src/engine/kvstore/kv_store.dart)

`KvStore` is the public boundary of the storage engine. Above this line,
everything deals with typed documents and namespaces. Below it, everything deals
with raw bytes and string keys.

The key API surface:

```dart
Future<void> put(String namespace, String key, Uint8List value)
Future<Uint8List?> get(String namespace, String key)
Future<void> delete(String namespace, String key)
Future<void> writeBatch(WriteBatch batch)
Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey})
Stream<String> get writeEvents   // broadcast stream: fires after every write
```

`writeEvents` is a broadcast stream that carries the namespace that just
changed. The cache layer and reactive queries both subscribe to it for
invalidation and re-execution.

`WriteBatch` is important: it applies multiple puts/deletes atomically, in a
single WAL record and a single Manifest update. All document writes (including
index maintenance) use `WriteBatch` to keep documents and their index entries
consistent.

---

# Layer 4: The Cache Layer

[lib/src/cache/cache_layer.dart](lib/src/cache/cache_layer.dart)

The cache layer wraps `KvStore` and adds two caches:

1. **Session cache** ([session_cache.dart](lib/src/cache/session_cache.dart)):
   An LRU map of decoded `Map<String,dynamic>` objects, keyed by
   `(namespace, key, sequenceNumber)`. Avoids CBOR decode on repeated reads of
   the same document. Sized at 2,000 entries on desktop/native, 256 on
   mobile/web.

2. **Materialised view cache** (`$cache` namespace): Persisted scan results for
   expensive queries. Critical on mobile/web where the OS may kill the process
   at any time and recomputing large scans on startup would be too slow.

**Invalidation uses generation counters**, not per-key tracking. Each write
increments a counter in `$meta` (e.g., `gen:notes`). When the cache checks an
entry, it compares the cached generation against the current counter. If they
differ, the entire namespace is considered stale and re-fetched.

This approach trades some cache efficiency (a single write to "notes"
invalidates all cached notes) for implementation simplicity. Given typical write
rates in a local-first app, this is the right trade-off.

---

# Layer 5: Value Encoding

[lib/src/encoding/value_codec.dart](lib/src/encoding/value_codec.dart)

User documents go through this pipeline before hitting the KvStore:

```
Map<String, dynamic>
    → CBOR encoding      (compact binary, supports all JSON types)
    → Compression        (Zstd on native, Deflate on web; skipped for < 64 bytes)
    → 1-byte prefix      (CompressionFlag: which algorithm was used, or none)
    → Uint8List stored in KvStore
```

The 1-byte flag prefix lets the decoder know which algorithm to use for
decompression. This makes it safe to change the compression strategy in a future
version — old and new encodings can coexist in the same database.

---

# Layer 6: The Query Layer

[lib/src/query/kmdb_database.dart](lib/src/query/kmdb_database.dart)

This is what application code interacts with. The query layer adds:

- **Typed collections** (`KmdbCollection<T>`) with user-supplied codecs
- **A composable filter DSL** for ad-hoc queries
- **Secondary indexes** for fast filtered scans
- **Reactive queries** via `watch()`

## Write Pipeline

Every document write routes through three explicit layers before the
`WriteBatch` is committed:

```
insert / put / update / delete
    ↓
Layer 1 — Validators     WriteValidator list; any validator may throw to abort
    ↓
Layer 2 — Augmentors     WriteAugmentor list; each adds side-effect entries to the batch
    ↓
Layer 3 — Atomic commit  WriteBatch committed; KvStore.writeEvents fires
```

**Layer 1 validators** run before any I/O. A validator throws to abort the write
entirely — no partial state is ever written. Built-in validators:
`ReservedKeyValidator` (blocks writes to `_id` and other engine-reserved fields)
and `SchemaManager` (enforces any registered JSON Schema, if one is active for
the collection). Application code can register additional validators at
`KmdbDatabase.open()`.

**Layer 2 augmentors** add side-effect entries to the `WriteBatch`. All four
built-in augmentors run: `IndexManager` (secondary index entries), `FtsManager`
(BM25 inverted index), `VecManager` (vector embeddings), and
`VaultRefInterceptor` (blob reference counts). Because augmentors write into the
same `WriteBatch` as the document, all side-effects are atomic — a secondary
index entry is never out of sync with its document.

**Layer 3 is implicit.** Once `WriteBatch` is committed, `KvStore.writeEvents`
fires. The cache layer and reactive queries both subscribe to this stream for
invalidation and re-execution.

**Deletes skip Layer 1.** Validation gates write content; a delete is never
blocked by a validator.

**Sync ingestion bypasses all three layers.** Incoming SSTables from other
devices are applied directly to the LSM and are never re-validated. The
admission gate is a per-device, per-write guarantee, not a database-wide
invariant (see _Multi-Device Sync_ below).

## Collections and Codecs

Each collection is bound to a namespace and a `KmdbCodec<T>`:

```dart
abstract interface class KmdbCodec<T> {
  String keyOf(T value);                        // must return a 32-char hex key
  Map<String, dynamic> encode(T value);
  T decode(Map<String, dynamic> json);
}
```

Keys must be 32-character hex strings internally. In practice you'll use UUIDv7
(which encodes a millisecond timestamp in the top bits, so keys sort
chronologically by default).

## The Filter DSL

[lib/src/query/filter/filter.dart](lib/src/query/filter/filter.dart),
[field_filter.dart](lib/src/query/filter/field_filter.dart)

Filters are composable, immutable value objects:

```dart
Filter.and([
  Field('status').equals('active'),
  Field('address.city').equals('London'),
  Filter.not(Field('tags').containsAny(['archived'])),
])
```

Dot notation traverses nested fields. `tags[]` syntax fan-outs over array
elements for index purposes. Filters are evaluated in-process against decoded
documents — they are not translated to a query language. This is intentional: it
keeps the query engine simple and makes filters composable without a query
planner.

## Lazy Query Pipeline

[lib/src/query/kmdb_query.dart](lib/src/query/kmdb_query.dart)

Each `KmdbQuery<T>` method returns a new, immutable query object. No I/O happens
until you call a terminal:

```dart
final q = collection
  .where(Filter.and([...]))
  .orderBy('createdAt', descending: true)
  .limit(10);

// Nothing has happened yet.

final results = await q.get();  // ← I/O starts here
```

This design enables safe query reuse and composition without accidental
side-effects.

## Secondary Indexes

[lib/src/query/index/index_manager.dart](lib/src/query/index/index_manager.dart)

Indexes are declared at `KmdbDatabase.open()` time and built lazily — the first
query that needs an index triggers its build. This means declaring an index is
free until it's actually used.

Index lifecycle:

```
undefined  →  building  →  current
                             ↓ (write arrives during build)
                           stale  →  (delta rebuild)  →  current
```

Index entries live in `$index:{namespace}:{path}` system namespaces. Because
index writes share the same `WriteBatch` as the document write, indexes are
always consistent with the documents — there's no window where a document exists
without its index entry.

## Reactive Queries

```dart
final stream = collection
  .where(Field('status').equals('active'))
  .watch();
```

`watch()` re-executes the full query on each `writeEvents` emission for the
namespace, debounced at 50 ms. It emits complete result lists, not deltas. This
keeps the implementation simple and avoids the complexity of diff computation —
at the cost of some unnecessary re-computation on rapid writes.

---

# The Clock: Hybrid Logical Clocks

[lib/src/engine/util/hlc.dart](lib/src/engine/util/hlc.dart)

KMDB uses HLC (Hybrid Logical Clock) timestamps on all SSTable entries and WAL
records. An HLC is a 64-bit value:

```
[ Physical timestamp (48 bits) | Logical counter (16 bits) ]
```

The physical component tracks wall-clock time (millisecond granularity). The
logical component breaks ties within the same millisecond and "ticks forward"
when the device receives a message from a peer with a higher timestamp. This
gives causally-consistent ordering across devices without a central coordinator.

**Conflict resolution:** when two devices update the same document while
offline, the version with the higher HLC wins (Last-Write-Wins). If HLCs are
identical (vanishingly rare), the device with the lexicographically higher
`deviceId` wins as a deterministic tiebreaker.

LWW operates at the document level — there's no field-level merge. If Device A
updates `title` and Device B updates `body` on the same document, one entire
update is lost. For fields that need smarter merging (counters, sets), the
engine supports custom `MergeOperator` callbacks that run during compaction.

---

# Multi-Device Sync

[lib/src/sync/sync_engine.dart](lib/src/sync/sync_engine.dart)

Sync works by exchanging SSTables through a shared folder in cloud storage. The
sync folder has this layout:

```
{sync-root}/
  highwater/
    {deviceId}.hwm         ← per-device progress tracker
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst          ← regular flush file
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst  ← consolidated file
  .consolidation-lease     ← coordinator lock
  vault/
    sha256/{2-char}/{62-char}/
      manifest.json        ← first-writer-wins; immutable after creation
      blob                 ← binary content
      tombstone.json       ← present when GC candidate
```

**Push:** flush the memtable → identify new local SSTables → upload each one to
`sstables/` → update this device's `.hwm` file.

**Pull:** read local `.hwm` → list remote `sstables/` → download any file newer
than the high-water mark → ingest into local L0 → trigger compaction.

**Key invariant:** each device only writes to files that include its own
`deviceId`. Device A never modifies a file created by Device B. This eliminates
write conflicts at the file level entirely — the only concurrent access pattern
is "many writers, each writing to their own namespace."

**Consolidation**
([consolidation_coordinator.dart](lib/src/sync/consolidation_coordinator.dart)):
periodically, one device wins a lease and runs a cross-device compaction,
producing a merged SSTable. Other devices see this as a regular ingestible file.

---

# Text Search

[lib/src/search/](lib/src/search/)

Text search extends the Query Layer with two complementary index types and a
hybrid mode that combines them. All three operate through a single entry point:
`KmdbCollection.search()`.

## Three Modes

| Mode       | Index type        | Algorithm              | Best for                          |
| :--------- | :---------------- | :--------------------- | :-------------------------------- |
| `lexical`  | Inverted index    | BM25                   | Exact keywords, technical terms   |
| `semantic` | Flat vector index | Cosine similarity      | Conceptual meaning, paraphrases   |
| `auto`     | Both (if present) | Reciprocal Rank Fusion | General-purpose; the safe default |

`SearchMode.auto` automatically selects hybrid when both indexes exist on the
field, lexical-only or semantic-only if only one is available, and returns an
empty result (field listed in `SearchMetadata.skipped`) if neither exists. There
is no separate `hybrid` enum value.

## Lexical Search — BM25

[fts_manager.dart](lib/src/search/lexical/fts_manager.dart),
[pipeline.dart](lib/src/search/lexical/pipeline.dart)

The inverted index stores one KV namespace per term:
`$fts:{ns}:{field}:{hexTerm}` → `{docId}` → term frequency.

Write path: every document write runs the four-stage preprocessing pipeline
(tokenise → lowercase → optional stop-word filter → Snowball stem) and writes
index entries in the same `WriteBatch` as the document — the index is always
consistent.

Query path: for each query term, scan the per-term namespace, filter through the
overlay (which carries authoritative state for recently updated/deleted
documents), compute BM25 scores using corpus statistics (`n`, `avgdl`), and
rank.

An overlay namespace (`$fts:overlay:{ns}:{field}`) absorbs updates and deletes
without a read-before-write on the hot path. A background compaction step
reconciles the overlay back into the base index periodically.

## Semantic Search — BGE + SQ8

[vec_manager.dart](lib/src/search/semantic/vec_manager.dart)

Uses the [BGE Small En v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) ONNX
model (bundled, ~127 MB, 384 dimensions). ONNX inference runs synchronously
before the `WriteBatch` is committed on the write path — a document and its
embedding are never out of sync.

Vectors are SQ8-quantized before storage: each float32 dimension is mapped to a
uint8 (4× size reduction, 384 bytes per vector). Cosine similarity is computed
as a dot product at query time (both vectors are L2-normalized, so dot product
equals cosine). The search is a brute-force flat scan — no approximate
nearest-neighbour graph — which is the correct trade-off at KMDB's target scale
(< 50K documents).

## Hybrid Search — RRF

[hybrid_manager.dart](lib/src/search/hybrid/hybrid_manager.dart)

Combines BM25 and cosine result lists using Reciprocal Rank Fusion:

```
RRF(d) = Σ_{r ∈ R}  1 / (k + rank_r(d))     where k = 60
```

RRF works on ranks, not raw scores, so the unbounded BM25 scale and the
`[−1, 1]` cosine scale are naturally compatible. A document absent from one list
contributes 0 from it — single-index matches are still returned.

## Platform and Sync Constraints

- **Native platforms only.** Semantic search (ONNX inference) and vault are
  deferred on web.
- **English-language only.** The tokenizer, stop-word list, and Snowball stemmer
  are tuned for English.
- **Never synced.** All `$fts:` and `$vec:` namespaces are excluded from SSTable
  sync. Each device independently rebuilds its indexes from its local documents.
  After a sync pull, `FtsManager` and `VecManager` receive a `SyncDelta` event
  and apply incremental updates without a full rebuild.

---

# The Vault

[lib/src/vault/](lib/src/vault/)

The vault is KMDB's content-addressable binary object store — file attachment
support for documents, analogous to a BLOB column in an RDBMS.

## Content-Addressing

Files are stored outside the LSM engine, identified by their SHA-256 hash:

```
kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8
```

Two documents referencing identical files share one vault object — deduplication
is automatic and cross-collection. The shared object is reference-counted; it is
only deleted when no document references it.

## Storage Layout

```
{db-dir}/vault/
  staging/          ← in-progress writes (swept on open)
  blobs/sha256/
    {2-char prefix}/
      {62-char suffix}/
        manifest.json   ← always present for a known object
        blob            ← absent if stub
        tombstone.json  ← present when ref-count = 0
  VAULT_OFFLINE       ← device-local pin list (not synced)
```

The two-level prefix shards the SHA-256 space to avoid large flat directories
(same approach as Git's object store).

## Write Path

Writes follow a strict ordering to support crash recovery without a separate
journal:

1. Write blob to `vault/staging/{uuid}`.
2. Verify SHA-256 hash.
3. Rename blob to final path (atomic on local filesystems).
4. Write `manifest.json`.
5. Commit `WriteBatch`: increment `$vault` ref-count + write document.

Steps 1–4 complete before the KV store is touched. On crash recovery, any hash
directory without a KV ref-count entry is deleted as an incomplete write.

## Stubs and On-Demand Hydration

During sync, only `manifest.json` is copied to peer devices — the blob is not
downloaded eagerly. A hash directory with `manifest.json` but no `blob` is a
**stub**. Calling `VaultRef.getBlob()` on a stub triggers on-demand hydration:
the blob is fetched from the sync remote, verified, and written to the final
path.

## Reference-Counted GC

The `$vault:{sha256}` key in KvStore tracks the reference count for each vault
URI. `VaultRefInterceptor` implements `WriteAugmentor` and runs as part of the
Query Layer write pipeline. It diffs the vault URIs in the old and new document
and adjusts counters in the same `WriteBatch` — the ref-count and the document
are always consistent.

When the count reaches zero, `VaultGc.onZeroRefs()` writes `tombstone.json`. The
GC sweep (`VaultGc.sweep()`) deletes the hash directory after re-validating that
the count is still zero (TOCTOU guard).

## VaultRef

[vault_ref.dart](lib/src/vault/vault_ref.dart)

`VaultRef` is the typed handle for vault objects in document models. The URI is
validated eagerly at construction. `getBlob()` and `getMetadata()` are the two
access methods; both trigger on-demand hydration if needed.

```dart
final ref = VaultRef('kmdb-vault://sha256/dd92c2...');
final bytes = await ref.getBlob();         // Uint8List
final meta  = await ref.getMetadata();     // VaultManifest
```

`KmdbCodec<T>` is responsible for mapping between `VaultRef` and the typed
model. The Query Layer treats `VaultRef` as opaque.

---

# Navigating the Code

If you want to trace a specific path, start at these files:

| Goal                                      | Start here                                                           |
| :---------------------------------------- | :------------------------------------------------------------------- |
| Understand a write end-to-end             | [lsm_engine.dart](lib/src/engine/kvstore/lsm_engine.dart)            |
| Understand the Query Layer write pipeline | [kmdb_collection.dart](lib/src/query/kmdb_collection.dart)           |
| Understand crash recovery                 | [crash_recovery.dart](lib/src/engine/kvstore/crash_recovery.dart)    |
| Understand a query end-to-end             | [kmdb_query.dart](lib/src/query/kmdb_query.dart)                     |
| Understand how indexes work               | [index_manager.dart](lib/src/query/index/index_manager.dart)         |
| Understand sync                           | [sync_engine.dart](lib/src/sync/sync_engine.dart)                    |
| Understand compaction / merging           | [compaction_job.dart](lib/src/engine/compaction/compaction_job.dart) |
| Understand the SSTable format             | [sstable_writer.dart](lib/src/engine/sstable/sstable_writer.dart)    |
| Understand cache invalidation             | [cache_layer.dart](lib/src/cache/cache_layer.dart)                   |
| Understand lexical search                 | [fts_manager.dart](lib/src/search/lexical/fts_manager.dart)          |
| Understand semantic search                | [vec_manager.dart](lib/src/search/semantic/vec_manager.dart)         |
| Understand hybrid search (RRF)            | [hybrid_manager.dart](lib/src/search/hybrid/hybrid_manager.dart)     |
| Understand the vault                      | [vault_store.dart](lib/src/vault/vault_store.dart)                   |
| Understand vault GC                       | [vault_gc.dart](lib/src/vault/vault_gc.dart)                         |
| Understand vault crash recovery           | [vault_recovery.dart](lib/src/vault/vault_recovery.dart)             |

The [docs/spec/](docs/spec/) directory has detailed specification documents for
each subsystem, useful when you need the precise on-disk format or protocol
semantics.

---

# Key Terms

| Term                   | Meaning                                                                                                 |
| :--------------------- | :------------------------------------------------------------------------------------------------------ |
| **WAL**                | Write-Ahead Log — sequential crash-recovery log; the commit point for all writes                        |
| **Memtable**           | In-memory sorted write buffer (skip list); flushed to disk at 64 KB                                     |
| **SSTable**            | Sorted String Table — an immutable file on disk; the fundamental sync unit                              |
| **Manifest**           | Append-only log of which SSTables are live at which level                                               |
| **Tombstone (LSM)**    | A delete marker in the LSM engine; kept until all devices have seen the deletion                        |
| **Bloom Filter**       | Probabilistic bitset per SSTable; eliminates disk reads for absent keys                                 |
| **HLC**                | Hybrid Logical Clock — 48-bit physical + 16-bit logical; orders events across devices                   |
| **Compaction**         | Merging multiple SSTables to remove duplicates, tombstones, and level overlap                           |
| **LWW**                | Last-Write-Wins — conflict resolution strategy; higher HLC value wins                                   |
| **Generation counter** | Monotonic integer per namespace; incremented on write; drives cache invalidation                        |
| **WriteValidator**     | Layer 1 interface; throws to abort a write before any I/O occurs                                        |
| **WriteAugmentor**     | Layer 2 interface; adds side-effect entries (indexes, FTS, vectors, vault ref-counts) to the WriteBatch |
| **BM25**               | Best Match 25 — probabilistic term-frequency ranking function used by lexical search                    |
| **Inverted index**     | Data structure mapping terms → documents; basis of lexical search (`$fts:` namespaces)                  |
| **Embedding**          | Dense vector representing text meaning; produced by BGE model for semantic search                       |
| **SQ8**                | 8-bit scalar quantisation; compresses 384-dim float32 vectors from 1,536 → 384 bytes                    |
| **RRF**                | Reciprocal Rank Fusion — rank-based score combiner for hybrid search                                    |
| **Vault**              | Content-addressable binary object store; files identified by SHA-256 hash                               |
| **Stub**               | Vault object whose metadata is present locally but whose blob has not been downloaded                   |
| **Tombstone (vault)**  | `tombstone.json` written when a vault object's ref-count reaches zero; GC signal                        |
| **KVLT**               | Zstandard archive format bundling a document with its vault attachments                                 |
