# KMDB Implementation Plan

Status as of 2026-03-28. Spec is complete and frozen for implementation.
The codebase contains only stubs — everything below is greenfield.

---

## Dependencies to Add (pubspec.yaml)

```yaml
dependencies:
  cbor: ^6.3.0          # CBOR encoding/decoding
  uuid: ^4.5.0          # UUIDv7 generation
  zstandard: ^1.5.0     # Zstd (FFI native + WASM fallback)
  archive: ^4.0.0       # Deflate for web (fallback)
  meta: ^1.16.0         # @internal, @visibleForTesting

dev_dependencies:
  test: ^1.25.6         # (already present)
  lints: ^6.0.0         # (already present)
  mockito: ^5.4.0       # mock StorageAdapter in unit tests
  build_runner: ^2.4.0  # mockito codegen
```

> **XXH64:** No suitable pub.dev package exists. Implement as a pure-Dart class
> (`lib/src/engine/util/xxhash.dart`) using the published algorithm spec.
> **LRU cache:** Implement as a `_LruMap<K, V>` in the cache layer — not worth
> a dependency for one data structure.

---

## Directory Structure

```
lib/
  kmdb.dart                            # Public exports only

  src/
    engine/                            # Platform-agnostic storage engine
      util/
        xxhash.dart                    # XXH64 implementation
        hlc.dart                       # Hybrid Logical Clock
        key_codec.dart                 # UUIDv7 ↔ hex string, namespace prepending
        varint.dart                    # Variable-length int encoding (SSTable blocks)

      platform/                        # Conditional storage I/O
        storage_adapter.dart           # Abstract interface + conditional export
        storage_adapter_native.dart    # dart:io + flock
        storage_adapter_web.dart       # OPFS via dart:js_interop
        storage_adapter_memory.dart    # In-memory (tests)

      memtable/
        skip_list.dart                 # In-memory sorted skip list
        memtable.dart                  # Wrapper: size tracking, frozen snapshots

      wal/
        wal_record.dart                # Binary record format, record types
        wal_writer.dart                # Append WAL records, fsync, rotate
        wal_reader.dart                # Sequential replay, checksum validation

      sstable/
        bloom_filter.dart              # 10 bits/key, double hashing, XXH64
        block_builder.dart             # 4KB data blocks with prefix compression
        sstable_writer.dart            # Full file: data → filter → index → footer
        sstable_reader.dart            # Open, footer parse, Bloom check, block read
        sstable_info.dart              # Parsed filename metadata (name formats §8)

      manifest/
        version_edit.dart             # VersionEdit CBOR schema
        manifest_writer.dart          # Append VersionEdit records, rotation
        manifest_reader.dart          # Replay to reconstruct level state
        current_file.dart             # Read/write CURRENT pointer file

      compaction/
        merge_iterator.dart            # N-way merge; internal key ordering
        compaction_job.dart            # Single compaction run: read → merge → write

      kvstore/
        lsm_engine.dart                # Core LSM: levels map, write/read/scan path
        crash_recovery.dart            # open() sequence: lock → manifest → orphan → WAL
        kv_store_impl.dart             # KvStore implementation wrapping lsm_engine
        kv_store.dart                  # Public interface + WriteBatch + OpenResult + config

    encoding/
      value_codec.dart                 # 1-byte flag + CBOR + Zstd/Deflate pipeline
      compression_flag.dart            # Flag constants: 0x00 raw, 0x01 Zstd, 0x02 Deflate

    sync/
      hlc_clock.dart                   # Global HLC singleton, maxOffset clamp (60s)
      highwater.dart                   # .hwm file read/write, peer tracking
      sync_engine.dart                 # Push/pull SSTables, ingest at L0
      consolidation_coordinator.dart   # Lease protocol, state machine
      consolidation_config.dart        # ConsolidationConfig with .forTesting()
      local/
        local_directory_adapter.dart   # dart:io POSIX adapter (network volume, locally-synced cloud folder)
        memory_sync_adapter.dart       # In-memory adapter for tests (simulates concurrent access)
      cloud/
        cloud_adapter.dart             # Abstract sync folder interface
        google_drive_adapter.dart
        icloud_adapter.dart
        s3_adapter.dart                # AWS S3 (conditional PUT via if-none-match)
        gcs_adapter.dart               # Google Cloud Storage (if-generation-match)

    cache/
      lru_map.dart                     # Simple LRU linked-hash map
      session_cache.dart               # (namespace, key, seq) → Map<String, dynamic>
      cache_layer.dart                 # Wraps KvStore; generation-counter invalidation
      cache_tier.dart                  # Enum: desktop / mobile / web

    query/
      kmdb_database.dart               # Open, close, onResume, collection accessor
      kmdb_collection.dart             # get/put/delete/insert/replace/update/putMany
      kmdb_query.dart                  # where/orderBy/limit/offset/keyPrefix + terminals
      kmdb_codec.dart                  # KmdbCodec<T> interface
      filter/
        filter.dart                    # Filter base + Filter.and/or/not
        field_filter.dart              # Field('x').equals(...) etc.
        field_path.dart                # Dot-path resolver (nested + array)
      index/
        index_definition.dart          # IndexDefinition (namespace, path)
        index_manager.dart             # Lifecycle: undefined→building→current/stale
        index_writer.dart              # Write interception, entry encoding
        index_reader.dart              # Prefix scan, decode document keys
      watcher.dart                     # watch() stream, writeEvents subscription, debounce

test/
  engine/
    xxhash_test.dart
    hlc_test.dart
    key_codec_test.dart
    skip_list_test.dart
    memtable_test.dart
    wal_writer_test.dart
    wal_reader_test.dart
    bloom_filter_test.dart
    sstable_writer_test.dart
    sstable_reader_test.dart
    manifest_test.dart
    merge_iterator_test.dart
    compaction_test.dart
    crash_recovery_test.dart
    lsm_engine_test.dart
  kv_store_test.dart                   # Full KvStore integration tests
  encoding/
    value_codec_test.dart
  sync/
    highwater_test.dart
    consolidation_test.dart
    sync_engine_test.dart
  cache/
    session_cache_test.dart
    cache_layer_test.dart
  query/
    filter_test.dart
    field_path_test.dart
    kmdb_collection_test.dart
    kmdb_query_test.dart
    index_test.dart
    watcher_test.dart
  integration/
    full_stack_test.dart               # open → write → read → watch → close
    recovery_test.dart                 # Simulated crash scenarios
    compaction_integration_test.dart
```

