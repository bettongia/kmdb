# LSM in KMDB: A Developer's Primer

This document provides a foundational overview of the Log-Structured Merge-tree (LSM) architecture used in KMDB. If you are new to the codebase, read this first to understand how data flows from a `put()` call to an immutable file on disk.

## Why LSM?

The primary driver for using an LSM engine in KMDB is **multi-device sync via commodity cloud storage** (Google Drive, iCloud, etc.) without a central server.

Traditional databases like SQLite use B-trees, which perform in-place updates to a single large file. In a cloud-sync environment, two devices making independent updates to the same SQLite file will cause a "conflict copy" (e.g., `database (1).db`), with no automated way to merge them.

**LSM solves this using immutable files.** Once an SSTable (Sorted String Table) is written, it is never modified. Syncing becomes a simple matter of moving these immutable files between devices, which cloud storage handles safely and natively.

## The Life of a Write

KMDB uses a classic LSM write path, optimized for a single-isolate Dart environment.

1.  **WAL (Write-Ahead Log):** Every mutation is first appended to an active `.log` file. This ensures durability; if the app crashes, the log is replayed to restore the in-memory state.
2.  **Memtable:** The mutation is then inserted into an in-memory **Skip List**. This keeps the data sorted by key as it arrives.
3.  **Flush:** When the Memtable reaches **64KB**, it is "frozen" and written to disk as a new **SSTable** at **Level 0**. A new mutable Memtable is started for incoming writes.
4.  **Manifest:** The `MANIFEST` file (the database's "Source of Truth") is updated to include the new SSTable.

## The Life of a Read

Because data is spread across memory and multiple files, a `get()` operation follows a strict hierarchy:

1.  **Active Memtable:** Check the most recent (unsaved) writes.
2.  **Frozen Memtable:** Check data currently being written to disk.
3.  **L0 SSTables:** Check these in "newest-first" order. L0 files can have overlapping key ranges.
4.  **L1 & L2 SSTables:** Check these levels. Files in L1 and L2 are non-overlapping, meaning at most one file per level needs to be checked.

### Performance Optimizations
*   **Bloom Filters:** Every SSTable has a Bloom Filter. This is a compact bitset that allows the engine to skip reading a file if it *definitely* doesn't contain the requested key.
*   **Single-File Shortcut:** If the total database size is $\le$ 512KB, KMDB collapses everything into a single L2 file. This turns most reads into a single Bloom check and a single disk read.

## Multi-Device Sync: The Sync Folder

KMDB syncs by exchanging SSTables through a shared "Sync Folder" in the cloud.

### The Sync Folder Structure
```text
/sync/
  highwater/
    {deviceId}.hwm    # Sync progress for each device
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst  # Immutable data files
```

### How Syncing Works
1.  **Ownership:** Each device **only writes to its own files**. Device A never modifies a file created by Device B. This eliminates write conflicts at the file level.
2.  **Ingestion:** When Device A sees a new SSTable from Device B, it downloads it and places it into its local **Level 0**.
3.  **High-Water Marks:** Each device maintains a `.hwm` file to track the highest timestamp it has processed from its peers. This ensures it only downloads *new* data.

## The Clock Mechanism: HLC

KMDB uses **Hybrid Logical Clocks (HLC)** instead of simple counters or wall-clock time.

*   **Structure:** An HLC is a 64-bit value: `[Physical Timestamp (48 bits)] : [Logical Counter (16 bits)]`.
*   **Causality:** If Device A makes a write and then Device B reads it and makes its own write, Device B's write will have a higher HLC. The clock "ticks" forward with every write and "jumps" forward if it sees a timestamp from a peer that is newer than its local clock.
*   **Conflict Resolution:** In an LSM, conflicts are resolved during **merging**. If two devices updated the same key while offline, the entry with the **higher HLC wins**. If HLCs are identical (rare), the device with the lexicographically higher `deviceId` wins as a stable tiebreaker.

## The Query API: Developer Interface

While the LSM engine handles the bytes, developers interact with KMDB through the **Query Layer**. This layer provides a high-level, typed API for document storage and retrieval.

### Typed Collections
Data is organized into **Collections**. Each collection uses a `KmdbCodec` to translate between your Dart models and the database's internal format (CBOR).

```dart
final notes = db.collection(
  namespace: 'notes',
  codec: NoteCodec(),
);

// Basic CRUD
await notes.put(myNote);
final note = await notes.get('note-123');
await notes.delete('note-123');
```

### Composable Queries & Filter DSL
KMDB features a powerful **Filter DSL** that supports dot-notation for nested fields. Queries are lazy; no disk I/O occurs until you call a terminal method like `get()`, `stream()`, or `watch()`.

```dart
// Find all active projects in London
final query = notes.where(
  Filter.and([
    Field('status').equals('active'),
    Field('address.city').equals('London'),
  ])
).orderBy('createdAt', descending: true).limit(10);

final results = await query.get();
```

### Conflict Semantics: Last-Write-Wins (LWW)
Because KMDB is a distributed system, it's possible for two devices to update the same document while offline. 

*   **Resolution:** When the devices sync, KMDB uses **Last-Write-Wins**. The version with the higher HLC timestamp is kept, and the other is discarded.
*   **Granularity:** This happens at the **document level**. If Device A updates the `title` and Device B updates the `body` of the same document, one of those entire updates will be lost. 
*   **Merge Operators:** For fields that need smarter merging (like incrementing a counter), KMDB supports custom `MergeOperator` callbacks that run during compaction.

## Merging & Compaction

As SSTables accumulate, the background **Compaction** process merges them to keep the database performant.

1.  **N-Way Merge:** The engine reads multiple SSTables simultaneously using a `MergeIterator`. It yields entries sorted by `(userKey ASC, HLC DESC)`.
2.  **Deduplication:** For any given user key, only the entry with the highest HLC is kept; all older versions are discarded.
3.  **Tombstone Dropping:** Deletion markers (tombstones) are eventually removed during L2 compaction, but only once the engine confirms (via `.hwm` files) that every other device has seen the deletion.

## Crash Recovery: No Data Left Behind

KMDB is designed to recover gracefully from power loss or process crashes.

1.  **LOCK File:** Prevents two instances of the engine from opening the same database directory.
2.  **Manifest Replay:** On startup, the engine reads the `MANIFEST` to reconstruct the level structure. It identifies any "orphan" SSTables (files written to disk but not yet committed to the Manifest) and deletes them.
3.  **WAL Replay:** The engine identifies the highest sequence number in the Manifest and replays any WAL entries newer than that. This restores the Memtable to the exact state it was in before the crash.
4.  **Atomicity:** A write is considered "committed" once it is fsynced to the WAL. All subsequent steps (memtable insert, SSTable flush) are just optimizations to make reads faster.

## Navigating the Engine

If you are diving into the code, start here:

*   `lib/src/engine/kvstore/lsm_engine.dart`: The orchestrator for the entire flow.
*   `lib/src/engine/memtable/memtable.dart`: The in-memory buffer logic.
*   `lib/src/engine/sstable/sstable_writer.dart`: How we build the immutable files.
*   `lib/src/engine/compaction/compaction_job.dart`: The logic for merging and de-duplicating data.
*   `lib/src/engine/kvstore/crash_recovery.dart`: The startup recovery sequence.

## Key Terms

| Term | Definition |
| :--- | :--- |
| **WAL** | Write-Ahead Log. A sequential file used for crash recovery. |
| **Memtable** | The in-memory "Sorted String Table" buffer (a Skip List). |
| **SSTable** | Sorted String Table. An immutable file containing sorted keys and values. |
| **Manifest** | A log of all live SSTables and their levels; the DB's index. |
| **Tombstone** | A special marker indicating a key has been deleted. |
| **Bloom Filter** | A probabilistic data structure used to avoid unnecessary disk reads. |
| **HLC** | Hybrid Logical Clock. Used to order events across distributed devices. |
| **Compaction** | The process of merging multiple SSTables to reclaim space and improve read speed. |
