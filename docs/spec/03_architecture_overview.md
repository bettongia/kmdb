# Architecture Overview

## Layer Stack

```
┌───────────────────────────────────────────────────────────────┐
│         Application Code                    │                 │
├───────────────────────────────────────────────────────────────┤
│  KmdbCollection<T>  │  KmdbQuery<T>         │  Query Layer    │
├───────────────────────────────────────────────────────────────┤
│  KmdbCodec<T>       (freezed + json_ser)    │  Codec Layer    │
├───────────────────────────────────────────────────────────────┤
│  KvStore             (LSM engine)           │  Storage Layer  │
├───────────────────────────────────────────────────────────────┤
│  SyncEngine          (SSTable exchange)     │  Sync Layer     │
├───────────────────────────────────────────────────────────────┤
│  StorageAdapter      (native / web / test)  │  Platform Layer │
└───────────────────────────────────────────────────────────────┘
```

The query layer never touches the LSM directly — it always operates through the
KvStore public API. The sync layer operates on immutable SSTable files produced
by the storage layer. The platform layer abstracts file I/O, compression, and
file locking across native (dart:io/dart:ffi), web (OPFS via dart:js_interop),
and test (in-memory) targets.

## Why LSM, Not SQLite?

SQLite is the industry default for embedded local-first databases. The decision
to use a custom LSM engine instead is driven by a single constraint:
multi-device sync via commodity cloud storage without a central server.

SQLite files cannot be safely shared via cloud sync. SQLite in WAL mode uses two
files (the database and the \-wal journal) that must be in transactional
lockstep; cloud services sync them independently. File-region locking
(fcntl/LockFileEx) is not replicated by cloud sync clients. Two devices opening
the same SQLite file will both believe they hold exclusive locks, producing
divergent states. Google Drive responds by creating conflict copies (database
(1).db), forking state with no automated merge path.

The LSM architecture avoids this entirely. SSTables are immutable once written —
a receiving device either sees the complete file or does not see it at all. File
creation is the atomic primitive in cloud storage, and SSTables map directly
onto that primitive. The WAL remains a local implementation detail for crash
recovery, never exposed to the sync layer.

## Architectural Decision Record

**Decision**: Use custom LSM storage engine instead of SQLite.

**Context**: Multi-device sync via Google Drive / iCloud without a central
server.

**Rationale**: Immutable SSTables are safe for cloud-folder sync; SQLite files
are not. This sync-safety property is a first-class requirement.

**Trade-off**: Higher implementation cost and risk vs. battle-tested SQLite.
Must build query engine, indexing, and ACID semantics from scratch.