---

## Phase 1 — Primitives & Platform Layer

**Goal:** Everything that has no KMDB dependencies itself. Establishes the foundation all other phases build on.

### 1.1 Package setup
- Replace `lib/kmdb.dart` and `lib/src/kmdb_base.dart` with the real package skeleton
- Configure `pubspec.yaml` with dependencies above
- Set up `analysis_options.yaml` (already present; verify strict lints)
- Create `hook/build.dart` for native Zstd compilation

### 1.2 StorageAdapter (conditional exports)
**Files:** `storage_adapter.dart`, `*_native.dart`, `*_web.dart`, `*_memory.dart`

```dart
abstract interface class StorageAdapter {
  Future<Uint8List> readFile(String path);
  Future<void> writeFile(String path, Uint8List bytes);
  Future<void> appendFile(String path, Uint8List bytes);
  Future<void> syncFile(String path);          // fsync
  Future<void> syncDir(String dirPath);        // fsync directory entry (Linux)
  Future<void> deleteFile(String path);
  Future<bool> fileExists(String path);
  Future<List<String>> listFiles(String dirPath, {String? extension});
  Future<void> renameFile(String from, String to);  // atomic on POSIX
  Future<void> acquireLock(String lockPath);   // flock/LockFileEx
  Future<void> releaseLock(String lockPath);
}
```

- Native: `dart:io` `RandomAccessFile` for append; `FileLock.exclusive` for lock
- Memory: `Map<String, Uint8List>` — used in all unit tests via `KvStoreConfig.forTesting()`
- Web: OPFS stub for now (defer full implementation to Phase 8)

**Tests:** Read/write/append/delete/rename round-trips on memory adapter. Lock exclusivity test.

