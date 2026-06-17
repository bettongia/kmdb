# Extract `betto_icu` — Standalone ICU Tokenizer Package

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/40

**Roadmap**: [v0.05 — Multi-platform pipelines § ICU](../roadmap/0_05.md#icu)

## Problem statement

KMDB's Unicode tokenization types (`Tokenizer` interface, `RegExpTokenizer`,
`IcuTokenizer`) are currently split between two KMDB-internal packages:

- `kmdb_lexical` owns `Tokenizer` and `RegExpTokenizer`.
- `kmdb_tokenizer_icu` owns `IcuTokenizer` and depends on `kmdb_lexical` for
  the interface.

Neither package has any dependency on KMDB-specific types. They form a
self-contained Unicode text-segmentation library that is useful to any Dart
application — yet they are locked inside the KMDB monorepo. This means:

- Other Bettongia projects (or external consumers) cannot take a standalone
  tokenizer dependency without pulling in all of KMDB.
- Consumers that want `IcuTokenizer` must add a second `kmdb_tokenizer_icu`
  dependency alongside `kmdb_lexical`.

The fix is to extract all three into a new standalone `betto_icu` package
(separate repo at `/Users/gonk/development/bettongia/icu`, matching the
`betto_zstd` / `betto_onnxrt` family convention), then wire `kmdb_lexical` to
depend on it and re-export its public surface.

See [docs/proposals/implemented/betto_icu.md](../proposals/implemented/betto_icu.md) for the full
proposal, rationale, and platform ICU availability table.

## Open questions

All questions from the proposal are resolved:

- [x] **Q1 — re-export or remove `RegExpTokenizer` from `kmdb_lexical`?**
  Re-export. Backward-compatible; existing `import 'package:kmdb_lexical/lexical.dart'`
  call sites continue to work.
- [x] **Q2 — who owns the `Tokenizer` interface?**
  `betto_icu` must own it — any other arrangement creates a circular dependency.
  `kmdb_lexical` re-exports it.
- [x] **Q3 — broader ICU surface in v1?**
  v1 is limited to `Tokenizer` / `IcuTokenizer` / `RegExpTokenizer`. Scope can
  expand incrementally under the `betto_icu` name.

## Investigation

### Files moving to `betto_icu`

| Source file | Destination in `betto_icu` |
|---|---|
| `packages/kmdb_lexical/lib/src/tokenizer.dart` | `lib/src/tokenizer.dart` |
| `packages/kmdb_lexical/lib/src/regexp_tokenizer.dart` | `lib/src/regexp_tokenizer.dart` |
| `packages/kmdb_lexical/test/regexp_tokeniser_test.dart` | `test/regexp_tokeniser_test.dart` |
| `packages/kmdb_tokenizer_icu/lib/src/icu_tokenizer.dart` | `lib/src/icu_tokenizer.dart` |
| `packages/kmdb_tokenizer_icu/test/icu_tokeniser_test.dart` | `test/icu_tokeniser_test.dart` |

### Import changes required after moving

| File | Current import | New import |
|---|---|---|
| `regexp_tokenizer.dart` | `import 'tokenizer.dart'` | unchanged (same package, same `src/`) |
| `icu_tokenizer.dart` | `import 'package:kmdb_lexical/lexical.dart' show Tokenizer` | `import 'tokenizer.dart'` |
| `icu_tokeniser_test.dart` | `import 'package:kmdb_lexical/...'; import 'package:kmdb_tokenizer_icu/...'` | `import 'package:betto_icu/betto_icu.dart'` |
| `regexp_tokeniser_test.dart` | `import 'package:kmdb_lexical/lexical.dart'` | `import 'package:betto_icu/betto_icu.dart'` |
| `kmdb_lexical/lexical.dart` | exports `src/tokenizer.dart`, `src/regexp_tokenizer.dart` | re-exports from `betto_icu` + also re-exports `IcuTokenizer` |

### `kmdb_tokenizer_icu` deprecation

`kmdb_tokenizer_icu` currently has one source file (`icu_tokenizer.dart`) and
one barrel (`kmdb_tokenizer_icu.dart`). After extraction, the package is
dissolved: its workspace entry in `pubspec.yaml` and its `packages/` directory
are removed. The package's `kmdb:` and `kmdb_lexical:` dependencies are both
dropped in the process.

### `kmdb_lexical` dependency graph change

Before:
```
kmdb_tokenizer_icu → kmdb_lexical (for Tokenizer)
                   → ffi, package:ffi
```

