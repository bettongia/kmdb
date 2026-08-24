# WI-9: Release dependency gate — promote the `betto_*` closure to `0.1.0` and tag KMDB

**Status**: Open

**PR link**: _(none yet)_

> **Provenance.** WI-9 of the 0.10.01 hardening track — **the last item, and the
> only irreversible one** (`docs/roadmap/0_10_01.md`). Everything else can be
> redone; publishing `0.1.0` of a package and then needing a change means burning
> that version number. Do not start until every other 0.10.01 work item is
> merged. **Re-sequencing (2026-08-24, maintainer):** publish the dependency
> closure first, then run **W6** (WI-10's code-health remainder) as the final
> readiness sweep against the promoted pins, then tag. W6 moves from "parallel
> anytime" to the last gate before the tag.

## Problem statement

The `betto_*` dependency closure is **12 packages**, all still at `-dev`
suffixes, consumed by KMDB via hosted `-dev` pins in `dependency_overrides`. A
`0.1.0` KMDB release cannot ship on `-dev` dependencies. WI-9:

1. Publishes all 12 at a suffix-free `0.1.0` (per-repo, **maintainer action** —
   publishing to pub.dev is never automated here), in dependency order.
2. Closes the review's release-readiness findings: **O-1** (`betto_abnf`
   undocumented), **O-1b** (`kmdb_flutter`/`kmdb_icloud` pins a dev behind and
   resolving independently), **O-2** (`kmdb_flutter` CI-lane coverage).
3. Promotes KMDB's `dependency_overrides` from `-dev` to `^0.1.0` and **re-runs
   the full suite against the promoted pins** — a green run on `-dev` pins is not
   evidence about the shipped artefact.
4. Runs **W6** (public-API audit, dead-code sweep, doc-comment audit, CHANGELOG
   accuracy incl. A5) as the final readiness check, plus the applicable
   `docs/spec/28_release_checklist.md` RC-items.
5. Tags KMDB `0.1.0`.

## The 12-package closure (to verify)

Currently pinned in `dependency_overrides` (`pubspec.yaml`): `betto_common`,
`betto_schema`, `betto_zstd` (already `0.1.0-dev.4`), `betto_mediatype_detector`,
`betto_lexical`, `betto_inferencing`, `betto_charset_detector`, `betto_pdfium`
(already `0.1.0-dev.4`), `betto_lang_detector` — **9 explicit**. Reaching KMDB
**transitively** and *not* currently pinned/documented: `betto_onnxrt` (via
`betto_inferencing`), `betto_icu` (via `betto_lexical`), and **`betto_abnf`** (via
`betto_schema` — O-1, absent from both the pins and CLAUDE.md). That is the 12.
**`betto_builder_tools` is NOT in the gate** — it is a `dev_dependencies` entry in
all consumers and never reaches a consumer's resolution.

## Open questions

- [ ] **Exact topological publish order.** Packages must publish bottom-up: a
      package cannot go to `0.1.0` while any dependency it declares is still an
      unpublished `0.1.0`. The precise order must be **derived from each
      package's own pubspec** (their inter-`betto_*` dependency declarations),
      not guessed. Known edges from CLAUDE.md (partial, to confirm):
      `betto_icu → betto_lexical`; `betto_onnxrt → betto_inferencing`;
      `betto_abnf → betto_schema`; `betto_pdfium → kmdb_extractor_pdf`. Likely
      leaves: `betto_common`, `betto_zstd`, `betto_abnf`, `betto_icu`,
      `betto_onnxrt`, `betto_pdfium`, `betto_mediatype_detector`. **Decision
      needed:** the full ordered list, produced by reading the 12 pubspecs.
