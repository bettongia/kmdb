# Overview

KMDB is a local-first document database for Dart and Flutter applications
targeting mobile, desktop, and web platforms. It provides a typed, reactive
query API over a key-value storage engine, with multi-device sync via commodity
cloud storage (Google Drive, iCloud) without requiring a central server.

The storage layer is a Log-Structured Merge Tree (LSM) with a write-ahead log
(WAL), in-memory memtable, and immutable Sorted String Table (SSTable) files.
This architecture was chosen specifically because immutable SSTables serve as
the natural sync unit for cloud storage — file creation is atomic in cloud
storage, file mutation is not. This sync-safety property is a first-class
architectural requirement, not an incidental benefit.

The query layer provides a typed collection API with lazy evaluation, a
composable filter DSL supporting nested field paths, and reactive watch()
streams with debounced re-execution. Documents are serialized via a thin codec
bridge to freezed/json_serializable, with UUIDv7 keys providing time-ordered
insertion and index locality.

## Why LSM, Not SQLite?

Everything in KMDB flows from one core requirement: multi-device sync via
commodity cloud storage without a central server. This rules out the obvious
choice — SQLite. A SQLite database is a single mutable file; if two devices
each write to it independently, cloud storage creates a conflict copy
(`database (1).db`) with no automated resolution, and the loser's writes are
gone.

KMDB's answer: never mutate files. The storage engine only ever *creates* new
files — once written, a file is immutable. Cloud storage handles file creation
atomically and safely, which is exactly the property multi-device sync needs:
two devices can each create new files independently, and syncing becomes each
device downloading the other's files. See §3 for the full architectural
decision record and layer diagram.

## The System, Layer by Layer

This is a narrative walkthrough of *why* each layer exists; §3 has the
authoritative layer diagram and storage-tier layout, and §4–§32 have the
per-subsystem specifications this section cross-references.

**Platform layer (§19).** All file I/O goes through a single `StorageAdapter`
interface, with one implementation per platform: native (`dart:io`), web
(Origin Private File System via a dedicated Web Worker), and an in-memory
adapter for tests. The engine above this layer has zero platform
conditionals — tests run against the same code paths as production.

**Storage engine (§6–§9).** Every write appends to the WAL and fsyncs before
anything else happens — that fsync is the durability commit point. The
memtable (a skip list, chosen for implementation simplicity in Dart's
single-isolate model rather than for lock-free properties) buffers writes in
sorted order and flushes to an immutable SSTable at 64 KB. New SSTables land
at Level 0 with overlapping key ranges; compaction — synchronous on the write
path, not a background isolate, to keep the concurrency model simple —
periodically merges them into non-overlapping L1 and L2 files. Each SSTable
carries a Bloom filter (10 bits/key, ~0.8% false-positive rate) so a `get()`
miss can skip a file without a disk read.

**Manifest & crash recovery (§10, §17).** The Manifest is an append-only log
of which SSTables are live at which level; partial writes from a mid-write
crash are detectable via checksum mismatch. On `open()`, the engine acquires
an exclusive lock, replays the Manifest, deletes orphan SSTables (files
written but never committed), and replays any WAL entries newer than the
Manifest's high-water mark.

**KvStore (§11).** The public boundary of the storage engine — everything
above deals with typed documents and namespaces, everything below deals with
raw bytes and string keys. `WriteBatch` applies multiple puts/deletes
atomically in a single WAL record and Manifest update; all document writes
(including index maintenance) use it, so a document is never out of sync with
its index entries. `writeEvents` is a broadcast stream carrying the namespace
that just changed, which the cache layer and reactive queries subscribe to.

**Cache layer (§15).** Sits above KvStore with two caches: a session object
cache (decoded `Map<String, dynamic>` objects, LRU, platform-sized) and a
persisted materialised-view cache (`$cache` namespace, needed on mobile/web
where the OS may kill the process at any time). Invalidation uses namespace
generation counters in `$meta` rather than per-key tracking — a single write
to a namespace invalidates the whole namespace's cached entries, trading some
cache efficiency for implementation simplicity.

**Value encoding (§5, §31).** User documents pass through a pipeline —
`codec.encode()` → CBOR → optional Zstd compression → a prefix byte — before
reaching KvStore. This seam is also where encryption applies: when enabled,
AES-256-GCM wraps the compressed payload before it crosses into the storage
engine, so SSTables, compaction, and sync all see opaque ciphertext. See
_Encryption_ below.

**Query layer (§13, §14, §16).** What application code interacts with
directly: typed `KmdbCollection<T>` with user-supplied codecs, a composable
`Filter` DSL (dot-notation nested fields, `tags[]` array fan-out), a lazy
query pipeline where no I/O happens until a terminal method is called, lazily
built secondary indexes, and `watch()` streams that re-run on writes to the
watched namespace, debounced at 50ms. Every document write routes through
three layers before commit: validators (may abort the write), augmentors
(add side-effect entries — index, FTS, vector, vault ref-count — to the same
`WriteBatch` as the document), then the atomic commit itself.

