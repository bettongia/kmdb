# CLI — Sync commands

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/6

## Problem statement

KMDB's sync engine (`SyncEngine`) is fully implemented and tested, but it is
only accessible from application code. The CLI has no way to push local
SSTables to a sync folder, pull peer SSTables, or run a combined sync. This
means users cannot synchronise a KMDB database from the command line — for
example, to sync a local database to a NAS mount or a locally-mapped Dropbox
folder.

This plan adds sync commands to `kmdb_cli` with git-style named remotes for
ergonomics:

- **`remote`** — manage named sync targets (`add`, `remove`, `list`).
- **`push [<remote>]`** — flush the local memtable and upload new SSTables to
  a sync folder.
- **`pull [<remote>]`** — download peer SSTables from the sync folder and
  ingest them.
- **`sync [<remote>]`** — convenience wrapper that runs push then pull.

Named remotes are stored in a new per-database config file
`{dbDir}/local/config.json`. When no remote name is given, `push`, `pull`, and
`sync` default to the remote named `origin` if one is defined.

The initial implementation targets `LocalDirectoryAdapter` only. Future cloud
adapters (Google Drive, iCloud, GCS) will integrate via the same
`SyncStorageAdapter` interface using the typed `RemoteConfig` structure
described below.

## Open questions

- [x] Should `syncRoot` passed to `SyncEngine` be an empty string when the
  `LocalDirectoryAdapter` root path already points to the sync folder root?
  **Resolved: yes, pass `''`.**
- [x] Should namespace filtering default to all non-system namespaces, or
  require explicit `--namespace` flags?
  **Resolved: default to all non-`$`-prefixed namespaces; allow `--namespace`
  to restrict.**
- [x] Should the config support future adapter types that need OAuth, keys etc?
  **Resolved: yes — remotes are typed. Each type has its own required fields.**
- [x] Should a bare `push`/`pull`/`sync` with no remote name fail or try a
  default?
  **Resolved: default to `origin` if defined; error if no remote name given
  and no `origin` exists.**
- [x] Where should the config file live?
  **Resolved: `{dbDir}/local/config.json`. The `local/` subdirectory holds
  all locally-managed, non-synced artefacts. CLI tooling (scan, dump, export,
  etc.) explicitly ignores this directory.**

## Investigation

### Existing CLI architecture

Commands are stateless `const` objects implementing `CliCommand` (name,
description, usage, `execute()`). They are registered in a `Map<String,
CliCommand>` in `cli_runner.dart`. Flag parsing is manual: `--flag value` →
`flags['flag'] = value`; `--bool-flag` → `flags['bool-flag'] = true`. No
external `package:args` dependency.

`DatabaseOpener.open(dbPath)` returns an open `KvStoreImpl` and calls
`store.ensureDeviceId()` to ensure a stable device UUID is present in `$meta`.
The device ID is stored in the database itself (not in a global `~/.kmdb`
file), so the same device identity is used across all CLI commands.

No config file infrastructure exists today. `dart:convert` provides JSON
parsing as a built-in, so no new dependency is needed.

### The `local/` directory

A new `{dbDir}/local/` subdirectory holds all per-machine, non-synced state:

```
{local-db-dir}/
  LOCK
  CURRENT
  MANIFEST-00001
  wal-00001.log
  sst/
    {deviceId}-{minHlc}-{maxHlc}.sst
  local/
    config.json          ← remote definitions (new)
```

**Contract for `local/`:**
- Never uploaded or read by `SyncEngine`. The `SyncStorageAdapter` only
  touches `sstables/`, `highwater/`, and `.consolidation-lease` in the remote
  sync folder; the local `local/` directory is invisible to it.
- Excluded from `scan`, `dump`, `export`, `restore`, `compact`, `verify`
  operations. These commands operate on SSTable data only.
- May hold additional per-device artefacts in future (e.g. REPL history,
  per-machine preferences).

The directory is created lazily on first write (e.g. first `remote add`).

### Remote config schema

`{dbDir}/local/config.json`:

```json
{
  "remotes": {
    "origin": {
      "type": "local",
      "path": "/Volumes/NAS/myapp-sync"
    },
    "dropbox": {
      "type": "local",
      "path": "/Users/me/Dropbox/myapp-sync"
    }
  }
}
```

The `type` field is mandatory and determines which `SyncStorageAdapter`
implementation is constructed. The remaining fields are type-specific.

**Current types:**

| Type | Required fields | Adapter |
|------|----------------|---------|
| `local` | `path` | `LocalDirectoryAdapter(path)` |

**Reserved for future types:**

| Type | Likely fields |
|------|--------------|
| `google_drive` | `folderId`, `credentialsFile` |
| `icloud` | `containerIdentifier` |
| `gcs` | `bucket`, `prefix`, `serviceAccountFile` |

Credentials are referenced by file path rather than stored inline to avoid
plaintext secrets in `config.json`. Each future adapter type will document its
own required fields.