### 1.3 XXH64
**File:** `util/xxhash.dart`

Implement the published XXH64 algorithm (seed=0 default). Pure Dart. Use Dart `Int64` or manual 64-bit arithmetic with two `int`s if needed.

**Tests:** Verify against published test vectors from the xxHash repository.

### 1.4 Hybrid Logical Clock (HLC)
**Files:** `util/hlc.dart`, `sync/hlc_clock.dart`

```dart
/// Immutable HLC timestamp: 48-bit physical (ms) + 16-bit logical.
final class Hlc implements Comparable<Hlc> {
  final int physicalMs;   // 48-bit; millis since epoch
  final int logical;      // 16-bit

  int get encoded => (physicalMs << 16) | logical;  // 64-bit packed
  static Hlc decode(int encoded) { ... }
  static Hlc fromHex(String hex) { ... }
  String toHex() { ... }   // 12 uppercase hex chars

  Hlc tick(Hlc? received);  // NTP-style merge
}
```

`HlcClock` is a process-singleton wrapping a mutable `Hlc`, with a `maxClockSkew` clamp (default 60s). Receives external HLC values on WAL replay and SSTable ingestion.

**Tests:** tick() monotonicity, maxOffset clamping, hex encoding round-trip, comparison ordering.

### 1.5 Key codec
**File:** `util/key_codec.dart`

- `keyToBytes(String hexKey)` → 16-byte `Uint8List`
- `bytesToKey(Uint8List bytes)` → hex string
- `namespacePrefix(String namespace)` → length-prefixed bytes for internal SSTable key
- `internalKey(String namespace, String key, Hlc seq)` → composite key for SSTable
- `KeyGenerator` interface with `UuidV7KeyGenerator` and `SequentialKeyGenerator` (tests)

**Tests:** Round-trip encode/decode. Namespace prefix ordering. Internal key sort order.

### 1.6 Value encoding
**Files:** `encoding/value_codec.dart`, `encoding/compression_flag.dart`

```
encode: Map<String,dynamic> → cbor.encode() → compress if ratio > 1.1× → [flag|bytes]
decode: [flag|bytes] → decompress → cbor.decode() → Map<String,dynamic>
```

- Flag 0x00: uncompressed CBOR
- Flag 0x01: Zstd — primary on all platforms. Native: `dart:ffi` to libzstd. Web: WASM via `zstandard` package. (Defer FFI/WASM wiring to Phase 8; stub returning raw CBOR for now.)
- Flag 0x02: Deflate — web fallback only, for browsers without WASM support. Use `archive` package.

Compression is applied to the CBOR output, not individual fields. Decision threshold: compressed size < original × (1/1.1).

**Tests:** Round-trip all CBOR-compatible types. Compression threshold logic. Cross-flag decode (simulate native-encoded value decoded on web path). Null/missing field handling.

---

## Phase 2 — Storage Engine: Core Components

**Goal:** The individual building blocks of the LSM engine, each independently testable.

### 2.1 Skip List (memtable)
**Files:** `memtable/skip_list.dart`, `memtable/memtable.dart`

- Ordered by internal key: `(userKey ASC, sequenceNumber DESC, deviceId DESC)`
- `put(InternalKey, Uint8List)`, `get(String namespace, String userKey)` → newest visible entry
- `scan(String namespace, {String? start, String? end, bool descending})` → `Iterable<KvEntry>`
- Size tracking in bytes (key bytes + value bytes). Flush threshold: 64KB.
- `freeze()` → immutable snapshot (for concurrent read during flush); `Memtable` wraps active + optional frozen

**Tests:** Ordering invariant. Tombstone visibility (get on deleted key returns null). Byte-size accuracy. freeze/thaw round-trip.

### 2.2 WAL Writer & Reader
**Files:** `wal/wal_record.dart`, `wal/wal_writer.dart`, `wal/wal_reader.dart`

**Record format** (from §7):
```
[XXH64 8B][type 1B][seq 8B][nsLen 1B][ns NB][keyLen 2B][key KB][valLen 4B][val VB]
```
Types: `0x01` Put, `0x02` Delete, `0x03` FlushMarker, `0x04` WriteBatch