**HLC and conflict resolution (§4).** KMDB uses Hybrid Logical Clocks
(48-bit physical + 16-bit logical) on all SSTable entries and WAL records,
giving causally-consistent ordering across devices without a central
coordinator. When two devices edit the same document while offline, the
higher-HLC write wins (Last-Write-Wins) — a document-level resolution with no
field-level merge. §26 (_Document Versioning_, below) exists precisely
because LWW silently discards the losing write.

**Multi-device sync (§12).** Devices exchange immutable SSTables through a
shared cloud folder. Each device writes only to files that include its own
device ID, so two devices never write the same file — this eliminates
file-level write conflicts without a central server or lock service. A push
uploads newly-flushed local SSTables and updates the device's own
high-water-mark file; a pull downloads and ingests any remote SSTable newer
than the local high-water mark. Periodically, one device wins a lease and runs
a cross-device consolidation compaction.

**Text search (§20–§23).** Three modes over a single `search()` entry point:
lexical (BM25 inverted index), semantic (BGE-family embeddings, SQ8-quantized,
brute-force cosine similarity — the correct trade-off at KMDB's target scale),
and `auto`/hybrid (Reciprocal Rank Fusion combining both when both indexes
exist). Native-only, English-only. All `$$fts:`/`$$vec:` entries are
local-only — excluded from SSTable sync — and each device rebuilds its
indexes independently from synced document data.

**Vault (§24, §32).** A content-addressable binary object store for file
attachments, keyed by SHA-256 hash; two documents referencing identical bytes
share one ref-counted object. During sync, only the manifest is copied
eagerly — the blob itself hydrates on demand when first requested. Vault
search (§32) extends this with extracted-text indexing over attachment
content (PDF/HTML/Markdown), searchable via the same `search()`-family API.

## Encryption

KMDB supports opt-in, value-level encryption (AES-256-GCM) applied at the
value-encoding seam described above: every value is encrypted on the way
into the storage engine and decrypted on the way out, so the storage engine,
SSTables, and sync all see only ciphertext. Encryption uses an
envelope-encryption pattern — a random Data Encryption Key (DEK) encrypts
every value; the DEK itself is wrapped under a passphrase-derived key and,
separately, a recovery-code-derived key, so either credential unlocks the
database.

This is a confidentiality guarantee for **values**, including the local-only
`$$fts:`/`$$vec:`/`$$index:` namespace values (protecting against local disk
theft) and `$meta` operational metadata (protecting against the cloud
provider) — not a structural-anonymity guarantee: keys, namespace names, and
index paths are not encrypted, so an observer of the cloud folder can see how
many documents and index entries exist without seeing their contents. See §31
for the full wire format, the bootstrap/error-code matrix, and the current
list of accepted-limitation gaps.

There is no in-place migration path between a plaintext and an encrypted
database in either direction — encryption is a create-time choice.

## Document Versioning

Because Last-Write-Wins conflict resolution is silent — the losing write in a
sync conflict simply disappears — KMDB offers opt-in document versioning
(§26). Every write to a versioned collection retains a numbered version entry
in a `$ver:` system namespace, in the same `WriteBatch` as the document write
itself, so the document and its version history are never out of sync. The
full history is queryable, and any prior version can be promoted back to
current. A configurable per-collection maximum (or retention window) bounds
storage growth; older entries are trimmed at compaction time.

## Key Design Decisions

| Decision | Choice | Rationale |
| :------- | :----- | :-------- |
| Storage engine | Custom LSM, not SQLite | Immutable SSTables map directly onto the atomic primitive in cloud storage (file creation). SQLite files cannot be safely shared via cloud sync — two devices believe they hold exclusive locks, producing divergent state. See §3. |
| Manifest format | Append-only VersionEdit log, not atomic JSON rewrite | An atomic rewrite requires a temp-file rename, which is unsafe across cloud-synced paths. The append-only log survives a crash mid-record (replay stops at the first checksum failure) and never produces a partial manifest. See §10. |
| Compaction model | Synchronous on the write path, no background isolate | At the target scale (200–2,000 typical docs, 100K upper bound) L1→L2 compaction reads/writes ≤20MB and completes in under 200ms. A background isolate adds FFI pointer-transfer complexity for no meaningful gain at this scale. See §18. |
| Value encoding | CBOR + optional compression, not JSON | CBOR is 20–30% smaller than JSON, handles binary values natively (no Base64), and is language-agnostic. Applied at the Query Layer boundary; the LSM engine stores opaque bytes. See §5. |
| Storage tiers | Two separate locations (local DB dir + cloud sync folder) | WAL files and the Manifest are device-local implementation details. Only immutable SSTables enter the sync folder. This eliminates all file-level write conflicts without requiring a central server or lock service. See §3. |
| Conflict resolution | Last-Write-Wins via HLC timestamps | Hybrid Logical Clocks (48-bit physical + 16-bit logical) preserve causality across devices without a central coordinator. LWW is sufficient for the personal-app document model targeted by KMDB. See §4. |
| Document keys | UUIDv7, not random UUIDv4 | UUIDv7 is time-ordered at millisecond precision. This gives documents implicit insertion order, improves SSTable key locality during compaction, and makes key-order scans meaningful without a secondary index. |
| Index build strategy | Lazy on first query, not eager at open() | Indexes are declared at open time but entries are not written until the index is first queried. This keeps `open()` fast and avoids unnecessary work for indexes that are never used. See §16. |
| Cache invalidation | Namespace generation counters in `$meta` | A single integer per namespace that increments on every `WriteBatch` provides a universal staleness signal for both the in-memory session cache and the persisted `$cache` materialised views, without tracking individual key versions. See §15. |
| Index consistency | All index writes in the same `WriteBatch` as the document | Atomic writes ensure there is never a window where a document exists without its index entries (or vice versa), even if the process is killed mid-write. See §16. |
| Encryption | Value-level AES-256-GCM at the encoding seam, opt-in | Applying encryption at the Query Layer's value-encoding boundary (rather than whole-file or whole-database) means the storage engine, compaction, and sync are all encryption-agnostic — they only ever see ciphertext once enabled. See §31. |
| Conflict silence | Opt-in document versioning alongside LWW | LWW is deterministic but silently discards the losing write in a conflict. Versioning retains every write as a numbered, promotable entry for callers who need an audit trail. See §26. |

## Navigating the Code

If you want to trace a specific path through `packages/kmdb/`, start at these
files:

| Goal                                      | Start here                                                           |
| :----------------------------------------- | :--------------------------------------------------------------------------- |
| Understand a write end-to-end             | [lsm_engine.dart](../../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart) |
| Understand the Query Layer write pipeline | [kmdb_collection.dart](../../packages/kmdb/lib/src/query/kmdb_collection.dart) |
| Understand crash recovery                 | [crash_recovery.dart](../../packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart) |
| Understand a query end-to-end             | [kmdb_query.dart](../../packages/kmdb/lib/src/query/kmdb_query.dart) |
| Understand how indexes work               | [index_manager.dart](../../packages/kmdb/lib/src/query/index/index_manager.dart) |
| Understand sync                           | [sync_engine.dart](../../packages/kmdb/lib/src/sync/sync_engine.dart) |
| Understand compaction / merging           | [compaction_job.dart](../../packages/kmdb/lib/src/engine/compaction/compaction_job.dart) |
| Understand the SSTable format             | [sstable_writer.dart](../../packages/kmdb/lib/src/engine/sstable/sstable_writer.dart) |
| Understand cache invalidation             | [cache_layer.dart](../../packages/kmdb/lib/src/cache/cache_layer.dart) |
| Understand lexical search                 | [fts_manager.dart](../../packages/kmdb/lib/src/search/lexical/fts_manager.dart) |
| Understand semantic search                | [vec_manager.dart](../../packages/kmdb/lib/src/search/semantic/vec_manager.dart) |
| Understand hybrid search (RRF)            | [hybrid_manager.dart](../../packages/kmdb/lib/src/search/hybrid/hybrid_manager.dart) |
| Understand the vault                      | [vault_store.dart](../../packages/kmdb/lib/src/vault/vault_store.dart) |
| Understand vault GC                       | [vault_gc.dart](../../packages/kmdb/lib/src/vault/vault_gc.dart) |
| Understand vault crash recovery           | [vault_recovery.dart](../../packages/kmdb/lib/src/vault/vault_recovery.dart) |
| Understand encryption / key management    | [encryption_config.dart](../../packages/kmdb/lib/src/encryption/encryption_config.dart) |

Terminology (WAL, SSTable, HLC, BM25, SQ8, RRF, DEK, KEK, and the rest) is
defined authoritatively in §99 (Glossary), not repeated here.

## Future Work

Areas noted for further investigation, not yet designed or scheduled:

| Question | Context | Options |
| :------- | :------ | :------ |
| Pagination cursors | `offset()` is fragile at scale. Should `KmdbQuery` support cursor-based pagination using the last-seen key? | Key-based cursors are more robust but require `orderBy` to be on the key or an indexed field. Deferred — offset is sufficient at KMDB's target scale (§13). |
| Type-safe field paths | Could field paths be compile-time safe via code generation? | Generate `Note_.id`, `Note_.address.city` as typed `FieldPath` constants from freezed models. |
| Array root documents | Should a document value be allowed to be a JSON array at the root level? | Currently root-level documents are always objects. Arrays would complicate `keyOf()`. |
