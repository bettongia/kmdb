# Write-Ahead Log

## File Lifecycle

**WAL files are local to each device and are never written to or read from
shared cloud storage.** They exist solely as a crash-recovery mechanism for the
local storage engine. The sync layer operates exclusively on immutable SSTable
files — the WAL is an implementation detail that the sync layer never sees.

The WAL uses multiple sequentially-numbered files. A new WAL file is created
when the active memtable is frozen for flushing (at the 64KB threshold). The
old file is retained until the corresponding SSTable is confirmed durable on
disk (fsync'd and referenced in the Manifest), at which point it is deleted.

```
wal-00001.log   ← retired, safe to delete once L0 SSTable confirmed
wal-00002.log   ← active
```

### Naming Convention

```
wal-{sequence}.log
```

The sequence number is a zero-padded 5-digit decimal integer, monotonically
increasing. It is stored in the Manifest alongside the SSTable it corresponds to,
so recovery knows which WAL files are still needed.

### Rotation

1. The active memtable is frozen. A new active memtable is created.
2. A new WAL file `wal-{N+1}.log` is opened and becomes the active WAL.
3. The frozen memtable is flushed to an L0 SSTable.
4. The new SSTable is fsync'd and added to the Manifest (atomic write-then-rename).
5. `wal-{N}.log` is deleted — it is no longer needed for recovery.

If the process crashes between steps 3 and 5, `wal-{N}.log` still exists on
recovery. The recovery sequence replays it **in full**, which is safe because
re-applying records is idempotent under HLC last-write-wins. Replay is *not*
truncated at a flush boundary marker: a marker durably written before its
SSTable became durable would otherwise cause still-live records to be skipped
(see §17). Rotation therefore writes no boundary marker into the retiring file.

### Directory-entry durability

On a strict-POSIX filesystem, `fsync`ing a file's content does not persist its
parent directory's entry for that file — that requires a separate `fsync` of
the parent directory. `WalWriter.append` and `appendBatch` therefore also
`syncDir` the WAL directory (`db-dir`) the first time they write to a
newly-active file, once per file rather than once per write, so a fresh
`wal-{N}.log`'s directory entry is durable intrinsically rather than depending
on some other, unrelated code path happening to `syncDir(db-dir)` first (e.g.
the device-identity write at `open()`, Manifest rotation, or crash recovery —
which still `syncDir(db-dir)` for their own reasons, but WAL creation no
longer relies on them for this). The flush path's own `syncDir` remains
scoped to `sst/` only, since SSTable durability is a separate concern.

**Verified with fault injection** (`plan_0_09_walwriter_syncdir_durability.md`):
`packages/kmdb/test/engine/wal_test.dart`'s "directory-entry durability"
group uses `FaultyStorageAdapter` — which models file-content durability and
directory-entry durability as two independent dimensions, unlike
`MemoryStorageAdapter`, which cannot exercise this class of bug at all — to
confirm a freshly-rotated-to WAL file's first write survives a simulated
crash, and that reverting the fix makes that same test fail.

**Retired-WAL deletion has the mirror-image gap, left intentionally
untouched.** The flush path deletes the now-retired WAL file
(`LsmEngine`'s post-flush cleanup) without `syncDir`ing `db-dir` afterward, so
the *removal* of a WAL's directory entry is not intrinsically durable either.
This is confirmed benign, not merely assumed: the deletion loop only removes
WAL files with `seq < activeSequence`, and the "Multiple WAL Files on
Recovery" replay below already either re-deletes a resurrected retired file
(`seq < logNumber`) or idempotently replays it under HLC last-write-wins —
the same idempotent-replay property Rotation above relies on for the
no-boundary-marker design. A crash before that deletion's directory entry is
durable can only resurrect an already-retired WAL, never lose data. Revisit
only if WAL-file *absence* (not content) ever becomes load-bearing at
recovery time, which nothing does today.

### Multiple WAL Files on Recovery

On `open()`, recovery collects all `wal-*.log` files present, sorts them by
sequence number, deletes those with sequence `< logNumber` (already durable in
an SSTable), and replays each remaining file (sequence `≥ logNumber`) **in full**
in order. This handles the case where multiple flushes were in flight before a
crash. Sequence numbers in the WAL records maintain the correct causal order
across files via the HLC.

## WAL Record Format

| Field        | Size | Description                                                                  |
| :----------- | :--- | :--------------------------------------------------------------------------- |
| Checksum     | 8B   | XXH64 of all subsequent fields. Truncation detected by checksum failure.     |
| Record type  | 1B   | 0x01 \= Put, 0x02 \= Delete, 0x03 \= Flush marker (legacy; decoded but no longer written — see §17), 0x04 \= Batch frame (see below). |
| Sequence     | 8B   | HLC-encoded: upper 48 bits \= physical ms, lower 16 bits \= logical counter. |
| NS length    | 1B   | Namespace name byte length (max 255).                                        |
| Namespace    | NB   | UTF-8 namespace name.                                                        |
| Key length   | 2B   | Big-endian uint16.                                                           |
| Key          | KB   | Raw key bytes (UUIDv7, 16 bytes binary).                                     |
| Value length | 4B   | Big-endian uint32. Zero for Delete records.                                  |
| Value        | VB   | Compression-flag byte + compressed CBOR bytes. Absent for Delete. See §5.   |

XXH64 provides 64-bit output (collision probability \~1 in 10¹⁹) and runs faster
than CRC32 on ARM processors lacking CRC32C hardware acceleration. The
additional 4 bytes per record is negligible overhead for dramatically improved
integrity guarantees.

## Batch Frame Format (atomic `WriteBatch`)

Every `WriteBatch` — including the implicit one-entry batch produced by `put`
and `delete` — is serialised as a single **batch frame** under one checksum,
appended in one `appendFile` call, and fsynced once. This collapses an N-entry
batch from N WAL records and N fsyncs into a single record and a single fsync,
and is the basis for the **all-or-nothing** crash guarantee: a truncated or
corrupt frame fails its checksum and is dropped *whole* on recovery — the
database can never observe a partial batch.

| Field            | Size | Description                                                                              |
| :--------------- | :--- | :--------------------------------------------------------------------------------------- |
| Frame checksum   | 8B   | XXH64 of every byte that follows. A failure discards the entire frame on recovery.       |
| Frame type       | 1B   | `0x04` — batch.                                                                          |
| Entry count      | 4B   | Big-endian uint32; number of inner entries in this frame.                                |
| Entry …          | …    | Repeated `count` times. Each entry is encoded identically to the per-record layout above (`recType` 1B, `sequence` 8B, `nsLen`/`ns`, `keyLen`/`key`, `valLen`/`val`), but **without** its own checksum — the frame-level checksum covers all entries collectively. |

Only `Put` (0x01) and `Delete` (0x02) record types may appear inside a frame.
`Flush marker` (0x03) and `Batch` (0x04) record types are not permitted as inner
entries and are rejected by the decoder.

### Why a frame, not begin/commit markers

A single-checksum frame is the simplest representation that gives atomic
recovery: there is no buffered-but-uncommitted state to reason about, no
intermediate marker types, and the wire-level cost is one checksum and one
fsync regardless of batch size.

### Meta-write folding

The dirty-open flag, generation-counter bumps, and namespace-registry updates
that a user write triggers are folded into the **same** frame as the document
write. A single `KvStore.put`/`delete` therefore produces one atomic frame
containing the document and all of its metadata — a crash either leaves the
document with its bookkeeping intact, or leaves both absent.

### Back-compatibility

WAL files written by older builds contain individual `Put`/`Delete` records
rather than batch frames. Recovery dispatches on the type byte and accepts
both formats: legacy records apply as before; batch frames apply atomically.
A database that survives a build upgrade is replayed correctly without any
on-disk migration. Batches written by a pre-fix build are *not* retroactively
atomic; only batches written by the new build benefit from the all-or-nothing
guarantee.

## Sequence Number Layout (HLC)

Sequence number bit layout (64 bits total):

```
┌───────────────────────────────────┬──────────────────┐
│  Physical time (ms since epoch)   │  Logical counter │
│  Upper 48 bits                    │  Lower 16 bits   │
└───────────────────────────────────┴──────────────────┘
```

Higher sequence = newer write, regardless of device of origin. This is the sole
conflict resolution key for LWW semantics.

The HLC combines wall-clock time with a logical counter, preserving
human-readable timestamps while guaranteeing causal ordering across devices. The
maxOffset clamp (60 seconds) prevents a broken device clock from permanently
corrupting the clock state.