`WalWriter`:
- `append(WalRecord)` → encode → `StorageAdapter.appendFile` → `syncFile` (when `fsyncOnWrite`)
- `rotate()` → increment sequence, start new file, write FlushMarker to old
- `activeSequence` getter

`WalReader`:
- `replay(String path, {int fromSeq})` → `Iterable<WalRecord>`
- Stops at first checksum failure; does not throw (truncation is expected)

**Tests:** Append/replay round-trip all record types. Checksum corruption stops replay cleanly. FlushMarker seek. WriteBatch atomicity (partial batch with bad checksum drops entire batch). WAL rotation sequence numbering.

### 2.3 Bloom Filter
**File:** `sstable/bloom_filter.dart`

- Configurable bits/key (default 10 → ~0.8% FPR)
- Double hashing: `h1 = XXH64(key, seed=0)`, `h2 = XXH64(key, seed=h1)`
- `build(Iterable<Uint8List> keys)` → `Uint8List filterBytes`
- `mayContain(Uint8List key, Uint8List filterBytes)` → `bool`

**Tests:** Zero false negatives. FPR within spec at 10 bits/key over 10K keys. Serialisation round-trip.

### 2.4 SSTable Writer
**File:** `sstable/sstable_writer.dart`

Writes one complete SSTable:
1. Accumulate entries into 4KB data blocks (prefix compression, restart every 16 keys)
2. Write Bloom filter block
3. Write index block (one entry per data block: last key + offset + size)
4. Write 48-byte footer: filter offset/size, index offset/size, entry count, minKey, maxKey, XXH64 of all preceding bytes

`SSTableWriter`:
- `add(InternalKey key, Uint8List value)` — entries must arrive in key order
- `finish()` → `Uint8List` complete file bytes (or streams to adapter)

**Tests:** Produces readable file (reader integration). Footer checksum. Block boundary correctness. Restart interval. Prefix compression round-trip.

### 2.5 SSTable Reader
**File:** `sstable/sstable_reader.dart`, `sstable/sstable_info.dart`

`SSTableReader`:
- `open(String path, StorageAdapter)` → validates footer XXH64 → loads filter + index blocks
- `get(String namespace, String key)` → Bloom check → binary search index → read one block → linear scan
- `scan(String namespace, {String? start, String? end, bool descending})` → `Stream<KvEntry>`
- `close()`

`SstableInfo`: parses 3-segment and 4-segment filename formats → `deviceId`, `epoch?`, `minHlc`, `maxHlc`.

**Tests:** Get present/absent key. Bloom filter skips false positives correctly (count file reads). Scan order ascending and descending. Footer corruption throws `CorruptedSstableException`. Cross-namespace isolation. Stale consolidation detection (4-segment epoch validation).

---

## Phase 3 — Storage Engine: LSM Orchestration

**Goal:** Assemble the components into a working `KvStore`. This phase produces the first integration-testable unit.

### 3.1 Manifest
**Files:** `manifest/version_edit.dart`, `manifest/manifest_writer.dart`, `manifest/manifest_reader.dart`, `manifest/current_file.dart`

**VersionEdit CBOR schema** (from §10): `logNumber`, `nextSeq`, `add[]`, `remove[]`

`ManifestWriter`:
- `append(VersionEdit)` → `[XXH64 8B][len 4B][CBOR]` → `appendFile` → `syncFile`
- `rotate(List<SstFileInfo> liveFiles)` → write snapshot VersionEdit, atomically update `CURRENT`, delete old manifest

`ManifestReader`:
- `replay(String manifestPath)` → `ManifestState` (levels map, highest logNumber, nextSeq)
- Stops at first checksum failure

`CurrentFile`:
- `read(String dbPath)` → `String manifestName`
- `write(String dbPath, String manifestName)` → atomic write-then-rename

**Tests:** Append/replay round-trip. Rotation produces consistent snapshot. CURRENT update atomicity. Checksum failure mid-replay returns partial state. Orphan detection (add then implicit remove).

### 3.2 Merge Iterator
**File:** `compaction/merge_iterator.dart`

