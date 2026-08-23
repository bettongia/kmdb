# W5 CLI coverage quick wins

**Status**: Investigated

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

- [ ] **#1a — dump poisoned-value "Skipping" guard** (`dump_command.dart:97-99`,
      standard NDJSON path). In `test/commands/dump_command_test.dart`: via
      `_openCtx`, insert one good doc through the collection API, then
      `db.store.put('<coll>', '<key>', Uint8List.fromList([0xFF, 0xFE, 0xFD]))`
      for a second key. Run `DumpCommand().execute(ctx, [], {})`. Assert `ok`
      is `true`, `out` contains the good doc, and the **err** sink contains
      `Skipping`.
- [ ] **#1b — export poisoned-value "Skipping" guard**
      (`export_command.dart:98-100`, standard path). Same shape in
      `test/commands/export_command_test.dart`, but export takes a collection
      arg: `ExportCommand().execute(ctx, ['<coll>'], {})`. Assert `ok`, `out`
      has the good doc, **err** contains `Skipping`.
- [ ] **#1c — scan poisoned-value guard** (`scan_command.dart:313-320`). **Add
      to the `ScanCommand` group in `test/commands_test.dart`** (no dedicated
      file). Insert a good doc + inject an undecodable value on a second key,
      then run scan **with `--key-prefix`** covering both keys
      (`ScanCommand().execute(ctx, ['<coll>'], {'key-prefix': '<prefix>'})`).
      Assert the command **survives** (`ok` true) and returns the good row.
      **Do NOT assert any "Skipping" text — this guard skips silently.**
- [ ] **#2 — search `query failed` catch** (`search_command.dart:324`).
      **In scope** (open question resolved above). In
      `test/commands/search_command_test.dart`, reuse the `_seedDb` helper to
      open a db with an FTS index and insert a doc whose body contains a
      distinctive term. Then overwrite that doc's stored value with garbage:
      `db.store.put('docs', id, Uint8List.fromList([0xFF, 0xFE, 0xFD]))`. In the
      **same session**, run `SearchCommand().execute(ctx, ['docs', '<term>'],
      {})`. Assert `ok` is `false` and `err` contains `query failed`.
- [ ] **#3 — `index create` success path** (`index_command.dart:117-152`). The
      command's own success branch (`config.save()` + the "…registered." message)
      is never hit; `commands_test.dart` only asserts the `addIndex` mutation
      directly plus duplicate/reserved-prefix errors. Add a create-success test
      to the `IndexCommand` group's `create` subgroup, mirroring the `delete`
      real-temp-dir setup (`createTempSync` + `StorageAdapterNative()` +
      `KmdbConfig.forDatabase(tmpDir.path)`). Assert `ok`, `out` contains
      `registered`, and the on-disk `local/config.json` exists.
- [ ] **#4 — `index list` / `index info` against a *built* index.** Both are only
      asserted at `status: undefined` / `gen=0` (`commands_test.dart:2193,2277`).
      Open a db with `indexes: [IndexDefinition('<coll>','<path>')]`, insert docs,
      run a `col.where(Field('<path>').equals(...)).get()` to drive the build to
      `current`, **and register the same index in the `KmdbConfig`** passed to
      the command (so `_list`/`_info` iterate it — they read
      `ctx.config.indexesForCollection`). Then run `index list`/`info` and assert
      the `current` status, non-zero `gen=`/`builtThrough`, and a non-empty
      `builtAt`. Same file (`test/commands_test.dart`).
- [ ] **#5 — `--read` abort-on-first-error default.** `cli_runner_inprocess_test`
      tests `--continue-on-error` but never asserts that *without* the flag the
      script stops at the first failing line. Add to the `--read file scenarios`
      group: a script whose first line fails (`not_a_cmd`) and whose second line
      would produce distinctive output (e.g. `collections list`), run **without**
      `--continue-on-error`, and assert exit code 1 **and** that the second
      command's output is **absent** (proving it never ran).
- [ ] **#6 — `--read` mutation round-trip.** Every script test runs read-only
      `scan ns`. Add a script whose first line `insert`s and whose later line
      observes the side effect. Script line form: `insert <coll> --value
      {"k":"v"}` followed by `scan <coll>`; assert the scan output contains the
      inserted value. **Caveat:** `--read` lines are whitespace-tokenised, so use
      **compact JSON with no spaces** in the `--value` argument. Same file.
- [ ] **#7 — `versions` delete / `promoted_from` rendering**
      (`versions_command.dart:78-81`). Add to
      `test/commands/versioning_command_test.dart`: (a) put a key then
      `col.delete(key)`, run `versions`, parse the JSON and assert a version has
      `is_delete == true` (not just the label present); (b) extend the existing
      "promote a known version succeeds" flow — after promoting, run `versions`
      and assert the output contains `promoted_from`.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥ baseline; the new assertions should not
      lower it. (This is `kmdb_cli`, not `kmdb`, so `make pre_commit`'s scoped
      test step does **not** cover it — run `cd packages/kmdb_cli && dart test`
      explicitly.)
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (none expected — all edits are to
      existing test files).

## Summary

_To be completed when the work is done._
