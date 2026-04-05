---
name: CLI sync commands implementation
description: Key decisions and patterns from implementing remote/push/pull/sync CLI commands
type: project
---

## DatabaseOpener two-phase open

`DatabaseOpener.open()` was updated to do a two-phase open:
1. Open with default `deviceId = '00000000'`
2. Call `store.ensureDeviceId()` to load/generate the stable meta ID
3. If it differs from `'00000000'`, close (no flush) and reopen with the correct device ID

**Why:** `KvStoreImpl.open()` names SSTables after the `deviceId` argument, not the one stored in `$meta`. Without this fix, `storeInfo().deviceId` returns the meta ID but SSTables are named `00000000-...`, so `SyncEngine.push()` can't find them (it filters by `deviceId`).

**How to apply:** Any CLI command that uses `storeInfo().deviceId` for sync must go through `DatabaseOpener.open()` (not raw `KvStoreImpl.open()`) so the engine and meta device IDs are consistent.

## Device ID collision in tests

Two databases opened within the same millisecond get the same device ID (UUIDv7 uses ms precision). For tests with "two logical devices", explicitly pass a distinct `deviceId` to `KvStoreImpl.open()` for the peer store rather than using `DatabaseOpener.open()`.

## SyncEngine construction in CLI

Device ID comes from `store.storeInfo().deviceId`. The `syncRoot` is `''` when using `LocalDirectoryAdapter(path)` because the adapter root already points to the sync folder root. `localAdapter` is always `StorageAdapterNative()`.

## Config location

Named remotes are in `{dbDir}/local/config.json`. The `local/` directory is created lazily by `KmdbConfig.save()`. It is never read or written by `SyncEngine`.

## Test patterns

- Pull/sync tests that need to exercise cross-device ingest: push via `SyncEngine` directly (not via `PushCommand`) with an explicit `deviceId`, to guarantee the peer's SSTable is named differently from the local device's ID.
- All sync command tests use `DatabaseOpener.open()` for the primary store (not raw `KvStoreImpl.open()`).
