# Stamp `IndexState.builtAt` on secondary-index build completion

**Status**: Open

**PR link**: _(none yet)_

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

- [ ] **Stamp `builtAt` on the `current` state.** In
      `IndexManager._buildIndex`, add
      `builtAt: DateTime.now().toUtc().toIso8601String()` to the `current`
      `IndexState` construction
      ([index_manager.dart:496-502](../../packages/kmdb/lib/src/query/index/index_manager.dart#L496-L502)),
      mirroring `FtsManager`/`VecManager`. Leave `building` and `stale` unchanged.
- [ ] **Correct the doc comment.** Rewrite
      [index_manager.dart:112-113](../../packages/kmdb/lib/src/query/index/index_manager.dart#L112-L113)
      to match reality and the siblings — e.g. *"Wall-clock ISO-8601 UTC
      timestamp recorded when the build completed. Empty when not yet built.
      Informational only."* Drop the false "HLC" wording.
- [ ] **kmdb unit test.** In
      `packages/kmdb/test/query/index_query_test.dart` (reuse its
      `openWithCurrentIndex`/spin-poll-to-`current` pattern), assert that after an
      index reaches `IndexStatus.current`, `state.builtAt` is non-empty and
      `DateTime.parse(state.builtAt)` succeeds; and that a not-yet-built index's
      `builtAt` is empty. Add a build→persist→reload round-trip assertion so the
      CBOR path is covered.
- [ ] **Update the W5 #4 CLI test to the corrected behaviour.** In
      `packages/kmdb_cli/test/commands_test.dart`, replace the
      `contains('builtAt=-')` assertion
      ([:2468](../../packages/kmdb_cli/test/commands_test.dart#L2468)) with one
      asserting a non-empty, `-`-free `builtAt=` value (e.g. matches an ISO-8601
      pattern), and the `contains('builtAt:      (not built)')` assertion
      ([:2488](../../packages/kmdb_cli/test/commands_test.dart#L2488)) with one
      asserting `info` renders a real timestamp. Update the explanatory comments
      (which currently describe the gap) to reference this plan as the fix.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥ baseline. This touches **both** `kmdb`
      (production + unit test) and `kmdb_cli` (the #4 test), and `make
      pre_commit`'s scoped test step is `kmdb`-only — so additionally run
      `cd packages/kmdb_cli && dart test` explicitly.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (none expected — all edits are to
      existing files).
- [ ] Update `docs/roadmap/0_10_01.md` — record this fix under the WI-5
      "Follow-ups discovered" section (or the WI-10 W6 code-health area) and link
      this plan; move the plan to `docs/plans/completed/` with the PR link.

## Summary

_To be completed when the work is done._
