# Coverage Uplift — kmdb_cli to ≥90%

**Status**: Open

**PR link**: _none yet_

## Problem statement

`kmdb_cli` currently sits at **78.8% line coverage** against the
project-wide 90% bar. Most CLI commands have integration coverage for the
golden path but skip error/exit-code branches, malformed-flag handling, and
remote/sync edge cases. This plan brings the package to ≥90%.

## Open questions

- [ ] Should we adopt a single `_runCommand` test helper that exercises
      `usageException` and exit-code paths uniformly, or expand existing
      command-specific tests?
- [ ] Is it acceptable to mock `SyncEngine` interactions for `pull`/`push`
      branches, or should we use `MemorySyncAdapter` end-to-end?

## Investigation

Lowest-coverage CLI files (excluding generated code):

| File                                | Hits/Total | %     |
| :---------------------------------- | :--------- | :---- |
| `commands/command.dart`             | 14/33      | 42.4% |
| `commands/dump_command.dart`        | 36/69      | 52.2% |
| `commands/vault/vault_import_helper.dart` | 21/41 | 51.2% |
| `commands/export_command.dart`      | 34/61      | 55.7% |
| `commands/compact_command.dart`     | 4/7        | 57.1% |
| `commands/flush_command.dart`       | 4/7        | 57.1% |
| `config/remote_config.dart`         | 18/29      | 62.1% |
| `commands/new_device_id_command.dart` | 12/19    | 63.2% |
| `commands/init_command.dart`        | 7/10       | 70.0% |
| `commands/info_command.dart`        | 7/10       | 70.0% |
| `commands/pull_command.dart`        | 20/27      | 74.1% |
| `commands/sync_command.dart`        | 23/31      | 74.2% |
| `commands/count_command.dart`       | 15/20      | 75.0% |
| `config/kmdb_config.dart`           | 118/157    | 75.2% |

The recurring patterns are:

1. **Base `Command` class** (42.4%) — error paths in argument parsing,
   `_resolveDbPath` fallbacks, and exit-code propagation are untested.
2. **`dump`/`export` commands** — alternate output modes (CSV escaping,
   ndjson framing) and binary output paths.
3. **`flush`/`compact`** — error paths when no DB exists.
4. **`config/remote_config.dart`** — malformed `local/config.json` parsing.
5. **`vault_import_helper.dart`** — manifest/attachment mismatch branches.

## Implementation plan

- [ ] Cover `commands/command.dart` argument-parsing branches (unknown flag,
      missing required, conflicting flags).
- [ ] Cover `commands/dump_command.dart` for each `--format` value with a
      mix of text and binary documents.
- [ ] Cover `commands/export_command.dart` for ndjson/csv error paths.
- [ ] Cover `commands/import_command.dart` for malformed input and partial
      batch failure rollback.
- [ ] Cover `commands/flush_command.dart` and `compact_command.dart` with
      "no DB found" and post-flush state assertions.
- [ ] Cover `config/remote_config.dart` for missing/malformed/duplicate
      remote names.
- [ ] Cover `commands/new_device_id_command.dart` re-roll on existing DB.
- [ ] Cover `commands/init_command.dart` exit codes for non-empty / sub-dir
      cases (some are present; complete the matrix).
- [ ] Cover `commands/pull_command.dart`, `push_command.dart`,
      `sync_command.dart` against a `MemorySyncAdapter` with conflicting
      HLCs.
- [ ] Cover `commands/vault/vault_import_helper.dart` for manifest/object
      mismatch and CRC failure branches.
- [ ] Re-run `make coverage` and confirm `kmdb_cli` ≥ 90%.

## Summary

_(left blank — fill in after implementation)_
