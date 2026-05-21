# KmdbDatabase Sync API

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

`SyncEngine` is a first-class feature of KMDB but it is not reachable through
the `KmdbDatabase` public API. A developer using the query layer today must:

1. Know that `SyncEngine` exists as a separate internal class.
2. Access `db.store` — a getter marked internal in the doc comments.
3. Separately manage `dbDir`, `deviceId`, `localAdapter`, `syncRoot`, and
   `syncNamespaces`.
4. Construct `SyncEngine` themselves and call `push()`/`pull()` manually.

This is the boilerplate that currently lives in the CLI's `sync_command.dart`.
Every application developer who wants sync must replicate it. Every other
first-class KMDB feature — indexes, FTS, vector search, vault, schemas — is
configured and managed through `KmdbDatabase`. Sync is the odd one out.

This plan adds a `sync()` method (and `push()`/`pull()` variants) to
`KmdbDatabase`, updates the CLI to use the new API, and removes the direct
`SyncEngine` construction from `sync_command.dart`, `push_command.dart`, and
`pull_command.dart`. The result is a clean public surface that the test harness
plan (`plan_test_harness.md`) can rely on without relaxing its "public API only"
rule.

## Investigation

### Q1: When does the `SyncStorageAdapter` get passed — at open time or at call time?

**Decision: at call time.**

The two use-cases are:

- **CLI**: resolves a named remote per-invocation from `local/config.json`. The
  adapter (a `LocalDirectoryAdapter` pointing at a specific filesystem path) is
  only known at the moment the user runs `kmdb sync`. Requiring it at `open()`
  time would force the CLI to know the remote before opening, which breaks the
  current flow where `DatabaseOpener` opens first and commands resolve their
  remote later.

- **Flutter / background sync**: an app that wants periodic background sync
  would construct its adapter once (e.g. a Google Drive adapter with a cached
  auth token) and pass it on each call. This is not fundamentally different from
  a per-call adapter — the app owns the adapter lifetime, not the database.

A single `syncAdapter` parameter on `sync()` / `push()` / `pull()` is the
correct model. There is no need for an adapter stored at `open()` time; that
would couple the database lifecycle to sync configuration, which is wrong for
the CLI and adds unnecessary state to `KmdbDatabase` for apps that never sync.

An `open()`-time `SyncStorageAdapter` would also require rethinking close()
semantics (who disposes the adapter?) and would block use-cases where the
adapter changes between syncs (e.g. switching between remotes, or re-authing a
cloud adapter).

### Q2: Does `KvStoreImpl` expose `dbDir`, `deviceId`, and the local `StorageAdapter` that `SyncEngine` needs?

**Yes, via existing public methods. No new exposure is needed.**

`KvStore.storeInfo()` already returns a `StoreInfo` with `dbDir` and
`deviceId`. The `SyncEngine` constructor needs:

| Parameter       | Source                                          |
| --------------- | ----------------------------------------------- |
| `store`         | `_store` (already held by `KmdbDatabase`)       |
| `cloudAdapter`  | caller-supplied at call time                    |
| `localAdapter`  | `StorageAdapterNative()` — constructed inline   |
| `deviceId`      | `(await _store.storeInfo()).deviceId`           |
| `dbDir`         | `(await _store.storeInfo()).dbDir`              |
| `syncRoot`      | see Q4                                          |
| `syncNamespaces`| see Q3                                         |

`KvStoreImpl` also exposes `_engine.adapter` (the local `StorageAdapter`) as
an internal getter on `LsmEngine`, but `SyncEngine` actually needs a
`StorageAdapter` for local file I/O (to list and read local SSTables). The CLI
correctly constructs `StorageAdapterNative()` inline, and `KmdbDatabase.sync()`
should do the same.

Note: `storeInfo()` calls `await _meta.getDeviceId() ?? _engine.deviceId`. For
the device ID to be stable, it must have been established before `sync()` is
called. In the CLI this is guaranteed because `DatabaseOpener` calls
`ensureDeviceId()` during open. For direct `KmdbDatabase` users,
`KmdbDatabase.open()` should call `ensureDeviceId()` internally (see
Implementation plan). This ensures `storeInfo().deviceId` is always the
persisted, stable value rather than the `'00000000'` default.

