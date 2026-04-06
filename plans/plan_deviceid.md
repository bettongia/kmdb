# CLI: Allow the deviceId to be changed

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

When a database directory is copied we need to provide a CLI utility to generate
a new `deviceId` for the copy - otherwise sync will not work.

Consider the following example:

```sh
dart run ../../bin/kmdb.dart copydb_og put notes --value '{"title": "Original note"}'
dart run ../../bin/kmdb.dart copydb_og scan notes

# Use the filesystem to copy the database directory:
cp -R copydb_og copydb_copy

# We should see the original note:
dart run ../../bin/kmdb.dart copydb_copy scan notes

dart run ../../bin/kmdb.dart copydb_og info | jq '.deviceId'
dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId'

# Configure a remote
dart run ../../bin/kmdb.dart copydb_og remote add origin --path $PWD/remote_mount/copydb_sync
dart run ../../bin/kmdb.dart copydb_copy remote add origin --path $PWD/remote_mount/copydb_sync

# When you now sync you'll see that it looks like the data is from the same deviceId
dart run ../../bin/kmdb.dart copydb_og sync
dart run ../../bin/kmdb.dart copydb_copy sync

# So create a new note and sync it
dart run ../../bin/kmdb.dart copydb_og put notes --value '{"title": "Original note - the sequel"}'
dart run ../../bin/kmdb.dart copydb_og scan notes
dart run ../../bin/kmdb.dart copydb_og sync

# Sync to the copy
dart run ../../bin/kmdb.dart copydb_copy sync

# The scan unfortunately displays only 1 note:
dart run ../../bin/kmdb.dart copydb_copy scan notes
```

Determine if generating a new `deviceId` will have side effects. If it does,
describe them; if not, implement the required change.

## Open questions

- [x] Does changing deviceId break SSTable access?
- [x] Does changing deviceId orphan remote highwater files?
- [x] Can the manifest be safely updated without a full rebuild?
- [x] Should peer-owned SSTables (ingested via pull) be renamed?

## Investigation

### Where deviceId lives

The 8-character hex deviceId is stored in the `$meta` system namespace, keyed as
`device_id` (hashed via XXH64). Read/write via `MetaStore.getDeviceId()` and
`MetaStore.putDeviceId()` (`meta_store.dart:111-127`). On first open,
`DeviceId.load()` generates a random UUID-derived ID (`device_id.dart:53-67`).

The CLI uses a two-phase open (`database_opener.dart:56-100`): phase 1 opens
with a temporary `00000000` ID, phase 2 reads the stable ID from `$meta` and
reopens so every SSTable written in this session carries the correct prefix.

### deviceId is embedded in SSTable filenames — not content

Every SSTable is named `{deviceId}-{minHlc}-{maxHlc}.sst` (3 segments, regular
flush) or `{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst` (4 segments, consolidation
output). The ID appears only in the filename, not in any file content.

`SyncEngine.push()` identifies "own" SSTables by matching the filename prefix
against `_deviceId` (`sync_engine.dart:315-321`). If `$meta` is updated but
files are not renamed, `push()` silently skips all local data — **effective data
loss on sync**.

### Manifest stores filenames as VersionEdits

The Manifest is an append-only log of `VersionEdit` records. Each edit lists
files added and removed. `ManifestState._fromEdits()` (`manifest_reader.dart:158`)
replays all edits to determine the current active set.

To update filenames it is sufficient to append one new `VersionEdit` that removes
every old-named file and adds the corresponding new-named file — no manifest
rewrite required. The Manifest already supports this pattern for compaction.

### Highwater mark files

The remote sync folder contains `highwater/{deviceId}.hwm`. After a deviceId
change the old `.hwm` file is never updated. On the next sync the device appears
as a brand-new peer: the remote will re-upload everything it knows about to the
new device. For the primary use case (copy *before* first sync) the remote has no
`.hwm` for either ID yet, so there is nothing to orphan.

If the database has already synced under the old ID the operator must manually
delete `highwater/{oldDeviceId}.hwm` from the remote after reassigning. The
`new-device-id` command will warn when configured remotes are detected.

### Peer-owned SSTables

After `pull`, peer SSTables (those whose filename deviceId differs from the local
ID) are stored in `sst/`. During a rename operation these files must **not** be
touched — they belong to the peers that created them. Only files whose filename
starts with `{oldDeviceId}-` are renamed to `{newDeviceId}-`.

### Side-effect summary