N-way sorted merge over multiple `SSTableReader.scan()` streams. Internal key ordering: `(userKey ASC, seq DESC, deviceId DESC)`. Deduplicate: for each user key, emit only the highest-sequence entry; drop tombstones at L2 when all peer HWMs are past tombstone HLC.

**Tests:** Two-file merge preserves order. Tombstone shadowing. Duplicate key deduplication. Empty source streams. Descending merge.

### 3.3 Compaction
**File:** `compaction/compaction_job.dart`

```dart
final class CompactionJob {
  // Inputs: source files at level N
  // Output: one or more files at level N+1
  // Returns: VersionEdit (remove inputs, add outputs)
  Future<VersionEdit> run();
}
```

Triggers (checked synchronously after every flush):
- L0 file count ≥ 2 → L0→L1 (merge all L0 + existing L1)
- L1 size > 2MB → L1→L2
- Single-file shortcut: total live bytes ≤ 512KB → collapse all to one L2 file
- All compaction is N-way merge → new SSTable → append VersionEdit → delete inputs

**Tests:** L0→L1 trigger. L1→L2 trigger. Single-file shortcut activates and deactivates correctly. Tombstone dropped at L2 when safe. Orphan detection if crash before VersionEdit (simulate via memory adapter).

### 3.4 Crash Recovery
**File:** `kvstore/crash_recovery.dart`

Implements the 9-step `open()` recovery sequence (§17):
1. Acquire `LOCK` file (exclusive)
2. Read `CURRENT` → identify active manifest
3. Replay manifest → reconstruct levels + highest logNumber + nextSeq
4. Delete orphan `.sst` files (in `sst/` but not in live adds)
5. Collect `wal-*.log`, sort by sequence; skip ≤ highest logNumber
6. Replay remaining WALs from last FlushMarker; stop at checksum failure
7. Delete safe WAL files (sequence ≤ highest logNumber)
8. Prepare dirty-open flag (written on first WriteBatch, not now)
9. Return `OpenResult`

**Tests:** Clean open. WAL truncation recovery (data loss bounded to one write). Orphan SSTable deletion. Dirty-open flag set/cleared. All 9 failure scenarios from the spec table (use memory adapter with injected faults).

### 3.5 LSM Engine & KvStore
**Files:** `kvstore/lsm_engine.dart`, `kvstore/kv_store_impl.dart`, `kvstore/kv_store.dart`

`LsmEngine` holds:
- Active `Memtable` (+ optional frozen snapshot during flush)
- Level map: `Map<int, List<SstFileInfo>>` (rebuilt from manifest on open)
- `ManifestWriter`, `WalWriter`, `HlcClock`

`KvStoreImpl` implements the public `KvStore` interface:
- `put`/`delete`/`writeBatch` → WAL append → memtable insert → flush check
- `get` → memtable → L0 newest-first → L1 → L2
- `scan` → merge iterator over memtable + all levels (range-filtered)
- `flush()` / `compactAll()` as explicit control methods
- `writeEvents` stream (broadcast, fires namespace string after each successful write)

**Integration tests** (`kv_store_test.dart`):
- Full write → read → delete → scan round-trip
- WriteBatch atomicity
- Flush triggers at 64KB
- Compaction triggers (use `KvStoreConfig.forTesting()` with tiny thresholds)
- Descending scan ordering
- Multi-namespace isolation
- System namespace protection (`$` prefix)
- `close()` releases lock; second open on same path succeeds
- `OpenResult` fields populated correctly after recovery scenarios

---

## Phase 4 — Value Encoding Integration & `$meta`

**Goal:** Wire CBOR/compression into KvStore path; establish system namespace primitives used by all upper layers.

- Connect `ValueCodec` to `KvStore.put/get` (encoding on write, decoding only at Query Layer — KvStore stores raw bytes; this phase just ensures the codec works end-to-end)
- Implement `$meta` read/write helpers: `generation counter` (`gen:{ns}`), `dirty-open flag`, `device ID` storage
- Write `device_id.dart`: read/write stable device UUID from `$meta` (in-scope) and platform secure storage (stub; full per-platform implementation in Phase 8)