### Q3: What does `syncNamespaces` default to?

**Decision: all registered user (non-`$`) namespaces.**

`SyncEngine.syncNamespaces` is documented as "the set of user namespaces to
include in sync (system `$` namespaces are always excluded)". The CLI already
defaults to `await store.listNamespaces()` filtered to non-`$` namespaces via
`SyncHelpers.resolveCollections`. That is the correct default.

`KmdbDatabase.sync()` should default `syncNamespaces` to `null`, and when null,
resolve it the same way: `await _store.listNamespaces()` filtered to
non-`$` entries. The caller may pass an explicit set to restrict sync to a
subset of collections.

This default is safe because `SyncEngine` never uploads `$`-prefixed namespaces
— they are excluded by the SSTable naming and ingestion logic (SSTables carry
all namespaces written during their lifetime; the namespace filter in
`syncNamespaces` is used for future selective-sync features, not today's push/
pull logic). Defaulting to all user namespaces is the correct "just sync
everything" ergonomic default.

### Q4: Where does `syncRoot` come from?

**Decision: it is a parameter to `sync()` / `push()` / `pull()`, with a
default of `''` (empty string).**

Looking at the CLI code, `syncRoot` is hardcoded to `''` in all three commands.
The `LocalDirectoryAdapter` and `LocalDirectoryAdapter`-backed `MemorySyncAdapter`
use full paths as their root, so `syncRoot` being empty means the sync folder's
root is the adapter's root itself.

For `LocalDirectoryAdapter`, `SyncEngine` constructs paths like
`$syncRoot/sstables/` and `$syncRoot/highwater/`, which with `syncRoot = ''`
becomes `/sstables/` and `/highwater/` relative to the adapter root. This is
correct and consistent with how the CLI works today.

The `syncRoot` parameter is a path prefix within the adapter — it is only
meaningful for adapters that share a namespace (e.g. a Google Drive folder that
holds multiple KMDB databases). For the common single-database case, the empty
default is correct.

Concretely: `KmdbDatabase.sync()` should accept `syncRoot = ''` as a named
parameter with the empty-string default. Power users who share an adapter root
can override it.

### Q5: How does the new API relate to `ConsolidationConfig`?

**Decision: accept at call time with a default of `const ConsolidationConfig()`.**

`ConsolidationConfig` controls the threshold (8 files), lease TTL (120 s), and
renewal fraction (0.5). Its production defaults are fine for almost all callers.
The test harness will want to override it (e.g. `ConsolidationConfig.forTesting()`
to trigger consolidation more readily). The CLI does not currently expose it.

Exposing `ConsolidationConfig` as a named parameter on `sync()` / `pull()`
(consolidation only runs during pull) with the production default is correct:
it keeps the common path simple and gives the harness the knob it needs.

Storing it at `open()` time would be wrong for the same reasons as the adapter:
callers may want different consolidation behaviour per sync call (e.g. a
maintenance run with aggressive consolidation vs. a normal sync).

### Additional findings

**Post-sync cleanup is CLI-specific, not part of `KmdbDatabase`.**

`SyncHelpers.purgeOrphanedIndexes` detects collections tombstoned by an
incoming pull and purges their CLI config and secondary index entries. This
logic depends on `CommandContext.config` (the CLI's `local/config.json` index
registry) which is a CLI concept, not a `KmdbDatabase` concept. `KmdbDatabase`
must not include this logic; the CLI commands will continue to call
`SyncHelpers.purgeOrphanedIndexes` after delegating to `db.sync()` / `db.pull()`.

**`StorageAdapterNative` is not available on web.**

