# kmdb_icloud macOS SPM build: fix `FlutterFramework` resolution + gate it in CI

**Status**: Draft (needs investigation → `kmdb-architect` then `kmdb-plan-reviewer`)

**PR link**: _(none yet)_

> **Provenance.** Split out of the CI-hardening slice
> (`plan_0_10_01_ci_hardening_flutter_publish.md`, release-ninja #3) on
> 2026-09-02 after its `flutter build macos --debug` step **failed on CI** (run
> 33564788829, PR #87 `test-icloud`). #3 assumed the native build would "just
> work" once CI ran it; instead the build surfaced a real defect. The publish
> dry-run half (#4) shipped separately in PR #87. Part of WI-9 Phase C
> release-readiness — **potentially a 0.1.0-blocking `kmdb_icloud` defect** (see
> below), so it should be triaged before the tag.

## Problem statement

`flutter build macos --debug` of the `kmdb_icloud` example fails to compile the
Swift plugin:

```
packages/kmdb_icloud/macos/kmdb_icloud/Sources/kmdb_icloud/ICloudSyncPlugin.swift:16:8:
  error: unable to resolve module dependency: 'Flutter'
```

The plugin's `Package.swift` declares its Flutter dependency as
`.package(name: "FlutterFramework", path: "../FlutterFramework")` — i.e.
`packages/kmdb_icloud/macos/FlutterFramework/`. **That directory does not exist
and is not tracked in git.** The only `FlutterFramework` SPM package present is
Flutter's *ephemeral, generated* one under
`packages/kmdb_icloud/example/macos/Flutter/ephemeral/Packages/.packages/FlutterFramework/`,
which is **gitignored** (`example/macos/.gitignore`: `**/Flutter/ephemeral/`) and
so absent on a clean checkout until a Flutter build regenerates it. On CI's fresh
checkout the plugin's `../FlutterFramework` path can't resolve, and `import
Flutter` fails.

This was invisible until now because **no CI lane ever compiled the plugin's
native code**: `cicd_icloud` was Dart-only (against a fake channel), and
`kmdb_flutter` — the other Flutter package — has no macOS native code at all, so
`cicd_flutter` never builds native either. Release-ninja #3 existed precisely to
close this blind spot.

**Two things to establish and fix:**
1. **Is this a real consumer-facing defect?** If a downstream macOS app that
   depends on `kmdb_icloud` would hit the same `FlutterFramework` resolution
   failure, then `kmdb_icloud` 0.1.0 does not build on macOS as shipped — a
   genuine release problem, not just a CI gap. Determine this first (see Open
   Questions).
2. **Make the macOS build green and gate it in CI** — re-add the
   `flutter build macos --debug` step to `cicd_icloud` (reverted from PR #87)
   once the underlying build works.

## Investigation

### Findings (2026-09-02 — local clean-checkout reproduction)

Reproduced the CI failure locally in `packages/kmdb_icloud/example`:
`flutter clean` (removes the gitignored `macos/Flutter/ephemeral/`) →
`flutter pub get` → `flutter build macos --debug`. Two decisive results:

1. **The SPM / `FlutterFramework` module resolves fine locally.** The build got
   **past** Swift compilation of the plugin — there was **no** "unable to resolve
   module dependency: 'Flutter'" error locally, even on a freshly-cleaned tree.
   So the plugin's `Package.swift` / `../FlutterFramework` wiring is **not** a
   fundamental defect; `flutter pub get` regenerates the ephemeral
   `FlutterFramework` and the plugin compiles against it. This makes the CI
   "unable to resolve module" error most likely a **cold-checkout SPM-resolution
   ordering issue** on the runner (Xcode's SPM package graph not resolved before
   `flutter build`), not a shipping defect. **Preliminary Q1 answer: NOT a
   consumer-facing `kmdb_icloud` SPM defect.**

2. **The example cannot build unsigned on CI — a hard entitlements wall.** The
   local build instead failed at codesigning:
   `"Runner" has entitlements that require signing with a development
   certificate.` The example's `macos/Runner/{DebugProfile,Release}.entitlements`
   declare **iCloud/CloudKit + push** capabilities
   (`com.apple.developer.icloud-services: CloudKit`,
   `com.apple.developer.icloud-container-identifiers:
   iCloud.com.bettongia.kmdb.probe`, `com.apple.developer.aps-environment`).
   These require a **real Apple Developer signing identity / provisioning
   profile** — an unprovisioned GitHub runner cannot satisfy them, and
   `--debug`'s ad-hoc "Sign to Run Locally" signing is **not** sufficient because
   entitled capabilities need a provisioned cert. This is inherent to it being an
   *iCloud* example, not a wiring bug.

**Reframing.** #3 is therefore **not** "add a `flutter build macos` line." The
entitled example app cannot be built on an unprovisioned CI runner at all, and
the plugin itself already compiles. The real question is **how (or whether) to
build-verify the Swift plugin's native compilation in CI without tripping the
entitled-app signing wall** — see the revised options below. This is why it was
right to split #3 out of the CI-hardening PR.

**Candidate directions (to evaluate — none chosen):**
- **Strip/override entitlements for a CI-only build** of the example (build a
  variant with no iCloud/CloudKit/push entitlements so ad-hoc signing suffices) —
  compiles the plugin's Swift without needing a provisioned cert. Likely the
  lightest path; verify it still exercises the plugin's `import Flutter` +
  compilation.
- **Compile the plugin scheme directly via `xcodebuild`** (e.g. `xcodebuild
  build -scheme kmdb_icloud ... CODE_SIGNING_ALLOWED=NO`) instead of
  `flutter build macos` of the entitled app — build the native target without the
  app-level entitlements/signing. Needs the SPM package graph resolved first
  (`-resolvePackageDependencies`), which also addresses finding 1's cold-checkout
  resolution gap.
- **Provision CI signing** (Apple Developer cert + profile via encrypted
  secrets) — heaviest; exposes a signing identity to CI; almost certainly
  overkill for build-verification.
- **Accept macOS native isn't CI-build-verified**, rely on the plugin compiling
  locally (it does) + a documented manual release-checklist build, and record an
  RC entry in `docs/spec/28_release_checklist.md`.

### Anchor points

_Needs `kmdb-architect` input on the Flutter-plugin SPM structure and hands-on
macOS-build iteration (only truly validates on a macOS runner / local macOS
build)._

- `packages/kmdb_icloud/macos/kmdb_icloud/Package.swift` — the `.package(name:
  "FlutterFramework", path: "../FlutterFramework")` declaration and the target's
  `.product(name: "FlutterFramework", …)` use.
- `packages/kmdb_icloud/example/macos/Flutter/ephemeral/` — where Flutter
  actually generates `FlutterFramework` and `FlutterGeneratedPluginSwiftPackage`
  (gitignored).
- `packages/kmdb_icloud/example/macos/.gitignore` — `**/Flutter/ephemeral/`.
- `docs/plans/completed/plan_icloud_spm.md` — the reference SPM migration this
  plugin was built from; CLAUDE.md cites its `FlutterFramework` pattern as
  correct. **Reconcile:** either the pattern regressed against the current
  Flutter version (3.47.1 / Dart 3.13.1), or the example runner is stale and
  needs regeneration, or the CI build needs an extra generate step before the
  build.
- The `kmdb_flutter` package as a *negative* reference (no macOS native → never
  built → why the gap existed).

Likely directions to evaluate (not yet decided):
- Whether `flutter build macos` on a **clean** checkout regenerates the ephemeral
  `FlutterFramework` and wires the plugin correctly, and if not, what step is
  missing (`flutter pub get` in the example is already run by `cicd_icloud` but
  evidently isn't enough).
- Whether the plugin's `../FlutterFramework` path is correct for how Flutter lays
  out the SPM package graph at build time, or whether the example's `macos/`
  Runner project (committed) is stale relative to the current Flutter SPM
  integration and should be regenerated (SPM-only, no CocoaPods — CLAUDE.md).
- Whether a local `flutter build macos --debug` in `packages/kmdb_icloud/example`
  reproduces the CI failure on a clean tree (note: it may *pass* locally because
  the gitignored `ephemeral/` is already present from prior local builds —
  reproduce on a clean checkout / after removing `example/macos/Flutter/ephemeral`).

## Open questions

- [x] **Q1 — Is `kmdb_icloud` 0.1.0 macOS-buildable by a consumer today?**
      **Preliminary answer (2026-09-02): most likely YES / not a consumer SPM
      defect.** The local clean-checkout reproduction resolved the
      `FlutterFramework` module and compiled the plugin's Swift (see Findings 1);
      it failed only at the entitled-app codesigning step (Finding 2), which a
      consumer with their own signing set up would pass. **Still to confirm** on
      a truly cold environment (a fresh clone on a machine with no warm Xcode
      DerivedData / SPM cache) that the module resolves there too — the CI "unable
      to resolve" error means the cold-runner path differs from the warm-local
      one. If a cold clone also fails to resolve, severity rises.
- [ ] **Q2 — How to build-verify the plugin's native compile in CI given the
      entitlements wall?** (Replaces the earlier "fix location" framing.) Choose
      among the candidate directions above: strip entitlements for a CI-only
      build, `xcodebuild` the plugin scheme with `CODE_SIGNING_ALLOWED=NO` (+
      `-resolvePackageDependencies` to also fix Finding 1's cold-resolution gap),
      provision CI signing, or defer to a manual RC-checklist build. This is the
      core design decision and needs `kmdb-architect` + macOS iteration.
- [ ] **Q3 — iOS parity:** the iOS plugin (`ios/kmdb_icloud/Package.swift`) uses
      the same `../FlutterFramework` pattern; if a cold-resolution defect is
      confirmed for macOS (Q1), check iOS equivalently. iOS build-verification
      (a new `ios/` runner) remains out of scope for the tag regardless.

## Implementation plan

_To be completed once the investigation (esp. Q1) settles the direction. It will
include: the `FlutterFramework`/SPM fix (or CI generate step), re-adding
`flutter build macos --debug` to `cicd_icloud`, and — if Q1 finds a real defect —
a note/fix for the iOS plugin and any README/spec correction about macOS support._

## Summary

_To be completed when the work is done._
