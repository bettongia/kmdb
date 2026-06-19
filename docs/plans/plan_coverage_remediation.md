# Coverage Remediation: 87.6% → >95%

**Status**: Investigated

**PR link**: TBD

## Problem statement

Following the Flutter package extraction restructure, overall test coverage has
dropped to 87.6% (8,878 / 10,139 instrumented lines). The project requires a
minimum of 90% and targets >95%. Key low-coverage areas are:

- `packages/kmdb_cli/lib/src/cli_runner.dart` — 19.7% (40/203)
- `packages/kmdb_cli/lib/src/commands/encryption_command.dart` — 6.4% (3/47)
- `packages/kmdb/lib/src/test_support/gated_sync_adapter.dart` — 0% (0/45)
- `packages/kmdb/lib/src/test_support/sync_adapter_conformance.dart` — 55.4% (134/242)
- `packages/kmdb/lib/src/search/lexical/fts_manager.dart` — 78.3% (322/411)
- `packages/kmdb/lib/src/cache/cache_layer.dart` — 73.9% (51/69)
- Several CLI commands, REPL components, and engine files in the 62–90% range.

Coverage must improve while tests exercise real failure modes — not just
golden-path coverage. To close the gap we need to cover roughly 750 additional
lines.

## Open questions

These were raised by the 2026-06-19 reviewer pass (see Review section below).
All six are resolved below; the plan returns to `Investigated`.

- [x] **Q1 — In-process output-capture harness.**
  **Decision: use `IOOverrides.runZoned` with `StringBuffer`-backed sinks.**
  Define one shared helper in `cli_runner_inprocess_test.dart`:
  ```dart
  Future<({int code, String out, String err})> _run(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await IOOverrides.runZoned(
      () => KmdbCli.run(args),
      stdout: () => _BufferSink(out),
      stderr: () => _BufferSink(err),
    );
    return (code: code, out: out.toString(), err: err.toString());
  }
  ```
  Where `_BufferSink` is a minimal `IOSink` wrapper that writes to a
  `StringBuffer`. Scenarios that assert on printed text (version string, usage,
  error messages, recovery code on stderr) use `result.out` / `result.err`.
  Scenarios that only care about exit code omit the buffer checks. This approach
  is consistent with how `IOOverrides` is used in the Dart SDK test suite and
  requires no production-code changes.

- [x] **Q2 — Synchronous stdin in encryption tests.**
  **Split confirmed:**
  - **In-process** (`encryption_command_test.dart` calling `EncryptionCommand`
    / `_ChangePassphraseCommand` via `CommandContext` directly): no-subcommand
    error, unknown-subcommand error, non-encrypted-DB guard. These three return
    before any call to `_readPassword()`.
  - **Subprocess** (`cli_runner_test.dart` extension, using `Process.run` with
    `stdin: piped`): empty new passphrase, mismatched confirmation, wrong current
    passphrase, success path. Subprocess tests pipe lines to the process's stdin
    stream, which feeds `readLineSync()` correctly and can run in CI without a
    tty.
  The in-process file covers the command's dispatch/guard logic (lines 36–75 of
  `encryption_command.dart`); the subprocess file covers the prompt-reaching
  `_ChangePassphraseCommand` body (lines 109–196).

- [x] **Q3 — stdin-pipe blocking in Group A.**
  **Confirmed safe.** In-process, `KmdbCli.run` blocks on stdin only when
  `remaining.length == 1` (just `<db>`, no command tokens) AND `readPath == null`
  AND `!io.stdin.hasTerminal` (always true in a test isolate). Every Group A
  scenario avoids this:
  - *Early-exit scenarios* (before any db is opened or stdin is read):
    `--version`, `--help`/`-h`, `help`, `help <cmd>`, no-args, bad flag-in-db,
    `--format invalid`, any missing-value flag, mutual-exclusion guard.
  - *Inline-token scenarios* (remaining.length > 1, never hits stdin branch):
    `--format=json`, `--passphrase=mypass`, `--no-flush`, config-parse-error
    scenario, `--output <file>`, `--continue-on-error`, encrypted-init,
    bad-passphrase, lock-error, unknown-open-error — all include a command token
    after the db path (e.g. `<db> scan ns` or `<db> init`).
  - *`--read <file>` scenarios*: populate `readPath`, which takes precedence over
    stdin. Safe.
  Add a comment at the top of the in-process test file: *"Every test must supply
  inline tokens, `--read`, or an early-exit flag. Bare-`<db>` (REPL path) is
  subprocess-only — the tty detection always reads stdin in a test isolate."*

