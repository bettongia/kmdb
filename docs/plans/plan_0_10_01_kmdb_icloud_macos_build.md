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

_To be completed — this needs `kmdb-architect` input on the Flutter-plugin SPM
structure and likely hands-on macOS-build iteration (which only truly validates
on a macOS runner / local macOS build)._ Anchor points:

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

- [ ] **Q1 — Is `kmdb_icloud` 0.1.0 macOS-buildable by a consumer today?**
      Reproduce cleanly: from a fresh checkout (or after `rm -rf
      packages/kmdb_icloud/example/macos/Flutter/ephemeral`), run `flutter build
      macos --debug` in the example. If it fails, this is a real 0.1.0 defect and
      rises in priority. If it passes (ephemeral regenerated correctly), the CI
      failure is a checkout/generate-ordering issue and the fix is a CI/build
      step, not a plugin fix. **This determines severity and scope — answer
      before designing the fix.**
- [ ] **Q2 — Fix location:** plugin `Package.swift` path, example `macos/` Runner
      regeneration, or a CI generate-before-build step? Depends on Q1.
- [ ] **Q3 — iOS:** the deferred `ios/` runner from the CI-hardening plan is still
      out of scope; but if Q1 shows a macOS SPM defect, check whether the iOS
      plugin (`ios/kmdb_icloud/Package.swift`) has the same `../FlutterFramework`
      pattern and would fail equivalently for an iOS consumer.

## Implementation plan

_To be completed once the investigation (esp. Q1) settles the direction. It will
include: the `FlutterFramework`/SPM fix (or CI generate step), re-adding
`flutter build macos --debug` to `cicd_icloud`, and — if Q1 finds a real defect —
a note/fix for the iOS plugin and any README/spec correction about macOS support._

## Summary

_To be completed when the work is done._
