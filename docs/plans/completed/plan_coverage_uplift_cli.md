# Coverage Uplift — kmdb_cli to ≥90%

**Status**: Complete

**PR link**: _none — implemented directly on main_

## Problem statement

`kmdb_cli` currently sits at **78.8% line coverage** (1506/1911 lines) against the
project-wide 90% bar. Most CLI commands have integration coverage for the
golden path but skip error/exit-code branches, malformed-flag handling, and
remote/sync edge cases. This plan brings the package to ≥90%.

## Open questions

All resolved during review. See decisions below.

## Decisions

**Q1 — Single `_runCommand` helper vs per-command expansion:**
Expand per-command tests using the existing `_ctx()` + `command.execute(ctx, args, flags)`
pattern from `commands_test.dart`. A new wrapper adds indirection without benefit — the
existing pattern is already uniform across 2,000+ lines of tests.

**Q2 — Mock `SyncEngine` vs `MemorySyncAdapter` end-to-end:**
`pull_command_test.dart` already uses real `LocalDirectoryAdapter` with temp directories.
Continue that pattern. Error branches (remote not configured, config malformed) can be
tested by manipulating `KmdbConfig` without touching the sync engine at all.

## Coverage exclusions

The following code is structurally untestable in automated tests and must not be counted
against the 90% bar. Document these exemptions here rather than chasing coverage with
meaningless tests.

| Code | Location | Reason |
| :--- | :------- | :----- |
| `_StdoutSink` / `_StderrSink` inner classes | `commands/command.dart` lines 181–203 | Production-only `io.stdout`/`io.stderr` wrappers. All tests supply `StringBuffer`; exercising the real sink would pollute test output. |
| `CommandContext` constructor `out ?? _StdoutSink()` / `err ?? _StderrSink()` fallbacks | `commands/command.dart` lines 57–58 | Consequence of the above: the null-fallback paths to `_StdoutSink`/`_StderrSink` are never reached in tests. |
| `CliCommand.configureArgParser` default no-op | `commands/command.dart` line 166 | Abstract base default; only meaningful on subclasses that override it. |
| Stdin reading loop | `commands/vault/vault_import_helper.dart` lines 41–51 | Requires piped `io.stdin`. Not feasible to attach in automated unit tests. |
| Stdin fallback path | `commands/insert_command.dart` line 264 | Same rationale: `io.stdin.transform(utf8.decoder).join()` is only reached when neither `--value` nor `--file` is supplied, which requires interactive stdin. |
| Stdin fallback path | `commands/import_command.dart` line 87 | Same rationale: `io.stdin.transform(…)` is only reached when `--input` is omitted, which requires piped stdin. |

After excluding these 26 lines from the denominator, the effective baseline is
1506/1885, still 79.9%. Reaching 90% of 1885 lines requires covering ~190 more lines.

**Coverage margin note:** The command metadata test covers `name`/`description`/`usage`/`configureArgParser`
across *all* command classes — not just those in the implementation plan — so it yields considerably
more than the ~30 lines listed in the plan item. In practice the metadata test alone is expected
to cover 60–70 lines across the full command set, providing a comfortable buffer against the
estimated shortfall.

## Investigation

Per-file coverage from the last `make coverage` run (sorted by coverage %):

