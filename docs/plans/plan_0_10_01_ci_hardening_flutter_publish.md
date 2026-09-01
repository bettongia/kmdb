# CI hardening: Flutter native build + publish dry-run gate (release-ninja #3 + #4)

**Status**: Investigated (reviewer pass 2026-09-01 resolved Q2/Q3 empirically;
Q1/Q1b resolved by the maintainer 2026-09-01 — macOS-only build, defer iOS,
touch no README)

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

- [x] **Q1 — iOS build-verification scope for #3. RESOLVED (maintainer,
      2026-09-01): option (b) — macOS only, defer iOS.** Add `flutter build
      macos --debug` of the example now (the macOS runner exists and it compiles
      the shared Swift plugin + `Package.swift` end-to-end); the SPM-based `ios/`
      runner + `flutter build ios --no-codesign` is a post-0.1.0 fast-follow, not
      a tag gate.
- [x] **Q1b — which README claim does deferring iOS verification touch?
      RESOLVED (maintainer, 2026-09-01): option (i) — touch no README.** The
      macOS build simply *adds* coverage; no existing claim is false. Explicitly
      do **not** edit `packages/kmdb/README.md`'s "iOS, Android (Flutter): Full
      support" row (it is a true statement about the pure-Dart core), and do not
      add a CI-status note to `kmdb_icloud/README.md`. Original reviewer analysis
      retained below for the record.

      The original plan proposed qualifying
      `packages/kmdb/README.md`'s "iOS, Android (Flutter): Full support" row.
      **Reviewer flag: that is the wrong README for this risk.** `packages/kmdb`
      is the pure-Dart core library with *no native code*; its iOS/Android
      claim is about the Dart library running under Flutter, which the
      native-build gap does not threaten. The uncompiled-native-code risk (#3)
      is entirely in **`kmdb_icloud`**, a separate package that already scopes
      itself correctly ("iOS and macOS only", `kmdb_icloud/README.md:7`) and
      whose README makes **no CI-build-verification claim** to walk back. So the
      honest options are: (i) touch no README — the macOS build simply *adds*
      coverage and no existing claim is false; or (ii) add a one-line CI-status
      note to `kmdb_icloud/README.md` recording that macOS is build-verified in
      CI and iOS is not yet. The reviewer recommends **(i) for the tag** and
      explicitly **not** editing `packages/kmdb/README.md`, whose "Full support"
      row is a true statement about the pure-Dart core and out of scope here.
      Maintainer to confirm.
- [x] **Q2 — where do the new steps run? RESOLVED (reviewer).** The
      `flutter build macos` step goes in `cicd_icloud` (make) / the `test-icloud`
      job (`.github/workflows/cicd.yml:162`, `macos-latest`, Flutter toolchain
      already present) — no new job needed. The publish-dry-run belongs in a
      **new, dedicated `publish-dryrun` job on `ubuntu-latest` with
      `needs: build`**, mirroring the shape of `test-web`. Rationale: do **not**
      append the six dry-runs to the existing `build` job — that job is already
      the long critical-path gate (coverage + benchmarks + doc site) that every
      other job depends on, and each dry-run resolves the whole workspace + hits
      the network. A sibling job keeps it off the critical path. **Network/auth
      (verified empirically 2026-09-01):** `dart pub publish --dry-run` **needs
      pub.dev network** (it resolves the workspace and checks name availability)
      but needs **no auth/credentials** — it ran clean here with no pub token.
      All GitHub runners have pub.dev egress. Keep `actions/checkout@v6` and the
      pinned `dart-lang/setup-dart@v1 / sdk: 3.13.1` used by the other Linux
      jobs; introduce no new or deprecated actions.
- [x] **Q3 — dry-run failure semantics. RESOLVED (reviewer, empirically).**
      Verified by running `dart pub publish --dry-run` in
      `packages/kmdb_google_drive` on 2026-09-01 (clean today):
      - The command **exits 0** even with the 5 workspace-override hints. Hints
        do **not** raise the exit code; only genuine validation *errors* do.
      - The 5 hints are one-per-overridden-dependency
        (`meta`/`uuid`/`cbor`/`web`/`charset`), each the text *"Non-dev
        dependencies are overridden in ../../pubspec.yaml."* The count is
        **per-package** (only overrides that appear in that package's resolution
        are reported), so it is **not** always 5 — do **not** hardcode `== 5`.
      - The output ends with a single machine-parseable summary line:
        `Package has N warnings and M hints.`

      **Exact contract the implementer must apply (no guessing):**
      1. Run `dart pub publish --dry-run` in each of the six package dirs,
         capturing combined stdout+stderr and the exit code.
      2. **Fail** the lane for a package if its **exit code is non-zero**
         (validation errors, resolution/network failure).
      3. **Also fail** if the summary line reports **`warnings` > 0** — parse
         `Package has ([0-9]+) warnings? and ([0-9]+) hints?` and gate on the
         first capture group. This is required *because warnings do not change
         the exit code*, so exit-code alone would miss them, and a warning
         (e.g. missing example, over-length description) is a real
         release-quality signal we want to block on.
      4. **Ignore the hint count entirely.** Do **not** grep for the substring
         `Package validation found the following` — that phrase appears for
         *hints too* (`"...found the following 5 hints"`), so grepping it would
         false-positive on the expected override hints. The whole point of
         parsing the `warnings` count instead is to tolerate hints while still
         catching warnings.
      If the summary line is absent (e.g. the command aborted before
      validation), treat that as a failure via the non-zero exit code from step 2.

## Implementation plan

**#3 — Flutter native build:**

- [ ] Add `cd packages/kmdb_icloud/example && flutter build macos --debug` to
      `cicd_icloud` (`make_cicd.mk`, after the existing `flutter test` step) so
      the Swift plugin + `Package.swift` compile end-to-end. Keep SPM-only (no
      `Podfile`, no Pods xcconfig — CLAUDE.md / `plan_icloud_spm.md`). **Use
      `--debug`**, not release: `flutter build macos` has no `--no-codesign`
      flag (that is iOS-only), and a debug build uses "Sign to Run Locally"
      (ad-hoc) signing that succeeds on an unprovisioned CI runner, whereas a
      release build can demand a distribution identity. If even the debug build
      hits a codesigning wall on `macos-latest`, that is the one genuine
      unknown here — see the QA note below; it must be confirmed green on the
      real runner, not just locally.
- [ ] Per **Q1 (maintainer)**: only if the maintainer picks option (a), create
      the SPM-based `ios/` Runner and add `flutter build ios --no-codesign`.
      Under the recommended option (b) this checklist item is a no-op for the
      tag.
- [ ] Per **Q1b (maintainer)**: do **not** edit `packages/kmdb/README.md` under
      the recommended answer. If the maintainer chooses to record CI status,
      add the note to `packages/kmdb_icloud/README.md` only.
- [ ] Confirm the `test-icloud` job (`.github/workflows/cicd.yml:162`) invokes
      the updated `cicd_icloud` and passes on the `macos-latest` runner. No
      workflow YAML change is needed for #3 — the job already calls
      `make cicd_icloud`; only the make target gains a step.

**#4 — publish dry-run gate:**

- [ ] Add a `cicd_publish_dryrun` target to `make_cicd.mk` that iterates the six
      auto-published package dirs (`kmdb`, `kmdb_cli`, `kmdb_google_drive`,
      `kmdb_extractor_pdf`, `kmdb_extractor_html`, `kmdb_extractor_markdown`) and
      applies the **Q3 contract exactly**: fail on non-zero exit, and fail if the
      parsed `warnings` count from the `Package has N warnings and M hints.`
      summary line is > 0; ignore the hint count. The six names are the single
      source of truth for this matrix — mirror `docs/releasing/0.1.0.md` Stage 2
      (which additionally lists `kmdb_flutter`/`kmdb_icloud` as *hand-published*
      / `publish_to: none` — those are **out** of this matrix). Note the target
      needs no `melos bootstrap`: `dart pub publish --dry-run` resolves the
      workspace itself; a `dart pub get` at the workspace root first is optional
      for determinism but not required.
- [ ] Add a **new `publish-dryrun` job** to `.github/workflows/cicd.yml`:
      `runs-on: ubuntu-latest`, `needs: build`, `actions/checkout@v6`,
      `dart-lang/setup-dart@v1` with `sdk: "3.13.1"`, the pub cache step, then
      `- run: make cicd_publish_dryrun`. Do **not** fold it into the `build`
      job (Q2 rationale).
- [ ] Document the lane in `docs/releasing/0.1.0.md` (Stage 2) as the automated
      pre-publish check — a sentence noting that `publish-dryrun` gates every
      push/PR so Stage 2's real `dart pub publish` calls should never be the
      first time a validation error is seen.

**Then:** `kmdb-qa` → `kmdb-pre-commit` → PR. (Mostly workflow YAML + `make`
targets; the main verification is that the new CI steps actually run green on the
real runners — call that out for QA, since a green local `make pre_commit` does
not exercise the macOS build or the dry-run matrix.)

## Reviewer notes (2026-09-01)

**Both gaps confirmed against the code:**

- `cicd_icloud` (`make_cicd.mk:102-110`) and `cicd_flutter`
  (`make_cicd.mk:120-136`) are Dart-only — no `flutter build` step. Confirmed.
- The `kmdb_icloud` example has a `macos/` runner but **no `ios/`** directory —
  confirmed by listing `packages/kmdb_icloud/example/`. `Package.swift` SPM
  manifests exist for **both** `ios/kmdb_icloud/` and `macos/kmdb_icloud/`
  plugin trees, and the example has **no `Podfile`/Pods xcconfig** — the SPM
  constraint is already satisfied and must stay that way.
- `.github/workflows/cicd.yml` wires `make cicd_icloud` on the `test-icloud`
  job (`macos-latest`, line 162) and `make cicd_flutter` on `test-flutter`
  (`macos-latest`, line 199). Every secondary job already uses
  `actions/checkout@v6` and pinned `sdk: 3.13.1` / Flutter `3.47.1` — the new
  job must match, and introduces no deprecated action.
- `#4` matrix confirmed: `kmdb`, `kmdb_cli`, `kmdb_google_drive`,
  `kmdb_extractor_{pdf,html,markdown}` are the six with no `publish_to: none`;
  `kmdb_flutter`, `kmdb_icloud`, `kmdb_harness` are `publish_to: none`.
- The 5 root `dependency_overrides` are `meta`/`uuid`/`cbor`/`web`/`charset`
  (`pubspec.yaml:32-45`) — these are what produce the dry-run hints; the
  `betto_*` closure now resolves from member `dependencies:` (WI-9), so it does
  **not** contribute overrides hints. Verified live: `kmdb_google_drive`
  dry-run today = **0 warnings, 5 hints, exit 0**.

**Scope note — this plan is CI/workflow only, no product code.** That matches
its provenance and keeps risk low. The one residual real-runner risk is the
macOS codesigning behaviour of `flutter build macos` on `macos-latest`; the
`--debug` choice above is the mitigation, and QA must treat "green on the real
runner" as the acceptance signal (local `make pre_commit` cannot exercise it).

**Resolution → `Investigated` (2026-09-01):** Q2 and Q3 were fully pinned by
the reviewer (network/auth, runner placement, exact pass/fail filter — no
implementer judgement needed). Q1/Q1b were the two genuine maintainer decisions
and are now answered: **Q1 = option (b)** (macOS-only build via `flutter build
macos --debug`; iOS runner deferred to a post-0.1.0 fast-follow) and **Q1b =
option (i)** (touch no README — the macOS build only adds coverage; the pure-Dart
core's "Full support" row stays, and `kmdb_icloud` gets no CI-status note). With
those settled, every step is mechanical.

## Summary

_To be completed when the work is done._
