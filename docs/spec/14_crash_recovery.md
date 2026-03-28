# Crash Recovery

## Recovery Sequence on Open

1. Acquire exclusive file lock on the database directory.

1. Detect and delete orphan files: SSTables on disk not referenced in the
   Manifest.

1. Read and replay the Manifest to reconstruct the current level structure.

1. If a WAL file exists, replay it from the last flush marker to recover
   uncommitted writes.

1. If the WAL is truncated (CRC failure mid-record), stop replay at the last
   valid record. Acknowledge data loss of at most one memtable window.

1. Resume normal operation.

| Crash Point            | State on Recovery                              | Data Loss           |
| :--------------------- | :--------------------------------------------- | :------------------ |
| During WAL append      | WAL truncated at last valid record.            | At most one write.  |
| During memtable flush  | WAL intact. Replay recovers all writes.        | None.               |
| During SSTable write   | Orphan SSTable detected and deleted.           | None (WAL replays). |
| During Manifest update | Old Manifest valid. Orphan SSTable deleted.    | None (WAL replays). |
| During compaction      | Input SSTables intact. Partial output deleted. | None.               |
| During sync upload     | Local state intact. Re-upload on next sync.    | None locally.       |