| File                                        | Hits/Total | %     |
| :------------------------------------------ | :--------- | :---- |
| `commands/command.dart`                     | 14/33      | 42.4% |
| `commands/vault/vault_import_helper.dart`   | 21/41      | 51.2% |
| `commands/dump_command.dart`                | 36/69      | 52.2% |
| `commands/export_command.dart`              | 34/61      | 55.7% |
| `commands/compact_command.dart`             | 4/7        | 57.1% |
| `commands/flush_command.dart`               | 4/7        | 57.1% |
| `config/remote_config.dart`                 | 18/29      | 62.1% |
| `commands/new_device_id_command.dart`       | 12/19      | 63.2% |
| `commands/info_command.dart`                | 7/10       | 70.0% |
| `commands/init_command.dart`                | 7/10       | 70.0% |
| `commands/create_collection_command.dart`   | 8/11       | 72.7% |
| `commands/pull_command.dart`                | 20/27      | 74.1% |
| `commands/sync_command.dart`                | 23/31      | 74.2% |
| `commands/count_command.dart`               | 15/20      | 75.0% |
| `config/kmdb_config.dart`                   | 118/157    | 75.2% |
| `commands/insert_command.dart`              | 91/120     | 75.9% |
| `commands/push_command.dart`                | 22/29      | 75.9% |
| `commands/vault/vault_get_command.dart`     | 23/30      | 76.7% |
| `commands/update_command.dart`              | 84/108     | 77.8% |

**Root causes (confirmed by line-level lcov.info analysis):**

1. **Command metadata getters not exercised** — `name`, `description`, and `usage`
   getter bodies (e.g. `String get name => 'compact'`) appear as uncovered lines in
   *every* command. Tests call `.execute()` directly; the CLI runner is the only caller
   of these getters in production. A single `command_metadata_test.dart` can cover all
   of them cheaply. The same applies to `configureArgParser` overrides on commands that
   declare flags (e.g. `dump`, `export`, `scan`).

2. **`_StdoutSink` / `_StderrSink`** — 19 lines in `command.dart` that are
   structurally untestable (see exclusions above).

3. **Vault dump/export paths** — `dump_command.dart` and `export_command.dart` each
   have a `--vault` branch (~30 uncovered lines each) that requires a vault-configured
   `KmdbDatabase` with real tmpDirs and `VaultStore`.

4. **`config/remote_config.dart` error paths** — `RemoteConfig.fromJson` error branches
   (null `type`, non-string `type`, unknown `type`), `LocalRemoteConfig.fromJson` with
   bad `path`, and `adapterFor()` are all pure unit tests, straightforward to add.

5. **`config/kmdb_config.dart` load error paths** — malformed JSON, `remotes` not an
   object, `indexes` not an array, etc. — all reachable by writing bad files to tmpDir.

6. **Pull/push/sync error branches** — "no remote configured", config-load failure, and
   remote-not-found branches are untested. These require only manipulating `KmdbConfig`,
   not a full sync engine.

7. **`vault_import_helper.dart`** — `VaultCrcMismatchException` catch in
   `ingestVaultAttachments` and `applyVaultRefCounts` function are uncovered.
   The stdin path is excluded (see above).

8. **`new_device_id_command.dart`** — config-load failure path (`FormatException` on
   load) and `reassignDeviceId` `ArgumentError` path are uncovered.

## Implementation plan

- [x] **Command metadata** — Add `test/command_metadata_test.dart` that instantiates
      every `CliCommand` subclass and asserts `name`, `description`, and `usage` are
      non-empty strings, and calls `configureArgParser(ArgParser())` without error.
      This covers the metadata getters and `configureArgParser` bodies across all commands
      — estimated 60–70 lines total, making it the highest-yield single test file.

- [x] **`config/remote_config.dart`** — Add unit tests for:
      - `RemoteConfig.fromJson` with missing `type` field → `FormatException`
      - `RemoteConfig.fromJson` with non-string `type` → `FormatException`
      - `RemoteConfig.fromJson` with unknown type → `FormatException`
      - `LocalRemoteConfig.fromJson` with missing `path` → `FormatException`
      - `LocalRemoteConfig.fromJson` with non-string `path` → `FormatException`
      - `adapterFor(LocalRemoteConfig(...))` returns a `LocalDirectoryAdapter`
      - `LocalRemoteConfig` equality and `hashCode`