After:
```
kmdb_lexical → betto_icu (new)
betto_icu    → ffi, package:ffi
```

`kmdb_tokenizer_icu` is removed entirely.

### `betto_icu` pubspec

```yaml
name: betto_icu
description: >
  Unicode text tokenization for Dart — Tokenizer interface, IcuTokenizer
  (system ICU FFI, UAX #29), and RegExpTokenizer (pure Dart, Latin fallback).
version: 0.1.0
homepage: https://github.com/bettongia/icu

environment:
  sdk: ^3.12.0

dependencies:
  ffi: ^2.2.0

dev_dependencies:
  lints: ^6.0.0
  test: ^1.25.6
```

Note: `package:ffi` (pub.dev) provides `calloc` and `Utf8`. `dart:ffi` is an
SDK library; it needs no pubspec entry.

### Doc comment cleanup in moved files

`tokenizer.dart` currently contains forward references to `IcuTokenizer` in
`kmdb_tokenizer_icu` and a "future implementation" note. After extraction both
implementations live in the same package, so these comments must be updated to
remove the cross-package references and the "future implementation" framing.

`regexp_tokenizer.dart` contains a "Why not ICU now?" rationale block that is
no longer accurate. It should be condensed to a note that `IcuTokenizer` is the
preferred implementation for non-Latin scripts.

`icu_tokenizer.dart` references "KMDB" in several comments and doc strings that
should be generalised (the class is no longer KMDB-specific).

### Workspace / melos wiring

- Remove `packages/kmdb_tokenizer_icu` from the `workspace:` list in the root
  `pubspec.yaml`.
- Add `betto_icu: ^0.1.0` to `kmdb_lexical`'s `dependencies:` as a **regular
  pub.dev dependency**. Unlike the other `betto_*` packages (which are wired as
  bare deps with a `git:` ref in the root `dependency_overrides`), `betto_icu`
  is published to pub.dev at `0.1.0`, so it needs **no** `dependency_overrides`
  entry. See the B1/B2 resolution in the Review section.
- Remove `kmdb_tokenizer_icu` from any package that listed it as a dependency
  (currently only `kmdb_tokenizer_icu/pubspec.yaml` itself and any test runner
  paths; confirm `kmdb_cli` does not import it directly — grep confirms it does not).

### No build hook

`betto_icu` requires no `hook/build.dart`. ICU is a system library on all
target platforms; there is nothing to download, compile, or stage.

## Implementation plan

### Stage A — Create and verify the standalone package

_This stage produces a self-contained `betto_icu` package. Once complete, stop
and follow the **Stage gate** instructions below before continuing._

#### Phase 1 — Create `betto_icu` repo and package scaffold

- [ ] Create the directory `/Users/gonk/development/bettongia/icu/`.
- [ ] Initialise a git repository (`git init`).
- [ ] Write `pubspec.yaml` (content in the Investigation section above).
- [ ] Write `analysis_options.yaml` (`include: package:lints/recommended.yaml`).
- [ ] Add Apache 2.0 `LICENSE` file.
- [ ] Create `lib/src/` and `test/` directories.

#### Phase 2 — Copy and adapt source files

- [ ] Copy `tokenizer.dart` into `lib/src/tokenizer.dart`.
  - Remove the "future implementation" forward-reference paragraphs; update
    the doc comment to note that `IcuTokenizer` (in this same package) provides
    the full UAX #29 implementation.
  - Ensure the Apache 2.0 license header is present.
- [ ] Copy `regexp_tokenizer.dart` into `lib/src/regexp_tokenizer.dart`.
  - Import path `import 'tokenizer.dart'` is unchanged (same `src/` directory).
  - Remove the "Why not ICU now?" rationale block; replace with a one-line note
    that `IcuTokenizer` should be preferred for non-Latin scripts.
  - Update any remaining `kmdb_tokenizer_icu` references to `betto_icu`.
  - Ensure license header present.
