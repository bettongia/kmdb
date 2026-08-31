# CI hardening: Flutter native build + publish dry-run gate (release-ninja #3 + #4)

**Status**: Draft (needs investigation → `kmdb-plan-reviewer`)

**PR link**: _(none yet)_

> **Provenance.** Release-blocker-adjacent findings **#3** and **#4** from the
> pre-0.1.0 `bettongia:release-ninja` audit (2026-08-26). Both are CI/workflow
> gaps, not code defects: the release ships artefacts that CI never fully
> exercises. Part of WI-9 Phase C release-readiness (`docs/roadmap/0_10_01.md`);
> should land before the 0.1.0 tag. Grouped because both are edits to
> `make_cicd.mk` + `.github/workflows/cicd.yml` with no product-code change and
> low risk. Deliberately separate from the web-barrel fix
> (`plan_0_10_01_web_barrel_compile.md`) and the SAHPool export follow-up.

## Problem statement

Two CI blind spots let release-facing breakage pass every lane:

**#3 — the `kmdb_icloud` Flutter plugin's native code is never compiled.**
`make cicd_icloud` runs only `flutter pub get`, `dart format`, `flutter analyze`,
and `flutter test` (all Dart, against a `FakeICloudSyncChannel`) —
`make_cicd.mk:102-110`. `kmdb_icloud` ships real native surface: Swift plugins
(`ios/.../ICloudSyncPlugin.swift`, `macos/.../ICloudSyncPlugin.swift`) and
`Package.swift` SPM manifests for both platforms. **No `flutter build macos` /
`flutter build ios` ever compiles the Swift/SPM layer**, so a broken
`Package.swift` or Swift plugin would pass every CI lane and only fail in a
consumer's Xcode build. Compounding it: the example app
(`packages/kmdb_icloud/example/`) has **only a `macos/` runner** — no `ios/`
runner exists — yet `packages/kmdb/README.md` asserts "iOS, Android (Flutter):
Full support." (`kmdb_flutter` has no custom native code — it's a pure Dart
add-on over `flutter_secure_storage`/`cryptography_flutter` — so this gap is
`kmdb_icloud`-specific.)

**#4 — no publish-validation lane.** Eight packages publish at the tag (six via
`dart pub publish`), and there is no `dart pub publish --dry-run` step anywhere in
CI. Release-ninja ran the dry-runs manually and found `kmdb`, `kmdb_cli`, and
`kmdb_google_drive` clean *today* (0 warnings; 5 expected workspace-local
`dependency_overrides` hints), but nothing keeps them clean — a future path-dep,
metadata slip, or constraint regression would surface only when a human runs
`dart pub publish` at release time.

## Investigation

**#3 anchor points.**
- `make_cicd.mk:102-110` (`cicd_icloud`) — the Dart-only lane to extend.
- `packages/kmdb_icloud/{ios,macos}/kmdb_icloud/` — the Swift plugin sources + `Package.swift`.
- `packages/kmdb_icloud/example/` — has `macos/` only; **no `ios/` runner**.
- `packages/kmdb/README.md` — the "iOS … Full support" claim to either
  build-verify or qualify.
- CLAUDE.md's SPM rule: any iOS/macOS runner work must use **Swift Package
  Manager**, not CocoaPods — do not add a `Podfile` or Pods xcconfig refs to the
  example app; see `docs/plans/completed/plan_icloud_spm.md`.

The cheap, high-value step is `flutter build macos` of the `kmdb_icloud` example
(the macOS runner already exists) — that alone compiles the Swift plugin + SPM
manifest end-to-end. The iOS side is more work: an `ios/` runner must be created
(SPM-based) before `flutter build ios --no-codesign` can run. See Open Question 1
for whether iOS build-verification is in scope for 0.1.0 or whether the README
claim is qualified instead.

**#4 anchor points.**
- The six auto-published packages: `kmdb`, `kmdb_cli`, `kmdb_google_drive`,
  `kmdb_extractor_pdf`, `kmdb_extractor_html`, `kmdb_extractor_markdown`.
