---
name: CLI diagnostic command implementation patterns
description: Key architectural decisions and patterns from implementing the util command and kmdb_analysis sub-library (plan_cli_db_analysis)
type: project
---

## Sub-library pattern for exposing engine internals

`lib/kmdb_analysis.dart` is the idiomatic way to expose storage-engine types to
tooling without polluting the primary `kmdb.dart` API. The name "analysis" was
chosen deliberately over "util", "internals", "debug", or "diagnostics" — each
of which had misleading connotations.

**Why:** Adding storage internals to the main library imposes ongoing maintenance
burden and pollutes the API surface that library consumers see.

**How to apply:** When future plans need to expose engine internals to tooling
or test utilities, extend `lib/kmdb_analysis.dart` rather than `lib/kmdb.dart`.

## CLI util command does not acquire a lock

`UtilCommand` uses `StorageAdapterNative` directly with no `KvStore.open()` call.
This allows inspection of a database currently open in another process.

**Why:** A primary use case is inspecting a running database to diagnose issues.

**How to apply:** Any future diagnostic or read-only inspection command that
targets raw files should follow the same no-lock pattern.

## Private type rename requirement

`_BlockRef` had to be renamed to `BlockRef` (public) because returning
`List<_BlockRef>` from a public getter is a Dart compilation error outside the
defining library file. This is a Dart language constraint, not a style choice.

## Test pattern: real temp directories for native adapter tests

The util command tests use `io.Directory.systemTemp.createTempSync()` with
real `StorageAdapterNative` — not `MemoryStorageAdapter`. This is necessary
because the util command directly instantiates `StorageAdapterNative`.

Track temp dirs in a list and clean up with `deleteSync(recursive: true)` in
`tearDown`.

## Test pattern: generating corrupt WAL files

To test corruption handling: write valid `WalRecord.encode()` bytes, then
`writeAsBytes(List<int>.filled(N, 0xFF), mode: FileMode.append)`. This triggers
a checksum failure on the next record decode in `replayStrict`.

## WalRecord key format in tests

Store tests must use valid UUIDv7 keys (from `UuidV7KeyGenerator().next()`), not
`'0' * 32` padding. `KvStoreImpl._validateKey` enforces UUIDv7 format.

## editCount for fresh database

A freshly opened `KvStoreImpl` may already have 1 or more Manifest edits
(device ID setup writes to `$meta` and flushes). Tests for "empty" manifest
should check structure, not a specific count of 0.

## Pre-existing test failures

`packages/kmdb_cli/test/cli_runner_test.dart` integration tests (those that
run the actual `bin/kmdb.dart` binary as a subprocess) were already failing
before this implementation due to a path resolution issue. These are not
regressions introduced by this plan.
