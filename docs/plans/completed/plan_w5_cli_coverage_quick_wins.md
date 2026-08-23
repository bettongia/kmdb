# W5 CLI coverage quick wins

**Status**: Complete

**PR link**: _(none yet)_

> **Provenance.** Produced by the WI-10 / W5 CLI test-**adequacy** audit
> (`kmdb-qa`, 2026-08-23), which found the roadmap's "never swept" CLI list
> largely stale: of 11 flagged areas, 6 are already behaviorally covered
> (close them — see the roadmap update), 7 are small quick-win gaps (this plan),
> and 1 is a plan-sized gap (see `plan_w5_vault_search_cli_coverage.md`).

## Problem statement

`kmdb_cli` has ~95% line coverage, but several commands have **behavioral**
gaps: specific failure paths, success branches, and flag/mode combinations that
are executed-but-not-asserted, or not exercised at all. Line coverage hides
these because a happy-path smoke test runs the line without checking what it
does. Each item below is a concrete, low-risk **test-only** addition to an
existing test file — no production code changes.

The highest-value item is #1: the poisoned-value "Skipping" guard is a
deliberate S-2 durability hardening feature (one undecodable value must not
abort a whole-collection dump/export/scan) that is currently unguarded by tests
for three of the four commands that implement it.

## Open questions

- [x] **Item #2 (search `query failed` catch) — is the throw reachable from a
      black-box CLI test, or does it need a production seam?**
      **RESOLVED (reviewer, 2026-08-23): reachable black-box, no new production
      seam. Item #2 stays in scope.** The catch is at `search_command.dart:324`
      (`ctx.writeError('search: query failed: $e')`), firing when
      `col.search(...)` throws. `KmdbCollection.search` delegates to
      `FtsManager.search`, which at `fts_manager.dart:799` calls
      `fetchDoc(scored.docId)` — i.e. `KmdbCollection.get(id)` — **unguarded**
      (it only checks `doc == null`, not a throw). `get()` calls
      `ValueCodec.decode` with no local try/catch, so an undecodable stored value
      propagates the throw all the way up into the command's catch. The injection
      is the *same* seam already used in `restore_verify_test.dart`
      (`db.store.put(ns, key, Uint8List.fromList([0xFF, 0xFE, 0xFD]))`) — a
      test-only raw write over an already-indexed document, **not** a production
      change. `KvStoreImpl.put` folds a `$$genstate` generation bump into its WAL
      frame, so the raw put invalidates the session cache and the poisoned bytes
      are actually read back (the cache cannot mask them). **Recipe caveat:** do
      the poison-and-search in a *single* db session — do **not** close/reopen
      between injection and search, because FTS indexes rebuild lazily from the
      (now garbage) source doc on reopen and would drop the term→docId posting,
      so the search would no longer match and the throw would not fire.

## Investigation

All references confirmed by the W5 audit against the current test tree
(2026-08-23) and **re-verified by the reviewer against HEAD (2026-08-23)**.
**Re-verify line numbers at implementation time** — they drift.

Existing patterns to reuse (all confirmed present):
- The undecodable-value injection pattern already exists in
  `test/restore_verify_test.dart:335` ("undecodable document":
  `db.store.put('notes', id1, Uint8List.fromList([0xFF, 0xFE, 0xFD]))`) — reuse
  it for #1 and #2. Both `test/commands/dump_command_test.dart` and
  `test/commands/export_command_test.dart` already have an `_openCtx({out, err})`
  helper returning `(KmdbDatabase, CommandContext)` with capturable `_Sink`
  buffers — use it directly.
- The `IndexCommand` group in `test/commands_test.dart` already has a
  real-temp-dir test (its `delete` case at ~`:2300`, using
  `io.Directory.systemTemp.createTempSync` + `StorageAdapterNative()` +
  `KmdbConfig.forDatabase(tmpDir.path)`) — reuse that setup for #3. For #4,
  `packages/kmdb/test/query/index_query_test.dart` shows the build-to-`current`
  pattern: open with `indexes: [IndexDefinition('c','p')]`, run a
  `col.where(Field('p').equals(...)).get()`, then `db.indexManager` reports
  `IndexStatus.current`.
- `test/cli_runner_inprocess_test.dart` has a `--read file scenarios` group
  (`:328`) with a `--continue-on-error` test (`:299`) — extend it for #5/#6.