**Tests:** Round-trip CBOR+Zstd through KvStore. Generation counter increments atomically with WriteBatch. Device ID persistence across close/open.

---

## Phase 5 — Sync Protocol

**Goal:** SSTable-based multi-device sync. Can be developed largely independently of the Query Layer.

### 5.1 High-Water Mark
**File:** `sync/highwater.dart`

- `HighwaterMark`: read/write `.hwm` JSON file
- `peerHighwaters`: `Map<String, Hlc>` — highest processed HLC per peer device
- `markProcessed(String peerId, Hlc hlc)`

**Tests:** Read/write round-trip. Peer map merging. Stale device detection (90-day threshold).

### 5.2 Sync Folder Adapter Interface
**File:** `sync/cloud/cloud_adapter.dart`

```dart
abstract interface class CloudAdapter {
  Future<void> upload(String remotePath, Uint8List bytes);
  Future<Uint8List?> download(String remotePath);      // null if not found
  Future<List<String>> list(String remoteDir);
  Future<void> delete(String remotePath);
  Future<bool> compareAndSwap(                         // atomic conditional write
    String path, Uint8List newBytes, {String? ifMatchEtag});
}
```

**Local adapters** (`sync/local/`):

- `MemorySyncAdapter` — in-memory map, used in all unit/integration tests. Simulates concurrent access for lease tests.
- `LocalDirectoryAdapter` — `dart:io`-backed, desktop-only (guarded by `!kIsWeb`). Targets a local filesystem path: a shared network volume (NAS, SMB/NFS mount), or any locally-synced cloud folder (iCloud Drive, Dropbox, Synology Drive) without needing their native SDKs. `compareAndSwap` is implemented via write-to-temp + `File.renameSync` (atomic on POSIX); throws `LockConflictException` if the file already exists and no `ifMatchEtag` is supplied (`if-none-match: *` semantics).

**Cloud adapters** (`sync/cloud/`, Phase 8):

- `GoogleDriveAdapter` — Google Drive REST API; `compareAndSwap` via Drive's `If-Match` ETag header.
- `ICloudAdapter` — CloudKit / iCloud Drive; `compareAndSwap` via CloudKit record change tags.
- `S3Adapter` — AWS S3; `compareAndSwap` via `If-None-Match: *` on PutObject (supported since 2024). No DynamoDB dependency required for new buckets.
- `GcsAdapter` — Google Cloud Storage; `compareAndSwap` via `if-generation-match` precondition on upload.

### 5.3 Sync Engine
**File:** `sync/sync_engine.dart`

- `push()`: flush local KvStore → upload new SSTables (those not yet in cloud) → upload `.hwm`
- `pull()`: list remote sstables → download files with minHlc > our peer HWM → verify XXH64 → ingest at L0 via `KvStore` → update `.hwm`
- `sync()`: push then pull

Namespace-scoped: only upload SSTables containing sync-enabled namespaces.

**Tests:** Push uploads new SSTables, skips already-uploaded. Pull ingests remote SSTables in HLC order. Corrupted SSTable (bad footer checksum) rejected on ingestion. HWM updated correctly. Idempotent re-ingestion.

### 5.4 Consolidation Coordinator
**File:** `sync/consolidation_coordinator.dart`

Implements the lease file protocol (§12):
- `runIfNeeded()`: check threshold (default 8 shared SSTables) → attempt consolidation
- `acquireLease()`: write tmp → rename → re-read (verify won the race)
- `consolidate()`: N-way merge of input SSTables → write 4-segment output SSTable
- `commit()`: write consolidation manifest → delete input SSTables → delete lease
- `assessRecoveryState()`: handle expired lease from previous coordinator

State machine: `IDLE → LEASE_ACQUIRED → CONSOLIDATING → VERIFYING → COMPLETE`

**Tests:** Happy path consolidation. Lease expiry (simulate clock advance). Two concurrent coordinators (one wins, one aborts). Partial output recovery (previous coordinator crashed after writing outputs but before manifest). Fencing token validation prevents stale write.

---

## Phase 6 — Cache Layer

**Files:** `cache/lru_map.dart`, `cache/session_cache.dart`, `cache/cache_layer.dart`, `cache/cache_tier.dart`

