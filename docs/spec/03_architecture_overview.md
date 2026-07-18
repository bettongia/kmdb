# Architecture Overview

## Layer Stack

```
┌────────────────────────────────────────────────────────────────────┐
│  Application Code                                                  │
├────────────────────────────────────────────────────────────────────┤
│  Query Layer    KmdbCollection<T> · KmdbQuery<T> · Filter DSL      │
│                 Index definitions · Write interception             │
│                 search() · VaultRef interception                   │
├────────────────────────────────────────────────────────────────────┤
│  Cache Layer    Session object cache · $cache materialised views   │
│                 Platform-aware sizing · Generation counter reads   │
├────────────────────────────────────────────────────────────────────┤
│  KvStore        put · get · delete · scan · writeBatch · open      │
│  (Public API)   System namespaces · Namespace generation counters  │
├────────────────────────────────────────────────────────────────────┤
│  LSM Engine     WAL · Memtable (skip list) · SSTable files         │
│                 Bloom filters · 3-level compaction · Manifest      │
├────────────────────────────────────────────────────────────────────┤
│  Sync Layer     SyncEngine (SSTable exchange) · ConsolidationCoord │
├────────────────────────────────────────────────────────────────────┤
│  Platform Layer StorageAdapter: native (dart:io+FFI) / web (OPFS)  │
│                 / memory (tests)                                   │
└────────────────────────────────────────────────────────────────────┘

        ┌──────────────────────────┐   ┌──────────────────────────┐
        │  Text Search Subsystem   │   │  Vault Subsystem         │
        │  (native-only, §20–23)   │   │  (native-only, §24)      │
        │                          │   │                          │
        │  FtsManager   (§21)      │   │  VaultStore              │
        │  VecManager   (§22)      │   │  VaultGc · VaultRecovery │
        │  HybridManager (§23)     │   │  VaultStorageAdapter     │
        │                          │   │                          │
        │  $$fts: / $$vec: namespaces│   │  vault/ directory tree   │
        │  in KvStore (no sync)    │   │  $vault: ref counts in   │
        │                          │   │  KvStore (no sync)       │
        └──────────────────────────┘   └──────────────────────────┘
```

Both subsystems sit alongside the main stack rather than inside it. They use
the KvStore (for index/ref-count entries) and the platform layer (for blob
file I/O) but do not participate in SSTable sync.

**CBOR encoding and decoding** occurs at the Query Layer boundary on writes
(before `KvStore.writeBatch`) and at the Cache Layer boundary on reads (after
`KvStore.get`, before populating the session cache). The LSM engine stores and
retrieves opaque `Uint8List` — it has no knowledge of document structure at any
point. See §5 for the full value encoding pipeline.

**Encryption is a cross-cutting transform, not a layer of its own.** When
enabled, it applies at the same value-encoding seam CBOR does — values are
plaintext above the Cache Layer and encrypted (AES-256-GCM) before they reach
`KvStore`, so the LSM Engine, SSTables, and Sync Layer in the diagram above all
operate on opaque ciphertext regardless of whether encryption is active. See
§1 for the narrative overview and §31 for the full specification.

**Document versioning (§26)** is likewise not a separate layer: it is a
`WriteAugmentor` in the Query Layer's write pipeline, alongside the secondary
index, FTS, vector, and vault-ref augmentors, adding a companion `$ver:` entry
to the same `WriteBatch` as each document write.

**The Query Layer** never touches the LSM directly — it always operates through
the KvStore public API. It is also the only layer that maintains secondary
indexes, intercepting writes to keep index entries consistent (§16).

**The Cache Layer** sits between the Query Layer and KvStore, providing a
platform-tiered session object cache and a persistent materialised view cache.
See §15.

**The Sync Layer** operates on immutable SSTable files produced by the storage
layer. The platform layer abstracts file I/O, compression, and file locking
across native (dart:io/dart:ffi), web (OPFS via dart:js_interop), and test
(in-memory) targets.

## Storage Tiers

KMDB uses two completely separate storage locations. Understanding the boundary
between them is essential to understanding the sync design.