### Config management

A new `KmdbConfig` class (in `packages/kmdb_cli/lib/src/config/`) owns
reading and writing `config.json`:

```dart
final class KmdbConfig {
  static Future<KmdbConfig> load(String dbDir);   // reads file or returns empty
  Future<void> save(String dbDir);                 // writes atomically

  Map<String, RemoteConfig> get remotes;
  void addRemote(String name, RemoteConfig remote);
  void removeRemote(String name);                  // throws if not found
}
```

`RemoteConfig` is a sealed class hierarchy:

```dart
sealed class RemoteConfig {
  String get type;
  static RemoteConfig fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}

final class LocalRemoteConfig extends RemoteConfig {
  final String path;
}
```

This sealed hierarchy makes it straightforward to add future adapter types
without breaking existing code.

A factory `SyncStorageAdapter adapterFor(RemoteConfig remote)` (in the same
config package) constructs the correct adapter for a given remote, keeping
adapter-specific logic out of the command layer.

### SyncEngine wiring

`SyncEngine` constructor:

```dart
SyncEngine({
  required KvStore store,
  required SyncStorageAdapter cloudAdapter,
  required StorageAdapter localAdapter,
  required String deviceId,
  required String dbDir,
  required String syncRoot,
  required Set<String> syncNamespaces,
  ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
})
```

`syncRoot` is used as a path prefix for keys passed to `SyncStorageAdapter`.
When `LocalDirectoryAdapter(rootPath)` is used and `rootPath` already points
to the sync folder root, `syncRoot` should be `''` so that paths resolve to
`$rootPath/highwater/$deviceId.hwm`.

`deviceId` is obtained from the open store via `MetaStore(store).getDeviceId()`.

`localAdapter` is a `StorageAdapterNative()` — the same one used to open the
database. `dbDir` is the database path on disk.

### Namespace resolution

`SyncEngine` accepts `Set<String> syncNamespaces`. The CLI defaults to all
namespaces from `KvStore.listNamespaces()` that do not begin with `$`. An
optional `--namespace` flag (repeatable) restricts to named namespaces.

### Command design

**`remote` command** — manages remotes; first positional arg is the
subcommand:

```
kmdb <db> remote add <name> --type local --path <path>
kmdb <db> remote remove <name>
kmdb <db> remote list
```

For the `local` type, `--path` is sufficient; `--type local` may be omitted
and defaulted (since `local` is the only type for now).

**`push`, `pull`, `sync` commands** — remote name is the first positional arg,
defaulting to `origin`:

```
kmdb <db> push                      # uses remote named "origin"
kmdb <db> push dropbox              # uses remote named "dropbox"
kmdb <db> push --sync-dir <path>    # one-off; does not require a saved remote
kmdb <db> pull [<remote>]
kmdb <db> sync [<remote>]
```

`--sync-dir` is a one-off escape hatch that bypasses config entirely. When
both a positional remote name and `--sync-dir` are provided, it is an error.

An optional `--namespace` flag (repeatable) restricts which namespaces sync.

### Output

Sync commands produce human-readable summaries, not document output:

```
push: 3 SSTable(s) uploaded, HWM updated (device: a1b2c3d4...)
pull: 2 SSTable(s) ingested from 1 peer(s), HWM updated
sync: push complete, pull complete
```

The `--mode` flag has no effect on sync command output.

### Key files to create / modify

| File | Change |
|------|--------|
| `packages/kmdb_cli/lib/src/config/kmdb_config.dart` | New — config file I/O |
| `packages/kmdb_cli/lib/src/config/remote_config.dart` | New — sealed `RemoteConfig` hierarchy |
| `packages/kmdb_cli/lib/src/commands/remote_command.dart` | New — add/remove/list |
| `packages/kmdb_cli/lib/src/commands/push_command.dart` | New |
| `packages/kmdb_cli/lib/src/commands/pull_command.dart` | New |
| `packages/kmdb_cli/lib/src/commands/sync_command.dart` | New |
| `packages/kmdb_cli/lib/src/cli_runner.dart` | Register 4 new commands |
| `packages/kmdb_cli/test/config/kmdb_config_test.dart` | New |
| `packages/kmdb_cli/test/commands/remote_command_test.dart` | New |
| `packages/kmdb_cli/test/commands/push_command_test.dart` | New |
| `packages/kmdb_cli/test/commands/pull_command_test.dart` | New |
| `packages/kmdb_cli/test/commands/sync_command_test.dart` | New |
| `docs/spec/` (layout doc) | Update directory layout diagram |
| `CLAUDE.md` | Update local directory layout section |

### Edge cases and failure scenarios

- **No remote name and no `origin`**: error — "no remote specified and no
  'origin' remote is configured".