**Reviewer corrections to the item descriptions below (verified against HEAD):**
- **#1 scan sub-case — the plan's "emits `Skipping`" assertion is WRONG for
  scan.** `dump_command.dart:98` and `export_command.dart:99` emit
  `ctx.writeError('Skipping …')` on decode failure, but `scan_command.dart`'s
  poisoned-value guard is a **silent `continue`** (`:318-320`) — no message.
  Furthermore that guard lives **only in the `--key-prefix` branch**
  (`scan_command.dart:301-326`); the no-prefix path routes through the Query
  Layer (`col.where(...)`/`col.all()`), whose own `_fullScan` handles poison —
  testing that path would exercise the Query Layer, not the CLI guard. So the
  scan test **must pass `--key-prefix`** and must assert survival + good rows
  **without** asserting any "Skipping" text.
- **#1 scan test home:** there is no `scan_command_test.dart`; the `ScanCommand`
  group lives in `test/commands_test.dart` (`:387`). Add the scan case there.
- **#7:** the existing test already asserts `output.contains('is_delete')`
  (`versioning_command_test.dart:87`), but `versions_command.dart:78` emits the
  `is_delete` label for *every* version, so that only proves the label exists,
  not the `true` value. The real gaps are (a) a **deleted** key rendering
  `is_delete: true` and (b) `promoted_from` rendering (`versions_command.dart:80`
  only emits it when `promotedFrom != null`).

## Implementation plan

Each item is one or two `test()` cases added to the named existing file.

- [x] **#1a — dump poisoned-value "Skipping" guard** (`dump_command.dart:97-99`,
      standard NDJSON path). In `test/commands/dump_command_test.dart`: via
      `_openCtx`, insert one good doc through the collection API, then
      `db.store.put('<coll>', '<key>', Uint8List.fromList([0xFF, 0xFE, 0xFD]))`
      for a second key. Run `DumpCommand().execute(ctx, [], {})`. Assert `ok`
      is `true`, `out` contains the good doc, and the **err** sink contains
      `Skipping`.
- [x] **#1b — export poisoned-value "Skipping" guard**
      (`export_command.dart:98-100`, standard path). Same shape in
      `test/commands/export_command_test.dart`, but export takes a collection
      arg: `ExportCommand().execute(ctx, ['<coll>'], {})`. Assert `ok`, `out`
      has the good doc, **err** contains `Skipping`.
- [x] **#1c — scan poisoned-value guard** (`scan_command.dart:313-320`). **Add
      to the `ScanCommand` group in `test/commands_test.dart`** (no dedicated
      file). Insert a good doc + inject an undecodable value on a second key,
      then run scan **with `--key-prefix`** covering both keys
      (`ScanCommand().execute(ctx, ['<coll>'], {'key-prefix': '<prefix>'})`).
      Assert the command **survives** (`ok` true) and returns the good row.
      **Do NOT assert any "Skipping" text — this guard skips silently.**
- [x] **#2 — search `query failed` catch** (`search_command.dart:324`).
      **In scope** (open question resolved above). In
      `test/commands/search_command_test.dart`, reuse the `_seedDb` helper to
      open a db with an FTS index and insert a doc whose body contains a
      distinctive term. Then overwrite that doc's stored value with garbage:
      `db.store.put('docs', id, Uint8List.fromList([0xFF, 0xFE, 0xFD]))`. In the
      **same session**, run `SearchCommand().execute(ctx, ['docs', '<term>'],
      {})`. Assert `ok` is `false` and `err` contains `query failed`.
      **Implementation note (deviation):** the recipe as written raced a
      second, distinct lazy-build hazard beyond the reopen case already called
      out above. The FTS index is `undefined` until its *first* query, which
      triggers a one-off full rebuild scan straight from the source documents
      — so if the value is poisoned *before* that first query, the rebuild
      simply skips the undecodable doc (no posting is ever created) and the
      query reports "no results" rather than throwing. Fixed by running one
      `SearchCommand().execute(...)` call (discarding its result) **before**
      poisoning, to force the index to build from the still-good data; the
      poison + second search then reuses the already-built index and reaches
      the unguarded `fetchDoc` throw as intended.
- [x] **#3 — `index create` success path** (`index_command.dart:117-152`). The
      command's own success branch (`config.save()` + the "…registered." message)
      is never hit; `commands_test.dart` only asserts the `addIndex` mutation
      directly plus duplicate/reserved-prefix errors. Add a create-success test
      to the `IndexCommand` group's `create` subgroup, mirroring the `delete`
      real-temp-dir setup (`createTempSync` + `StorageAdapterNative()` +
      `KmdbConfig.forDatabase(tmpDir.path)`). Assert `ok`, `out` contains
      `registered`, and the on-disk `local/config.json` exists.