`CacheLayer` wraps `KvStore`:
- Delegates all writes to `KvStore`; subscribes to `writeEvents`
- On write event: read new generation from `$meta`; evict session entries for namespace with old generation; mark `$cache` entries stale
- `get()`: check session cache → KvStore → decode → cache decoded object
- `scan()`: check `$cache` for materialised results → if stale: mobile/web return stale + recompute background; desktop recompute synchronously

Platform tier auto-detection: check `Platform.isAndroid || Platform.isIOS` etc. (native); `kIsWeb` (web); else desktop.

**Tests:** Cache hit on second read (no KvStore.get called). Session eviction on write. Generation counter invalidation. Materialised view stale-then-fresh cycle. `onResume()` triggers generation check. Platform tier selection. LRU eviction when capacity exceeded.

---

## Phase 7 — Query Layer

**Goal:** The user-facing API. Depends on Cache Layer and KvStore (via Cache Layer).

### 7.1 KmdbCodec & KmdbDatabase
**Files:** `query/kmdb_codec.dart`, `query/kmdb_database.dart`

`KmdbDatabase.open()`:
- Opens KvStore, wraps in CacheLayer
- Registers index definitions (no build yet)
- Inspects `OpenResult.hadUnclosedSession` → calls `onIndexRebuildRequired` if any index was `building`
- Returns `KmdbDatabase`

### 7.2 Filter DSL
**Files:** `query/filter/filter.dart`, `query/filter/field_filter.dart`, `query/filter/field_path.dart`

All filter types from §13. Field path resolution handles:
- Top-level: `doc['city']`
- Nested: `doc['address']['city']` via dot splitting
- Indexed array: `doc['tags'][0]`
- Fan-out: `doc['tags']` (returns `List`)

Null vs missing: resolve to `_Missing` sentinel; `isNull()` matches both; `isNotNull()` requires presence AND non-null.

**Tests:** Every filter type. Dot-path resolution (nested, array, missing). `Filter.and/or/not` composition. Null/missing semantics. Short-circuit evaluation in `Filter.and`.

### 7.3 KmdbCollection & KmdbQuery
**Files:** `query/kmdb_collection.dart`, `query/kmdb_query.dart`

`KmdbCollection<T>`:
- All write methods wrap in WriteBatch with write interception (Phase 7.4)
- `all()` and `where()` return `KmdbQuery<T>` (no I/O yet)

`KmdbQuery<T>`:
- Pipeline methods return new `KmdbQuery` (immutable builder)
- `orderBy('id')` → sets `descending` flag for `KvStore.scan`; all other fields → in-memory sort
- Terminals execute the pipeline:
  - `get()` → scan → decode → filter → sort → limit/offset
  - `stream()` → same but lazy, holds snapshot
  - `first()` → get with limit 1
  - `count()` → scan counting only (avoids full decode when filter is key-only)
  - `any()` → count > 0
  - `watch()` → reactive stream (Phase 7.5)

**Tests:** All terminal methods. `orderBy('id')` uses scan descending (no in-memory sort). Pipeline immutability (each `where()` returns new instance). `keyPrefix` filter. `limit`/`offset`. Empty namespace. Decode errors surface correctly.

### 7.4 Write Interception (Indexes)
**Files:** `query/index/index_manager.dart`, `query/index/index_writer.dart`, `query/index/index_reader.dart`

Write interception sequence (every `put`/`delete` via `KmdbCollection`):
1. Fetch current document from CacheLayer (for old index entry removal)
2. Begin `WriteBatch`
3. For each index in `current` or `building`: remove old entries, add new entries
4. Add document put/delete
5. Increment `gen:{namespace}` counter
6. Commit atomically

Lazy index build on first query:
1. Set `status = building` in `$meta`
2. Record current generation
3. Scan namespace in batches of 200 → write index entries
4. On completion: compare generation; set `current` or `stale`
5. Fire `onIndexReady`

**Tests:** Index entries consistent with document (no partial state). Tombstone removes old index entries. Concurrent write during build results in `stale` not `corrupt`. Interrupted build shows `building` on next open. Full round-trip: build → query via index → filter remaining.