- [ ] **Per-repo release readiness.** Each `betto_*` repo may have its own
      release bar before `0.1.0` (e.g. the maintainer flagged wanting "a more
      comprehensive release check on `betto_pdfium`" before its `0.1.0`; the zstd
      repo has already bumped its working copy to `0.1.0`). **Decision needed:**
      is each repo's own release process a prerequisite this plan just gates on,
      or does WI-9 only cover the KMDB-side promotion and assume each repo is
      independently released? (Recommended: WI-9 lists the order + the readiness
      bar, and treats each publish as a maintainer-owned per-repo step; the KMDB
      plan's implementable work is steps 2–5 below.)
- [ ] **KMDB's own version.** The workspace is `0.1.0-dev.1` (`pubspec.yaml:3`).
      Confirm the tag target is `0.1.0` and whether member package pubspecs carry
      independent versions that also need promoting.
- [ ] **Do the promoted deps stay in `dependency_overrides`, or move to real
      `dependencies`?** Overrides exist to pin `-dev`/path builds; once the deps
      are hosted `^0.1.0`, the override layer may be removable in favour of
      ordinary version constraints in each member pubspec. **Decision needed** —
      affects whether the final artefact resolves the way pub.dev consumers will.

## Investigation

_To be completed by the reviewer/implementer._ Anchor points:

- Current pins: `pubspec.yaml` `dependency_overrides` (lines 32–56).
- The closure and O-findings: `docs/roadmap/0_10_01.md` §"WI-9" and the
  release-readiness review's O-1/O-1b/O-2.
- Release infrastructure already in place: `docs/spec/28_release_checklist.md`
  (the RC-items, incl. RC-3 Windows / RC-25) and the completed
  `docs/plans/completed/plan_0_09_release_process_doc.md`.
- Dart 3.13 hard floor: **already satisfied** (workspace + CI on 3.13.1 / Flutter
  3.47.1; see `plan_dart_3_13_adoption.md`). No SDK work remains for WI-9.
- **O-1b** — inspect `kmdb_flutter` and `kmdb_icloud` pubspecs: they pin `kmdb`
  a dev release behind and resolve independently of the workspace; both must be
  reconciled to the `0.1.0` line.
- **O-2** — audit `.github/workflows/cicd.yml` for a lane that actually resolves
  and tests `kmdb_flutter` (it is outside the Dart-only workspace — see the
  workspace comment at `pubspec.yaml:19–24`).

## Implementation plan

**Phase A — dependency publishing (maintainer-owned, per repo, in DAG order):**

- [ ] Derive and record the exact topological publish order (open question 1).
- [ ] For each of the 12, in order: confirm the repo's own release readiness,
      set its pubspec inter-`betto_*` constraints to `^0.1.0`, publish `0.1.0`.
      (`betto_zstd` and `betto_pdfium` already at `0.1.0-dev.4`; the zstd repo has
      already bumped its working copy to `0.1.0`.) **Publishing is the
      maintainer's action** — this plan tracks order and readiness, it does not
      publish.

**Phase B — KMDB-side promotion (this repo):**

- [ ] **O-1:** add `betto_abnf` to CLAUDE.md's external-package list and to
      `dependency_overrides` (documented + pinned).
- [ ] Promote every `betto_*` override from its `-dev` pin to `^0.1.0`; resolve
      the removability of the override layer (open question 4).
- [ ] **O-1b:** reconcile `kmdb_flutter` / `kmdb_icloud` `kmdb` pins to the
      `0.1.0` line.
- [ ] **O-2:** confirm/add a CI lane that resolves and tests `kmdb_flutter`.
- [ ] Confirm KMDB member versions and the `0.1.0` tag target (open question 3).
- [ ] **Re-run the full suite against the promoted `^0.1.0` pins** — VM, web
      (`--platform chrome`), and the Flutter lanes — plus `make coverage` ≥
      baseline and the §18 benchmarks. This is the load-bearing verification: it
      is the first run against the actual shipped dependency artefacts.

**Phase C — W6 final readiness sweep (the re-sequenced gate):**

- [ ] Run **W6** (WI-10 code-health remainder) against the promoted tree:
      public-API surface audit, dead-code sweep, doc-comment audit, and CHANGELOG
      accuracy (incl. **A5** — the `ConsolidationCoordinator` required-`dbDir` and
      vault-envelope breaking-change notes, and the R-5 sync-root re-push upgrade
      note, which the CHANGELOG still omits). Coordinate a **`kmdb-spec-auditor`**
      pass (spec-vs-code truth) and a full **`kmdb-qa`** audit as part of this
      sweep.
- [ ] Run the applicable `docs/spec/28_release_checklist.md` RC-items, including
      **RC-3** (Windows, covers A6) and **RC-25**.

**Phase D — tag:**

- [ ] Tag KMDB `0.1.0` once A–C are green. **Irreversible; last.**

## Summary

_To be completed when the work is done._
