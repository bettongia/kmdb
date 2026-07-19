# SSTable Format

SSTables are immutable files containing sorted key-value entries with
prefix-compressed keys, a Bloom/Xor filter block, and a footer for metadata.
Once written, an SSTable is never modified — this immutability is the foundation
of both crash safety and sync safety.

## File Structure

| Block        | Description                                                                                  |
| :----------- | :------------------------------------------------------------------------------------------- |
| Data blocks  | Sorted key-value entries with prefix compression and restart points. Block size: 4KB.        |
| Filter block | Bloom filter (current) or Xor filter (planned migration) for all keys in the file.           |
| Index block  | One entry per data block: (last key, block offset, block size).                              |
| Footer (48B) | Filter block offset/size, index block offset/size, entry count, XXH64 checksum. Note: min/max key are **not** stored in the footer — `maxKey` is available as `index.last.lastKey` (the last key of the last data block), and `minKey` requires reading the first data block's first entry. Both are recorded in the Manifest's `SstableMeta` for each file (see §10). |

## Untrusted-Input Validation (S-1, S-2)

The SSTable is the **only** on-disk format that crosses a trust boundary — it
is written locally, but also ingested from peers via sync. The footer's XXH64
checksum defends against accidental corruption, but it is **not
cryptographic**: a party who controls a file's body (an untrusted cloud
provider, or a malicious peer under the T1/T3 threat model — see §31) can
simply recompute the checksum after tampering with any field, so a
checksum-valid file carries no guarantee of authenticity. `SstableReader`
therefore validates every length and offset field against the actual buffer
before it is used to allocate or slice, rather than trusting the format to be
well-formed:

- **Footer fields** (`filterOffset`, `filterSize`, `indexOffset`, `indexSize`)
  must each be non-negative, and `offset + size` must not exceed the file's
  actual size. Violations reject the file with `CorruptedSstableException`
  before either field is used to seek or allocate.
- **Index entries**: each entry's `keyLen` (a varint) is bounds-checked
  against the remaining index-block bytes before it sizes a slice.
- **Data block entries**: `shared` (the shared-key-prefix length) is
  bounds-checked against the length of the key reconstructed so far — a data
  block's very first entry is always a restart point with `shared = 0`, so any
  non-zero value there is immediately invalid. `unsharedLen` and `valueLen`
  are bounds-checked against the remaining block bytes. All three checks run
  **before** the entry's key/value reconstruction allocates a buffer.
- **Varint decoding**: a 64-bit varint whose tenth (final) byte would set bit
  63 is rejected outright (`FormatException`) rather than silently decoding to
  a negative `int` — every caller treats a decoded varint as a length or
  offset, and a negative one is never valid.
- **Range reads**: `StorageAdapterNative.readFileRange` bounds every requested
  `[offset, offset + length)` range against the file's real size *before*
  allocating the destination buffer, so an attacker-declared length read from
  an untrusted footer/index field cannot reach `malloc` unbounded.

Any structural failure surfaces uniformly as `CorruptedSstableException` — the
one type every ingest call site (`SyncEngine.pull`, `LsmEngine.ingestAt0`,
`ConsolidationCoordinator.consolidate`) treats as "reject this file."
`SstableReader.open` and `_readBlock` (the `get`/`scan`/`firstKey` path)
achieve this by catching every other structural-failure type that validation
can still let through — `RangeError`, `FormatException` (varint overflow), and
`StorageException` (an out-of-file-bounds `readFileRange`, e.g. an index
entry's `blockOffset`/`blockSize` that individually pass validation but
together exceed the file) — and rethrowing each as
`CorruptedSstableException`. This closes a confirmed gap: an earlier version
of this hardening converted only `RangeError`, leaving `FormatException` and
`StorageException` free to escape uncaught through
`ConsolidationCoordinator.consolidate` specifically, since it is the one call
site that does not separately catch either type. A rejected peer file's
high-water mark still advances past it (`SyncEngine.pull`) so it is
quarantined rather than re-downloaded and re-rejected on every subsequent sync
cycle.

