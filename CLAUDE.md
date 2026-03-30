# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## General

The `docs/roadmap.md` is used to track future work items and their priority.

We'll create plans for our work and place them in the `plans/` directory. When
the planned work has been completed we'll move them to `plans/completed`.

Quality assurance is critical to this project and you need to maintain a minimum
of 90% test coverage at all times. You must also run all tests successfully
before considering a task to be complete.

Consider edge-cases and failure scenarios when preparing tests - it is critical
not just to focus on easy, "golden-path" tests.

All public classes, methods and properties must have appropriate doc comments.
You may include examples in dec comments if you believe it will help another
developer.

Any complex segments of code should be commented so as to describe the process
and rationale for the approach.

All code files must have a license at the top. The template file is
@header_template.txt. You must add the comment syntax appropriate to the
programming language. Also replace `{{.Year}}` to match the current year.

## Repository Layout

This is a **Pub Workspace**. The root `pubspec.yaml` is a workspace coordinator
only; all source code lives under `packages/`:

```
packages/
  kmdb/        — the core library (lib/, test/, example/)
  kmdb_cli/    — the CLI tool (bin/, lib/, test/)
```

Run `dart pub get` once from the workspace root to resolve dependencies for all
packages.

## Commands

```bash
# Run all tests (kmdb package)
dart test packages/kmdb

# Run a single test file
dart test packages/kmdb/test/some_test.dart

# Run tests matching a name pattern
dart test packages/kmdb --name "some pattern"

# Analyze/lint (all packages)
dart analyze packages/kmdb
dart analyze packages/kmdb_cli

# Format (all packages)
dart format packages/

# Build docs site (requires pandoc)
make docs
```

## Implementation Status

| Phase | Scope                                                                                            | Status         |
| :---- | :----------------------------------------------------------------------------------------------- | :------------- |
| 1     | Primitives & platform layer (XXH64, HLC, KeyCodec, ValueCodec, StorageAdapter)                   | ✅ Complete    |
| 2     | Storage engine core (SkipList, Memtable, WAL, Bloom filter, SSTable writer/reader)               | ✅ Complete    |
| 3     | LSM orchestration (Manifest, MergeIterator, CompactionJob, LsmEngine, CrashRecovery, KvStore)    | ✅ Complete    |
| 4     | Value encoding integration & `$meta` (MetaStore, DeviceId, generation counters)                  | ✅ Complete    |
| 5     | Sync protocol (HighwaterMark, CloudAdapter, SyncEngine push/pull, ConsolidationCoordinator)      | ✅ Complete    |
| 6     | Cache layer (LruMap, SessionCache, CacheTier, CacheLayer with generation invalidation)           | ✅ Complete    |
| 7     | Query layer (KmdbDatabase, KmdbCollection, KmdbQuery, Filter DSL, secondary indexes, reactivity) | ✅ Complete    |
| 8     | Platform hardening (OPFS web storage, Zstd FFI/WASM, cloud adapters, performance benchmarks)     | ✅ Complete    |

All 600 kmdb + 112 kmdb_cli tests pass as of 2026-03-30.

## Architecture

KMDB is a local-first document database for Dart/Flutter with a 6-layer stack:

```
Application
    ↓
Query Layer       — typed KmdbCollection<T> API, filter DSL, reactive watch() streams
    ↓
Cache Layer       — session object cache + persistent materialised views ($cache)
    ↓
KvStore           — public LSM API boundary (untyped Uint8List, String keys)
    ↓
Storage Engine    — WAL + memtable + SSTables, Manifest, compaction
    ↓
Platform Layer    — conditional exports: dart:io (native) vs dart:js_interop (web)
```

**Why LSM over SQLite:** Immutable SSTables are the core design constraint. File
creation is atomic in cloud storage; file mutation is not. SSTables are the
natural, sync-safe unit of replication — a first-class requirement, not an
incidental benefit.

### Storage Engine (LSM)

- **Write path:** WAL append + fsync → memtable insert → flush at 64KB → L0
  SSTable
- **Levels:** L0 (2-file trigger), L1 (2MB), L2 (20MB). Single-file shortcut: if
  total data ≤512KB, compact everything to one L2 file (common case).
- **Compaction:** synchronous on the write path — no background isolate. Fires
  before the triggering `put()` returns. Roughly every ~30 writes.
- **Manifest:** append-only VersionEdit log (`MANIFEST-NNNNN`). Each record is
  `[XXH64 8B][length 4B][CBOR VersionEdit]`. `CURRENT` file names the active
  manifest. Rotated when >1MB.
- **WAL:** multi-file (`wal-00001.log`). Local only — never synced to cloud.
  Retired after flush is confirmed in the Manifest.
- **SSTables:** 4KB data blocks, Bloom filter block (10 bits/key, ~0.8% FPR),
  index block, footer. XXH64 checksums throughout.