- **Unknown remote name**: error — "remote 'foo' not found".
- **Both remote name and `--sync-dir`**: error — mutually exclusive.
- **`remote add` with duplicate name**: error — require `--force` to overwrite.
- **`remote remove` non-existent name**: error.
- **Non-existent `--path` for local remote**: not validated at `add` time
  (path may not exist yet); `LocalDirectoryAdapter` creates directories on
  first write so first `push` is safe, first `pull` returns empty.
- **Missing `local/` directory**: created lazily on first `remote add`.
- **Corrupt `config.json`**: surface a clear parse error; do not silently
  ignore or overwrite.
- **Database locked by another process**: `LockException` from
  `DatabaseOpener`; already handled by the CLI runner.
- **No user namespaces**: warn and exit successfully (nothing to sync).
- **Corrupted remote SSTables**: `SyncEngine.pull()` skips unparseable files
  without updating HWM, so they are retried next pull. Surface a warning.
- **Push partially uploaded**: HWM is not updated on failure so next push
  re-uploads from the last HWM — idempotent, no data loss.
- **Unknown `type` in config**: surface a clear error naming the type; do not
  silently fall back.

## Implementation plan

### 1. Config infrastructure

- [x] Create `remote_config.dart` — sealed `RemoteConfig`, `LocalRemoteConfig`,
  `fromJson` factory, `toJson`, `adapterFor()` factory function
- [x] Create `kmdb_config.dart` — `KmdbConfig.load()`, `save()`,
  `addRemote()`, `removeRemote()`, `remotes` getter; atomic write
  (write-to-temp, rename)
- [x] Tests: `kmdb_config_test.dart` — round-trip JSON, duplicate add error,
  remove non-existent error, corrupt JSON error, missing file returns empty

### 2. `remote` command

- [x] Create `remote_command.dart` — dispatch on first arg (add/remove/list)
- [x] `add`: validate flags, construct `RemoteConfig`, load config, add,
  save; error on duplicate without `--force`
- [x] `remove`: load config, remove by name, save; error if not found
- [x] `list`: load config, print name + type + key fields per remote
- [x] Tests: `remote_command_test.dart` — add/list/remove round-trip; duplicate
  error; remove non-existent error; unknown subcommand error

### 3. Sync commands

- [x] Create `push_command.dart`
  - [x] Resolve remote: positional arg → config lookup; no arg → `origin`;
    `--sync-dir` → ad-hoc `LocalRemoteConfig`; conflict → error
  - [x] Flush the memtable via `ctx.store.flush()` before pushing — ensures
    all recent writes are materialised as SSTables so nothing is silently
    excluded from the upload
  - [x] Resolve device ID via `store.storeInfo().deviceId`
  - [x] Build namespace set (all non-`$`, or `--namespace` override)
  - [x] Construct adapter via `adapterFor(remote)` and `SyncEngine`
  - [x] Call `engine.push()`; print summary; return `true`
  - [x] Handle errors; write to `ctx.err`; return `false`
- [x] Create `pull_command.dart` (same structure, call `engine.pull()`; no
  flush needed — pull only writes to the local store as a destination)
- [x] Create `sync_command.dart` (flush then `engine.sync()` — same rationale
  as push: memtable must be flushed before the push half of sync)
- [x] Tests:
  - [x] `push_command_test.dart` — push via named remote; push via `--sync-dir`;
    default to `origin`; error when no remote and no `origin`; both name and
    `--sync-dir` is error; no user namespaces warns
  - [x] `pull_command_test.dart` — pull with no peer data is no-op; pull
    ingests peer SSTables; same remote resolution error cases
  - [x] `sync_command_test.dart` — round-trip between two logical devices;
    same error cases

### 4. CLI registration

- [x] Register `remote`, `push`, `pull`, `sync` in `cli_runner.dart`

### 5. Documentation

- [x] Add doc comments to all new classes and commands
- [x] Update `CLAUDE.md` local directory layout to show `local/` subdirectory
- [ ] Update `docs/spec/` directory layout diagram

## Summary

- Added CLI sync commands (`push`, `pull`, `sync`) backed by the existing `SyncEngine`
- Added `remote` command for managing named sync targets (`add`, `remove`, `list`)
- Introduced `KmdbConfig` and `RemoteConfig` (sealed hierarchy) in a new
  `packages/kmdb_cli/lib/src/config/` package for per-database config in
  `{dbDir}/local/config.json`
- Introduced `SyncHelpers` utility for shared remote-resolution and
  namespace-resolution logic across all three sync commands
- Fixed `DatabaseOpener.open()` to perform a two-phase open: after generating
  or loading the stable device ID from `$meta`, reopen the store with that ID
  so SSTable filenames are consistent with the identity exposed by
  `SyncEngine.push()` — preventing a "no files to upload" silent failure
- Added 64 new tests covering config round-trips, error cases, sync edge cases,
  and a round-trip push/pull scenario between two logical devices
- Updated `CLAUDE.md` to document the `local/` subdirectory
