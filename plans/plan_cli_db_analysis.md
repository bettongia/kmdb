# Database analysis utility in the CLI

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

It can be useful to analyse key files in the database directory, including the
SSTable files, the MANIFEST file and WAL logs. Creating a `util` command in the
CLI that lets the user point at one of those files and get a human-readable
output can help with debugging issues.

This may create very large outputs so consider providing a `--summary` flag that
provides key metadata but only the count of records in files such as the WAL and
the SSTables.

Example CLI calls include:

```bash
# Display the details of an SSTable given by the filename (not the path)
kmdb mydb util sstable <file>

# Display the details of a WAL given by the filename (not the path)
kmdb mydb util wal <file>

# The MANIFEST file doesn't need to be provided as there should only be one
kmdb mydb util manifest
```

This is a READ ONLY facility.

## Open questions

- None at this stage.

## Investigation

### SSTables

- `SstableReader` already handles footer parsing, index loading, and Bloom
  filter loading.
- I need to expose `SstableFooter`, `BloomFilter`, and the index `_BlockRef`
  list to allow the `util` command to inspect them.
- A `scanBlocks()` method or similar would be useful for iterating over the data
  blocks without fully decoding every KV pair if only a summary is needed.

### WAL

- `WalReader` and `WalRecord` provide the necessary decoding logic.
- I'll need to add `toMap()` or similar serialization to `WalRecord` and
  `WalRecordType` to support the CLI's JSON/Table output modes.
- `replayStrict` should be used to ensure we catch any corruption.

### Manifest

- `ManifestReader` replays `VersionEdit`s into a `ManifestState`.
- I should expose the sequence of `VersionEdit`s to show the history of the
  database state.
- `VersionEdit` and `SstableMeta` also need `toMap()` methods.

### CLI Integration

- A new `UtilCommand` will act as a parent for `sstable`, `wal`, and `manifest`
  subcommands.
- It will use `store.stats().dbDir` to resolve relative filenames to absolute
  paths.
- It will respect the global `--mode` flag for output formatting.

## Implementation plan

### Engine Changes (`packages/kmdb`)

- [ ] **SSTable Analysis Support**:
  - Update `SstableReader` to expose `SstableFooter footer`,
    `BloomFilter filter`, and `List<_BlockRef> index` via public getters.
  - Add `toMap()` to `SstableFooter` to facilitate JSON output.
- [ ] **WAL Analysis Support**:
  - Add `toMap()` to `WalRecord` and `WalRecordType`.
- [ ] **Manifest Analysis Support**:
  - Add `toMap()` to `VersionEdit` and `SstableMeta`.
  - Update `ManifestReader` or `ManifestState` to retain the list of replayed
    edits for inspection.

### CLI Changes (`packages/kmdb_cli`)

- [ ] **Implement `UtilCommand`**:
  - Create `lib/src/commands/util_command.dart`.
  - Support subcommands: `sstable`, `wal`, `manifest`.
  - Add a `--summary` flag to provide high-level metadata only.
- [ ] **`util sstable <filename>`**:
  - Resolve path via `sst/` subdirectory.
  - Output footer, Bloom filter stats, and index summary.
- [ ] **`util wal <filename>`**:
  - Iterate through records and output type, HLC, namespace, and key.
- [ ] **`util manifest`**:
  - Output the sequence of `VersionEdit`s from the active Manifest.
- [ ] **Registration**:
  - Register `UtilCommand` in `cli_runner.dart`.

### Verification & Testing

- [ ] **Unit Tests**:
  - Add tests in `packages/kmdb_cli/test/util_command_test.dart` using mock
    storage.
- [ ] **Manual Verification**:
  - Verify `manifest`, `sstable <file>`, and `wal <file>` on a real database.
  - Verify `--summary` flag behavior.

## Summary

{Dot points highlighting the work undertaken}