- [ ] Copy `icu_tokenizer.dart` into `lib/src/icu_tokenizer.dart`.
  - Replace `import 'package:kmdb_lexical/lexical.dart' show Tokenizer'` with
    `import 'tokenizer.dart'`.
  - Update "KMDB" occurrences in doc comments to be package-neutral (e.g. "all
    of this package's target platforms").
  - Ensure license header present.
- [ ] Write `lib/betto_icu.dart` barrel:
  ```dart
  library;
  export 'src/tokenizer.dart' show Tokenizer;
  export 'src/icu_tokenizer.dart' show IcuTokenizer;
  export 'src/regexp_tokenizer.dart' show RegExpTokenizer;
  ```
  Add license header. **All three symbols (`Tokenizer`, `IcuTokenizer`,
  `RegExpTokenizer`) must be exported from this single barrel** — the
  consolidated ICU test (Phase 3) runs the shared contract suite against both
  `IcuTokenizer` and `RegExpTokenizer` and imports both from
  `package:betto_icu/betto_icu.dart`. Do not trim the barrel to `IcuTokenizer`
  only (the old `kmdb_tokenizer_icu.dart` barrel exported only `IcuTokenizer`;
  the test got `RegExpTokenizer` from a second import — consolidation changes
  that). See B4 in the Review section.

#### Phase 3 — Copy and adapt tests

- [ ] Copy `icu_tokeniser_test.dart` into `test/icu_tokeniser_test.dart`.
  - Replace imports: `package:kmdb_lexical/lexical.dart` and
    `package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart`
    → `package:betto_icu/betto_icu.dart`.
  - Ensure license header present.
- [ ] Copy `regexp_tokeniser_test.dart` into `test/regexp_tokeniser_test.dart`.
  - Replace import: `package:kmdb_lexical/lexical.dart`
    → `package:betto_icu/betto_icu.dart`.
  - Ensure license header present.
- [ ] Run `dart pub get` then `dart test` from `/Users/gonk/development/bettongia/icu/`
      to confirm all tests pass in the new standalone package.
- [ ] Commit all files on a branch (do **not** open the PR yet — the GitHub
      repo is created in the Stage gate below).

---

### ⛔ Stage gate — manual steps required before Stage B

Before continuing to Stage B, the following steps must be completed manually:

1. **Create the GitHub repository** at `github.com/bettongia/icu` and push the
   Stage A branch.
2. **Open the Stage A PR** against the now-existing `bettongia/icu` repo and
   merge it.
3. **Publish `betto_icu 0.1.0` to pub.dev.** This is a deliberate, user-decided
   departure from the other `betto_*` packages (which are git-ref-only) — see
   the B1/B2 resolution in the Review section. `betto_icu` is a self-contained,
   build-hook-free library and is published so KMDB can consume it as a plain
   `^0.1.0` pub.dev dependency with **no** `dependency_overrides` entry.
4. **Confirm `betto_icu 0.1.0` resolves from pub.dev** (e.g. `dart pub global`
   or a scratch `pub get`) before starting Stage B.

Once those steps are done, return here and continue with Stage B.

---

### Stage B — Wire `betto_icu` into the KMDB workspace

_Prerequisite: `betto_icu 0.1.0` is published and resolvable from pub.dev._
_Note: published as `0.1.0-dev.1`; constraint used is `^0.1.0-dev.1`._

#### Phase 4 — Wire `betto_icu` into the KMDB workspace

- [x] Update `packages/kmdb_lexical/pubspec.yaml`:
  - Add `betto_icu: ^0.1.0-dev.1` under `dependencies:` as a **regular pub.dev
    dependency**. Do **not** add any `dependency_overrides` entry for
    `betto_icu`, and do **not** declare it bare — it is a published package, not
    a git ref. (This differs from `betto_zstd`/`betto_common`/etc., which remain
    git-ref overrides.)
- [x] Update `packages/kmdb_lexical/lib/lexical.dart`:
  - Remove `export 'src/tokenizer.dart' show Tokenizer`.
  - Remove `export 'src/regexp_tokenizer.dart' show RegExpTokenizer`.
  - Add re-exports from `betto_icu`:
    ```dart
    export 'package:betto_icu/betto_icu.dart'
        show Tokenizer, RegExpTokenizer, IcuTokenizer;
    ```
- [x] Delete `packages/kmdb_lexical/lib/src/tokenizer.dart`.
- [x] Delete `packages/kmdb_lexical/lib/src/regexp_tokenizer.dart`.
- [x] Delete `packages/kmdb_lexical/test/regexp_tokeniser_test.dart`.
- [x] Run `dart pub get` from the workspace root to verify dependency resolution.
- [x] Run `cd packages/kmdb_lexical && dart test` to confirm lexical tests pass.

#### Phase 5 — Dissolve `kmdb_tokenizer_icu`

- [x] Remove `packages/kmdb_tokenizer_icu` from the `workspace:` list in the
      root `pubspec.yaml`.
- [x] Delete the `packages/kmdb_tokenizer_icu/` directory.
- [x] Run `dart pub get` from the workspace root.
- [x] Run `make analyze` to confirm no broken imports remain.

#### Phase 6 — Full pre-commit gate and documentation

- [x] Run `make pre_commit` and confirm it passes cleanly (format_check,
      analyze, license_check, scoped tests).
- [x] Run `make test` to confirm the full workspace test suite passes.
- [x] Update `CLAUDE.md` `Repository Layout` section:
  - Remove `kmdb_tokenizer_icu` from the package list.
  - Add `betto_icu` to the external `betto_*` packages list.
- [x] Update stale `kmdb_tokenizer_icu` doc-comment references in
      `kmdb_inferencing` to point at `betto_icu` (B3). These are doc-only — no
      imports, no pubspec dep — so they will not break the build, but they go
      stale the moment `kmdb_tokenizer_icu` is dissolved:
  - `packages/kmdb_inferencing/lib/src/bert_tokenizer.dart` (the
    `package:kmdb_tokenizer_icu` references near lines ~30, ~46, ~81, including
    the `import 'package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart';` example —
    update to `package:betto_icu/betto_icu.dart`).
  - `packages/kmdb_inferencing/lib/src/embedding_model.dart` (line ~78).
  - [x] After editing, update `packages/kmdb_inferencing/README.md` if it also
        names `kmdb_tokenizer_icu` (grep to confirm — updated).
- [ ] Open a PR for the KMDB monorepo changes.

## Review (2026-06-08, kmdb-plan-reviewer)

**Status downgraded from `Investigated` to `Questions`.** The plan is well
structured, the staging is sensible, and the factual claims I could verify are
mostly accurate. But there are a handful of concrete gaps that would force the
Sonnet implementer to make decisions or improvise — and one outright incorrect
instruction. These must be closed before this is mechanically implementable.

### What I verified as correct

- All five files in the "Files moving" table exist exactly where claimed.
- Import paths are accurate: `regexp_tokenizer.dart` imports `tokenizer.dart`;
  `icu_tokenizer.dart` imports `package:kmdb_lexical/lexical.dart show Tokenizer`.
- `kmdb_cli` does **not** import `kmdb_tokenizer_icu` — confirmed; the only match
  is a stale `.dart_tool` build artifact, not source.
- `kmdb_lexical/lib/lexical.dart` exports `src/tokenizer.dart` and
  `src/regexp_tokenizer.dart` as described (it also exports `stemmer` and
  `stopwords`, which correctly stay put).
- The proposal (`docs/proposals/implemented/betto_icu.md`) and roadmap anchor
  (`docs/roadmap/0_05.md#icu`) both exist.

### Blocking issues (all resolved — see follow-up below)

- [x] **B1 — `dependency_overrides` form for `betto_icu`.** **Resolved
  (user, 2026-06-08):** `betto_icu` is **published to pub.dev at `0.1.0`** and
  consumed as a **regular pub.dev dependency** — `betto_icu: ^0.1.0` under
  `kmdb_lexical/pubspec.yaml` `dependencies:`, with **no** `dependency_overrides`
  entry. This deliberately departs from the bare-dep-plus-git-ref pattern used by
  the other `betto_*` packages, which is acceptable here because `betto_icu` is a
  self-contained, build-hook-free library suitable for pub.dev publication. The
  Investigation "Workspace / melos wiring" and Stage B Phase 4 instructions have
  been updated accordingly.

- [x] **B2 — pub.dev publication path.** **Resolved (user, 2026-06-08):** pub.dev
  publication is the chosen path, not deferred future work. The git-ref-vs-pub.dev
  either/or has been removed from the Stage gate and Phase 4. The Stage gate now
  mandates publishing `0.1.0` to pub.dev and confirming it resolves before
  Stage B begins.

- [x] **B3 — `kmdb_inferencing` doc-comment references to `kmdb_tokenizer_icu`.**
  **Resolved:** added to the Phase 6 checklist (update
  `bert_tokenizer.dart`, `embedding_model.dart`, and `README.md` if it names the
  package) to point at `betto_icu`. Confirmed 2026-06-08 these references still
  exist (4 in `lib/src`, all doc-only — no imports, no pubspec dep).

- [x] **B4 — ICU test relies on all three symbols from the single barrel.**
  **Resolved:** Phase 2 (barrel step) now states explicitly that `Tokenizer`,
  `IcuTokenizer`, and `RegExpTokenizer` must all be exported from
  `betto_icu.dart`, because the consolidated `icu_tokeniser_test.dart` runs the
  shared contract suite against both `IcuTokenizer` and `RegExpTokenizer` and
  imports both from that one barrel. Confirmed 2026-06-08: the current test
  imports `show Tokenizer, RegExpTokenizer` from `kmdb_lexical` plus a second
  import of `kmdb_tokenizer_icu` for `IcuTokenizer` — consolidation collapses
  these to the single `betto_icu` barrel.

### Stage gate assessment (updated)

With B1/B2 resolved, the gate's output is fully deterministic: a published
`betto_icu 0.1.0` on pub.dev, consumed as `^0.1.0`. There is no
`dependency_overrides` value to decide and no git-ref/tag/SHA to pin — pub.dev
version resolution handles it. The gate no longer leaves anything undecided for
Stage B.

The PR-before-repo ordering nit is fixed: Stage A Phase 3 now commits the branch
without opening a PR, and the Stage gate creates the repo, pushes, then opens and
merges the Stage A PR before publication.

### Non-blocking observations

- **License header inconsistency to normalise.** The existing files use a
  `// Copyright 2026 The Authors` header. The plan says "Apache 2.0 license
  header" — fine, but the implementer should copy the project's
  `header_template.txt` form with the current year, not invent one. The two
  existing barrels even differ in their license URL indentation
  (`http://` vs `https://`); pick the `header_template.txt` canonical form.
- **`betto_icu` SDK constraint `^3.12.0`** matches the workspace — good.
- **Coverage:** the moved code already has tests moving with it, so the 90% bar
  is preserved by construction. No new untested surface is introduced. Worth a
  one-line note that `betto_icu`'s own CI/coverage is now that repo's concern,
  not KMDB's — KMDB coverage no longer counts those files.
- The `kmdb_tokenizer_icu` pubspec carries a `kmdb:` dependency (not just
  `kmdb_lexical:`). The plan's claim that dissolving it "drops the `kmdb:` and
  `kmdb_lexical:` dependencies" is accurate — confirmed.

### Recommendation

Solid, low-risk refactor with a clean problem statement and correct file
inventory. Resolve **B1–B4** (B1/B2 are the real blockers — they're an incorrect
instruction, not just a missing detail) and tighten the Stage gate ordering.
Once the `dependency_overrides` form is pinned to the git-ref pattern and the
`kmdb_inferencing` doc churn is captured, this clears the implementation-ready
bar and can return to `Investigated`.

## Follow-up review (2026-06-08, kmdb-plan-reviewer)

**Status promoted to `Investigated`.** All four blocking items are resolved and
checked off above.

- **B1/B2** resolved by user decision: `betto_icu` is published to pub.dev at
  `0.1.0` and consumed as a plain `betto_icu: ^0.1.0` dependency in
  `kmdb_lexical/pubspec.yaml` — **no `dependency_overrides` entry**. This is a
  deliberate departure from the other `betto_*` git-ref packages and is recorded
  in the Investigation, Stage gate, and Phase 4. The pubspec `version` is set to
  `0.1.0`.
- **B3** captured as a Phase 6 checklist item (inferencing doc-comment + README
  churn).
- **B4** pinned as an explicit barrel-export requirement in Phase 2.
- Stage-gate ordering fixed: branch is committed in Stage A; repo creation, PR,
  and publication happen in the gate before Stage B.

The remaining non-blocking observations (license-header normalisation via
`header_template.txt`, the SDK-constraint note, and the coverage-ownership note)
are advisory and do not block implementation. The implementer should still apply
the `header_template.txt` canonical header form rather than inventing one.

An implementer could now execute this plan end-to-end without making design
decisions. Cleared for `kmdb-plan-implement`.

## Summary

Extracted `Tokenizer`, `RegExpTokenizer`, and `IcuTokenizer` from the KMDB
monorepo into the standalone `betto_icu` package published to pub.dev at
`0.1.0-dev.1`. `kmdb_lexical` now re-exports all three symbols from
`betto_icu` via a single `export 'package:betto_icu/betto_icu.dart'`
declaration; existing call sites are fully backward-compatible. The
`kmdb_tokenizer_icu` workspace package was dissolved (directory deleted,
workspace entry removed). The full pre-commit gate and test suite pass
cleanly. Doc-comment references to `package:kmdb_tokenizer_icu` in
`kmdb_inferencing` were updated to `package:betto_icu`.
