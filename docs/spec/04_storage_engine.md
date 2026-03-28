# Storage Engine (LSM)

## Write Path

1. Client calls Put(namespace, key, value) or Delete(namespace, key).

1. The HLC clock advances and produces a sequence number.

1. The operation is appended to the WAL with CRC-guarded framing.

1. The operation is inserted into the active memtable (skip list).

1. When the memtable reaches the flush threshold, it is frozen and a new active
   memtable is created.

1. The frozen memtable is flushed to a new L0 SSTable. The WAL is rotated.

1. If L0 file count exceeds the trigger threshold, synchronous compaction merges
   L0 into L1.

All operations are synchronous on the calling isolate. At the target scale
(10–20K typical documents), flush and compaction complete in single-digit
milliseconds. At the upper bound (500K documents), compaction of large levels
should be moved to a background isolate to avoid UI jank (see
[Concurrency & Performance](#concurrency-performance)).

## Read Path

1. Check the active memtable (in-memory, O(log n) skip list lookup).

1. If a flush is in progress, check the immutable memtable snapshot.

1. Check L0 SSTables newest-first. Each check: Bloom/Xor filter query → if
   positive, binary search.

1. Check L1 and L2 SSTables using range metadata to identify candidates.

Point lookups are dominated by the filter check. At the target scale, Bloom
filters with 10 bits/key give a 0.8% false positive rate, meaning fewer than 1
in 100 point lookups requires an unnecessary file read.

## LSM Tier Constants

The following constants are derived from the
[workload profile](#target-workload-profile). They replace the original
small-scale constants.

| Parameter                | Value                         | Derivation                                                                                                  |
| :----------------------- | :---------------------------- | :---------------------------------------------------------------------------------------------------------- |
| Memtable flush threshold | 256 KB                        | Approx. 128 docs at 2KB avg. Triggers flush roughly every 10–15 seconds at typical write rates.             |
| L0 file count trigger    | 4 files                       | At 256KB each \= 1MB total L0 before compaction. Balances write stall avoidance against read amplification. |
| L1 max size              | 10 MB                         | \~10x L0 total. Covers 5K–10K documents comfortably.                                                        |
| L2 max size              | 100 MB                        | \~10x L1. Covers up to 100K documents.                                                                      |
| L3 max size              | 1 GB                          | \~10x L2. Covers full upper bound of 500K documents.                                                        |
| Size ratio               | 10                            | Standard LevelDB/RocksDB ratio. Bounds read amplification at O(levels).                                     |
| Bloom filter bits/key    | 10                            | 0.8% FPR. At 500K keys: \~625KB total filter memory.                                                        |
| Max SSTable file size    | 2 MB (L1), doubling per level | Bounds individual compaction I/O and sync upload size.                                                      |
| Single-file shortcut     | Removed                       | No longer applicable at \>10K documents. Was 512KB threshold.                                               |

## Compaction At Scale

At the upper bound (500K documents, ~500MB), L2→L3 compaction may read and write
100MB+ of data. This must not happen synchronously on the UI isolate. Section
13.2 specifies the background isolate strategy.
