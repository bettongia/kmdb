# End-to-end testing

**Status**: Completed

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

We should configure a test that attempts to replicate a non-trivial user session
using the CLI in batch mode. This will involve multiple calls to the namespace
to build out at least three collections. I would suggest the following
collections and associated document properties:

- `notes`: title (string), body (string), tags (array), creation_date
  (date/string)
- `reading_list`: title (string), authors (array), tags (array), review (string)
- `shopping_list`: item (string), quantity (int), needed (bool)

The test harness should generate at least 1000 synthetic records for each
collection.

Calls to the CLI's `put` command should use a mixture of flush/no-flush usage.
Don't use the CLI's scripting and pipeline capability.

At various points in the test run you should `get` a number of records at
various times - testing records that you know exist and know are not in the
database.

You should also delete records at various times and check that they cannot be
recalled.

Essentially, use the CLI like a person would, creating, getting & deleting
records as well querying the database. You would use different output modes and
should check the output matches what you expect.

This testing could potentially run for a long time so consider putting this
testing in its own directory and file. Also consider an approach to ensuring
that this test is only run when explicitly called.

To be clear, the test needs to be codified (built) in Dart using the standard
testing approach.

## Open questions

- [x] Should we use `dart compile exe` to speed up the test, or is
      `dart bin/kmdb.dart` acceptable given it will be run explicitly?
      **Decision: Use compiled exe.**
- [x] Is there a specific "batch mode" flag intended, or does it simply refer to
      non-interactive sequential command execution? **Decision: Sequential
      process invocations.**

## Investigation

The investigation covered the CLI architecture and established testing patterns:

1.  **CLI Entry Point**: `packages/kmdb_cli/bin/kmdb.dart` calls `KmdbCli.run`,
    which handles global flags (`--flush`, `--no-flush`, `--mode`) and
    dispatches commands.
2.  **Command Execution**: Commands like `put`, `get`, `delete`, and `scan` are
    implemented in `packages/kmdb_cli/lib/src/commands/`.
3.  **ID Generation**: `PutCommand` automatically assigns a new UUIDv7 `id` to
    every document it inserts and echoes the document back. This means the E2E
    test must capture and parse the output of `put` to track inserted IDs for
    later retrieval/deletion.
4.  **Persistence**: The CLI uses `DatabaseOpener.open(dbPath)`, which performs
    WAL recovery. This allows testing `--no-flush` behavior where data persists
    in the WAL between process invocations.
5.  **Performance**: A single `dart packages/kmdb_cli/bin/kmdb.dart` invocation
    takes ~0.7s. 3000+ invocations will take ~35 minutes. This confirms the need
    for a separate `test/e2e/` directory and `@Tags(['e2e'])`.
6.  **Batch Mode**: Interpreted as multiple sequential process invocations to
    simulate a user session without using internal scripting (`--read`) or
    piping.

### Key Files:

- `packages/kmdb_cli/bin/kmdb.dart`: The binary entry point.
- `packages/kmdb_cli/lib/src/cli_runner.dart`: The logic for handling global
  flags and command dispatch.
- `packages/kmdb_cli/lib/src/commands/put_command.dart`: Handles document
  insertion and ID assignment.
- `packages/kmdb_cli/lib/src/commands/scan_command.dart`: Handles bulk retrieval
  and filtering.

### Edge Cases & Risks:

- **Locking**: Sequential runs must ensure the previous process has fully
  released the database lock.
- **Output Parsing**: CLI output (JSON, NDJSON, Table) needs to be reliably
  parsed by the test harness to verify results.
- **Resource Cleanup**: The test should use a temporary directory and ensure
  it's cleaned up even on failure.

## Implementation plan

- [x] **Setup Infrastructure**
  - [x] Create `packages/kmdb_cli/test/e2e/` directory.
  - [x] Create `cli_session_test.dart` with `@Tags(['e2e'])`.
  - [x] Implement `CliHarness` helper to run commands via `Process.run` and
        parse JSON output.
- [x] **Synthetic Data Generation**
  - [x] Implement `NoteGenerator` (1000 records).
  - [x] Implement `ReadingListGenerator` (1000 records).
  - [x] Implement `ShoppingListGenerator` (1000 records).
- [x] **Phase 1: Ingestion**
  - [x] Insert 3000 records across 3 collections.
  - [x] Randomly alternate between `--flush` and `--no-flush`.
  - [x] Capture 10% of IDs for each collection for later verification.
- [x] **Phase 2: Point Lookups**
  - [x] `get` all captured IDs and verify content matches.
  - [x] `get` 10 non-existent IDs and verify "not found" errors.
- [x] **Phase 3: Bulk Operations**
  - [x] `count` each collection and verify it equals 1000 (adjusting for mixed
        deletions).
  - [x] `scan` with filters (e.g., specific tags or quantity ranges) and verify
        results.
  - [x] Test different output modes (`--mode ndjson`, `--mode table`).
- [x] **Phase 4: Deletion**
  - [x] `delete` a subset of captured records.
  - [x] Verify deleted records are gone via `get` and `count`.
- [x] **Phase 5: Maintenance**
  - [x] Run `flush`, `compact`, and `verify` commands.
  - [x] Ensure database remains consistent.

## Summary

- Created `packages/kmdb_cli/test/e2e/cli_session_test.dart` to simulate a
  non-trivial user session.
- Implemented synthetic data generators for `notes`, `reading_list`, and
  `shopping_list`.
- Configured the test to run multiple CLI invocations (3000+ commands) to test
  ingestion, persistence, lookups, filtering, and deletion.
- Added `@Tags(['e2e'])` and configured `dart_test.yaml` to exclude these tests
  by default due to their long execution time.
- Verified CLI output modes (JSON, NDJSON, Table) and flush/no-flush behavior.
- Mixed ingestion with point lookups and deletions to better replicate human
  usage.