- [x] **`config/kmdb_config.dart`** — Extend `kmdb_config_test.dart` to cover:
      - Load fails with non-JSON content → `FormatException`
      - Load fails when root is a JSON array → `FormatException`
      - Load fails when `remotes` is not an object → `FormatException`
      - Load fails when a remote entry is not an object → `FormatException`
      - Load fails when `indexes` is not an array → `FormatException`
      - Load fails when an index entry is missing `collection` or `path` → `FormatException`
      - Load fails when `ftsIndexes` is not an array → `FormatException`
      - Load fails when `embeddingModel` is not an object, or missing `type`/`modelPath` → `FormatException`
      - `addFtsIndex` / `removeFtsIndex` round-trip
      - `ftsIndexesForCollection` returns only matching entries
      - `removeRemote` on missing name → `ArgumentError`
      - `addRemote` with `force: true` overwrites existing

- [x] **`commands/dump_command.dart`** — Add tests for:
      - Standard NDJSON dump of a populated store (golden path — header lines + document lines)
      - `--vault` with no vault configured → error message, returns `false`

- [x] **`commands/export_command.dart`** — Add tests for:
      - Export missing collection arg → returns `false`
      - `--vault` with no vault configured → error, returns `false`

- [x] **`commands/pull_command.dart`, `push_command.dart`, `sync_command.dart`** —
      Add tests for the error branches only (golden paths already covered):
      - No remotes configured → error message, returns `false`
      - Named remote not found in config → error message, returns `false`
      - Config-load failure (corrupt config.json in tmpDir) → error message, returns `false`

- [x] **`commands/vault/vault_import_helper.dart`** — Add unit tests for:
      - `readVaultPackage` with `packageBytes` directly (skips file I/O) → returns parsed contents
      - `readVaultPackage` with invalid bytes → writes error, returns `null`
      - `readVaultPackage` with a non-existent `packagePath` → writes error, returns `null`
      - `ingestVaultAttachments` with a `VaultCrcMismatchException` → writes error, returns `null`
      - `extractVaultUrisFromDoc` with nested vault URIs (map, list, scalar)

- [x] **`commands/new_device_id_command.dart`** — Add test for:
      - Config-load failure (write corrupt config.json to tmpDir) → error, returns `false`

- [x] **`commands/restore_command.dart` and `commands/verify_command.dart`** — Add:
      - `test/restore_verify_test.dart` covering all RestoreCommand branches (8 tests),
        VerifyCommand (4 tests including corrupt-document error path), CountCommand
        ArgumentError filter path, and VaultCommand dispatch tests.

- [x] **`commands/vault/vault_command.dart`** — Covered via `restore_verify_test.dart`:
      no-vault, no-sub-command, unknown-sub-command cases.

- [x] **`commands/scan_command.dart`** — Extended `explain_test.dart` with:
      - `--key-prefix` with filter (exercises store-level filter path)
      - `--order-by` with string fields, null field values, and string limit arg
      - `--explain` with a defined-but-not-yet-current (building) index — exercises
        the full-scan fallback with `indexStatus != 'none'`

- [x] **`commands/collections_command.dart`** — Extended `commands_test.dart` with:
      - `collections create $system` → `ArgumentError` from `createNamespace`

- [x] **`output/output_mode.dart`** — Added `displayName` getter test via `explain_test.dart`.

- [x] **`filter/filter_parser.dart`** — ArgumentError for non-map input covered via
      `CountCommand` test in `restore_verify_test.dart`.

- [x] **Re-run `make coverage` and confirm `kmdb_cli` ≥ 90%.**
      Result: **90.0% (1756/1951 lines)** ✓

## Summary

Brought `kmdb_cli` from 78.8% to 90.0% line coverage (1756/1951 lines) by adding
11 new test files and extending 8 existing ones. The highest-yield additions were:
`command_metadata_test.dart` (~65 lines), `restore_verify_test.dart` (RestoreCommand,
VerifyCommand, VaultCommand, CountCommand — ~40 lines), `vault_import_helper_test.dart`
(~35 lines), and extensions to `kmdb_config_test.dart`, `explain_test.dart`, and the
pull/push/sync command tests. Vault dump/export paths with hydrated blobs remain
uncovered (require real vault I/O) but are not needed to meet the 90% bar.
