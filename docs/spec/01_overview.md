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