- [x] **Q4 — Cover vs. ignore test-only `lib/` scaffolding.**
  **Policy: pursue coverage first, ignore only pure-boilerplate residue.**
  - `sync_adapter_conformance.dart` (lines 298–490): adding
    `expectsCancellation: true` to the `MemorySyncAdapter` test exercises all
    108 uncovered lines. Do this — it validates real cancellation behaviour and
    is worth the test run time.
  - `gated_sync_adapter.dart` (all 45 lines): the cancellation conformance run
    exercises the 6 `SyncStorageAdapter` method bodies. The barrier-control
    methods (`holdX`, `releaseX`, `providesAtomicCas`) are covered by the direct
    unit test in Group B. After both are implemented, confirm all 45 lines are
    covered. If any lines remain uncovered (e.g. early-return guards in
    `releaseX` when already completed), apply line-level `// coverage:ignore`
    annotations rather than file-level ignore, so the behaviour-bearing code
    stays in coverage accounting.
  - Do NOT apply `// coverage:ignore-file` to either file — unlike `spinner.dart`
    and `input_reader.dart` (which wrap tty I/O that cannot be exercised in
    tests), these files contain real logic under test.

- [x] **Q5 — Coverage is measured per-package, lib-only.**
  **Confirmed.** `scripts/combine_coverage.sh` aggregates per-package `lcov.info`
  files; each package's coverage counts only its own `lib/` exercised by its own
  `dart test` run. The Drive and iCloud packages passing `expectsCancellation:
  true` in their own test suites contributes to *their* coverage numbers, not
  `kmdb`'s. Group B's +120-line gain comes entirely from adding
  `expectsCancellation: true` to `memory_sync_adapter_test.dart` inside the
  `kmdb` package.

