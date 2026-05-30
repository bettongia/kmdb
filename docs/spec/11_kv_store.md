# KvStore Interface

## Purpose

`KvStore` is the public API of the LSM storage engine. It is the boundary
between the storage layer and the Cache/Query layers — neither the Cache Layer
nor the Query Layer touches the LSM internals directly. See §3 (Architecture
Overview) for the full layer stack.

## Design Principles

**Untyped values.** `KvStore` operates on raw bytes (`Uint8List`). Document
encoding (CBOR + compression) is the responsibility of the Query Layer (§5).

**String keys at the boundary.** Keys are UUIDv7 values. `KvStore` accepts and
returns them as hex strings (the form produced by `KmdbCodec.keyOf()`).
Internally they are stored as 16-byte binary for index locality. The `KvStore`
implementation converts at the boundary.

**Namespace scoping.** Every operation is scoped to a namespace. The namespace
is prepended to the binary key in the SSTable, so entries from different
namespaces interleave in key order within a file. Scan always filters to a
single namespace.

**Namespace encoding.** Namespaces are stored as UTF-8 bytes (not UTF-16 code
units). `KvStoreImpl` NFC-normalises every user-supplied namespace string at
the public boundary before any storage operation, so callers supplying the same
logical name in different Unicode normalisation forms (NFC vs NFD) always access
the same namespace. Namespaces are limited to 255 UTF-8 bytes; exceeding this
limit throws a descriptive `ArgumentError`. See §4 (Keys) for the full
encoding spec.

**`orderBy` is not a KvStore concern.** Field-level ordering is applied in the
Query Layer after scan. The one exception is key-order (`orderBy('id')`) —
`scan` supports ascending and descending key traversal natively without an
in-memory sort.

## Interface

```dart
abstract interface class KvStore {

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Open the database at [path]. Acquires an exclusive file lock.
  /// Runs crash recovery (orphan sweep, Manifest replay, WAL replay).
  /// Returns an [OpenResult] describing any recovery that occurred.
  static Future<KvStore> open(String path, [KvStoreConfig config]);

  /// Release the exclusive lock and close all file handles.
  Future<void> close();

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Write a single value. Creates or overwrites.
  Future<void> put(String namespace, String key, Uint8List value);

  /// Write a Delete tombstone. No-op if the key does not exist.
  Future<void> delete(String namespace, String key);

  /// Apply multiple writes as a single atomic WAL append.
  /// All writes land in the same memtable batch. [writeEvents] fires once
  /// for the batch regardless of batch size.
  Future<void> writeBatch(WriteBatch batch);

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// Point lookup. Returns null if the key does not exist or is deleted.
  Future<Uint8List?> get(String namespace, String key);

  /// Iterate all live entries in [namespace] in key order. Tombstones are
  /// never emitted.
  ///
  /// [startKey] is inclusive. [endKey] is exclusive.
  /// When [descending] is true, traversal order is reversed: [startKey]
  /// becomes the upper bound (inclusive) and [endKey] the lower bound
  /// (exclusive). The LSM read path implements this natively without
  /// materialising results in memory.
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
    bool descending = false,
  });

  // ── Engine Control ─────────────────────────────────────────────────────────

  /// Flush the active memtable to a new L0 SSTable immediately, even if the
  /// flush threshold has not been reached. Useful before a sync push to
  /// minimise the number of files that need uploading.
  Future<void> flush();

  /// Force compaction of all levels down to a single L2 SSTable.
  /// Blocks until complete. Equivalent to the single-file shortcut triggered
  /// manually — useful before a sync push or for testing.
  Future<void> compactAll();

  // ── Device Identity ────────────────────────────────────────────────────────

  /// Assigns a new device identity to this store.
  ///
  /// Renames every SSTable whose filename starts with the current device ID to
  /// use [newDeviceId], appends a VersionEdit to the Manifest, then persists
  /// the new ID to `$meta`. Peer-owned SSTables are not renamed.
  ///
  /// [newDeviceId] must be an 8-character lowercase hex string and must differ
  /// from the current device ID. Throws [ArgumentError] otherwise.
  ///
  /// Call this after copying a database directory to give the copy a unique
  /// identity before its first sync. See §4 (Keys & Identifiers) for details.
  Future<void> reassignDeviceId(String newDeviceId);

  // ── Reactivity ─────────────────────────────────────────────────────────────

  /// Emits the namespace name after each successful write to that namespace.
  /// Fires once per [writeBatch] call regardless of batch size.
  /// The Cache Layer and Query Layer subscribe to this stream to trigger
  /// debounced watcher re-execution and cache invalidation (see §14, §15).
  Stream<String> get writeEvents;
}

/// A raw key-value entry returned by [KvStore.scan].
typedef KvEntry = ({String key, Uint8List value});
```

## WriteBatch

`WriteBatch` is a mutable builder, not a sealed type. The Query Layer constructs
batches incrementally during write interception (§16) before committing.

