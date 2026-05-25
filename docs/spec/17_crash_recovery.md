# Crash Recovery

## Recovery Sequence on Open

1. Acquire exclusive file lock (`LOCK` file) on the database directory.

2. Read `CURRENT` to identify the active Manifest file.

3. Replay the Manifest forward record by record (stopping at the first XXH64
   checksum failure) to reconstruct the current level structure, the highest
   flushed WAL sequence number, and the next HLC sequence number.

4. Detect and delete orphan files: any `.sst` file in `sst/` not referenced by
   a live `add` entry in the replayed Manifest is an orphan (produced by a flush
   or compaction that crashed before its VersionEdit was appended). Orphans are
   deleted before WAL replay begins.

5. Collect all `wal-*.log` files present and sort by sequence number. Delete any
   WAL file whose sequence number is **strictly less than** the highest
   `logNumber` recorded in the Manifest — those writes are already durable in an
   SSTable. WAL files whose sequence number is **≥ `logNumber`** are retained for
   replay. Note that the *active* WAL's own sequence number equals `logNumber`
   (every `VersionEdit` records `logNumber = activeSequence`), so the comparison
   must be `<`, not `≤`; using `≤` would delete the active WAL and silently
   discard every write made since the last edit.

6. Replay every retained WAL file (sequence ≥ `logNumber`) **in full**, in
   sequence order. Full replay re-applies records that may already be in an
   SSTable, which is idempotent under HLC last-write-wins. It deliberately does
   **not** skip to a flush boundary marker: a marker fsync'd before its SSTable
   became durable would otherwise cause still-live records to be skipped. If a
   retained WAL is truncated (checksum failure mid-record), stop replay of that
   file at the last valid record and set `OpenResult.hadInterruptedWrites`;
   acknowledge data loss of at most the final in-flight write. Legacy flush
   markers written by older builds remain decodable and are skipped as no-ops.

7. Retained WAL files are **not** deleted during open. They are reclaimed at the
   next flush, once their data is written to an SSTable and the new boundary is
   recorded in the Manifest. (Backfilling a recovery checkpoint to reclaim them
   immediately is a possible future optimisation; it is intentionally omitted so
   that read-only opens perform no writes.)

8. Set the dirty-open flag in `$meta`. This is written as part of the first
   `WriteBatch` on this session so that a crash before any write leaves the
   flag unset.

9. Run vault crash recovery (if the vault directory exists):
   a. **Staging sweep:** delete all files and directories under
      `vault/staging/`. The LOCK file guarantees no other process is
      mid-write, so these are unconditionally incomplete and safe to delete.
   b. **Hash directory sweep:** for each hash directory under
      `vault/blobs/sha256/`: delete if it contains a blob but no
      `manifest.json` (incomplete write), or a `manifest.json` with no
      corresponding KV reference in `$vault` (orphaned vault object).
   See §24 for the full vault recovery sequence and crash table.

10. Resume normal operation. Return an `OpenResult` describing any recovery.

## Failure Scenarios

| Crash point | State on recovery | Data loss |
| :---------- | :---------------- | :-------- |
| During WAL append | WAL truncated at last valid record. Records before failure are replayed. | At most one write. |
| After WAL fsync, before memtable insert | WAL replay re-inserts the record. | None. |
| During memtable flush (SSTable write) | Partial SSTable not referenced in Manifest — treated as orphan and deleted. The retired WAL (sequence ≥ `logNumber`) is replayed in full. | None. |
| After SSTable fsync, before VersionEdit appended | SSTable is an orphan and deleted; `logNumber` is unchanged, so the retired WAL is still ≥ `logNumber` and is replayed in full. | None. |
| During VersionEdit append | Manifest replay stops at checksum failure. The previous VersionEdit is the current state; the new SSTable is an orphan and deleted; the WAL is replayed in full. | None. |
| During compaction (output SSTable write) | Output SSTable not in Manifest — deleted as orphan. Input SSTables still valid and present. | None. |
| After compaction VersionEdit, before input SSTable deletion | Both old and new SSTables present. Manifest is the authority — old SSTables listed in `remove` entries are deleted on open. | None **if the VersionEdit is durable** — see the manifest-durability caveat below. |
| Process killed without clean close | Dirty-open flag in `$meta` set on next open. Reported in `OpenResult.hadUnclosedSession`. Writes since the last flush are replayed from the WAL. | None (WAL is durable). |
| During sync upload | Local state intact. SSTable is re-uploaded on next sync cycle. | None locally. |

> **Manifest-durability caveat (separate work item C2).** The "None" guarantees
> above assume that a `VersionEdit` is durable on disk before any file it
> supersedes is deleted. Today `ManifestWriter.append` does not fsync, and flush
> and compaction delete the retired WAL / input SSTables immediately after
> appending. If a crash loses the un-fsynced `VersionEdit` *after* those source
> files were deleted, the new SSTable is orphaned (and removed on open) while its
> sources are already gone — losing that flush's or compaction's data. Closing
> this window requires fsyncing the Manifest (and `syncDir`) before deleting any
> source file, and is tracked as finding **C2 (manifest fsync & durability
> ordering)**. The WAL-replay correctness described in this section is
> independent of C2 and holds whenever the Manifest is durable.