`SyncEngine` requires a `StorageAdapter` for local file I/O. `StorageAdapterNative`
uses `dart:io` and is unavailable on web. Since `SyncEngine` itself is
unavailable on web (it reads and writes local SSTable files via `dart:io`
paths), `KmdbDatabase.sync()` / `push()` / `pull()` should be documented as
native-only. They must throw `UnsupportedError` on web or use a conditional
export. The simplest approach is to have `KmdbDatabase` accept an optional
`StorageAdapter localAdapter` parameter (defaulting to `StorageAdapterNative()`)
so that tests can pass a `MemoryStorageAdapter`. See Implementation plan.

**`syncNamespaces` is not currently enforced in `SyncEngine.push()` / `pull()`.**

Reading `SyncEngine`, the `syncNamespaces` field is stored and exposed but the
`push()` and `pull()` methods do not actually filter by it — they upload/
download based on SSTable filename patterns alone. The field is documented as
"reserved for future use". The new `KmdbDatabase` API should still accept and
forward `syncNamespaces` for API completeness; the filtering behaviour will
follow when `SyncEngine` implements it.

**`KmdbDatabase.open()` should call `ensureDeviceId()` when a real device ID was not supplied.**

Currently `KmdbDatabase.open()` accepts a `deviceId` string. In tests this is
`'00000000'`. In production (CLI) it is pre-established by `DatabaseOpener`.
For the public `KmdbDatabase` API to be self-contained, `open()` should detect
the test-sentinel `'00000000'` and call `_store.ensureDeviceId()` if the caller
did not supply one explicitly. A cleaner alternative is to make `deviceId`
nullable at `open()` time, with `null` meaning "load or generate from
DEVICE_ID file". This avoids the magic sentinel. The implementation plan below
uses the nullable approach.

## Implementation plan

### Phase 1 — `KmdbDatabase.open()` device ID self-management

- [x] Change `KmdbDatabase.open()` `deviceId` parameter from `String` (default
      `'00000000'`) to `String?` (default `null`).
- [x] After `KvStoreImpl.open()`, if `deviceId` is null, call
      `store.ensureDeviceId()` and use the result for subsequent SSTable naming
      by re-opening with the stable ID — **or** by calling
      `store.reassignDeviceId()` if the initial open used the engine default.
      - **Preferred**: pass `deviceId ?? '00000000'` to `KvStoreImpl.open()` as
        before, then call `store.ensureDeviceId()` and use that value as the
        authoritative ID for the `SyncEngine`. The engine's SSTable names will
        already use the correct device ID because `KvStoreImpl.open()` calls
        `CrashRecovery.open()` which accepts `deviceId`.
      - Actually the simplest correct approach: add a public `String get deviceId`
        to `KvStoreImpl` that delegates to `_engine.deviceId` and is updated by
        `ensureDeviceId()`. Then call `ensureDeviceId()` during `KmdbDatabase.open()`
        when the caller passes `null`. The stable device ID is then always
        available as `_store.deviceId` (not via `storeInfo()` which is async).
      - **Decision**: expose `String get deviceId` on `KvStoreImpl` (package-internal,
        annotated `@internal`). Call `ensureDeviceId()` during open when `deviceId`
        parameter is null. Use `_store.deviceId` inside `sync()` / `push()` / `pull()`.
- [x] Update all existing tests that pass `deviceId: '00000000'` to continue
      passing it explicitly; no behaviour change for tests.
- [x] Update `DatabaseOpener` to pass `deviceId: null` and remove its own
      `ensureDeviceId()` call (it will now happen inside `open()`).
      - **Wait**: `DatabaseOpener` does a two-phase open specifically because
        `ensureDeviceId()` writes to `$meta`, and that write must use the correct
        device ID to produce a correctly-named SSTable. If `KmdbDatabase.open()`
        calls `ensureDeviceId()` after the initial open, the SSTable produced by
        that write will use the device ID passed to `KvStoreImpl.open()` (which
        is `'00000000'` when the caller passes null). This is the exact bug that
        `DatabaseOpener`'s two-phase open was designed to avoid.
      - **Revised plan**: keep `deviceId` as a required-with-default parameter
        on `KmdbDatabase.open()` as it is today (`String deviceId = '00000000'`).
        Do not call `ensureDeviceId()` inside `open()`. Instead, expose a public
        `Future<String> ensureDeviceId()` method on `KmdbDatabase` that delegates
        to `_store.ensureDeviceId()`. Document that callers who want stable
        sync identity must call this before the first `push()`. The harness
        will call `db.ensureDeviceId()` during its `CreateDb` action.
        The CLI's `DatabaseOpener` is already correct and needs no change.