- **Value encoding (§5):** `KmdbCodec<T>` → CBOR → optional Zstd (native) or
  Deflate (web) compression. 1-byte flag prefix on each value.
- **Keys:** UUIDv7 (16-byte binary internally, hex string at KvStore boundary).
  HLC timestamps (48-bit physical + 16-bit logical) on WAL records and SSTables.

### SSTable Naming

Two formats — both live under `sst/`:

- **Regular flush:** `{deviceId}-{minHlc}-{maxHlc}.sst` (3 segments)
- **Consolidation output:** `{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst` (4
  segments)

The `epoch` field is a fencing token (sequence number from the lease file) that
identifies which consolidation round produced the file.

### Local Directory Layout

```
{local-db-dir}/
  LOCK
  CURRENT
  MANIFEST-00001
  wal-00001.log
  sst/
    {deviceId}-{minHlc}-{maxHlc}.sst
```

### Sync Folder Layout

```
{sync-root}/
  highwater/
    {deviceId}.hwm        ← per-device high-water mark (JSON)
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst          ← regular flush (3 segments)
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst  ← consolidation output (4 segments)
  .consolidation-lease    ← coordinator lock (JSON)
```

### Cache Layer (§15)

Sits between KvStore and the Query Layer. Two caches:

1. **Session object cache** — decoded `Map<String, dynamic>` objects, keyed by
   `(namespace, key, sequenceNumber)`. 2,000 objects on desktop; 256 on
   mobile/web.
2. **Materialised view cache** (`$cache` namespace) — persisted scan results
   required on mobile/web where processes are killed silently.

Invalidation uses **namespace generation counters** in `$meta`
(`gen:{namespace}`), incremented atomically on every `WriteBatch`. The Cache
Layer subscribes to `KvStore.writeEvents` to evict stale entries.

### Query API (§13)

Core types: `KmdbDatabase`, `KmdbCodec<T>`, `KmdbCollection<T>`, `KmdbQuery<T>`

Filter DSL: comparisons, nested dot-paths, string ops (`startsWith`, `endsWith`,
`contains`), array ops (`containsAll`, `containsAny`), null semantics,
`Filter.not()`.

Query pipeline: `where` → `orderBy` → `limit` / `offset` → terminals (`get()`,
`stream()`, `watch()`, `first()`, `count()`, `any()`).

**Reactivity:** `watch()` re-executes the query on each `writeEvents` emission
for the namespace, debounced at 50ms.

### Secondary Indexes (§16)

Defined at `KmdbDatabase.open()` time. Lazy build on first query. 4 lifecycle
states: `undefined` → `building` → `current` (or `stale` if writes arrived
during build). Index entries stored in `$index:{ns}:{path}` system namespaces.
All index writes are in the same `WriteBatch` as the document write — always
consistent. Dot-path syntax supports nested fields (`address.city`) and array
fan-out (`tags[]`).

### Sync Protocol (§12)

- Each device has a stable UUID identity
- SSTables are the sync unit — uploaded after flush/compaction; WAL never synced
- Per-device high-water marks (`.hwm` files) track what each device has seen
- Conflict resolution: Last-Write-Wins via HLC timestamps
- Cross-device consolidation via a `ConsolidationCoordinator` using a lease file

### Crash Recovery (§17)

On `open()`: acquire exclusive lock → read `CURRENT` → replay Manifest → delete
orphan SSTables → replay WAL files above highest `logNumber` → set dirty-open
flag on first write.

## Documentation

Full specification is in [docs/spec/](docs/spec/) (Pandoc Markdown). The built
HTML lives in [site/](site/) and is generated via `make docs`. Key spec files:

- `03_architecture_overview.md` — ADR and layer diagram
- `04_keys.md` — UUIDv7 document keys, device identity, HLC
- `05_value_encoding.md` — CBOR encoding pipeline and compression
- `06_storage_engine.md` — LSM write/read/compaction paths
- `07_wal.md` — WAL record format and file lifecycle
- `08_sstable.md` — SSTable format and naming conventions
- `09_integrity.md` — checksum strategy and Bloom filter notes
- `10_manifest.md` — VersionEdit log format and CURRENT pointer
- `11_kv_store.md` — KvStore interface, WriteBatch, OpenResult, KvStoreConfig
- `12_sync.md` — full sync protocol
- `13_query_api.md` — public API surface
- `14_reactivity.md` — watch() and debounced re-execution
- `15_cache_layer.md` — session cache, materialised views, generation counters
- `16_secondary_indexes.md` — index lifecycle, write interception, lazy build
- `17_crash_recovery.md` — recovery sequence and failure scenarios
- `18_concurrency.md` — synchronous model and performance targets
- `19_platform.md` — platform conditional exports and package layout