- [x] **#4 — `index list` / `index info` against a *built* index.** Both are only
      asserted at `status: undefined` / `gen=0` (`commands_test.dart:2193,2277`).
      Open a db with `indexes: [IndexDefinition('<coll>','<path>')]`, insert docs,
      run a `col.where(Field('<path>').equals(...)).get()` to drive the build to
      `current`, **and register the same index in the `KmdbConfig`** passed to
      the command (so `_list`/`_info` iterate it — they read
      `ctx.config.indexesForCollection`). Then run `index list`/`info` and assert
      the `current` status, non-zero `gen=`/`builtThrough`, and a non-empty
      `builtAt`. Same file (`test/commands_test.dart`).
      **Finding (recipe's `builtAt` expectation does not hold — discovered
      defect, left as-is, out of scope for this test-only plan):** triggering
      the build is also asynchronous relative to the triggering query's
      returned `Future` — `IndexManager.getOrActivate` only *launches* the
      build (`_launchBuild`, a fire-and-forget `Future(() => _buildIndex(...))`)
      and returns a `building`/stale-carrying state immediately, so a single
      `.get()` call is not sufficient; the test spin-polls
      `db.indexManager.getOrActivate(...)` until `status == current`
      (same pattern as `packages/kmdb/test/query/index_query_test.dart`'s
      `openWithCurrentIndex`). Once actually `current`, `builtAt` is still
      **empty** (`list` prints `builtAt=-`, `info` prints
      `builtAt:      (not built)`) — `IndexManager._buildIndex` (unlike
      `FtsManager`/`VecManager`'s build-completion paths, which both call
      `DateTime.now().toUtc().toIso8601String()`) never stamps
      `IndexState.builtAt` on any of its three `IndexState(...)` constructions
      (building/current/stale), even though `IndexState.builtAt`'s own doc
      comment describes it as "HLC timestamp string recorded when the build
      completed". This is a genuine, pre-existing gap in `IndexManager`, not a
      test-writing mistake — production code changes are out of scope for this
      test-only plan, so the test asserts the real (always-empty) behaviour
      instead of the recipe's original "non-empty builtAt" expectation. Worth a
      small follow-up roadmap item to wire `builtAt` into
      `IndexManager._buildIndex` for parity with FTS/Vec.
- [x] **#5 — `--read` abort-on-first-error default.** `cli_runner_inprocess_test`
      tests `--continue-on-error` but never asserts that *without* the flag the
      script stops at the first failing line. Add to the `--read file scenarios`
      group: a script whose first line fails (`not_a_cmd`) and whose second line
      would produce distinctive output (e.g. `collections list`), run **without**
      `--continue-on-error`, and assert exit code 1 **and** that the second
      command's output is **absent** (proving it never ran).
- [x] **#6 — `--read` mutation round-trip.** Every script test runs read-only
      `scan ns`. Add a script whose first line `insert`s and whose later line
      observes the side effect. Script line form: `insert <coll> --value
      {"k":"v"}` followed by `scan <coll>`; assert the scan output contains the
      inserted value. **Caveat:** `--read` lines are whitespace-tokenised, so use
      **compact JSON with no spaces** in the `--value` argument. Same file.
      **Additional caveat found during implementation:** compact-JSON-with-
      no-spaces alone is not sufficient — `CliRunner._tokenize` also *strips*
      every quote character it uses to toggle quote mode (single or double),
      so a bare `--value {"k":"v"}` loses its double quotes entirely (becomes
      `{k:v}`, invalid JSON). The value must additionally be wrapped in single
      quotes — `--value '{"k":"v"}'` — so the tokenizer's quote-mode treats
      the enclosed double quotes as literal characters rather than its own
      delimiters.
