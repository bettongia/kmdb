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

## Open Questions

There's a number of areas for further investigation/clarification:

| Question                         | Context                                                                                        | Options                                                                                     |
| :------------------------------- | :--------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------ |
| Pagination cursors               | offset() is fragile. Should KmdbQuery support cursor-based pagination using the last-seen key? | Key-based cursors are more robust but require orderBy to be on the key or an indexed field. |
| Type-safe field paths            | Could field paths be compile-time safe via code generation?                                    | Generate Note\_.id, Note\_.address.city as typed FieldPath constants from freezed models.   |
| Full-text search                 | containsSubstring() is O(n) on document count. Need tokenised FTS?                             | Defer to v2. FTS requires an inverted index, which is a significant addition.               |
| Array root documents             | Should a document value be allowed to be a JSON array at the root level?                       | Currently root-level documents are always objects. Arrays would complicate keyOf().         |
| iCloud CloudKit integration      | CloudKit offers atomic batch operations and push notifications. Worth a dedicated adapter?     | Yes, as a v2 cloud adapter alongside Google Drive. Different API but same sync protocol.    |
| Stale device tombstone threshold | How long to retain tombstones for devices that may have gone offline permanently?              | 90 days proposed. Configurable at SyncConfig level. Stale devices require full re-sync.     |