- `docs/releasing/0.1.0.md` Stage 2 — the publish list this lane should mirror.
- `dart pub publish --dry-run` from each package dir. It exits non-zero on real
  problems; the workspace-root `dependency_overrides` produce **expected**
  informational hints (not failures) — the lane must tolerate those without
  masking real warnings. Confirm whether the dry-run needs any network/auth
  (it validates locally + checks pub.dev for name availability; should run on
  the standard CI runner). `kmdb_flutter`/`kmdb_icloud` are `publish_to: none`
  (hand-published) and are **out** of the auto dry-run matrix.

## Open questions

- [ ] **Q1 — iOS scope for #3.** Two options: (a) add `flutter build macos` of the
      example **and** create an SPM-based `ios/` runner + `flutter build ios
      --no-codesign`, fully build-verifying the README's "iOS: Full support"
      claim; or (b) add `flutter build macos` now (cheap, runner exists) and
      **qualify the README** iOS claim to "supported; macOS build-verified in CI,
      iOS build-verification is a fast-follow" until an iOS runner exists.
      Recommendation: **(b) for the 0.1.0 tag** — macOS build already exercises the
      shared Swift/SPM plugin code, and standing up an iOS runner (SPM linking the
      CloudKit surface) is a larger task that shouldn't gate the tag. Reviewer to
      decide.
- [ ] **Q2 — where do the new steps run?** `cicd_icloud`/`cicd_flutter` run on
      macOS runners already. Confirm the `flutter build macos` step fits the
      existing `test-icloud` job (it does — macOS runner, Flutter toolchain
      present) and that the publish-dry-run matrix belongs in the Dart `test`/build
      job (Linux) rather than a new job. Confirm GitHub Actions versions stay on
      the non-deprecated majors (CLAUDE.md: `actions/checkout@v6`).
- [ ] **Q3 — dry-run failure semantics.** Should the lane fail the build on any
      `dart pub publish --dry-run` warning, or only on error/non-zero exit? The
      expected `dependency_overrides` hints must not fail it. Recommend: gate on
      the command's exit code (non-zero = fail), and additionally grep the output
      to fail on unexpected `Package validation found the following` *errors* while
      allowing the known overrides hint. Reviewer to confirm the exact filter.

## Implementation plan

**#3 — Flutter native build:**

- [ ] Add `cd packages/kmdb_icloud/example && flutter build macos` to
      `cicd_icloud` (`make_cicd.mk`), after the existing analyze/test steps, so the
      Swift plugin + `Package.swift` are compiled end-to-end. Keep SPM-only (no
      Podfile).
- [ ] Per Q1: either create the SPM-based `ios/` runner + add `flutter build ios
      --no-codesign`, **or** qualify the `packages/kmdb/README.md` iOS support
      claim to match what CI verifies.
- [ ] Confirm the `test-icloud` job in `.github/workflows/cicd.yml` invokes the
      updated `cicd_icloud` and passes on the macOS runner.

**#4 — publish dry-run gate:**

- [ ] Add a `cicd_publish_dryrun` target to `make_cicd.mk` that runs `dart pub
      publish --dry-run` in each of the six auto-published package dirs, with the
      Q3 pass/fail semantics (fail on non-zero / unexpected validation errors;
      tolerate the known workspace-overrides hint).
- [ ] Wire it into `.github/workflows/cicd.yml` as a step/job on an existing
      runner (per Q2).
- [ ] Document the lane in `docs/releasing/0.1.0.md` (Stage 2) as the automated
      pre-publish check.

**Then:** `kmdb-qa` → `kmdb-pre-commit` → PR. (Mostly workflow YAML + `make`
targets; the main verification is that the new CI steps actually run green on the
real runners — call that out for QA, since a green local `make pre_commit` does
not exercise the macOS/iOS build or the dry-run matrix.)

## Summary

_To be completed when the work is done._