### 7.5 Reactivity
**File:** `query/watcher.dart`

`watch()` implementation:
- Subscribe to `KvStore.writeEvents`
- On matching namespace emit: schedule re-execution after debounce window (50ms)
- A subsequent write within window resets the timer (one re-query per burst)
- Namespace-level scoping: write to "tasks" does not trigger "notes" watcher

**Tests:** Debounce: 10 rapid writes produce one re-emit. Namespace isolation. Watcher disposes cleanly on stream cancel. Error in re-query propagates to stream.

---

## Phase 8 — Platform Hardening & Polish

**Goal:** Production-ready on all targets.

- **Web StorageAdapter:** Full OPFS implementation via `dart:js_interop`; SAHPool pattern
- **Web compression:** Zstd WASM via `zstandard` package; fallback to Deflate
- **Platform device ID:** Per-platform secure storage (Keychain, SharedPreferences, localStorage, app data dir)
- **Native Zstd FFI:** Wire `hook/build.dart` with `native_toolchain_c` for libzstd compilation
- **Cloud adapters:** Google Drive, iCloud, S3, and GCS `CloudAdapter` implementations
- **`KvStoreConfig.forTesting()`:** Tiny thresholds, no fsync, memory adapter — used throughout test suite
- **Performance benchmarks:** Validate P99 targets from §18 (write, read, scan, open, compaction)
- **Error types:** Define KMDB-specific exceptions (`CorruptedWalException`, `CorruptedSstableException`, `LockConflictException`, `ClockSkewException`, `StaleIndexException`)

---

## Implementation Constraints (from spec & CLAUDE.md)

- **≥ 90% test coverage at all times.** Do not merge a phase until coverage is met.
- **All public APIs must have doc comments.** Include examples on complex methods.
- **Complex code segments must have inline comments** explaining the approach and rationale.
- **Test edge cases, not just golden paths.** Crash scenarios, corrupted files, concurrent access, boundary sizes.
- **Never use `dart test` with `--no-sound-null-safety`** or any flag that bypasses the type system.
- **`fsyncOnWrite: false`** only in tests via `KvStoreConfig.forTesting()`. Never in production paths.
- **Synchronous compaction only.** No `dart:isolate` for compaction. All operations on the calling isolate.
- **All writes go through WAL before memtable.** No exceptions, including index writes and `$meta` updates.

---

## Open Questions Before Implementation

These do not block Phase 1 but should be resolved before Phase 5 (Sync) or Phase 7 (Query):

1. ~~**`update()` cross-device safety:**~~ ✅ **Resolved.** The conflict is not specific to `update()` — it occurs whenever two devices independently write to the same key and their SSTables are merged during compaction. LWW picks the higher HLC timestamp and silently discards the other. The warning has been moved from the `update()` doc comment to a `### Conflict Semantics` section on `KmdbCollection`, applying equally to all write methods. `update()` comment updated to note single-device safety and point to that section. Applications needing field-level merge should use `MergeOperator` (§12).

2. ~~**Zstd package choice:**~~ ✅ **Resolved.** Use `zstandard` on all platforms: FFI (native) + WASM (web). Deflate (`0x02`) is web-only fallback for browsers without WASM. Spec updated.

3. ~~**`stream()` snapshot implementation:**~~ ✅ **Resolved.** `stream()` is implemented eagerly — same execution as `get()`, result emitted as `Stream<T>`. No LSM snapshot held, no ref-counting needed. Sufficient at target scale (≤100K docs). Spec updated. Lazy cursor with SSTable ref-counting deferred to roadmap if ever needed.

4. ~~**`keyPrefix` filter:**~~ ✅ **Resolved.** Unrelated to namespace — namespace is always the collection's fixed scope. `keyPrefix` filters on the document key (UUIDv7 hex string). Since UUIDv7 embeds a millisecond timestamp in its MSBs, a key prefix is a time-window query without a secondary index. Maps to `KvStore.scan(namespace, startKey: prefix, endKey: nextPrefix(prefix))` where `nextPrefix` increments the final hex character. Handled natively by the LSM range scan — no additional work required.
