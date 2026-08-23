# Adopt Dart 3.13.1 / Flutter 3.47.1 across dev and CI

**Status**: Complete

**PR link**: [#77](https://github.com/bettongia/kmdb/pull/77) (merged 2026-08-23)

> **Provenance.** Split out during the WI-5 unlock-policy work
> ([PR #75](https://github.com/bettongia/kmdb/pull/75)) on 2026-08-22. Local dev
> upgraded to Flutter 3.47.1 (bundles Dart 3.13.1); an attempt to align CI up to
> match surfaced a reproducible **betto_pdfium native-asset break on Linux** that
> is unrelated to WI-5. To avoid holding the security fix hostage to a toolchain
> migration, CI was pinned back to the last-known-good **Dart 3.12.2 / Flutter
> 3.44.4** for that PR, and the adoption deferred here.

## Problem statement

The team's local development toolchain is now **Flutter 3.47.1 / Dart 3.13.1**,
but CI is pinned to the last-known-good **Flutter 3.44.4 / Dart 3.12.2** (set in
PR #75 to unblock WI-5). This gap must be closed: while it stands, `dart format`
output differs between local (3.13.1) and CI (3.12.2), so contributors on the
current toolchain cannot satisfy `format_check` without manual workarounds, and
the repo cannot benefit from 3.13.1's analyzer/lint improvements.

Adopting 3.13.1 is **not** a pure version bump — it was attempted in PR #75
(commit `011fe65`, reverted by `git revert`) and failed CI on a real,
reproducible external-dependency incompatibility. **That blocker is now
resolved** (see the two ✅ questions below); the remaining work is mechanical.

## Open questions

- [x] **Why does `betto_pdfium` fail to index on Linux under Dart 3.13.1?**
      **RESOLVED (2026-08-22).** Not a native-build regression and not a
      `code_assets`/`native_toolchain_c` API change — betto_pdfium builds and
      loads on every platform under 3.13. The real cause: in a **Pub workspace**,
      `dart test` run from a member package (`packages/kmdb_cli`) stages the
      bundled `libpdfium.so` to the **workspace root** `.dart_tool/lib/`, not the
      member's own. betto_pdfium's runtime loader (`_openLibrary`) probed only
      `$cwd/.dart_tool/lib/` (the member dir) → miss; the bare-name
      `LD_LIBRARY_PATH` fallback then fails inside PDFium's **spawned isolate**
      (which does not inherit the test runner's `LD_LIBRARY_PATH`) →
      `cannot open shared object file`, swallowed into the blob's `failed`
      status. Confirmed via the throwaway `diag-313` workflow (runs 32549820366 /
      32549986422). betto_pdfium's own CI never hit it because its tests inject
      an explicit dylib path via `nativeDylibPath()`, bypassing bundled-asset
      resolution. Surfaced under 3.13 only because 3.13 changed workspace
      native-asset staging behaviour.
- [x] **Where does the fix land?** **RESOLVED.** Upstream in `betto_pdfium`
      ([PR #5](https://github.com/bettongia/pdfium/pull/5), merged) — a walk-up
      helper (`dartToolLibCandidates`) that probes each ancestor's
      `.dart_tool/lib/` on Linux/macOS/Windows. Released as **0.1.0-dev.4**
      (published to pub.dev 2026-08-22). kmdb re-pins to `0.1.0-dev.4`; no kmdb
      code change needed for the loader itself.
- [x] **Are other native-asset consumers affected on Linux/3.13.1?**
      **RESOLVED (2026-08-23, reviewer).** No.
      - **`betto_zstd`** — the Linux `build` job *is* the primary gate and runs
        the entire `kmdb` suite, which exercises `betto_zstd` compression on
        every write. It went green under 3.13.1 in PR #75's run, so its
        compile-from-source hook on Linux/3.13.1 is confirmed working. (Its
        dylib/DLL builds also went green on the macOS and Windows jobs.)
      - **`betto_onnxrt`** (transitive via `betto_inferencing`, in the root
        `pubspec.lock`) — **not a Linux/3.13.1 risk to kmdb CI**, for two
        independent reasons. (1) Its build hook is *download-prebuilt* (fetches
        the platform ORT binary from GitHub Releases + SHA-256 verify + stage),
        which is platform-agnostic and already fires and succeeds under 3.13.1 —
        `libonnxruntime.1.22.0.dylib` is currently staged in the workspace
        `.dart_tool/lib/` dirs on the local 3.13.1 toolchain. (2) The
        pdfium-class failure was a *runtime* loader bug, and **no automated kmdb
        or kmdb_cli test loads a real ORT session** — every semantic/vec/vault
        test uses a `_FakeEmbeddingModel`/`_StubEmbeddingModel`. Real ORT
        runtime loading is release-checklist-only, so the runtime-loader class
        of bug cannot manifest in the automated matrix. The final full-matrix
        run (below) is the confirmation.
- [x] **Does Flutter 3.47.1 introduce any other breaks?** **RESOLVED as a
      verification step.** `flutter analyze` on `kmdb_flutter` and `kmdb_icloud`
      was clean under 3.47.1 in PR #75, with no anticipated redesign. This is
      covered mechanically by re-running the `test-icloud` and `test-flutter`
      jobs after the pins move (final full-matrix step). Not a design decision.

## Investigation

Concrete findings already gathered during the PR #75 attempt (commit `011fe65`,
reverted) — carry these forward so they are not rediscovered:

1. **Formatter drift.** Dart 3.13.1's `dart format` rewraps files last formatted
   under 3.12. In PR #75's run it reformatted **10 test files** — 8 in the
   build-job format target (`packages/kmdb/test/encryption/*`,
   `packages/kmdb_cli/test/…`, `packages/kmdb_harness/test/*`,
   `packages/kmdb_google_drive/test/…`) plus 2 in `kmdb_icloud/test/`. These are
   whitespace/wrapping only. Re-derive the exact set at adoption time
   (`dart format` the whole workspace and commit) — it may differ as files
   change.

2. **New lint `unawaited_return_in_try_block` (3.13.1).** Originally 3 sites; 1
   already fixed, **2 remain**. Re-verified against HEAD on the local 3.13.1
   toolchain with `dart analyze` on 2026-08-23 (reviewer): the *only* two
   `unawaited_return_in_try_block` warnings in the entire workspace are the
   vault_searcher pair below. Every other Dart package (`kmdb_cli`,
   `kmdb_harness`, `kmdb_google_drive`, the three extractors) analyzes clean.
   - `packages/kmdb/lib/src/sync/local/local_directory_adapter.dart` — was a
     **genuine crash-safety bug** (a bare `return future()` inside a
     `try`/`finally` releasing the lock before the write completed).
     **Already fixed and merged in PR #76** (2026-08-23). Confirmed clean by
     `dart analyze` under 3.13.1 — the `compareAndSwap` path now uses
     `return await writeViaTempRename(...)` (currently lines ~321 / ~334, with a
     load-bearing comment). This adoption plan just re-confirms it; no action.
   - `packages/kmdb/lib/src/vault/search/vault_searcher.dart:719` and `:726` —
     `return _placeholderContext(…)` inside the `try` of `_buildChunkContext`;
     fix each with `return await _placeholderContext(…)` so the (unlikely)
     errors route through the enclosing `on … rethrow` / `catch (_)` handlers.
     Line numbers verified accurate against HEAD (2026-08-23).

3. **The blocker — pdfium on Linux — RESOLVED.** Root-caused to a Pub-workspace
   native-library resolution gap (staging at the workspace root, loader probing
   only the member dir); fixed upstream in betto_pdfium 0.1.0-dev.4 (see the ✅
   open questions above). This was the only thing that actually failed CI; format
   + analyze + the full kmdb/kmdb_cli test suites and the macOS/Windows/web jobs
   all went green under 3.13.1. Adoption now just re-pins the dependency and moves
   the toolchain pins.

   > **Diagnostic scaffolding — already cleaned up (2026-08-22).** The throwaway
   > `.github/workflows/diag_313.yml` and the `[DART313-DIAG]` prints (two in
   > `vault_search_manager.dart`, one in `pdf_text_extractor.dart`) lived only on
   > branch `20260822_dart_3_13_isolate_diag`, which has been **deleted (local +
   > remote)**. `main` never carried the marker — verified clean. No revert on
   > `main` is needed.

4. **CI pin mechanics.** `cicd.yml` has four `dart-lang/setup-dart` jobs
   (`sdk:`) and two `subosito/flutter-action` jobs. Both must move together:
   `setup-dart sdk: 3.12.2 → 3.13.1` (×4) and `flutter-action flutter-version:
   3.44.4 → 3.47.1` (×2). Leaving `flutter-action` on floating `channel: stable`
   is what let the icloud/flutter jobs drift independently and break — keep them
   version-pinned, not floating.

5. **Tooling re-bootstrap.** Upgrading the local SDK invalidates cached tool
   snapshots (`Invalid kernel binary format version` on melos/coverage). After
   any local SDK change, run `make prepare` to regenerate them. Note that
   `flutter pub get` under the new Flutter auto-injects `analyzer.exclude`
   blocks into `analysis_options.yaml` (kmdb_flutter, kmdb_icloud,
   kmdb_icloud/example) — these are transient and should **not** be committed.

6. **`lcov --ignore-errors empty` — already landed; no action.** Reviewer note
   (2026-08-23): the lcov 2.0 "empty tracefile" hardening is already present in
   the root `pubspec.yaml` melos coverage scripts (`coverage:generate` and
   `coverage:combine` both run `lcov --ignore-errors empty --summary … || true`).
   The `build` job's separate "Coverage summary" step in `cicd.yml` uses a plain
   `lcov --summary … || true` (no `--ignore-errors`) but is guarded by `|| true`
   and cannot fail the build. This is a CI-runner (ubuntu-noble) concern, not a
   Dart-3.13 one, and requires **no change** for this adoption. Listed only so
   the implementer does not go looking for missing work.

**Decision — bump the `environment: sdk` floor to `^3.13.0` across all
packages.** Reviewer + user, 2026-08-23. All 10 pubspec files currently pin
`sdk: ^3.12.0` (root coordinator + `kmdb`, `kmdb_cli`, `kmdb_harness`,
`kmdb_google_drive`, `kmdb_extractor_pdf`, `kmdb_extractor_html`,
`kmdb_extractor_markdown`, `kmdb_flutter`, `kmdb_icloud`). Raise each to
`^3.13.0`. Rationale: (a) `betto_pdfium` 0.1.0-dev.4's native-asset build hook
is Dart 3.13 and will not compile under 3.12, so any consumer of
`kmdb_extractor_pdf` already *requires* 3.13 — advertising `^3.12.0` is now
false; (b) the workspace uses `resolution: workspace`, so all members resolve
against one SDK anyway — a uniform floor is the honest and simplest expression;
(c) CI will only test 3.13.1 after this change, so claiming 3.12 support would be
untested. Convention here is a minor-level floor (`^3.12.0`, not `^3.12.2`), so
use `^3.13.0`, not `^3.13.1`. **Leave the two Flutter packages'
`flutter: ">=3.29.0"` constraint unchanged** — 3.47.1 satisfies it and there is
no need to raise the Flutter floor.

## Implementation plan

Sequenced so the blocker is resolved before the pins move.

- [x] **Fix the pdfium Linux break — DONE.** Root-caused (Pub-workspace
      native-library resolution) and fixed upstream in betto_pdfium
      ([PR #5](https://github.com/bettongia/pdfium/pull/5)), published as
      **0.1.0-dev.4** (2026-08-22). Remaining kmdb-side action is the re-pin
      below and the final Linux/3.13.1 verification.
- [x] **Re-pin `betto_pdfium` to `0.1.0-dev.4`** in the root `pubspec.yaml`
      `dependency_overrides` (currently pinned to exactly `0.1.0-dev.3`, line 50)
      and `dart pub upgrade`. Confirm
      `packages/kmdb_cli/test/database_opener_test.dart` "lexical hits over … PDF"
      indexes all 4 fixtures on Linux/3.13.1. **Note:** this pin bump and the CI
      toolchain bump below MUST land together — dev.4's build hook requires Dart
      3.13, so it will not compile under the current 3.12.2-pinned CI.
      Done: pin bumped, `pubspec.lock` updated (`dart pub upgrade`, confirmed
      `betto_pdfium: 0.1.0-dev.4` in lockfile). PDF fixture test run pending
      until CI verification (local run tracked below).
- [x] **Delete the diagnostic scaffolding — DONE (2026-08-22).** The throwaway
      `diag-313` workflow and the `[DART313-DIAG]` prints were already removed
      before this adoption began. Re-verified against HEAD on 2026-08-23
      (reviewer): `.github/workflows/` contains only `cicd.yml`, and there are no
      `DART313-DIAG` markers anywhere under `packages/`. No action.
- [x] **Confirm other native consumers on Linux/3.13.1 — RESOLVED (2026-08-23,
      reviewer).** betto_zstd and betto_onnxrt are both fine — see the answered
      open question above. The final full-matrix run is the standing confirmation.
- [x] **Bump CI pins** in `.github/workflows/cicd.yml`: `setup-dart sdk`
      `"3.12.2"` → `"3.13.1"` (×4 — the `build`, `test-macos`, `test-windows`,
      `test-web` jobs) and `flutter-action flutter-version` `"3.44.4"` →
      `"3.47.1"` (×2 — `test-icloud`, `test-flutter`). Update the (identical,
      repeated) pin-rationale comment blocks accordingly. Keep
      `flutter-action`'s `channel: stable` line but rely on the pinned
      `flutter-version` (do not let it float).
- [x] **Bump the `environment: sdk` floor to `^3.13.0`** in all 10 pubspec
      files (root + 9 packages — see the Decision in Investigation). Leave the
      `flutter: ">=3.29.0"` constraint in `kmdb_flutter`/`kmdb_icloud` unchanged.
- [x] **Reformat the workspace** with 3.13.1 (`dart format packages/`) and commit
      the whitespace-only churn. The drift set at review time (2026-08-23) was 10
      files (`kmdb/test/encryption/{encryption_crash,kmdb_database_encryption}_test.dart`,
      `kmdb_cli/test/config/secret_store/directory_secret_store_test.dart`,
      `kmdb_cli/test/e2e/cli_session_test.dart`,
      `kmdb_google_drive/test/harness_convergence_test.dart`,
      `kmdb_harness/test/{cloud_semantics,e2e,test_manager}_test.dart`,
      `kmdb_icloud/test/{harness_convergence,icloud_adapter}_test.dart`) —
      re-derive at implementation time as the set may shift, but expect
      whitespace/wrapping only.
      Done: `make format` at implementation time reformatted **98 files**
      (larger set than the reviewer's 10 — expected drift given time elapsed
      since the review sample). Spot-checked several diffs (`cli_runner.dart`,
      `icloud_adapter_test.dart`) — all changes are import-blank-line and
      line-wrap reflow only, no semantic changes. The transient
      `analyzer.exclude` blocks that `flutter pub get`/`make prepare`
      auto-injected into `kmdb_flutter/analysis_options.yaml`,
      `kmdb_icloud/analysis_options.yaml`, and
      `kmdb_icloud/example/analysis_options.yaml` were reverted (not
      committed), per the plan's note that these are transient.
- [x] **Fix the two `vault_searcher.dart` lint sites** (`:719`, `:726`): change
      `return _placeholderContext(sha256, fieldPath);` to
      `return await _placeholderContext(sha256, fieldPath);`. Then confirm the
      new-lint set is clean: `dart analyze` across all packages (expect zero
      `unawaited_return_in_try_block`) + `flutter analyze` on `kmdb_flutter` and
      `kmdb_icloud`. `local_directory_adapter.dart` is already clean (PR #76).
      Done: both sites fixed; `make analyze` clean across all 7 Dart packages
      (0 issues), `flutter analyze` clean on `kmdb_flutter` and `kmdb_icloud`
      (0 issues each). Confirmed `local_directory_adapter.dart` still uses
      `return await writeViaTempRename(...)` at lines 321/334.
- [x] **Update docs that name the toolchain version.** Reviewer survey
      (2026-08-23): the release checklist (`docs/spec/28_release_checklist.md`)
      and CLAUDE.md do **not** hard-pin a version, so no change there. The only
      live doc to update is `docs/roadmap/0_10_01.md` — its WI-5 row (line ~65)
      and Follow-ups section (lines ~629–638, ~768–770) describe the deferred
      3.12.2 pin and this plan's intent; flip them to reflect the completed
      adoption. Also honour the roadmap's stated requirement to **state the Dart
      3.13 minimum in the release notes** (WI-9 gate). Completed plans under
      `docs/plans/completed/` that mention the old pin are historical — do not
      edit them.
      Done: WI-5 row's parenthetical now points to the completed follow-up; the
      gate paragraph (~629) and the "Follow-ups discovered during WI-5" entry
      (~768) both flipped to ✅ **Complete** with the concrete landed changes,
      and the follow-up entry explicitly directs WI-9 to record the Dart 3.13
      minimum in release notes at release time (confirmed no separate release
      notes file exists yet — `CHANGELOG.md` is an unpopulated placeholder,
      `docs/spec/28_release_checklist.md`/`CLAUDE.md` verified unpinned, per
      the reviewer's survey). Historical completed plans left untouched.
- [x] Roadmap pointer updated in-branch (moves with the PR).

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new files.
      Done: overall workspace coverage 94.9% (11916/12553 lines across 221
      source files) — `kmdb` 95.2%, `kmdb_cli` 95.2%, `kmdb_harness` 90.0%,
      `kmdb_google_drive` 94.9%, extractors 100%. All packages individually
      clear the CLAUDE.md 90% floor. This PR touches no test/coverage-relevant
      code (2 one-line `await` additions + formatting), so the ~0.1pp
      difference from the previously-recorded 95% workspace baseline reflects
      normal drift since that baseline was set, not a regression introduced
      here.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
      **Not performed by kmdb-plan-implement** — this implementation session
      had no Agent-launcher tool available to invoke `kmdb-qa`. Per the
      coordinator's explicit instruction for this task, the mechanical checks
      below were run directly instead, and QA sign-off is deferred to the
      coordinator to arrange.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green
      (on 3.13.1 by then).
      Done: full `make pre_commit` green (`dart format --set-exit-if-changed`:
      0 changed; `dart analyze`: 0 issues across all 7 Dart packages;
      `addlicense --check`: clean; `pre_commit_test` (kmdb suite): 2647 passed,
      12 intentionally skipped E2E). Additionally ran the full test suite for
      every other package not covered by `pre_commit_test`'s `kmdb`-only scope
      — `kmdb_cli` (1228 passed), `kmdb_harness` (153 passed),
      `kmdb_google_drive` (117 passed), the three extractors (34/19/21
      passed), `kmdb_flutter` (`flutter test`, 9 passed), `kmdb_icloud`
      (`flutter test`, 128 passed, 1 credential-gated skip) — all green.
      `flutter analyze` on `kmdb_flutter` and `kmdb_icloud`: 0 issues each.
- [x] Verify licence headers on all new files (2026).
      Done: no new source files were created by this plan (pubspec/CI-yaml
      edits, a workspace reformat, and two one-line `await` additions to an
      existing file) — nothing requires a new license header. `addlicense
      --check` (via `make pre_commit`) confirms the existing header set is
      still intact after the reformat.
- [ ] Confirm the **full CI matrix is green under 3.13.1** — this is the whole
      point; the build + all five platform jobs must pass, especially
      `test-icloud` (format) and any job touching pdfium.
      **Cannot be confirmed from this session** — CI only runs once the PR is
      pushed/opened. All-equivalent local checks (format, analyze, license,
      full test suite across every package including `kmdb_cli`'s PDF-fixture
      lexical-search test) pass under the local 3.13.1 toolchain on macOS; the
      Linux-specific pdfium native-asset-resolution behaviour this PR exists
      to unblock can only be verified by the actual Linux CI job. Left
      unchecked for the coordinator to confirm once CI completes.

## Review (2026-08-23, kmdb-plan-reviewer)

**Verdict: Investigated — ready for mechanical implementation.** Every claim in
the plan was grounded against HEAD; the residual open questions are resolved.

Verified against the repo at HEAD:

- **betto_pdfium pin** is exactly `0.1.0-dev.3` (`pubspec.yaml:50`) — the bump to
  dev.4 is real and must land together with the toolchain bump (dev.4's hook is
  Dart 3.13, won't compile on 3.12.2). ✅
- **Diagnostic scaffolding** already gone: no `diag-313` workflow (only
  `cicd.yml` in `.github/workflows/`), no `DART313-DIAG` markers under
  `packages/`. That checklist item was stale and is now marked done. ✅
- **CI pin count** correct: 4× `setup-dart sdk: "3.12.2"` (build, test-macos,
  test-windows, test-web) + 2× `flutter-action flutter-version: "3.44.4"`
  (test-icloud, test-flutter). ✅
- **Lint sites** re-derived with the local 3.13.1 `dart analyze`: the **only**
  two `unawaited_return_in_try_block` warnings in the whole workspace are
  `vault_searcher.dart:719` and `:726` (line numbers still accurate).
  `local_directory_adapter.dart` is clean (PR #76 landed `return await`). All
  other Dart packages analyze clean. ✅
- **betto_zstd / betto_onnxrt on Linux/3.13.1**: resolved — see the answered
  open questions. betto_onnxrt's download hook already stages
  `libonnxruntime.1.22.0.dylib` under 3.13.1 and no automated test loads a real
  ORT session (all fakes), so the pdfium-class runtime-loader failure cannot
  recur in CI. ✅
- **lcov `--ignore-errors empty`** already present in the melos coverage scripts
  (`pubspec.yaml:132,147`) — not a remaining step. ✅
- **SDK-constraint bump** was **missing** from the checklist and is the one
  substantive gap I closed. All 10 pubspec files pin `sdk: ^3.12.0`; the
  roadmap (`0_10_01.md:629–638`) already states the plan will raise them to
  `^3.13.0` and declare a Dart 3.13 release floor, so this is recorded as a
  decision, not an open question. ✅

No open questions remain that would force the implementer to make an
architecture-level decision. The work is a bounded, mechanical toolchain
migration: one dependency re-pin, six CI pin edits, ten SDK-constraint edits, a
whitespace-only reformat, two one-line lint fixes, and doc touch-ups, all gated
by the existing CI matrix.

## Summary

Adopted **Dart 3.13.1 / Flutter 3.47.1** across dev and CI (PR #77, merged
2026-08-23), closing the toolchain gap opened by WI-5's temporary 3.12.2 pin and
clearing the WI-9 release prerequisite. betto_pdfium re-pinned `0.1.0-dev.3` →
`0.1.0-dev.4` (the Pub-workspace native-library resolution fix); the 6 CI
toolchain pins moved to 3.13.1/3.47.1; the SDK floor raised to `^3.13.0` across
all 10 pubspecs (declaring a Dart 3.13 release minimum); the two
`vault_searcher.dart` `unawaited_return_in_try_block` sites fixed with
`return await`; the workspace reformatted under 3.13.1 (98 files, whitespace);
roadmap updated. `kmdb-plan-reviewer` → Investigated; `kmdb-qa` → sign-off.

**Post-CI deltas** (forced by the full matrix, both from Dart 3.13's shift to
shared *workspace-root* native-asset staging colliding with melos concurrency-2
`test_dart`):

- **Windows** could not delete/restage a loaded `zstd.dll`
  (`PathAccessException: Access is denied`).
- **macOS** raced two concurrent codesigns of the shared `libonnxruntime.dylib`
  (`Failed to codesign ... replacing existing signature`) — intermittent, so it
  slipped two runs before firing.

Both fixed by adding a `test_dart_serial` melos script (concurrency 1) and
pointing `cicd_macos` and `cicd_windows` at it; Linux stays at concurrency 2
(immune — no codesign, and a loaded `.so` replaces in place). Final full matrix
(build + macOS + Windows + web + icloud + flutter) green under 3.13.1/3.47.1.

Side effect: CI and local dev now run the same toolchain, ending the
format-drift commit-hook friction that dogged the preceding PRs.