**Decompressed-value size bound.** Independently of SSTable-level validation,
a value's *decoded* size — after decompression, before CBOR-decode — is
bounded by `ValueCodec.kMaxDecodedValueBytes` (1 MiB; see §5 and §18). This
guards against a Zstd decompression bomb sitting inert inside an otherwise
well-formed SSTable: neither `LsmEngine.ingestAt0` nor `CompactionJob` ever
decode values (both touch only keys), so the bomb cannot detonate on ingest or
compaction — only a `get`, `scan`, or full-collection operation (`dump`,
`export`, `verify`) that actually decodes the value can trigger it, and those
call sites treat a single oversized/corrupt value as a per-document failure
rather than aborting the whole operation.

## SSTable Naming Convention

SSTable filenames encode origin device, HLC range, and — for consolidation
output — the coordinator epoch. There are three distinct formats:

### Regular flush output — syncable (3 segments, `.sst`)

Produced by a local memtable flush when the flush contains at least one entry
from a syncable (non-`$$`-prefixed) namespace. Downloaded peer SSTables also
use this format:

```
{deviceId}-{minHlc}-{maxHlc}.sst
```

### Regular flush output — local-only (3 segments, `.local.sst`)

Produced by a local memtable flush when the flush contains at least one entry
from a local-only (`$$`-prefixed) namespace. These files are **never uploaded
to the sync folder**; `SyncEngine.push` identifies them by parsing the filename
suffix before building the upload list. A single flush may produce both a
`.sst` and a `.local.sst` file when the memtable contains entries from both
syncable and local-only namespaces (see §6 flush partitioning):

```
{deviceId}-{minHlc}-{maxHlc}.local.sst
```

The `.local` infix is parsed **before** splitting on `-`, because the HLC
segments and the deviceId also contain no `.` characters and splitting first
would leave `.local` as a stray segment.

### Consolidation output (4 segments, `.sst`)

Produced by the cross-device compaction coordinator. Consolidation output is
**always syncable** — local-only SSTables are never uploaded and therefore
never consolidated. The epoch is the coordinator's current epoch from the
fencing token, enabling stale partial output to be identified and deleted
without opening any file:

```
{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst
```

### Field encoding

| Field      | Encoding                                      | Width    |
| :--------- | :-------------------------------------------- | :------- |
| `deviceId` | Truncated UUID hex (no hyphens)               | 8 chars  |
| `epoch`    | Decimal integer, no padding                   | Variable |
| `minHlc`   | Regular flush: full 64-bit HLC (physical + logical), uppercase hex | 16 chars |
| `maxHlc`   | Regular flush: full 64-bit HLC (physical + logical), uppercase hex | 16 chars |
| `minHlc`   | Consolidation: 48-bit physical component only, uppercase hex | 12 chars |
| `maxHlc`   | Consolidation: 48-bit physical component only, uppercase hex | 12 chars |

Regular flush files embed the full 64-bit HLC (including the 16-bit logical
counter) to guarantee unique filenames even when multiple flushes occur within
the same physical millisecond. Consolidation files use the 48-bit physical
component only, since cross-device ordering relies solely on wall-clock time.

No field contains a `-` or `.`, so splitting on `-` and counting segments is
unambiguous once the extension (`.sst` or `.local.sst`) has been stripped.

### Examples

```
a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst         ← regular flush (syncable)
a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.local.sst   ← regular flush (local-only)
f9e8d7c6-017F8B0C00000000-017F8B0C3FFF0000.sst         ← regular flush (syncable)
a3f2b1c9-7-017F8A090000-017F8A0AFFFF.sst               ← consolidation, epoch 7
```

The device ID is a stable per-installation UUID generated on first launch and
persisted in platform-specific secure storage (Keychain on iOS,
SharedPreferences on Android, localStorage on web). It must not be stored inside
the database itself to avoid circular dependency during bootstrap.

### Stale consolidation output detection