- [x] **#7 — `versions` delete / `promoted_from` rendering**
      (`versions_command.dart:78-81`). Add to
      `test/commands/versioning_command_test.dart`: (a) put a key then
      `col.delete(key)`, run `versions`, parse the JSON and assert a version has
      `is_delete == true` (not just the label present); (b) extend the existing
      "promote a known version succeeds" flow — after promoting, run `versions`
      and assert the output contains `promoted_from`.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm ≥ baseline; the new assertions should not
      lower it. (This is `kmdb_cli`, not `kmdb`, so `make pre_commit`'s scoped
      test step does **not** cover it — run `cd packages/kmdb_cli && dart test`
      explicitly.)
      **Result:** `dart run coverage:test_with_coverage` in `packages/kmdb_cli`
      (equivalent to the per-package step `melos coverage` runs) — full
      workspace `make coverage` was skipped as impractically slow for a
      `kmdb_cli`-only change; this is the same per-package command it runs.
      Baseline (`main`, pre-change): 95.2% (3036/3188 lines). After this plan:
      **95.4%** (3042/3188 lines — same denominator, since no production code
      changed; 6 more previously-dead lines are now exercised by the new
      tests). All 1237 tests pass (3 e2e-tagged skipped by default).
- [x] Hand off to the **`kmdb-qa` agent** for sign-off. **PASS (2026-08-23)** —
      the coordinator ran `kmdb-qa`; verdict: all 9 cases behaviorally
      substantive (not vacuous), analysis/format clean, coverage above baseline,
      all three deviations sound. The #4 `builtAt` gap was confirmed a genuine
      pre-existing `IndexManager` defect, correctly scoped out of this test-only
      plan and recommended as a small follow-up. Zero blocking issues.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      (Mechanical gate only, run directly via Bash since the `kmdb-pre-commit`
      agent could not be invoked either, for the same reason as above.) All
      steps passed: `format_check`, `analyze`, `license_check`, and the
      `kmdb`-scoped `pre_commit_test` (2647 tests, 12 skipped — e2e-tagged).
- [x] Verify licence headers on any new files (none expected — all edits are to
      existing test files). Confirmed: `git status` shows only modifications to
      6 pre-existing test files (plus the plan and roadmap docs) — no new files
      were created, so no new license headers are needed.

## Summary

**Complete — `kmdb-qa` PASS (2026-08-23).** All 9 test cases (items #1a–#7) are
written, passing, and checked off; the roadmap WI-10 update is done;
`make pre_commit` is green; QA signed off (all cases behaviorally substantive,
zero blocking issues).

- Added 9 new `test()` cases across 6 existing test files — no production code
  changes, no new files, no new license headers needed:
  - `test/commands/dump_command_test.dart` (#1a), `test/commands/export_command_test.dart`
    (#1b): standard-path poisoned-value "Skipping" guard.
  - `test/commands_test.dart`: `ScanCommand` `--key-prefix` silent-skip guard
    (#1c); `IndexCommand create` success path + on-disk `config.json` (#3);
    `IndexCommand list`/`info` against an actually-built (`current`) index
    (#4) — this uncovered a genuine, pre-existing `IndexManager` gap
    (`builtAt` is never stamped, unlike `FtsManager`/`VecManager`); left as a
    documented finding, not fixed (out of scope for this test-only plan).
  - `test/commands/search_command_test.dart`: the `search: query failed`
    catch via a poisoned already-indexed document (#2) — required an extra
    "force the index build first" step beyond the original recipe, because
    the FTS index's first-query lazy build would otherwise silently skip the
    poisoned source doc.
  - `test/cli_runner_inprocess_test.dart`: `--read` abort-on-first-error
    default (#5) and a mutation round-trip (#6) — the latter surfaced a
    tokenizer quoting gotcha (`CliRunner._tokenize` strips the very quote
    characters needed to protect embedded JSON double quotes).
  - `test/commands/versioning_command_test.dart`: a deleted key's
    `is_delete == true` rendering and `promoted_from` rendering after a
    promote (#7).
- Updated `docs/roadmap/0_10_01.md`'s WI-10 entry (table row + prose section):
  closed the 6 W5 areas the 2026-08-23 audit found already-adequate (`sync`,
  `schema`, `encryption`, `import`/`export`/`restore`, the REPL), and linked
  both follow-up plans.
- Coverage: `kmdb_cli` line coverage 95.2% (main) → **95.4%** after this plan
  (3042/3188 lines; no production lines added, 6 more lines now exercised).
  All 1237 `kmdb_cli` tests pass.
- `make pre_commit` (format_check, analyze, license_check, `kmdb`-scoped
  tests) is green.

**Follow-up (non-blocking):** wire `builtAt` into `IndexManager._buildIndex`'s
three `IndexState` constructions for parity with `FtsManager`/`VecManager` (the
#4 discovered defect) — a small separate plan.