- [x] **Q6 — Release-checklist obligation.**
  **No new RC entries required.** The subprocess encryption tests (Q2) pipe stdin
  via `Process.run(stdin: ...)` and run headlessly in CI — they are fully
  automatable, not tty-dependent, and do not qualify for an RC entry. The REPL
  unit tests in Group F use `FakeInputReader` (the existing injection seam in
  `ReplRunner`'s constructor) and are likewise fully automatable. The only
  truly non-automatable REPL path (raw-mode terminal with `TtyInputReader`) is
  already covered by the existing subprocess test suite; no new RC entry is
  needed. RC-16 remains the last checklist entry.

## Investigation

### Coverage baseline

```
Overall: 87.6%  (8,878 / 10,139 lines)
Target:  95.0%  → need at least 9,632 lines covered
Gap:     754 lines to cover
```

### Root-cause analysis

**1. `cli_runner.dart` (163 uncovered lines)**

The existing `cli_runner_test.dart` spawns a subprocess per test
(`io.Process.run`). Coverage instrumentation only runs in the test isolate, so
no subprocess execution contributes to `cli_runner.dart` coverage. The 40 lines
that are covered are hit by other tests that import CLI utilities directly.

Fix: add a parallel in-process test file that calls `KmdbCli.run(...)` directly
within the test isolate using real tmpdir databases. The subprocess test suite
stays (it validates the actual binary), but the in-process suite drives coverage.

**2. `gated_sync_adapter.dart` (0% in `lib/`)**

> Reviewer correction (2026-06-19): the original framing here was inaccurate and
> is corrected below. `memory_sync_adapter_test.dart` *does* import the lib copy
> (`package:kmdb/test_support.dart`, which exports
> `lib/src/test_support/...`). The real reason for the gap is purely the
> `expectsCancellation` default, plus the per-package coverage model.

Root cause:
- `runSyncAdapterConformance()` is called by every kmdb-internal caller without
  `expectsCancellation: true` (default `false`), so the cancellation group —
  which wraps the adapter under test in a `GatedSyncAdapter` — never runs inside
  the `kmdb` package's own test process.
- Coverage is measured per package, lib-only (`scripts/combine_coverage.sh`).
  The Drive and iCloud packages *do* pass `expectsCancellation: true` against
  the same exported lib code, but that coverage counts toward *their* packages,
  not `kmdb`. So `kmdb`'s lib copy stays at 0%/55.4%.
- A stale duplicate exists at `test/support/gated_sync_adapter.dart` (used only
  by `sync_cancellation_integration_test.dart` via relative import). It is not
  the cause of the gap but is redundant; consider noting it for cleanup.

Fix: add `expectsCancellation: true` to the `MemorySyncAdapter` conformance
call in `memory_sync_adapter_test.dart` (it already imports the lib path) and
add a direct `GatedSyncAdapter` unit test importing from the `lib/` path to
cover barrier control, pass-through, and cancellation propagation. See Open
question Q4 on whether residual boilerplate lines should be `coverage:ignore`d
rather than tested.

**3. `sync_adapter_conformance.dart` (55.4% in `lib/`)**

The 108 uncovered lines are all in the `cancellation` conformance group (lines
298–490) — guarded by `if (expectsCancellation)`. Since no caller passes
`expectsCancellation: true`, this group has never run against the lib/ version.

Fix: same as above — `expectsCancellation: true` in `MemorySyncAdapter` test.

**4. `fts_manager.dart` (89 uncovered lines)**

Missing: field-removed-during-update branch, field-added-to-doc branch,
`_interceptDelete`, `compact()`, `applyDelta()`, and
`checkAndTransitionOnOpen()` crash recovery (syncing → stale transition).

**5. `encryption_command.dart` (44 uncovered lines)**

Almost entirely untested. The command dispatches to `EncryptionCommand` and
`_ChangePassphraseCommand`. No-sub-command error, unknown-sub-command error, and
the non-encrypted-DB guard are all testable without stdin interaction. The
interactive passphrase prompts (`_readPassword()`) require piped stdin, which
the subprocess-style tests already support.

**6. `cache_layer.dart` (18 uncovered lines)**

The 18 uncovered lines are all `KvStore` delegate forwarders:
`setTombstoneHorizonProvider`, `setVersionDropCallback`,
`setVersionRegistryProvider`, `scanVersionHistory`, `resetTombstoneFloor`,
`ingestSstable`, `dropAllSstables`, `createNamespace`, `reassignDeviceId`.
These are exercised through `KmdbDatabase` in integration tests but never
directly in `cache_layer_test.dart`.

**7. REPL and CLI commands (spread across ~40 files)**

`repl_runner.dart` (44 uncovered), `search_command.dart` (34), `remote_command.dart` (35),
`dump_command.dart` (27), `export_command.dart` (22), `insert_command.dart` (21),
`update_command.dart` (16), dot-command handlers (~40 combined), etc. These are
all missing error-branch and edge-case tests.

**8. Engine and query layer (spread across ~15 files)**

`LsmEngine` (35 uncovered), `IndexManager` (29), `KmdbDatabase` (28),
`KmdbCollection` (25), `MetaStore` (16), `StorageAdapterNative` (15),
`KmdbQuery` (19), `VaultPackage` (17), `KvStoreImpl` (14), `WalReader` (10),
`VersionEdit` (7), `SstableInfo` (6). These are resilience-oriented gaps:
corrupt input, missing metadata, error propagation paths.

### Coverage-to-target mapping

Estimated lines recoverable per group (conservative):

| Group | Target files | Uncovered | Estimated gain |
|-------|-------------|-----------|----------------|
| A — CLI runner in-process | `cli_runner.dart` | 163 | +130 |
| B — Cancellation conformance + GatedSyncAdapter | both `test_support/` files | 153 | +120 |
| C — FTS manager edge cases | `fts_manager.dart`, `fts_index_state.dart` | 98 | +88 |
| D — Encryption command + CLI error paths | `encryption_command.dart`, various CLI | ~80 | +60 |
| E — Cache layer delegates | `cache_layer.dart` | 18 | +18 |
| F — REPL and dot commands | `repl_runner.dart`, dot-cmd files | ~86 | +60 |
| G — Engine / query resilience | 15 engine+query files | ~160 | +100 |
| H — CLI command edge cases | remote/dump/search/export/insert/update | ~155 | +100 |
| **Total** | | **~913** | **~676** |

Reaching >95% (754-line gap) requires executing all groups. The estimate is
deliberately conservative; overlap between groups and easy-to-cover lines not
itemised above push the actual gain above the target.

## Implementation plan

Work is ordered by impact-per-effort. Complete and verify each group before
moving to the next. Run `make coverage` after each group to confirm progress.

### Group A — CLI runner in-process tests (highest impact)

**New file**: `packages/kmdb_cli/test/cli_runner_inprocess_test.dart`

This file calls `KmdbCli.run(...)` directly within the test process using real
tempdir databases, giving full coverage instrumentation of `cli_runner.dart`.

**Harness requirement (Q1):** All scenarios use the following shared helper,
which captures `io.stdout`/`io.stderr` via `IOOverrides.runZoned`:

```dart
// _BufferSink is a minimal IOSink wrapper that appends to a StringBuffer.
Future<({int code, String out, String err})> _run(List<String> args) async {
  final out = StringBuffer(), err = StringBuffer();
  final code = await IOOverrides.runZoned(
    () => KmdbCli.run(args),
    stdout: () => _BufferSink(out),
    stderr: () => _BufferSink(err),
  );
  return (code: code, out: out.toString(), err: err.toString());
}
```

**Blocking constraint (Q3):** Every test must supply inline tokens, `--read`, or
be an early-exit scenario. Bare-`<db>` (REPL path) is subprocess-only — the
tty detection always reads stdin in a test isolate.

- [ ] `_BufferSink` helper class: minimal `IOSink` writing to a `StringBuffer`.
- [ ] `_run` helper + tmpdir setUp/tearDown pattern.
- [ ] `--version` → exit 0; `out` contains version string.
- [ ] `--help` / `-h` → exit 0; `out` or `err` contains usage text.
- [ ] `help` (positional) → exit 0; usage printed.
- [ ] `help <command>` → exit 0; command-specific help printed.
- [ ] No args → exit 1; usage printed.
- [ ] DB path starts with `-` → exit 1; `err` contains "unknown flag".
- [ ] `--format invalid` → exit 1; `err` contains error.
- [ ] `--format` with no value → exit 1.
- [ ] `--output` with no value → exit 1.
- [ ] `--passphrase` with no value → exit 1.
- [ ] `--recovery-code` with no value → exit 1.
- [ ] `--read` with no value → exit 1.
- [ ] `--passphrase` + `--recovery-code` together → exit 1; `err` contains
  "mutually exclusive".
- [ ] `--format=json` inline-equals form → exit 0 for a valid command.
- [ ] `--passphrase=mypass` inline-equals form → parsed correctly.
- [ ] `--no-flush` flag honoured (close path taken without flush).
- [ ] Config parse error → exit 0 with warning in `err`; command still runs.
- [ ] `--read <script.kmdb>` executes a multi-line command file; each line runs.
- [ ] `--read` file not found → exit 1; `err` contains "file not found".
- [ ] `--output <file>` writes command output to that file (not `out` buffer).
- [ ] `--continue-on-error`: two commands where first fails → both run, exit 1.
- [ ] Inline tokens dispatched: `<db> scan ns` succeeds and exits 0.
- [ ] `<db> init --passphrase <pp>` on new DB → exit 0; `err` contains recovery
  code.
- [ ] `--passphrase <pp> <db> scan ns` on existing encrypted DB → exit 0.
- [ ] `--recovery-code <rc> <db> scan ns` on existing encrypted DB → exit 0.
- [ ] Wrong passphrase on encrypted DB → exit 1; `err` contains encryption error.
- [ ] Unknown DB-open error (simulate via non-creatable path) → exit 1; catch-all
  error message in `err`.
- [ ] REPL path (stdin = tty) is NOT tested in-process; covered by the existing
  subprocess test suite.

### Group B — Cancellation conformance + GatedSyncAdapter

**Edit**: `packages/kmdb/test/sync/memory_sync_adapter_test.dart`
- [ ] Add `expectsCancellation: true` to the `runSyncAdapterConformance` call.
  This exercises the full lib-path cancellation group including all six
  mid-flight barrier tests, covering `sync_adapter_conformance.dart` lines
  298–490 and all 45 lines in `gated_sync_adapter.dart`.

**New file**: `packages/kmdb/test/support/gated_sync_adapter_lib_test.dart`
(imports from `package:kmdb/src/test_support/gated_sync_adapter.dart`, not the
local copy, to ensure the lib/ version is exercised)

- [ ] Barrier control: `holdList()` blocks and `releaseList()` unblocks.
- [ ] Pass-through without a barrier: all 6 methods delegate to inner adapter.
- [ ] `releaseX()` is idempotent when barrier is already completed.
- [ ] Each barrier independently; releasing one does not release others.
- [ ] `providesAtomicCas` delegates to the inner adapter.
- [ ] Cancellation via `SyncContext`: hold barrier, cancel context, verify
  `SyncCancelledException` is thrown on the future (not synchronously on the
  cancel caller).
- [ ] Cancellation without a `SyncContext` (no ctx): barrier blocks until released.
- [ ] After cancellation wakes the barrier, the delegate is NOT called.

### Group C — FTS manager edge cases

**Edit**: `packages/kmdb/test/search/lexical/fts_manager_test.dart`

- [ ] `checkAndTransitionOnOpen` crash-recovery: open a DB, manually write a
  `syncing` state to `$meta`, close, reopen → state transitions to `stale`.
- [ ] Update where the FTS field is **removed** in the new document → tombstone
  written; BM25 score for deleted term drops to zero after next query.
- [ ] Update where the FTS field is **added** in the new document (was null/absent)
  → treated as fresh insert; document becomes retrievable.
- [ ] `_interceptDelete`: delete a document that has FTS entries → doc no longer
  returned by search; corpus stats updated correctly.
- [ ] `compact()`: base entries reflect overlay, overlay cleared post-compact;
  verify corpus stats are stable across multiple updates + compact cycles.
- [ ] `applyDelta()` mid-sync state: index enters `syncing`; after delta applied,
  transitions back to `current`; queries during sync return pre-delta results.
- [ ] **Fault injection**: crash during `compact()` (use `FaultyStorageAdapter` to
  fail mid-write) → index enters `stale`; subsequent rebuild returns correct
  results.

**Edit**: `packages/kmdb/test/search/lexical/` — add to pipeline or index state test:

- [ ] `FtsIndexState.copyWith`: each of the three optional fields overridden
  independently; non-overridden fields unchanged.
- [ ] `FtsIndexState.fromBytes` with populated `builtThrough` and `builtAt`
  → fields round-trip correctly.
- [ ] `FtsIndexState.fromBytes` with unknown `status` string → falls back to
  `undefined`.
- [ ] Key generators `baseKey`, `overlayKey`, `corpusKey`, `docKey` all produce
  expected string formats.

### Group D — Encryption command + EncryptionError paths

**In-process split (Q2):** Three scenarios are testable in-process (they return
before any call to `_readPassword()`); the rest require subprocess piped stdin.

**In-process** — **New file**: `packages/kmdb_cli/test/commands/encryption_command_test.dart`

Call `EncryptionCommand().execute(ctx, ...)` directly via a `CommandContext`
backed by a test `KmdbDatabase` (no stdin interaction for these cases):

- [ ] `encryption` with no sub-command → returns false; error written to ctx.
- [ ] `encryption unknown-sub` → returns false; error contains "Unknown
  encryption sub-command".
- [ ] `encryption change-passphrase` on **non-encrypted** DB (ctx.db.encryption
  == null) → returns false; error contains "requires an encrypted database".

**Subprocess** — **New group in** `packages/kmdb_cli/test/cli_runner_test.dart`
(uses `Process.run` with piped `stdin` to feed `readLineSync()`):

- [ ] Setup: create encrypted DB with `init --passphrase correct_pass`.
- [ ] Empty new passphrase (pipe `\n\n`): exit 1; stderr contains "must not be
  empty".
- [ ] Mismatched confirmation (pipe `new_pass\ndifferent\n`): exit 1; stderr
  contains "do not match".
- [ ] Wrong current passphrase (pipe `new\nnew\nwrong\n`): exit 1; stderr
  contains encryption error.
- [ ] Success path (pipe `new_pass\nnew_pass\ncorrect_pass\n`): exit 0; old
  passphrase can no longer open DB; new passphrase succeeds.
- [ ] `--passphrase wrong_pass <encrypted_db> scan ns` → exit 1 with encryption
  error (already in process, no stdin needed).

**Edit**: `packages/kmdb/test/encryption/` (if separate encryption error tests
exist) — cover `EncryptionError` message variants (lines 76, 85, 94, 103, 116):

- [ ] Each `EncryptionError` subtype / factory produces the expected `toString()`.

### Group E — Cache layer delegates

**Edit**: `packages/kmdb/test/cache/cache_layer_test.dart`

- [ ] `setTombstoneHorizonProvider` delegates to inner store (verify the
  underlying store's callback is set by calling a low-level scan that honours it).
- [ ] `setVersionDropCallback` delegates (verify callback is called when versions
  are dropped during compaction).
- [ ] `setVersionRegistryProvider` delegates (verify provider is consulted).
- [ ] `scanVersionHistory` delegates — returns the same entries as the underlying
  store's `scanVersionHistory`.
- [ ] `resetTombstoneFloor` delegates and completes without error.
- [ ] `ingestSstable` delegates — small SSTable ingested via cache layer is
  accessible via `get`.
- [ ] `dropAllSstables` delegates — `get` returns null for all keys after drop.
- [ ] `createNamespace` delegates — returns true for new namespace.
- [ ] `reassignDeviceId` delegates and completes without error.

### Group F — REPL and dot commands

**Injection seam confirmed (Q3):** `ReplRunner` accepts an optional `InputReader`
parameter; `FakeInputReader` is the test double. Use it to feed pre-loaded
command lines without any stdin interaction. The tty path (`TtyInputReader`) is
not testable in-process and is already excluded.

**Edit**: `packages/kmdb_cli/test/repl/repl_runner_test.dart`

- [ ] Command that returns false (`success=false`) → REPL records error, continues
  if `continueOnError` is set.
- [ ] `.mode` command with an invalid mode string → error message without crash.
- [ ] `.exit` / `.quit` terminates the REPL (FakeInputReader returns `.quit`).
- [ ] Multiline continuation: `FakeInputReader` feeds a line ending with `\` then
  a second line; REPL joins them before dispatch.
- [ ] REPL dispatches to `_executeCommandLine` for non-dot commands.

**Edit / new tests** for dot commands in
`packages/kmdb_cli/test/repl/dot_commands/`:

- [ ] `database_commands.dart`: `.open` on a non-existent path error; `.close`
  when no DB open; `.db` shows current path.
- [ ] `toggle_commands.dart`: each toggle that starts `on` can be turned `off`
  and vice versa; invalid value produces error.
- [ ] `limit_command.dart`: negative limit → error; non-integer → error.
- [ ] `output_command.dart`: all valid format strings accepted; invalid string
  → error.
- [ ] `history_command.dart`: `.history clear` clears history; `.history show`
  without entries shows empty.
- [ ] `help_command.dart`: `.help <unknown-command>` shows "not found".
- [ ] `collection_command.dart`: `.collection <unknown>` shows error.
- [ ] `io_commands.dart`: `.read` with nonexistent file → error.
- [ ] `color_command.dart`: `.color off` and `.color on` toggle without error.
- [ ] `completer.dart`: completions for partial command names; completion when no
  matching command exists returns empty; multi-word completion.

### Group G — Engine and query layer resilience

These tests must use `FaultyStorageAdapter` or real tmpdir adapters — not
`MemoryStorageAdapter` — to expose crash-safety gaps (per the 2026-05-22 review
mandate).

**WAL Reader** (`packages/kmdb/test/engine/wal/`) — add to existing WAL tests:

- [ ] Truncated WAL frame (corrupt length prefix) → recovery skips that frame,
  returns data up to last complete frame.
- [ ] CRC mismatch in WAL frame → frame silently dropped; prior frames replayed.
- [ ] WAL file that is entirely empty → treated as no WAL, no crash.
- [ ] Multiple WAL files where second has valid frames after the first's corruption.

**MetaStore** (`packages/kmdb/test/engine/kvstore/`) — add to existing meta tests:

- [ ] `getDeviceId` when `$meta` namespace is absent → generates and persists a
  new device ID.
- [ ] `getGenerationCounter` when no counter entry exists → returns 0.
- [ ] `incrementGenerationCounter` rolls over safely at max uint64 (if applicable).
- [ ] `putRawByName` / `getRawByName` round-trip for arbitrary names.

**IndexManager** (`packages/kmdb/test/query/`) — add:

- [ ] Index queried while in `building` state → fallback full-scan returns
  correct results.
- [ ] Index transitions `undefined` → `building` → `current` on first query.
- [ ] Two concurrent queries during index build do not double-build.
- [ ] Writes during build transition index to `stale`; next query triggers rebuild.
- [ ] `dropIndex` on an already-undefined index is a no-op.

**KmdbDatabase** (`packages/kmdb/test/query/`) — add:

- [ ] `close()` is idempotent (calling twice does not throw).
- [ ] `collection()` with an unregistered codec raises a clear error.
- [ ] `open()` with an empty `ftsIndexes` list opens without error.
- [ ] `changePassphrase()` on a non-encrypted DB raises `EncryptionError`.

**KmdbCollection** (`packages/kmdb/test/query/`) — add:

- [ ] `put()` with a document that fails schema validation → `SchemaViolationError`
  is thrown; document NOT persisted.
- [ ] `putAll()` partial failure: schema-invalid doc in batch aborts entire batch.
- [ ] `delete()` on a key that does not exist → silent no-op.
- [ ] `watch()` stream emits on write to the collection namespace; stream closes
  on `db.close()`.

**KmdbQuery** (`packages/kmdb/test/query/`) — add:

- [ ] `count()` on empty collection → 0.
- [ ] `any()` on empty collection → false.
- [ ] `first()` on empty collection throws `StateError`.
- [ ] `orderBy` on a field that does not exist in all documents → documents without
  the field sort consistently (null-last or null-first).
- [ ] Filter with `Filter.not()` wrapping a nested filter.
- [ ] `offset` beyond result count → empty list.

**StorageAdapterNative** (`packages/kmdb/test/engine/`) — add:

- [ ] `list()` on a non-existent directory → returns empty list (not throws).
- [ ] `upload()` creates parent directories if missing.
- [ ] `download()` returns null for a missing file (not throws).
- [ ] `delete()` on a missing file → no-op (not throws).
- [ ] `compareAndSwap` on a path under a read-only directory → returns false or
  rethrows a storage error (not uncaught).

**LsmEngine** — add to existing engine tests:

- [ ] `ingestSstable` with a file whose keyspace overlaps existing L2 → merge
  produces correct read-back.
- [ ] `dropAllSstables` then write → new SSTables created; old data absent.
- [ ] `reassignDeviceId` on an open store → subsequent flush produces new
  device-prefix filenames.

**SstableInfo / VersionEdit** — add to existing SSTable tests:

- [ ] `SstableInfo.fromFilename` with a 3-segment name (regular flush) round-trips.
- [ ] `SstableInfo.fromFilename` with a 4-segment name (consolidation) round-trips.
- [ ] `VersionEdit` CBOR round-trip includes all fields (addedFiles, removedFiles,
  logNumber, nextFileNumber).

**VaultPackage** — add to existing vault tests:

- [ ] `VaultPackage.open()` with a corrupt KVLT footer → `FormatException`.
- [ ] `VaultPackage` with zero-length payload → stored and retrieved correctly.
- [ ] Ref count not decremented below zero on double-GC of the same blob.

### Group H — CLI command edge cases

**Remote command** (`packages/kmdb_cli/test/commands/remote_command_test.dart`):

- [ ] `remote add` with a name that already exists → error / overwrite behaviour.
- [ ] `remote remove <nonexistent>` → error "not found".
- [ ] `remote list` when no remotes configured → empty output (not crash).
- [ ] `remote add` with an invalid URL scheme → validation error.
- [ ] `remote show <name>` displays remote details.

**Dump command** (`packages/kmdb_cli/test/dump_command_test.dart`):

- [ ] Dump with `--from` / `--to` range filtering → only keys in range emitted.
- [ ] Dump with `--namespace` filter → only matching namespace emitted.
- [ ] Dump on an empty DB → empty output + exit 0.
- [ ] Dump in `table` and `csv` output modes → format matches expectations.

**Search command** (`packages/kmdb_cli/test/commands/search_command_test.dart`):

- [ ] Search with `--mode semantic` on a DB with no vector index → friendly error.
- [ ] Search with `--mode hybrid` exercises hybrid scoring path.
- [ ] `--limit` flag caps results.
- [ ] `--threshold` flag filters out low-score results.
- [ ] Search on an empty collection → empty results + exit 0.

**Export / Import command**:

- [ ] Export to a nonexistent directory → error + exit 1.
- [ ] Export + import round-trip preserves all documents and metadata.
- [ ] Import from a corrupt file → error + exit 1, no partial writes.

**Insert command**:

- [ ] `insert` with `--stdin` reads JSON from piped input.
- [ ] `insert` with `--batch` reads multiple documents.
- [ ] `insert` with an invalid JSON body → parse error + exit 1.
- [ ] `insert` into a namespace with schema validation → schema-violating document
  rejected.

**Update command**:

- [ ] `update` on a key that does not exist → "not found" error.
- [ ] `update` with an invalid patch JSON → parse error.
- [ ] `update` with a merge flag applies partial patch correctly.

**Collections command**:

- [ ] `collections` on a DB with no user namespaces → empty output.
- [ ] `collections` with `--stats` flag shows document counts.

**Remote config** (`packages/kmdb_cli/test/config/remote_config_test.dart`):

- [ ] `RemoteConfig.load` from a file with a malformed URL → `FormatException`.
- [ ] `RemoteConfig.save` followed by `load` round-trips all fields.
- [ ] `RemoteConfig.remove(nonexistent)` → no-op or explicit error (document
  expected behaviour).

**Vault import helper**:

- [ ] Import a KVLT file with an unknown blob type → skipped or error (document
  actual behaviour).
- [ ] Import with duplicate blob SHA → idempotent (second import no-ops).

## Coverage tracking

Run `make coverage` after each group and record the running total. Do not start
the next group if the previous group's gain was more than 20 lines below its
estimate — instead, add targeted tests for that group's files before proceeding.

- [ ] After Group A: expect ≥ 89% (baseline 87.6% + ~1.3%).
- [ ] After Group B: expect ≥ 90.5%.
- [ ] After Group C: expect ≥ 91.5%.
- [ ] After Groups D + E: expect ≥ 93%.
- [ ] After Groups F + G + H: expect ≥ 95%.
- [ ] **Contingency**: if the cumulative total after Group H is below 95%, consult
  the per-file coverage summary (`site/coverage/index.html`) and add targeted
  tests for the files still below 90% before declaring done. Do not declare the
  plan complete until `make coverage` reports ≥ 95.0%.

```bash
make coverage
```

## Notes on test quality

- All new tests that touch storage/sync paths must use a real filesystem
  adapter (tmpdir) or `FaultyStorageAdapter`, not `MemoryStorageAdapter` alone.
  This is a hard requirement from the 2026-05-22 code review
  (`docs/reviews/code-review-2026-05-22.md`).
- Error-path tests must assert both the thrown exception type and that no
  partial state was committed (i.e., subsequent reads return the pre-error value).
- Cancellation tests must verify that the exception is delivered to the
  awaiting future, not synchronously to the cancel caller — use
  `expectLater(..., throwsA(...))` pattern, not `expect(() => ..., throws...)`.
- REPL tests should avoid relying on real stdin; use the `ReplRunner` test
  adapter pattern (if one exists) or inject a `StringReader` instead.

## Review (2026-06-19, kmdb-plan-reviewer)

**Status set to `Questions`.** The plan is unusually well-grounded — the lcov
baseline, root causes, and method/file names are accurate — but it is not yet
safe for a mechanical Sonnet implementer because the central new test technique
(in-process `KmdbCli.run`) has undefined harness mechanics, and a subset of the
specified scenarios are physically untestable as written. Resolve Q1–Q6, then
return to `Investigated`.

### Problem statement assessment

Real and worth solving. Coverage at 87.6% is above the 90% *spec floor only by
rounding* — actually below it — and the project mandates 90% minimum / >95%
target. The drop after the package extraction is a legitimate regression. Scope
is appropriate (test-only changes; no production behaviour change). Good.

One nuance the statement glosses: a meaningful share of the gap lives in
*test-only* code shipped in `lib/` (the two `test_support/` files = 287
instrumented lines). Whether to *cover* or *exclude* that code is a real
decision (Q4), and it changes the line math.

### Proposed solution assessment

Strengths:
- Root-cause analysis is genuinely investigated, not guessed. Verified accurate:
  the lcov totals (8,878/10,139 = 87.6%), every cited denominator (203, 47, 45,
  242, 411, 69), `KmdbCli.run`'s signature, the `expectsCancellation` default,
  the `FtsManager` methods (`applyDelta`, `compact`, `checkAndTransitionOnOpen`,
  `_interceptDelete`), the `FtsIndexState` API, all nine `cache_layer` delegate
  names, and `FaultyStorageAdapter`'s existence.
- The quality bar is correctly stated: FaultyStorageAdapter / tmpdir over
  MemoryStorageAdapter (matches the 2026-05-22 review mandate), assert-no-
  partial-state on error paths, and the cancellation `expectLater`/`throwsA`
  pattern. These are exactly right.
- Ordering by impact-per-effort with a `make coverage` checkpoint after each
  group is sound.

Weaknesses (the blockers):
- **No output-capture harness is specified (Q1).** This is the single biggest
  gap. `KmdbCli.run` writes to the global `io.stdout`/`io.stderr` getters; no
  existing test captures them. Roughly a third of Group A and most of Group D
  assert on printed text. Without a defined `IOOverrides.runZoned` helper, the
  implementer must invent one — exactly the kind of architecture-on-the-fly the
  `Investigated` bar forbids.
- **Several specified scenarios cannot run in the file they are listed under
  (Q2, Q3).** `encryption change-passphrase` reads stdin via *synchronous*
  `readLineSync()`, which `IOOverrides` cannot feed in-process — so the empty/
  mismatch/wrong-current/success scenarios are subprocess-only, yet they are
  listed under the in-process `encryption_command_test.dart`. Likewise bare-
  `<db>` in-process scenarios would block on the stdin-pipe branch. The plan
  half-acknowledges the stdin issue in prose but then mis-files the scenarios.
- **Factual error in root cause #2** (now corrected inline): the claim that the
  suite "never imports the lib path" is false for `memory_sync_adapter_test`.
  The real mechanism is the `expectsCancellation` default plus per-package,
  lib-only coverage measurement (Q5). Worth getting right so the implementer
  trusts the rest of the analysis.
- **Cover-vs-ignore not considered (Q4).** The project already `coverage:ignore`s
  analogous scaffolding (`repl/spinner.dart`, `repl/input_reader.dart`). For
  pure-boilerplate residue in the `test_support/` files, ignore is cheaper than
  tests. Note `input_reader.dart` being already-ignored also quietly caps what
  Group F can achieve on REPL stdin paths.

### Architecture fit

No production code changes — this is additive test work, so there is no risk to
the LSM/sync/cache invariants. The plan correctly routes storage/sync resilience
tests through `FaultyStorageAdapter`/tmpdir (Groups C, G), honouring the
durability-testing doctrine from `docs/reviews/code-review-2026-05-22.md` and
CLAUDE.md. The cancellation-delivery assertion guidance aligns with the
`SyncContext`/`throwIfExpired` model used by the Drive and iCloud adapters.

The per-package, lib-only coverage model (`scripts/combine_coverage.sh`,
`coverage:generate` with `packageFilters: dirExists: test`) is the load-bearing
architectural fact behind Group B; the plan's estimates are consistent with it
once Q5 is acknowledged explicitly.

### Risk & edge cases

- The estimate (676 gain vs. 754 needed) is *deliberately conservative and
  relies on un-itemised overlap to clear the bar* — i.e. it does not, on its own
  numbers, reach 95%. That is acceptable given the conservatism, but it means
  the `make coverage` checkpoints are not optional: if early groups under-
  deliver, the implementer must add targeted tests, and the plan should make
  that contingency explicit rather than implicit. There is genuine risk of
  landing at ~93–94% and needing an unplanned Group I.
- Several Group G/H scenarios say "document actual behaviour" or "no-op or
  explicit error" — these are *observations to encode*, not specifications.
  That is acceptable for resilience tests (the test pins whatever the code does)
  but the implementer should not treat an unexpected behaviour as a bug to fix
  under this plan (which is test-only).
- Group F leans on a "ReplRunner test adapter pattern (if one exists)" — the
  parenthetical "if one exists" is an unresolved dependency. Confirm the
  injection seam before committing to those scenarios.

### Implementation readiness

Close, but not there. The bulk (Groups C, E, G, and the exit-code-only parts of
A; the conformance one-liner in B) is mechanically executable today. The
blockers are concentrated in the in-process CLI technique (Q1–Q3) and the
cover-vs-ignore policy (Q4). These are not cosmetic — they determine whether
whole clusters of listed checkboxes are even runnable. Resolve them and the plan
clears the bar.

### Recommendations

1. Answer Q1 by committing to a single documented capture helper
   (`IOOverrides.runZoned` with `StringBuffer`-backed `IOSink`s) and reference
   it from Group A/D. This unblocks the most checkboxes.
2. Re-file the prompt-reaching encryption scenarios (Q2) under a subprocess test
   file and keep only the pre-prompt guards in-process.
3. Audit Group A for any bare-`<db>` scenario and either add tokens or move it to
   subprocess (Q3).
4. State the cover-vs-ignore policy for the `test_support/` lines (Q4) so the
   files do not end up stranded at partial coverage.
5. Add an explicit contingency line: if cumulative coverage after Group H is
   below 95%, consult the per-file summary and add targeted tests before
   declaring done (the plan implies this; make it a checklist item).
6. Reserve RC-17 in `docs/spec/28_release_checklist.md` for any subprocess/tty
   tests that the automated suite cannot exercise (Q6).

Everything else in the plan is solid and can stand as written.

## Summary

_To be filled in when implementation is complete._