```dart
final class WriteBatch {
  void put(String namespace, String key, Uint8List value);
  void delete(String namespace, String key);
  void clear();

  bool get isEmpty;
  int  get length;
}

// WriteBatch is encoded as WAL record type 0x04.
// The batch is atomic: a crash before the WAL fsync leaves no partial state.
// A crash after the WAL fsync but before the memtable update replays the
// full batch on next open.
```

## OpenResult

`KvStore.open()` returns an `OpenResult` describing any recovery that occurred.
The Query Layer inspects this to determine whether index rebuilds are needed.

```dart
final class OpenResult {
  /// True if WAL replay discarded one or more records (checksum failure).
  /// At most one memtable window of data may have been lost.
  final bool hadInterruptedWrites;

  /// Namespaces affected by interrupted writes. The Query Layer should check
  /// whether indexes for these namespaces are stale and trigger a rebuild.
  final List<String> affectedNamespaces;

  /// True if the dirty-open flag in $meta was set, indicating the process
  /// was killed without a clean close. Broader than WAL checksum failures —
  /// any unclean shutdown sets this flag.
  final bool hadUnclosedSession;
}
```

## System Namespaces

Any namespace beginning with `$` is reserved for engine and infrastructure use.
User code cannot write to system namespaces directly.

| Namespace              | Owner              | Purpose |
| :--------------------- | :----------------- | :------ |
| `$meta`                | KvStore / QueryLayer | Per-namespace generation counters (`gen:{ns}`), index definitions, device ID, last sync timestamps, dirty-open flag. |
| `$index:{ns}:{path}`   | Query Layer        | Secondary index entries for namespace `{ns}` on dot-path `{path}`. Keys encode the indexed value + document key. |
| `$cache:{ns}:{query}`  | Cache Layer        | Materialised scan results. Entries include the generation counter at compute time for staleness detection. |
| `$vault:{sha256}`      | Vault subsystem    | Reference count for the vault object identified by `{sha256}`. Incremented/decremented in the same `WriteBatch` as the document write. Zero-valued entries are GC candidates. See §24. |

## KvStoreConfig

```dart
final class KvStoreConfig {
  // Memtable
  final int memtableSizeBytes;        // default: 65536  (64KB)

  // Level sizes
  final int l0CompactionTrigger;      // default: 2      (file count)
  final int l1MaxBytes;               // default: 2097152   (2MB)
  final int l2MaxBytes;               // default: 20971520  (20MB); increase to
                                      //   ~100MB for deployments near 100K docs

  // Single-file shortcut
  final int singleFileThresholdBytes; // default: 524288 (512KB)

  // SSTable blocks
  final int blockSizeBytes;           // default: 4096   (4KB)
  final int blockRestartInterval;     // default: 16

  // Bloom filter
  final int bloomBitsPerKey;          // default: 10     (~0.8% FPR)

  // Table cache — see §8 (M1)
  final int tableCacheSize;           // default: 256 desktop, 64 mobile/web
                                      // Maximum open SstableReader instances
                                      // held in the LRU table cache. Each
                                      // entry ≈ 2–5 KiB (footer + index +
                                      // Bloom filter).

  // Cache — see §15
  final int sessionCacheMaxObjects;   // default: 2000 desktop, 256 mobile/web
  final CacheTier cacheTier;          // default: auto-detected from platform

  // WAL
  final bool fsyncOnWrite;            // default: true   (false in tests only)

  // Watch debounce
  final Duration watchDebounce;       // default: 50ms

  // Sync
  final Duration maxClockSkew;        // default: 60s

  // Value size guard
  final int maxValueBytes;            // default: 1048576 (1 MiB)
                                      // Set to maxValueBytesUnlimited (-1) to
                                      // disable. Checked at put()/writeBatch()
                                      // before any I/O. Large payloads should
                                      // use the vault facility instead.
  static const int maxValueBytesUnlimited = -1;

  /// Tiny thresholds, no fsync — forces all code paths with a handful of writes.
  factory KvStoreConfig.forTesting();
}
```

## How the Query Layer Uses KvStore

| `KmdbCollection<T>` operation | KvStore calls |
| :---------------------------- | :------------ |
| `get(key)` | `get(ns, key)` → decompress → CBOR decode |
| `put(value)` | CBOR encode → compress → `put(ns, key, bytes)` |
| `putMany(values)` | CBOR encode each → `writeBatch([put, put, ...])` |
| `delete(key)` | `delete(ns, key)` |
| `insert(value)` | `get(ns, key)` → throw if non-null → `put(...)` |
| `replace(value)` | `get(ns, key)` → throw if null → `put(...)` |
| `update(key, fn)` | `get(ns, key)` → decode → apply fn → encode → `put(...)` |
| `all().get()` | `scan(ns)` → decompress → decode → filter → sort → limit/offset |
| `all().count()` | `scan(ns)` → filter → count (decode avoided if filter is key-only) |
| `all().orderBy('id').get()` | `scan(ns, descending: false)` → decode → limit/offset |
| `all().orderBy('id', descending: true).get()` | `scan(ns, descending: true)` → decode → limit/offset |
| `watch()` / `query.watch()` | subscribe `writeEvents` → re-execute scan on namespace match |