- [x] Update doc comment on `KmdbDatabase.open()` `deviceId` parameter to
      explain that `'00000000'` is a test sentinel and production callers should
      call `db.ensureDeviceId()` (or use `DatabaseOpener`).

### Phase 2 — `KmdbDatabase` sync methods

Add to `KmdbDatabase` (in the public API section):

```dart
/// Flushes, pushes local SSTables to [syncAdapter], then pulls peer SSTables.
///
/// [syncAdapter] is the remote sync storage. [syncRoot] is the path prefix
/// within the adapter (empty string = adapter root). [syncNamespaces] restricts
/// which user collections are synced; defaults to all registered user
/// collections. [consolidationConfig] controls the peer-file consolidation
/// threshold; defaults to production values.
///
/// Equivalent to calling [push] then [pull] in sequence.
///
/// **Native-only.** Throws [UnsupportedError] on web.
Future<void> sync({
  required SyncStorageAdapter syncAdapter,
  String syncRoot = '',
  Set<String>? syncNamespaces,
  StorageAdapter? localAdapter,
  ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
});

/// Flushes and uploads local SSTables to [syncAdapter].
///
/// See [sync] for parameter documentation.
///
/// **Native-only.** Throws [UnsupportedError] on web.
Future<void> push({
  required SyncStorageAdapter syncAdapter,
  String syncRoot = '',
  Set<String>? syncNamespaces,
  StorageAdapter? localAdapter,
  ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
});

/// Downloads peer SSTables from [syncAdapter] and ingests them locally.
///
/// See [sync] for parameter documentation.
///
/// **Native-only.** Throws [UnsupportedError] on web.
Future<void> pull({
  required SyncStorageAdapter syncAdapter,
  String syncRoot = '',
  Set<String>? syncNamespaces,
  StorageAdapter? localAdapter,
  ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
});
```

Implementation of each method:

1. Resolve `syncNamespaces`: if null, call `await _store.listNamespaces()` and
   filter to non-`$` namespaces.
2. Get `dbDir` and `deviceId` from `await _store.storeInfo()`.
3. Resolve `localAdapter`: if null, use `StorageAdapterNative()`. On web this
   throws `UnsupportedError` immediately (or at construction time).
4. Construct `SyncEngine` with all resolved values.
5. Call `engine.sync()` / `engine.push()` / `engine.pull()`.

The `localAdapter` parameter (defaulting to null → `StorageAdapterNative()`) is
needed so tests can pass a `MemoryStorageAdapter` or other non-native adapter.
Without it, `KmdbDatabase.sync()` cannot be tested without a real filesystem.

### Phase 3 — Add `ensureDeviceId()` to `KmdbDatabase`

```dart
/// Loads or generates a stable device identifier for this database instance.
///
/// Call once after opening the database on production devices. Callers that
/// omit this call will use the device ID supplied at [open] time; the default
/// `'00000000'` is only suitable for tests.
///
/// Returns the 8-character lowercase hex device identifier.
Future<String> ensureDeviceId() => _store.ensureDeviceId();
```

### Phase 4 — Update CLI commands

In `sync_command.dart`, `push_command.dart`, `pull_command.dart`:

- [x] Replace the manual `storeInfo()`, adapter construction, `SyncEngine`
      construction, and `engine.push()` / `engine.pull()` calls with calls to
      `ctx.db.sync()` / `ctx.db.push()` / `ctx.db.pull()`.
- [x] The CLI commands must still call `SyncHelpers.resolveRemote()` to resolve
      the `SyncStorageAdapter` (this is CLI-specific business logic).
