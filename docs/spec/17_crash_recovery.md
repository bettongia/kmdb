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

5. Collect all `wal-*.log` files present, sort by sequence number. Skip any WAL
   file whose sequence number ≤ the highest `logNumber` recorded in the
   Manifest — those writes are already in an SSTable. Replay the remaining WAL
   files in sequence order from their last flush marker.

6. If any WAL file is truncated (checksum failure mid-record), stop replay at
   the last valid record. Acknowledge data loss of at most one 64KB memtable
   window.

7. Delete any WAL files confirmed safe (sequence ≤ highest Manifest
   `logNumber`) — they are no longer needed.

8. Set the dirty-open flag in `$meta`. This is written as part of the first
   `WriteBatch` on this session so that a crash before any write leaves the
   flag unset.

9. Resume normal operation. Return an `OpenResult` describing any recovery.

## Failure Scenarios

| Crash point | State on recovery | Data loss |
| :---------- | :---------------- | :-------- |
| During WAL append | WAL truncated at last valid record. Records before failure are replayed. | At most one write. |
| After WAL fsync, before memtable insert | WAL replay re-inserts the record. | None. |
| During memtable flush (SSTable write) | Partial SSTable not referenced in Manifest — treated as orphan and deleted. WAL replays the same writes. | None. |
| After SSTable fsync, before VersionEdit appended | Same as above — SSTable is an orphan; WAL re-replays. | None. |
| During VersionEdit append | Manifest replay stops at checksum failure. Previous VersionEdit is the current state. SSTable is an orphan and deleted. WAL re-replays. | None. |
| During compaction (output SSTable write) | Output SSTable not in Manifest — deleted as orphan. Input SSTables still valid and present. | None. |
| After compaction VersionEdit, before input SSTable deletion | Both old and new SSTables present. Manifest is the authority — old SSTables listed in `remove` entries are deleted on open. | None. |
| Process killed without clean close | Dirty-open flag in `$meta` set on next open. Reported in `OpenResult.hadUnclosedSession`. | None (WAL is durable). |
| During sync upload | Local state intact. SSTable is re-uploaded on next sync cycle. | None locally. |
