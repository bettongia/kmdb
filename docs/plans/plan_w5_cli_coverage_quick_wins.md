# W5 CLI coverage quick wins

**Status**: Open

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

- [ ] **Item #2 (search `query failed` catch) — is the throw reachable from a
      black-box CLI test, or does it need a production seam?** The catch at
      `search_command.dart` (audit cited `:325`) only fires if the underlying
      query throws. If no existing corrupt-state fixture forces that throw
      without a new injection seam, this item is **out of scope for this plan**
      and should be dropped here (the reviewer/implementer decides; do not add a
      production seam under this "quick wins" plan — that would make it
      plan-sized). Verify feasibility during implementation; if infeasible,
      note it and move on with the other six.

## Investigation

All references confirmed by the W5 audit against the current test tree
(2026-08-23). **Re-verify line numbers at implementation time** — they drift.

Existing patterns to reuse:
- The undecodable-value injection pattern already exists in
  `test/restore_verify_test.dart` ("undecodable document") — reuse it for #1.
- The `IndexCommand` group in `test/commands_test.dart` already has a
  real-temp-dir test (its `delete` case) — reuse that setup for #3/#4.
- `test/cli_runner_inprocess_test.dart` has a `--read file scenarios` group with
  a `--continue-on-error` test — extend it for #5/#6.

## Implementation plan

Each item is one or two `test()` cases added to the named existing file.

- [ ] **#1 — poisoned-value "Skipping" guard (dump / export / scan).** The S-2
      hardening (`dump_command.dart`, `export_command.dart`, `scan_command.dart`)
      must skip a single undecodable value and continue, not abort the
      collection. Only `verify`'s equivalent is tested today. Add one test each
      to `test/commands/dump_command_test.dart`,
      `test/commands/export_command_test.dart`, and a scan test: inject an
      undecodable value (per `restore_verify_test.dart`), assert the command
      **survives**, emits `Skipping`, and still returns the good rows.
- [ ] **#2 — search `query failed` catch** (`search_command.dart`). Force the
      underlying query to throw and assert the clean `query failed` error path.
      Add to `test/commands/search_command_test.dart`. **Subject to the open
      question** — drop if it requires a new production seam.
- [ ] **#3 — `index create` success path** (`index_command.dart`). The command's
      own success branch (config.save + "registered" message) is never hit;
      `commands_test.dart` only asserts the `addIndex` mutation directly plus
      duplicate/reserved-prefix errors. Add a create-success test to the
      `IndexCommand` group in `test/commands_test.dart`.
- [ ] **#4 — `index list` / `index info` against a *built* index.** Both are only
      asserted at `status: undefined` / `gen=0`. Build an index (run a query that
      uses it) first, then assert the `current` status, non-zero `builtThrough`,
      and a real `builtAt`. Same file (`test/commands_test.dart`).
- [ ] **#5 — `--read` abort-on-first-error default.** `cli_runner_inprocess_test`
      tests `--continue-on-error` but never asserts that *without* the flag the
      script stops at the first failing line. Add to the `--read file scenarios`
      group.
- [ ] **#6 — `--read` mutation round-trip.** Every script test runs read-only
      `scan ns`. Add a script that `insert`s and whose side effect a later line
      observes (the real migration use case). Same file.
- [ ] **#7 — `versions` delete / `promoted_from` rendering**
      (`versions_command.dart`). Only live-version listing is tested. Add a case
      with a deleted key (renders `is_delete`) and a post-promote listing
      (renders `promoted_from`). Add to
      `test/commands/versioning_command_test.dart`.

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