- [x] The CLI commands must still call `SyncHelpers.purgeOrphanedIndexes()` after
      sync (this is CLI-specific post-sync cleanup; it is not part of
      `KmdbDatabase`).
- [x] Verify that `CommandContext` exposes `ctx.db` — check whether commands
      currently use `ctx.store` directly and whether a `ctx.db` accessor is
      available. If not, add one. The `KvStore` reference in commands should be
      replaced with `KmdbDatabase` calls where possible. For methods that
      currently call `ctx.store` for non-sync purposes (e.g.
      `SyncHelpers.resolveCollections` calls `store.listNamespaces()`), access
      via `ctx.db.store` is acceptable since `store` is already a public getter
      on `KmdbDatabase`.

Note: the CLI's `--collection` flag support (passing explicit `syncNamespaces`)
must still work; pass the resolved set to the `syncNamespaces` parameter.

### Phase 5 — Tests

- [x] Unit tests for `KmdbDatabase.sync()` / `push()` / `pull()` using
      `MemoryStorageAdapter` (local) and `MemorySyncAdapter` (cloud).
- [x] Test that `syncNamespaces` defaults to all registered user namespaces.
- [x] Test that `syncRoot` is forwarded correctly (verify paths in
      `MemorySyncAdapter` contain the expected prefix).
- [x] Test that `ConsolidationConfig` is forwarded correctly by confirming
      consolidation fires at the configured threshold.
- [x] Test `ensureDeviceId()` — verify that calling it updates `storeInfo().deviceId`
      from `'00000000'` to a valid 8-char hex string.
- [x] Regression test that CLI sync commands still work end-to-end (existing
      CLI e2e tests should cover this after the refactor).
- [x] Maintain ≥ 90% coverage for the `kmdb` package after changes.

### Phase 6 — Documentation

- [x] Update `docs/spec/12_sync.md` to document the new `KmdbDatabase` sync API.
- [x] Update `docs/spec/13_query_api.md` to include `sync()`, `push()`,
      `pull()`, and `ensureDeviceId()` in the `KmdbDatabase` public API table.
- [x] Add example to `KmdbDatabase` class doc comment showing sync usage.

## Summary

- Added `sync()`, `push()`, `pull()`, and `ensureDeviceId()` public methods to
  `KmdbDatabase`, making sync a first-class feature of the Query Layer API
  (previously only accessible via the CLI's internal `SyncEngine` construction).
- Added a private `_buildSyncEngine()` helper to `KmdbDatabase` that resolves
  `syncNamespaces`, `dbDir`, and `deviceId` from the store, and constructs the
  `SyncEngine` with all required parameters.
- Fixed a path-construction bug in `SyncEngine._remoteSstDir` and
  `_remoteHwmDir`: when `syncRoot` is empty, the computed paths had a leading
  slash (`'/sstables'` instead of `'sstables'`), which broke exact-string-match
  adapters like `MemorySyncAdapter` while working incidentally on the filesystem
  (where `rootPath//sstables/` is collapsed). Fixed by returning the bare name
  when `syncRoot.isEmpty`.
- Applied the same empty-root fix to `ConsolidationCoordinator._leasePath` and
  `_sstablesDir` for consistency.
- Added 14 unit tests in `kmdb/test/query/kmdb_database_sync_test.dart` covering
  `ensureDeviceId`, `sync`, `push`, `pull`, default `syncNamespaces`, `syncRoot`
  path prefixing, and `ConsolidationConfig` forwarding — all using
  `MemoryStorageAdapter` and `MemorySyncAdapter` so no real filesystem is needed.
- Fixed a test design issue: tests that write with a specific key then later
  retrieve by that key must use `rawCollection.put()` (which honours the `_id`
  field) rather than `insert()` (which always generates a fresh key).
- Fixed a test isolation issue: tests that open two concurrent databases must use
  distinct `path` values (e.g. `'/dba'` and `'/dbb'`) because
  `MemoryStorageAdapter` uses a shared static lock table keyed by path string.