| Concern | Impact | Handled by |
|---|---|---|
| SSTable filenames embed deviceId | Old files invisible to push() | Rename files + VersionEdit |
| $meta stores deviceId | Old ID returned by storeInfo() | putDeviceId() |
| Remote .hwm named after deviceId | Orphaned if synced before rename | Warning in CLI output |
| Peer SSTables also on disk | Must not be renamed | Filter by old prefix |
| In-flight consolidation lease | Not affected (copy scenario) | N/A |
| Indexes / cache | No deviceId embedded | No action needed |
| WAL files | No deviceId embedded | No action needed |

## Implementation plan

### 1 — Core library: `KvStore.reassignDeviceId()`

Add method to `kv_store.dart`:

```dart
/// Assigns a new device identity to this store.
///
/// All SSTable files whose filename begins with the current device ID are
/// renamed to use [newDeviceId]. A single VersionEdit is appended to the
/// Manifest recording the renames. The `$meta` device_id entry is updated
/// last so that, on any crash before completion, the next open will still
/// see the old ID and recover cleanly.
///
/// [newDeviceId] must be an 8-character lowercase hex string. Throws
/// [ArgumentError] if the format is invalid.
///
/// **Caller responsibility:** the store must be idle (no concurrent writes).
/// Call [flush] before this method to ensure all memtable data is in SSTables.
Future<void> reassignDeviceId(String newDeviceId);
```

Implement in `LsmEngine` (`lsm_engine.dart`):

- [ ] Validate `newDeviceId` — 8 lowercase hex chars, not equal to current ID (defensive; the CLI always generates the ID)
- [ ] Call `flush()` to drain the memtable
- [ ] Read active SSTable list from current `ManifestState`
- [ ] For each SSTable whose bare filename starts with `{currentDeviceId}-`:
  - Compute new filename by replacing the prefix
  - Rename the file on disk via `StorageAdapter`
  - Collect `(level, oldName, newName, meta)` tuples
- [ ] Append one `VersionEdit` to the manifest:
  - `removed` = all old-named entries (level + filename)
  - `added` = all new-named entries (same level, same minKey/maxKey/entryCount, walSequence=null)
- [ ] Call `MetaStore.putDeviceId(newDeviceId)` and flush `$meta` to SSTable
- [ ] Update the in-memory `_deviceId` field used by push filtering

Also add to `KvStoreImpl` as a delegation wrapper.

### 2 — CLI command: `new-device-id`

New file `packages/kmdb_cli/lib/src/commands/new_device_id_command.dart`:

```
kmdb <db> new-device-id
```

- [ ] Generate a new random deviceId (same algorithm as `DeviceId.generate()`)
- [ ] Open the database via `DatabaseOpener`
- [ ] Check for configured remotes (`local/config.json`). If any exist, print a
  warning: the remote `highwater/{oldDeviceId}.hwm` file must be deleted
  manually after sync
- [ ] Call `store.reassignDeviceId(newId)`
- [ ] Close the store
- [ ] Output `{ "oldDeviceId": "…", "newDeviceId": "…" }`

Register in `kmdb_cli_runner.dart` (or wherever commands are wired up).

### 3 — Tests

**`kmdb` package** (`packages/kmdb/test/`):

- [ ] `reassign_device_id_test.dart`
  - Write several records (forces multiple SSTables), call `reassignDeviceId`, close,
    reopen — verify all documents still readable under new ID
  - Verify old SSTable filenames no longer exist on disk
  - Verify new SSTable filenames exist with correct prefix
  - Verify manifest replays correctly after rename
  - Verify `storeInfo().deviceId` returns new ID after reopen
  - Verify passing the current ID throws `ArgumentError`
  - Verify passing a malformed ID (wrong length, non-hex) throws `ArgumentError`
  - Verify peer SSTable files (ingested from a simulated pull) are **not** renamed

**`kmdb_cli` package** (`packages/kmdb_cli/test/`):

- [ ] `new_device_id_command_test.dart`
  - Happy path: command produces correct JSON output
  - Remote warning: output includes warning text when remotes are configured

### 4 — Documentation

- [ ] Add `new-device-id` to the CLI reference in `docs/` (whichever file covers
  CLI usage)
- [ ] Add a note to `docs/spec/04_keys.md` explaining that the deviceId can be
  changed with `new-device-id` and describing the SSTable rename semantics

## Summary

{Dot points highlighting the work undertaken}
