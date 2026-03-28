# Storage Engine (LSM)

## Write Path

1. Encode the mutation as a WAL record and append it to the active WAL file.
2. fsync the WAL file (and directory entry on Linux). Write is durable at this
   point.
3. Insert the key into the in-memory memtable (skip list).
4. If the memtable has reached the flush threshold (64KB): flush synchronously
   to a new L0 SSTable, update the Manifest, rotate the WAL, check the
   single-file shortcut, trigger L0 compaction if needed.
5. Return success to the caller.

All operations are synchronous on the calling isolate. At the target scale
(200–2,000 typical documents, up to 100,000 upper bound), flush and compaction
complete in single-digit milliseconds.

## Read Path

1. Check the active memtable (in-memory, O(log n) skip list lookup).
2. If a flush is in progress, check the immutable memtable snapshot.
3. Check L0 SSTables newest-first. Each check: Bloom filter query → if
   positive, binary search in index block → read data block.
4. Check L1 and L2 SSTables using range metadata to identify candidates.
   L1 and L2 have non-overlapping key ranges, so at most one file per level
   needs to be checked.

In single-file mode (see below), steps 3–4 collapse to a single Bloom check
and at most one file read — the dominant case for most users.

## LSM Tier Constants

| Parameter                | Value    | Derivation                                                                   |
| :----------------------- | :------- | :--------------------------------------------------------------------------- |
| Memtable flush threshold | 64 KB    | ~30 docs at 2KB avg. Keeps WAL replay bounded; no background scheduler needed. |
| L0 file count trigger    | 2 files  | 128KB total L0 before compaction. Compaction completes in < 50ms at this scale. |
| L1 max size              | 2 MB     | ~10x L0 total. Covers 1K–2K documents.                                       |
| L2 max size              | 20 MB    | ~10x L1. Covers up to ~20K documents. Tunable via `KvStoreConfig.l2MaxBytes`. |
| Size ratio               | 10       | Standard LevelDB ratio. Bounds read amplification at O(levels).              |
| Bloom filter bits/key    | 10       | 0.8% FPR. At 100K keys: ~125KB total filter memory.                          |
| Max SSTable file size    | 2 MB     | Bounds individual compaction I/O and sync upload size.                       |
| Block restart interval   | 16       | Every 16th key is a restart point for prefix-compressed key blocks.          |

For deployments approaching the 100K document upper bound, increase
`l2MaxBytes` to 100MB in `KvStoreConfig`.

## Single-File Shortcut

When total live bytes across all levels is 512KB or less, the engine collapses
the entire database into a single SSTable placed at L2. This is the dominant
state for the majority of users (< ~300 documents at 2KB avg):

- One Bloom filter check for any `get()`
- At most one file read for any `get()`
- Sequential read through one file for any `scan()`

The shortcut is evaluated after every flush and compaction and engages silently
— no API or behaviour change for the caller.

## Compaction

All compaction uses an N-way merge iterator that yields entries in
(user key ASC, sequence DESC) order. For each unique user key only the
highest-sequence entry is emitted; all older versions are dropped.

Delete tombstones are dropped at L2 when every known peer device has processed
past the tombstone's HLC timestamp (per the `.hwm` files — see §12). Until that
condition is met, tombstones are preserved across compaction.

Compaction fires synchronously on the write path:
- **L0→L1**: when L0 reaches 2 files
- **L1→L2**: when L1 total size exceeds 2MB
- **Single-file collapse**: when total live bytes falls to or below 512KB

At the target scale, L0→L1 compaction (merging two 64KB files) completes well
under 50ms on any device capable of running a Flutter application.
