# Self-healing native-asset cache for the dylib bundling flake

**Status**: Draft (needs investigation → `kmdb-plan-reviewer`)

**PR link**: _(none yet)_

> **Provenance.** Filed 2026-09-06 after the ONNX-runtime dylib bundling flake
> interrupted a routine doc-only commit for the third+ time this cycle (see the
> `dev-env-sandbox` memory's two "corrupted native-asset dylib" / "codesign
> race" entries). Deferred to v0.2.0 as a dev-ergonomics improvement — it is not
> release-blocking. Kept off the `0.1.0` gate deliberately so it doesn't race the
> integration-guide PR, which touches the same Makefiles/CI.

## Problem statement

Every `dart test` that imports the `kmdb` barrel triggers the `betto_onnxrt`
native-asset build hook, whose final step copies `libonnxruntime.*.dylib` into
`packages/kmdb/.dart_tool/lib/`, rewrites its install names, and codesigns it
(`package:dartdev/src/native_assets_macos.dart`). That step is intermittently
flaky in this environment, in two distinct failure shapes — both surface through
`make pre_commit`'s test step and can fail an otherwise-clean (even doc-only)
commit:

1. **Corruption after an interrupted build** —
   `install_name_tool: truncated or malformed object (LC_SEGMENT_64 … extends
   past the end of the file)`. A native-asset build was killed mid-write,
   leaving a truncated dylib in the cache.
2. **Codesign race during bundling** — `install_name_tool: … is not a Mach-O
   file`, `Failed to codesign … replacing existing signature`, or
   `… No such file or directory` on a file that existed moments earlier. A
   timing/concurrency issue in the copy-then-rewrite-then-sign sequence.

The manual workaround (documented in the `dev-env-sandbox` memory) is: `rm -rf
packages/kmdb/.dart_tool/{lib,native_assets.yaml,hooks_runner}` then re-warm with
a single `dart test <file>`, then retry. This is a `dartdev`-level flake, not a
defect in our code — so the goal is a **Makefile helper that automates the
recovery**, not a code fix.

## The key open question (drives the whole design)

**Can the bundled dylib be rebuilt offline?** Clearing `.dart_tool/lib` +
`native_assets.yaml` but **keeping `hooks_runner`** (which holds the *downloaded*
ORT artifact) — does a re-warm then rebuild the bundled copy **without hitting
the network**? This matters because:

- If **yes**: the helper (and an optional commit-hook retry) can run **in the
  sandbox**, since no network is needed — the ideal outcome.
- If **no** (clearing forces a re-download, as observed on 2026-09-06 when a
  full clear tripped an SSL handshake under the sandbox): the helper must either
  be a **manual, sandbox-off** target, or be scoped to clear only the bundled
  copy and accept that a full heal needs network.

Investigation must settle this empirically (clear only `lib`+`native_assets.yaml`,
keep `hooks_runner`, run `dart test` in-sandbox, observe whether it downloads).

## Candidate design (to refine after the open question is answered)

- **`make heal_native_assets`** — a target (backed by a small script, per the
  "Dart over Python for tools" preference — a Dart or shell script under
  `tool/`) that clears the minimal cache set needed to fix the flake and
  re-warms with one fast `dart test`. Run on demand when the flake hits.
- **Optional: retry-once-on-dylib-error guard around `pre_commit_test`** — wrap
  the scoped test step so that, on a failure whose output matches the known
  dylib-flake signatures above, it heals and retries once before giving up. Only
  viable as an unattended commit-hook step if the open question resolves to
  "offline rebuild works"; otherwise keep healing manual.

## Anchor points

- `make_cicd.mk` / root `Makefile` — where `pre_commit` and `pre_commit_test`
  are defined (confirm exact target locations during investigation).
- `packages/kmdb/.dart_tool/{lib,native_assets.yaml,hooks_runner}` — the cache
  set involved.
- The `dev-env-sandbox` memory — the two prior flake entries and the manual
  workaround this plan automates.
- `tool/` — where a helper script should live (Dart preferred).

## Open questions

- [ ] **Q1** — the offline-rebuild question above (the make-or-break for whether
      the commit-hook retry is feasible in-sandbox).
- [ ] **Q2** — script language/placement: a `tool/heal_native_assets.dart` vs. a
      shell script, and whether it lives in the root or `packages/kmdb`.
- [ ] **Q3** — should the guard wrap only `pre_commit_test`, or all `melos`
      test entry points? Scope it to the smallest surface that removes the pain.

## Implementation plan

_To be completed once Q1–Q3 are settled._

## Summary

_To be completed when the work is done._