A recovering coordinator scans the sync folder for 4-segment files. Any such
file whose epoch does not match the current fencing token for that `deviceId`
is stale output from a crashed coordinator and must be deleted before a new
consolidation begins. See §12 for the full recovery procedure.

## Table Cache (M1)

### Why open is expensive

The footer carries a single `checksum` field that is the XXH64 hash of **the
entire file** (bytes `0` to `fileSize - 8`). Validating it on every
`SstableReader.open()` call means reading and hashing up to ~20 MB for an L2
file — making every read O(database size) rather than O(block).

### TableCache design

`TableCache` (`lib/src/engine/sstable/table_cache.dart`) is an LRU cache of
open `SstableReader` instances keyed by absolute file path. It is owned by
`LsmEngine` and makes the whole-file validation a **one-time cost per file
per process**:

- **First open:** reads and validates the whole-file checksum, loads the footer,
  index block, and Bloom filter into memory. The resulting reader is stored in
  the cache.
- **Subsequent opens:** the cached reader is returned immediately — no file I/O,
  no hashing.
- **Data-block reads** still hit disk on every access (each block carries its
  own trailing XXH64 checksum validated on each read). A hot data-block cache
  is a possible future optimisation but is out of scope.

### Integrity model

Caching does not weaken integrity:

- The **whole-file checksum** is validated exactly once per file per process
  (on first open). After that the reader is trusted.
- Each **data block** is individually checksummed and validated on every read
  regardless of caching.
- The **footer, index, and filter blocks** are covered only by the whole-file
  checksum. If a cheaper footer-only open is ever added it would require
  per-section checksums (format change — deferred to a future phase).

### Capacity and defaults

The cache is LRU-evicting and bounded by `KvStoreConfig.tableCacheSize`:

| Platform | Default |
| :------- | :------ |
| Desktop / server | 256 readers |
| Mobile / embedded | 64 readers (set `tableCacheSize: 64` in config) |

Each entry holds approximately 2–5 KiB of in-memory state (footer 48B + Bloom
filter ~1 KB + index ~few hundred bytes per file). At the desktop default of 256
entries the total overhead is ~0.5–1.3 MiB.

### Invalidation

Cached readers are evicted whenever the underlying file is removed or renamed:

| Engine event | Eviction action |
| :----------- | :-------------- |
| Flush (new L0 file) | No eviction needed — new path never in cache |
| Compaction removes an input file | `evict(path)` before `deleteFile` |
| `dropAllSstables` | `clear()` entire cache |
| `reassignDeviceId` (file rename) | `evict(old-path)` before `renameFile` |
| `close` | `clear()` entire cache |

Because all operations run on a single isolate, no locking is required.

### Relationship with the §15 Cache Layer

The `TableCache` is a **storage-layer** cache (parsed footer + index + Bloom
filter). It is distinct from and complementary to the §15 query-layer object
cache (`SessionCache`). They live at different layers and serve different
purposes.

## Value-Level Compression

| Flag | Algorithm | Platform | Notes                                        |
| :--- | :-------- | :------- | :------------------------------------------- |
| 0x00 | None      | All      | When value is small or already compressed.   |
| 0x01 | Zstd      | All      | Level 3. Via `betto_zstd` (FFI on native; WASM on web). |

Both native and web platforms write Zstd (`0x01`) for compressible documents.
Deflate (`0x02`) was removed as a pre-release clean break —
`CompressionFlag.fromByte` rejects `0x02` with `ArgumentError`. See §5 for the
full encoding pipeline.

## Recommendations

### Zstd Dictionary Compression

Without a dictionary, Zstd achieves only 10–30% reduction on individual 1–10KB
JSON documents. With a trained dictionary, compression improves to 70–90%
reduction, and decompression runs 2–2.4x faster due to pre-seeded FSE tables.
Strategy: compress without dictionary initially, train a dictionary after
accumulating \~100 documents per namespace, recompress during idle. Store the
64–100KB dictionary alongside namespace metadata.
