# Adopt Dart 3.13.1 / Flutter 3.47.1 across dev and CI

**Status**: Open

**PR link**: _(none yet)_

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
- [ ] **Are other native-asset consumers affected on Linux/3.13.1?**
      Check `betto_zstd` (native-asset build hook, used everywhere) and
      `betto_onnxrt` (semantic search) — do their Linux native builds still work
      under 3.13.1? The `build`/`test-macos`/`test-windows`/`test-web` jobs all
      passed under 3.13.1 in PR #75's run, so betto_zstd looked fine on those
      platforms, but confirm Linux + onnxrt explicitly.
- [ ] **Does Flutter 3.47.1 introduce any other breaks?** `flutter analyze` on
      `kmdb_flutter` and `kmdb_icloud` was clean under 3.47.1 in PR #75; confirm
      again after the pdfium fix and re-run the full flutter test jobs.

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

2. **New lint `unawaited_return_in_try_block` (3.13.1).** Fires on 3 sites:
   - `packages/kmdb/lib/src/sync/local/local_directory_adapter.dart:255` — a
     **genuine crash-safety bug** (a bare `return future()` inside a
     `try`/`finally` releases the file lock and closes the handle before the
     write completes). **Being fixed separately** — see
     `plan_local_directory_adapter_unlock_ordering.md`. This adoption plan should
     not re-fix it; just confirm the lint is clean after that fix lands.
   - `packages/kmdb/lib/src/vault/search/vault_searcher.dart:719` and `:726` —
     `return _placeholderContext(…)` inside the try; fix with `return await` so
     the (unlikely) errors route through the enclosing rethrow/catch handlers.

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

## Implementation plan

Sequenced so the blocker is resolved before the pins move.

- [x] **Fix the pdfium Linux break — DONE.** Root-caused (Pub-workspace
      native-library resolution) and fixed upstream in betto_pdfium
      ([PR #5](https://github.com/bettongia/pdfium/pull/5)), published as
      **0.1.0-dev.4** (2026-08-22). Remaining kmdb-side action is the re-pin
      below and the final Linux/3.13.1 verification.
- [ ] **Re-pin `betto_pdfium` to `0.1.0-dev.4`** in the root `pubspec.yaml`
      `dependency_overrides` (currently a `git`/older pin) and `dart pub upgrade`.
      Confirm `packages/kmdb_cli/test/database_opener_test.dart` "lexical hits
      over … PDF" indexes all 4 fixtures on Linux/3.13.1.
- [ ] **Delete the diagnostic scaffolding** — the throwaway `diag-313` workflow
      and the three `[DART313-DIAG]` prints (see Investigation §3). Verify `main`
      is clean of the marker before adoption.
- [ ] **Confirm other native consumers on Linux/3.13.1** (betto_zstd,
      betto_onnxrt) — see open questions.
- [ ] **Bump CI pins** in `.github/workflows/cicd.yml`: `setup-dart sdk` →
      `3.13.1` (×4), `flutter-action flutter-version` → `3.47.1` (×2). Update the
      pin comments accordingly.
- [ ] **Reformat the workspace** with 3.13.1 (`dart format packages/…` across
      the build + icloud targets) and commit the whitespace-only churn.
- [ ] **Confirm the new-lint sites are clean:** `local_directory_adapter.dart`
      (fixed by its own plan) and `vault_searcher.dart:719,726` (`return await`).
      Run `dart analyze` across all packages + `flutter analyze` on the two
      Flutter packages.
- [ ] **Update any docs** that name the toolchain version (e.g. release
      checklist / integration guide, if they pin a Dart/Flutter version).
- [ ] Roadmap pointer updated in-branch (moves with the PR).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green
      (on 3.13.1 by then).
- [ ] Verify licence headers on all new files (2026).
- [ ] Confirm the **full CI matrix is green under 3.13.1** — this is the whole
      point; the build + all five platform jobs must pass, especially
      `test-icloud` (format) and any job touching pdfium.

## Summary

_To be completed when the work is done._
