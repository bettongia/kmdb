# Stamp `IndexState.builtAt` on secondary-index build completion

**Status**: Complete

**PR link**: [#80](https://github.com/bettongia/kmdb/pull/80)

> **Provenance.** Discovered by the W5 CLI quick-wins work
> ([plan](completed/plan_w5_cli_coverage_quick_wins.md), item #4, PR #78) and
> confirmed by `kmdb-qa` (2026-08-23) as a genuine, pre-existing defect. It was
> deliberately left unfixed there because that plan was test-only; this plan is
> the production follow-up.

## Problem statement

`IndexManager._buildIndex` never stamps `IndexState.builtAt`. All three
`IndexState` constructions it emits — `building`
([index_manager.dart:471-479](../../packages/kmdb/lib/src/query/index/index_manager.dart#L471-L479)),
`current`
([index_manager.dart:496-502](../../packages/kmdb/lib/src/query/index/index_manager.dart#L496-L502)),
and `stale`
([index_manager.dart:508-516](../../packages/kmdb/lib/src/query/index/index_manager.dart#L508-L516)) —
omit `builtAt`, so it falls back to the constructor default `''`
([index_manager.dart:101](../../packages/kmdb/lib/src/query/index/index_manager.dart#L101))
and stays empty forever, even for a `current` index.

This is out of step with the two sibling derived-index managers, which both stamp
it on build completion via `DateTime.now().toUtc().toIso8601String()`:

- `FtsManager` — [fts_manager.dart:656-662](../../packages/kmdb/lib/src/search/lexical/fts_manager.dart#L656-L662)
  and [fts_manager.dart:1054](../../packages/kmdb/lib/src/search/lexical/fts_manager.dart#L1054)
- `VecManager` — [vec_manager.dart:446](../../packages/kmdb/lib/src/search/semantic/vec_manager.dart#L446)
  and [vec_manager.dart:525](../../packages/kmdb/lib/src/search/semantic/vec_manager.dart#L525)

**Observable effect (diagnostics only, no correctness impact).** The CLI renders
the never-set field as a placeholder for an index that is genuinely `current`:

- `index list` prints `builtAt=-`
  ([index_command.dart:102](../../packages/kmdb_cli/lib/src/commands/index_command.dart#L102))
- `index info` prints `builtAt:      (not built)`
  ([index_command.dart:185](../../packages/kmdb_cli/lib/src/commands/index_command.dart#L185))

`builtThrough` is stamped correctly, so a user sees a `current` index with a real
generation but no build timestamp — misleading, but not a data or query bug.

**Secondary defect — a false doc comment.** `IndexState.builtAt`'s doc comment
([index_manager.dart:112-113](../../packages/kmdb/lib/src/query/index/index_manager.dart#L112-L113))
reads *"HLC timestamp string recorded when the build completed"*. It is neither
recorded (see above) **nor** an HLC value — the sibling managers stamp a
wall-clock ISO-8601 UTC string, and `FtsIndexState`/`VecIndexState` both document
theirs accurately as *"Empty when not yet built. Informational only."*
([fts_index_state.dart:111](../../packages/kmdb/lib/src/search/lexical/fts_index_state.dart#L111),
[vec_index_state.dart:90](../../packages/kmdb/lib/src/search/semantic/vec_index_state.dart#L90)).

## Decision (resolved during drafting)

- **Format:** match the siblings exactly — `DateTime.now().toUtc().toIso8601String()`.
  Not HLC. `builtAt` is diagnostics-only (never read back for correctness — it is
  round-tripped through CBOR at
  [index_manager.dart:611](../../packages/kmdb/lib/src/query/index/index_manager.dart#L611)
  and [:649](../../packages/kmdb/lib/src/query/index/index_manager.dart#L649) but
  no code branches on it), so wall-clock time is appropriate and consistent.
- **Which states get stamped:** only the **`current`** construction — the moment
  the build actually completes successfully. Leave `building` (build not finished)
  and `stale` (superseded before it could be trusted; it will be rebuilt) empty,
  consistent with "recorded when the build **completed**" and with the siblings,
  which stamp only on their `current` transition.

## Investigation

Complete — grounded against HEAD (Dart 3.13.1). No open questions.

- The three construction sites and the constructor default are as cited above.
- No production code reads `builtAt` for control flow (verified: the only
  consumers are the CBOR (de)serialiser and the two CLI render paths). Changing
  it from always-empty to a timestamp is therefore behaviourally safe.
- CBOR persistence already carries `builtAt` in both directions
  ([index_manager.dart:611](../../packages/kmdb/lib/src/query/index/index_manager.dart#L611),
  [:649](../../packages/kmdb/lib/src/query/index/index_manager.dart#L649)) — no
  format change is needed; a previously-persisted empty string simply becomes a
  non-empty one on the next build.
- The W5 #4 CLI test currently **asserts the buggy behaviour on purpose**
  ([commands_test.dart:2468](../../packages/kmdb_cli/test/commands_test.dart#L2468)
  `builtAt=-`, and
  [:2488](../../packages/kmdb_cli/test/commands_test.dart#L2488)
  `builtAt:      (not built)`), with comments pointing here. Those two assertions
  (and their explanatory comments) must flip to expect a non-empty timestamp.

## Implementation plan

- [x] **Stamp `builtAt` on the `current` state.** In
      `IndexManager._buildIndex`, add
      `builtAt: DateTime.now().toUtc().toIso8601String()` to the `current`
      `IndexState` construction
      ([index_manager.dart:496-502](../../packages/kmdb/lib/src/query/index/index_manager.dart#L496-L502)),
      mirroring `FtsManager`/`VecManager`. Leave `building` and `stale` unchanged.
- [x] **Correct the doc comment.** Rewrite
      [index_manager.dart:112-113](../../packages/kmdb/lib/src/query/index/index_manager.dart#L112-L113)
      to match reality and the siblings. Use the exact sibling wording for true
      parity: *"ISO-8601 UTC timestamp string recorded when the build last
      completed. Empty when not yet built. Informational only."*
      (`FtsIndexState`/`VecIndexState` both use this verbatim.) Drop the false
      "HLC" wording.
- [x] **kmdb unit test.** In
      `packages/kmdb/test/query/index_query_test.dart` (reuse its
      `openWithCurrentIndex`/spin-poll-to-`current` pattern), assert that after an
      index reaches `IndexStatus.current`, `state.builtAt` is non-empty and
      `DateTime.parse(state.builtAt)` succeeds; and that a not-yet-built index's
      `builtAt` is empty. Add a build→persist→reload round-trip assertion so the
      CBOR path is covered.
- [x] **Update the W5 #4 CLI test to the corrected behaviour.** In
      `packages/kmdb_cli/test/commands_test.dart`, replace the
      `contains('builtAt=-')` assertion
      ([:2468](../../packages/kmdb_cli/test/commands_test.dart#L2468)) with
      `isNot(contains('builtAt=-'))` **plus** a positive check that the rendered
      timestamp parses. **Do not assert the value is hyphen-free** — an ISO-8601
      UTC timestamp (`2026-08-24T…Z`) contains hyphens; the discriminator is the
      bare placeholder token `builtAt=-` (an empty value renders as `-`
      immediately after `=`, whereas a real value renders as `builtAt=2026…`, so
      `isNot(contains('builtAt=-'))` cleanly distinguishes the two). To assert a
      real timestamp positively, extract the `builtAt=` field from the line and
      `DateTime.parse` it. Likewise replace the
      `contains('builtAt:      (not built)')` assertion
      ([:2488](../../packages/kmdb_cli/test/commands_test.dart#L2488)) with
      `isNot(contains('(not built)'))` on the `builtAt` line plus a parse check.
      Update the explanatory comments (which currently describe the gap) to
      reference this plan as the fix.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm ≥ baseline. Result: 95.0% overall
      (11926/12554 lines), at the documented ≥95% baseline. New/changed lines
      confirmed hit in the lcov report: `index_manager.dart:502` (the
      `builtAt` stamp, hit 21×) and `index_command.dart:102`/`:185` (the CLI
      render paths). This touches **both** `kmdb` (production + unit test) and
      `kmdb_cli` (the #4 test), and `make pre_commit`'s scoped test step is
      `kmdb`-only — so additionally ran `cd packages/kmdb_cli && dart test`
      explicitly: 1240 tests passed (2 environment-only failures reproduced
      only under the implementation sandbox's filesystem restrictions —
      `DirectorySecretStore.forPlatform()` default-path tests — confirmed
      unrelated to this change and passing with sandboxing disabled).
- [x] Hand off to the **`kmdb-qa` agent** for sign-off. **PASS (2026-08-24)** —
      the coordinator ran `kmdb-qa`; verdict: correct, minimal, well-tested; the
      new tests genuinely exercise the fix and would fail against the pre-fix
      always-empty behaviour; doc comment now verbatim-identical to the
      siblings; coverage at baseline; the two reported `kmdb_cli` failures
      independently confirmed sandbox-environmental. Zero blocking items.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      Ran manually via Bash (no `kmdb-pre-commit` agent available this
      session): `dart format --set-exit-if-changed` reports 0 changed,
      `melos run analyze` reports no issues in all 7 packages, `melos
      licenses` (addlicense --check) passed, and the scoped `kmdb`
      `pre_commit_test` (2649 tests, 12 skipped E2E) passed. Exit code 0.
- [x] Verify licence headers on any new files (none expected — all edits are to
      existing files). Confirmed: only `index_manager.dart`,
      `index_query_test.dart`, and `commands_test.dart` were touched, all
      pre-existing files with headers already in place; `addlicense --check`
      in the pre-commit run above confirms no missing headers.
- [x] Update `docs/roadmap/0_10_01.md` — WI-10 entry now links this completed
      plan (✅) and describes the fix; plan moved to `docs/plans/completed/` with
      the PR link recorded below.

## Reviewer sign-off (kmdb-plan-reviewer, 2026-08-24)

Verified every claim against HEAD (Dart 3.13.1). The plan is accurate and
mechanically executable. Findings:

1. **Defect and cited sites — confirmed.** `IndexManager._buildIndex`'s three
   `IndexState` constructions (`building` :471-479, `current` :496-502, `stale`
   :508-516) all omit `builtAt`; the constructor default is `''` (:101). No
   production code reads `builtAt` for control flow — a full `builtAt` grep shows
   the only consumers are the CBOR (de)serialiser (:611 encode, :649 decode) and
   the two CLI render paths (`index_command.dart:102` list, `:185` info). The
   change from always-empty to a timestamp is behaviourally safe.

2. **Parity target — confirmed, and stamping only `current` is correct.**
   `FtsManager` (:656-662, :1054) and `VecManager` (:446, :525) both stamp
   `DateTime.now().toUtc().toIso8601String()` on their completion transition.
   Note the siblings *also* re-stamp on their incremental `syncing → current`
   transitions (fts :1054, vec :525) — but `IndexManager` has **no incremental /
   delta path**: a stale secondary index is fully rebuilt via `_buildIndex`, so
   the `current` construction there is its *sole* completion transition. Stamping
   only that site is therefore both complete and consistent with the siblings.
   Leaving `building`/`stale` empty is right.

3. **Doc-comment correction — warranted.** The current comment (:112-113) says
   "HLC timestamp string"; the value is neither HLC nor ever recorded. The
   siblings document theirs accurately and identically. Step updated to reuse the
   exact sibling wording for true parity.

4. **Test plan — adequate and correctly targeted.** `index_query_test.dart` has
   the `openWithCurrentIndex` spin-poll-to-`current` helper (:198-213) the plan
   reuses. Both `getState` (:246-256) and `getOrActivate` (:388) route through
   `_loadState → _decodeState`, so a `getState(...).builtAt` non-empty assertion
   after reaching `current` already exercises the full encode+decode round-trip
   without a db reopen — the CBOR path is covered by any state read. The W5 #4
   CLI assertions at `commands_test.dart:2468` (`builtAt=-`) and `:2488`
   (`builtAt:      (not built)`) are confirmed present with comments pointing
   here. **Corrected one hazard in the test guidance:** the original "assert a
   `-`-free value" advice is wrong — ISO-8601 timestamps contain hyphens. The
   correct discriminator is the bare placeholder token `builtAt=-`; the step now
   specifies `isNot(contains('builtAt=-'))` plus a `DateTime.parse` check.

5. **No CBOR format change — confirmed.** `builtAt` is already carried in both
   directions (:611 / :649 with a `?? ''` default). A previously-persisted empty
   string simply becomes non-empty on the next build; old records decode fine.

**Status → Investigated.** No open questions. Two small clarifications were
folded into the implementation checklist (exact sibling doc wording; corrected
CLI assertion guidance). Ready for `kmdb-plan-implement`.

## Summary

**Complete — `kmdb-qa` PASS (2026-08-24).** All code, doc, and test work is done
and verified; QA signed off (correct, minimal, tests genuinely exercise the fix
and would fail against the pre-fix behaviour; zero blocking items).

- Stamped `IndexState.builtAt` with `DateTime.now().toUtc().toIso8601String()`
  on `IndexManager._buildIndex`'s `current` completion transition only
  (`packages/kmdb/lib/src/query/index/index_manager.dart`), mirroring
  `FtsManager`/`VecManager`. `building`/`stale` constructions left unchanged,
  as decided.
- Corrected `IndexState.builtAt`'s doc comment to the exact sibling wording
  ("ISO-8601 UTC timestamp string recorded when the build last completed.
  Empty when not yet built. Informational only."), removing the false "HLC"
  claim.
- No CBOR format change — confirmed `builtAt` already round-trips through
  `_encodeState`/`_decodeState`.
- Added two `kmdb` unit tests in
  `packages/kmdb/test/query/index_query_test.dart`: `builtAt` is a
  non-empty, `DateTime.parse`-able value once an index reaches `current`
  (exercising the full persist/reload round trip via `getOrActivate` →
  `_loadState` → `_decodeState`), and `builtAt` stays empty for an
  as-yet-unbuilt (`undefined`) index.
- Flipped the two W5 #4 CLI assertions in
  `packages/kmdb_cli/test/commands_test.dart` that previously pinned the
  buggy always-empty behaviour (`builtAt=-` for `list`, `builtAt: (not
  built)` for `info`) to assert the fixed behaviour: `isNot(contains(...))`
  for the placeholder tokens, plus a positive `DateTime.parse` check on the
  extracted timestamp value. Comments updated to reference this plan as the
  fix rather than describing an open gap.
- Verified: `cd packages/kmdb && dart test` — 2649 passed, 12 skipped (E2E,
  by design). `cd packages/kmdb_cli && dart test` — 1240 passed (2
  environment-only failures reproduced only under this session's sandbox
  filesystem restrictions — real `DirectorySecretStore.forPlatform()`
  default-path tests unrelated to this change — pass cleanly with sandboxing
  disabled). `make coverage` — 95.0% overall (11926/12554 lines), at the
  documented baseline; new/changed lines confirmed hit in the lcov report.
  `make pre_commit` (run manually via Bash) — format_check, analyze,
  license_check, and the scoped `kmdb` `pre_commit_test` all green, exit 0.
- No new files were created, so no new license headers were needed.
- Branch/worktree: `20260824_plan_index_builtat_stamp` at
  `.worktrees/20260824_plan_index_builtat_stamp`. Not yet committed — see the
  outstanding `kmdb-qa` item above.
