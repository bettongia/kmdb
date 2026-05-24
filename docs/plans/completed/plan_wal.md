# Plan: WAL Persistence and Flush Optimization

This plan investigates the issue where the KMDB CLI creates a new SSTable file for every `put` operation and appears to never use or persist a WAL file.

## 1. Investigation & Root Cause Analysis

### Observations
- Small `put` operations via the CLI result in a new `.sst` file in the `sst/` directory.
- No `wal-*.log` files are visible in the database directory after a CLI command completes.

### Hypothesis
The issue is caused by the unconditional flush in `LsmEngine.close()`. 
1. The CLI opens the database for each command (or at the start of a script).
2. A `put` operation writes to the WAL and then to the memtable.
3. At the end of the command execution, `KvStore.close()` is called.
4. `KvStoreImpl.close()` calls `LsmEngine.close()`.
5. `LsmEngine.close()` flushes the memtable to an SSTable if it contains any entries (`_active.length > 0`).
6. The `flush()` operation rotates the WAL and deletes the old (now "fully persisted") WAL file.
7. Consequently, the WAL file only exists for the duration of the command, and every small write is immediately "promoted" to an SSTable, leading to fragmentation and excessive compaction load.

## 2. Proposed Changes

### 2.1. Refine `close()` Behavior
Modify `LsmEngine.close()` to make flushing optional.

- Update `KvStore.close()` to accept an optional `flush` parameter: `Future<void> close({bool flush = true})`.
- Update `KvStoreImpl.close()` and `LsmEngine.close()` to respect this parameter.

### 2.2. Update CLI Global Flags
Add `--flush` and `--no-flush` global flags to the KMDB CLI.

- `--flush` (default): Flush the memtable to an SSTable on exit.
- `--no-flush`: Skip flushing on exit, leaving data in the WAL/memtable for the next session to recover.

These flags will be handled in `KmdbCli.run` and passed to `store.close()`.

### 2.3. Provide a `flush` Command
The CLI already has a `flush` command (`packages/kmdb_cli/lib/src/commands/flush_command.dart`). 
- Verify its implementation calls `store.flush()`.
- Ensure it is correctly documented in `--help`.

## 3. Implementation Steps

### Phase 1: Engine Updates
- [x] Modify `KvStore` interface in `packages/kmdb/lib/src/engine/kvstore/kv_store.dart` to add `bool flush = true` to `close()`.
- [x] Update `KvStoreImpl.close({bool flush = true})` in `packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart`.
- [x] Update `LsmEngine.close({bool flush = true})` in `packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart`.
- [x] Update `CacheLayer.close({bool flush = true})` in `packages/kmdb/lib/src/cache/cache_layer.dart`.
- [x] Update `KmdbDatabase.close({bool flush = true})` in `packages/kmdb/lib/src/query/kmdb_database.dart`.

### Phase 2: CLI Updates
- [x] Update `packages/kmdb_cli/lib/src/cli_runner.dart` to parse `--flush` and `--no-flush`.
- [x] Update `KmdbCli.run` to pass the parsed value to `store.close()`.
- [x] Update `_printUsage()` in `cli_runner.dart` to include the new flags.

### Phase 3: Verification
- [x] **Reproduction Test**: Run a `put` command with `--no-flush` and verify a `wal-*.log` file exists and no new `.sst` file is created.
- [x] **Recovery Test**: Run a subsequent `get` command and verify it can read the data from the WAL (via recovery).
- [x] **Command Test**: Run the `flush` command and verify the WAL is consumed and an SSTable is created.
- [x] **Default Test**: Run a `put` command without flags (defaulting to `--flush`) and verify it still flushes (existing behavior).

## 4. Risks & Considerations
- **Recovery Time**: Large WALs increase startup time. However, KMDB's 64KB memtable limit keeps WALs small enough that recovery is always fast.
- **Consistency**: The WAL is fsynced by default (`fsyncOnWrite: true`), so `--no-flush` does not compromise durability or consistency.
