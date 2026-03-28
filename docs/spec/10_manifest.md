# Manifest

## Purpose

The Manifest is the source of truth for the local database's level structure.
On every open, the storage engine replays the Manifest to reconstruct which
SSTables exist at which levels before replaying the WAL. During normal
operation a new record is appended after every flush and compaction.

## Locality

**The Manifest is local to each device and is never written to or read from
shared cloud storage (Tier 2).** It tracks the state of one device's local
database directory only. Each device maintains its own independent Manifest.
See §3 (Storage Tiers) for the full boundary between local and sync storage.

## Format — Append-Only VersionEdit Log

The Manifest is an append-only binary log of `VersionEdit` records, following
the same pattern as LevelDB's MANIFEST. This design survives partial writes
without any temp-file dance: a crash mid-append leaves a truncated record
detected by checksum failure; all records before it are valid and are replayed.

Each record:

```
┌──────────────┬─────────────┬────────────────────────────┐
│ Checksum 8B  │ Length  4B  │ CBOR-encoded VersionEdit   │
│ (XXH64)      │ (uint32 BE) │ (variable)                 │
└──────────────┴─────────────┴────────────────────────────┘
```

XXH64 is computed over `[Length bytes][CBOR bytes]`. A checksum failure on any
record terminates replay — all prior records constitute the current state.

## VersionEdit Schema

Each `VersionEdit` is a CBOR map describing one atomic file-set transition:

```jsonc
{
  "logNumber": 2,          // WAL sequence number active at this edit
  "nextSeq": 10042,        // next HLC sequence number (for recovery)
  "add": [                 // SSTables added in this transition
    {
      "level": 0,
      "filename": "a1b2c3d4-017F8A0B1C00-017F8A0B2FFF.sst",
      "minKey": "0191e4a0000000000000000000000001",
      "maxKey": "0191e4a0000000000000000000000080",
      "entryCount": 128,
      "walSequence": 2     // WAL file retired by this flush; null for compaction output
    }
  ],
  "remove": [              // SSTables removed in this transition
    {
      "level": 0,
      "filename": "a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst"
    }
  ]
}
```

| Field         | Type       | Description |
| :------------ | :--------- | :---------- |
| `logNumber`   | int        | The WAL file sequence number active when this edit was written. Used by recovery to identify which WAL files still need replay. |
| `nextSeq`     | int        | The next HLC sequence number at the time of this edit. Restored on recovery so the HLC clock starts above any previously-assigned sequence. |
| `add`         | array      | SSTables added. Each entry includes level, filename, key bounds, entry count, and the WAL sequence number retired (L0 flushes only; `null` for compaction output). |
| `remove`      | array      | SSTables removed (inputs to a compaction that has completed). |

`add` and `remove` may both be non-empty in the same record (a compaction that
produces new files and retires old ones is a single atomic edit).

## CURRENT File

The active Manifest file is identified by a `CURRENT` file in the database
directory containing only the filename of the active Manifest:

```
CURRENT          → contains "MANIFEST-00001\n"
MANIFEST-00001   → the append-only VersionEdit log
```

When the Manifest grows beyond a practical size (default: 1MB), the engine
writes a new Manifest file containing a single snapshot `VersionEdit` (all
currently live SSTables as `add` entries, no `remove` entries), then atomically
updates `CURRENT` to point to the new file, then deletes the old Manifest. This
keeps replay fast on open regardless of database age.

## Update Triggers

| Event | VersionEdit written |
| :---- | :------------------ |
| Memtable flush → L0 SSTable | `add` the new L0 file; `logNumber` = retired WAL sequence; `walSequence` in the add entry = retired WAL file. |
| L0 → L1 compaction | `remove` the L0 inputs; `add` the new L1 file. `walSequence` = null. |
| L1 → L2 compaction | Same pattern. |
| Single-file collapse | `remove` all existing files; `add` the single output file at L2. |
| Peer SSTable ingested | `add` the file at L0. `walSequence` = null (peer files have no relation to the local WAL). |

## Role in Crash Recovery

See §17 for the full recovery sequence. The Manifest's role:

- **Orphan detection:** Any `.sst` file in `{local-db-dir}/sst/` not referenced
  in any `add` entry (after removing all `remove` entries) is an orphan —
  produced by a flush or compaction that crashed before the VersionEdit was
  appended. Orphans are deleted before normal operation resumes.

- **WAL triage:** The highest `logNumber` across all replayed VersionEdits
  identifies which WAL files have been fully persisted. WAL files with sequence
  numbers ≤ this value are safe to delete. WAL files above it are replayed.

- **Level reconstruction:** Replaying all VersionEdits in order reconstructs the
  full `levels` map (L0 array + L1/L2 sorted by key range) in memory.

- **HLC recovery:** The highest `nextSeq` across all records is loaded into the
  HLC clock so it resumes above any previously-assigned sequence number.