### Tier 1 — Local Database Directory

Device-local storage only. Never shared with any other device. Contains:

```
{local-db-dir}/
  LOCK                        ← zero-byte file; flock / LockFileEx target
  CURRENT                     ← name of the active MANIFEST file (see §10)
  MANIFEST-00001              ← append-only VersionEdit log (see §10)
  wal-00001.log               ← retired WAL files awaiting deletion
  wal-00002.log               ← active WAL
  sst/
    {deviceId}-{minHlc}-{maxHlc}.sst        ← locally-produced SSTables
    {otherDeviceId}-{minHlc}-{maxHlc}.sst   ← SSTables ingested from peers
  local/
    config.json               ← CLI-only: named sync remotes (never synced)
  vault/
    staging/                  ← in-progress vault writes; swept on open (§24)
    blobs/
      sha256/
        {2-char-prefix}/
          {62-char-suffix}/
            manifest.json     ← always present for a known vault object
            blob              ← absent if object is a stub
            tombstone.json    ← present if object has zero references
  VAULT_OFFLINE               ← device-local pin list; never synced (§24)
```

The local database directory is protected by an exclusive file lock
(`flock()`/`LockFileEx()`) at open time. Only one process on one device ever
writes to it.

### Tier 2 — Sync Folder

A shared folder in cloud storage (Google Drive, iCloud, or equivalent). No
device ever stores its WAL files or Manifest here. The only files written to
the sync folder are:

```
{sync-root}/
  highwater/
    {deviceId}.hwm                               ← each device writes only its own
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst            ← regular flush (3 segments)
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst    ← consolidation output (4 segments)
  .consolidation-lease                           ← coordinator lock (§12)
  .consolidation-manifest                        ← coordinator output record (§12)
  vault/
    sha256/
      {2-char-prefix}/
        {62-char-suffix}/
          manifest.json                          ← first-writer-wins (§24)
          blob
          tombstone.json
```

**Each device writes only to files it owns** (for SSTables and `.hwm` files). No two devices ever write to the
same file in the sync folder. This eliminates all write-conflict scenarios at
the file level and is the reason the sync protocol needs no central server.

### The Boundary

The sync engine's job is to move immutable SSTables from Tier 1 into Tier 2
(upload) and from Tier 2 into Tier 1 (download and ingest at L0). Everything
else — WAL files, the Manifest, in-progress compaction output — stays in Tier 1
and is invisible to the sync layer.

The vault subsystem (§24) adds a parallel sync path for binary objects via
`VaultStorageAdapter`. Vault objects in Tier 2 use a single shared directory
(any device can write the same content-addressed object), unlike SSTables which
are device-scoped. See §24 for the full vault sync design.

## Why LSM, Not SQLite?

See §1 for the narrative version of this rationale (the sync-without-a-server
constraint, and why a mutable SQLite file can't satisfy it). The mechanical
detail worth stating here: SQLite in WAL mode uses two files (the database and
the `-wal` journal) that must stay in transactional lockstep, but cloud sync
clients sync them independently, and file-region locking (`fcntl`/`LockFileEx`)
is not replicated across devices — two devices opening the same SQLite file
both believe they hold exclusive locks, and cloud storage responds to the
resulting conflict by forking a `database (1).db` copy with no automated merge
path. SSTables avoid this because they are immutable once written: a receiving
device either sees the complete file or does not see it at all, and file
creation (not mutation) is the atomic primitive cloud storage actually
guarantees. The WAL remains a local implementation detail for crash recovery,
never exposed to the sync layer.

## Architectural Decision Record

**Decision**: Use custom LSM storage engine instead of SQLite.

**Context**: Multi-device sync via Google Drive / iCloud without a central
server.

**Rationale**: Immutable SSTables are safe for cloud-folder sync; SQLite files
are not. This sync-safety property is a first-class requirement.

**Trade-off**: Higher implementation cost and risk vs. battle-tested SQLite.
Must build query engine, indexing, and ACID semantics from scratch.
