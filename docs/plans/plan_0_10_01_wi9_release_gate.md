# WI-9: Release dependency gate — promote the `betto_*` closure to `0.1.0` and tag KMDB

**Status**: Investigated

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

- [x] **Exact topological publish order.** **Resolved empirically** — the
      maintainer published all 12 bottom-up and a clean re-resolve confirmed the
      order held (last: `betto_onnxrt` → `betto_inferencing`). See Phase A.
- [x] **Per-repo release readiness.** **Moot** — all 12 `betto_*` are now
      published at `0.1.0`. Each repo's own release bar was a maintainer-owned
      per-repo prerequisite that has been satisfied; WI-9's KMDB-side work is
      steps 2–5.
- [x] **KMDB's own version + tag target.** **Resolved (2026-08-25 reviewer pass
      — see "Reviewer decisions" below).** Tag target is stable suffix-free
      **`0.1.0`**. Six publishable members carry independent `0.1.0-dev.1`
      versions that must move to `0.1.0`; the root coordinator's `version:` is
      cosmetic (`publish_to: none`) but bumps too as the release-train label.
- [x] **Do the promoted deps stay in `dependency_overrides`, or move to real
      `dependencies`?** **Resolved (2026-08-25 reviewer pass — see below).** The
      load-bearing fix is promoting each **member `dependencies:`** constraint
      from `^0.1.0-dev.x` to `^0.1.0`; `dependency_overrides` is consumer-local
      and does **not** describe how a pub.dev consumer of `kmdb` resolves. After
      member promotion the root betto_* override entries are redundant and are
      **removed**, so the workspace resolves the same way a consumer does.

## Reviewer decisions (2026-08-25)

Both remaining live questions are resolved, grounded in the member pubspecs on
HEAD.

### Q4 — member `dependencies:` promotion is the real fix; the override layer is removed

`dependency_overrides` is a **consumer-local** mechanism: pub.dev ignores it
when `kmdb` is pulled in as a dependency. So the root override block does **not**
describe how a pub.dev consumer of `kmdb` resolves `betto_*` — the member
`dependencies:` blocks do. On HEAD those are still `-dev`:

- `packages/kmdb/pubspec.yaml` declares 8 betto_* deps at `^0.1.0-dev.x`
  (`betto_schema` dev.2, `betto_zstd` dev.3, `betto_mediatype_detector` dev.1,
  `betto_common` dev.2, `betto_lexical` dev.2, `betto_inferencing` dev.3,
  `betto_charset_detector` dev.2, `betto_lang_detector` dev.1).
- `packages/kmdb_cli/pubspec.yaml`: `kmdb`, `kmdb_google_drive`,
  `kmdb_extractor_{html,markdown,pdf}`, `betto_inferencing` — all `^0.1.0-dev.x`.
- `packages/kmdb_google_drive/pubspec.yaml`: `kmdb: ^0.1.0-dev.1`.
- `packages/kmdb_extractor_pdf/pubspec.yaml`: `kmdb: ^0.1.0-dev.1`,
  `betto_pdfium: ^0.1.0-dev.3`.
- `packages/kmdb_extractor_html/pubspec.yaml`: `kmdb: ^0.1.0-dev.1`.
- `packages/kmdb_extractor_markdown/pubspec.yaml`: `kmdb: ^0.1.0-dev.1`.

A caret range on a prerelease (`^0.1.0-dev.2` ⇒ `>=0.1.0-dev.2 <0.2.0`) does
technically *admit* `0.1.0`, so a consumer would not hard-fail — but it still
advertises a prerelease floor, still permits `-dev` `betto_*` to be pulled into a
consumer's resolution, and makes `dart pub publish` emit the "packages dependent
on a pre-release should themselves be published as a pre-release" warning. All
three are wrong for a clean stable `0.1.0`. **Decision:** promote every member
`dependencies:` betto_*/inter-kmdb constraint from `^0.1.0-dev.x` to `^0.1.0`
(exact file list in the Phase B checklist below). `kmdb_harness`'s blank
`kmdb:`/`uuid:` constraints stay blank — it is permanently `publish_to: none` and
never reaches a consumer's resolution.

**Override layer — removed, not kept.** Once member constraints are `^0.1.0` and
`0.1.0` is the only published `betto_*`, the root `dependency_overrides` betto_*
entries are redundant *for resolution*. Keeping them would mask the member
constraints — a workspace green run would then not be evidence about how a
consumer resolves (exactly the trap the problem statement's step 3 warns
against). **Decision:** delete the betto_* entries from the root
`dependency_overrides` (lines 42–54, i.e. `betto_common`, `betto_schema`,
`betto_abnf`, `betto_zstd`, `betto_mediatype_detector`, `betto_lexical`,
`betto_icu`, `betto_inferencing`, `betto_onnxrt`, `betto_charset_detector`,
`betto_pdfium`, `betto_lang_detector`) so the workspace resolves via the member
constraints — the same path a pub.dev consumer takes. This makes the Phase B
full-suite re-run load-bearing. Keep the **non-betto** overrides (`meta`, `uuid`,
`cbor`, `web`, `charset`) — they are workspace-wide transitive unification pins,
outside WI-9's scope; do not churn them here. `betto_icu`/`betto_onnxrt` need no
explicit entry once removed — they are transitive via `betto_lexical` /
`betto_inferencing` and resolve to `0.1.0` from those direct constraints.

The Flutter packages (`kmdb_flutter`, `kmdb_icloud`) carry their own mirrored
betto_* overrides and consume `kmdb` via `path:`. Once `kmdb`'s own
`dependencies:` are `^0.1.0`, those betto_* resolve to `0.1.0` transitively, so
their mirrored overrides also become redundant. Removing them is a consistency
tidy-up (it retires the "keep in sync with root" burden the pubspec comments
describe) but is **optional and lower priority** — both packages are
`publish_to: none` and hand-published outside the Dart pipeline; their real
publish-time pubspec surgery is already documented in
`docs/releasing/README.md`'s hand-publish appendix.

### Q3 — versions to promote and the tag target

- **Tag target: `0.1.0`** (stable, suffix-free) — this is the whole premise of
  WI-9 (drop `-dev`).
- **Root coordinator `version:` (`pubspec.yaml:3`, `0.1.0-dev.1`)** — cosmetic
  (`publish_to: none`, consumed by nobody), but `docs/releasing/README.md`
  treats it as the release-train label and versions all members to match. Bump
  it to `0.1.0` for consistency; it is not load-bearing.
- **Member `version:` bumps `0.1.0-dev.1 → 0.1.0` (six publishable members):**
  `packages/kmdb/pubspec.yaml` (**the load-bearing one — what consumers depend
  on**), `packages/kmdb_cli/pubspec.yaml`,
  `packages/kmdb_google_drive/pubspec.yaml`,
  `packages/kmdb_extractor_pdf/pubspec.yaml`,
  `packages/kmdb_extractor_html/pubspec.yaml`,
  `packages/kmdb_extractor_markdown/pubspec.yaml`.
- **No change:** `kmdb_harness` (`0.1.0`, `publish_to: none`, never published),
  `kmdb_flutter` / `kmdb_icloud` (`0.1.0`, `publish_to: none`, hand-published).

**Consequential doc work (surfaced by Q3/Q4).** `docs/releasing/README.md`'s
"Version-bump rules" section currently *justifies* the first release staying at
`0.1.0-dev.1` precisely "to sidestep a stable package depending on prerelease
`betto_*` constraints." WI-9 removes that premise, so that paragraph and the
Stage 1 step-5 guidance ("member-to-member constraints ... `kmdb:
^0.1.0-dev.1`") must be updated to the `0.1.0` line, and a new per-release
checklist `docs/releasing/0.1.0.md` created from `TEMPLATE.md` (the existing one
is `0.1.0-dev.1.md`). These are added as Phase B/C checklist items below.

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

- [x] Derive and record the exact topological publish order (open question 1).
      Validated empirically: the maintainer published all 12 (last: `betto_onnxrt`
      then `betto_inferencing`, which depends on it), and a clean re-resolve
      confirmed the order held.
- [x] **All 12 published at suffix-free `0.1.0`** (maintainer, 2026-08-24/25):
      `betto_common`, `betto_schema`, `betto_abnf`, `betto_zstd`,
      `betto_mediatype_detector`, `betto_lexical`, `betto_icu`,
      `betto_inferencing`, `betto_onnxrt`, `betto_charset_detector`,
      `betto_pdfium`, `betto_lang_detector`. `betto_builder_tools` correctly not
      in the gate (dev-dependency only).

**Phase B — KMDB-side promotion (this repo):**

> **Progress — PR (this branch, 2026-08-25).** The pin promotion + O-1 doc + the
> full **Dart-workspace** verification are done here. A clean re-resolve lands
> every `betto_*` at exactly `0.1.0` (no `-dev`, no conflict), and all seven Dart
> packages pass against the shipped artefacts: kmdb 2653, kmdb_cli 1240,
> extractor_pdf 34, extractor_html 19, extractor_markdown 21, google_drive 117,
> harness 153. **O-1b + O-2 landed in a follow-up PR** (Flutter override
> reconciliation + CI-lane confirmation; `kmdb_flutter` 9 / `kmdb_icloud` 128
> green at `0.1.0`).
>
> **Reviewer update (2026-08-25):** the override-layer + version/tag questions
> are now resolved (see "Reviewer decisions"), and they surfaced **required
> member-side work that the earlier "pin promotion" did not cover**: the member
> `dependencies:` blocks still declare `betto_* ^0.1.0-dev.x` (the root
> overrides masked this), and six member `version:` fields are still
> `0.1.0-dev.1`. **Remaining Phase B** is therefore: promote member
> `dependencies:` to `^0.1.0`, remove the redundant root betto_* overrides, bump
> the six member versions + root to `0.1.0`, update `docs/releasing/`, then re-run
> the full CI matrix (VM + `test-web`/Chrome + Flutter lanes) with `make
> coverage`/benchmarks against the promoted, override-free tree.

- [x] **O-1:** `betto_abnf` added to CLAUDE.md's external-package list and to
      `dependency_overrides`. Also documented `betto_charset_detector` and
      `betto_lang_detector` (equally in the closure, previously undocumented).
- [x] Promote every `betto_*` override from its `-dev` pin to `^0.1.0` (and add
      `betto_icu`/`betto_onnxrt` explicitly so the override list is the full
      documented closure). Override-layer removability deferred (open question 4 —
      follow-on).
- [x] **O-1b:** reconciled `kmdb_flutter` / `kmdb_icloud` `dependency_overrides`
      betto_* blocks (were stale at `^0.1.0-dev.1/dev.3` and missing packages) to
      mirror the root's promoted `^0.1.0` closure. Both use `kmdb` via `path`, so
      `kmdb` already tracks local source — the drift was the betto_* overrides.
      `betto_pdfium` intentionally omitted (neither Flutter package depends on the
      pdf extractor). Verified with Flutter: both resolve every betto_* to exactly
      `0.1.0` and pass — `kmdb_flutter` 9, `kmdb_icloud` 128.
- [x] **O-2:** confirmed — a `test-flutter` CI lane (`make cicd_flutter`: format,
      analyze, `flutter test` + ≥90% coverage) and a `test-icloud` lane already
      exist in `.github/workflows/cicd.yml` (macOS runners). No new lane needed.
- [ ] **Q4 — promote member `dependencies:` constraints from `^0.1.0-dev.x` to
      `^0.1.0`** (the load-bearing fix; overrides do not reach pub.dev
      consumers). Exact edits:
      - `packages/kmdb/pubspec.yaml`: `betto_schema`, `betto_zstd`,
        `betto_mediatype_detector`, `betto_common`, `betto_lexical`,
        `betto_inferencing`, `betto_charset_detector`, `betto_lang_detector`
        → `^0.1.0`.
      - `packages/kmdb_cli/pubspec.yaml`: `kmdb`, `kmdb_google_drive`,
        `kmdb_extractor_html`, `kmdb_extractor_markdown`, `kmdb_extractor_pdf`,
        `betto_inferencing` → `^0.1.0`.
      - `packages/kmdb_google_drive/pubspec.yaml`: `kmdb` → `^0.1.0`.
      - `packages/kmdb_extractor_pdf/pubspec.yaml`: `kmdb`, `betto_pdfium`
        → `^0.1.0`.
      - `packages/kmdb_extractor_html/pubspec.yaml`: `kmdb` → `^0.1.0`.
      - `packages/kmdb_extractor_markdown/pubspec.yaml`: `kmdb` → `^0.1.0`.
      - Leave `kmdb_harness`'s blank `kmdb:`/`uuid:` constraints as-is
        (`publish_to: none`, never published).
- [ ] **Q4 — remove the betto_* entries from the root `dependency_overrides`**
      (`pubspec.yaml` lines 42–54: `betto_common`, `betto_schema`, `betto_abnf`,
      `betto_zstd`, `betto_mediatype_detector`, `betto_lexical`, `betto_icu`,
      `betto_inferencing`, `betto_onnxrt`, `betto_charset_detector`,
      `betto_pdfium`, `betto_lang_detector`). Keep the non-betto overrides
      (`meta`, `uuid`, `cbor`, `web`, `charset`). This makes the workspace
      resolve the way a pub.dev consumer resolves `kmdb`, so the re-run below is
      real evidence about the shipped artefact.
- [ ] _(Optional, consistency)_ Remove the mirrored betto_* overrides from
      `kmdb_flutter`/`kmdb_icloud` pubspecs (redundant once `kmdb`'s own
      `dependencies:` are `^0.1.0`; they resolve `betto_*` transitively). Lower
      priority — both are `publish_to: none` and hand-published.
- [ ] **Q3 — bump member `version:` `0.1.0-dev.1 → 0.1.0`** in the six
      publishable members (`kmdb`, `kmdb_cli`, `kmdb_google_drive`,
      `kmdb_extractor_pdf`, `kmdb_extractor_html`, `kmdb_extractor_markdown`) and
      the root coordinator `pubspec.yaml` (cosmetic, release-train label).
      `kmdb_harness`/`kmdb_flutter`/`kmdb_icloud` already at `0.1.0`.
- [ ] **Update `docs/releasing/README.md`** — the "Version-bump rules" section
      no longer needs to justify staying at `0.1.0-dev.1` (the prerelease-`betto_*`
      premise is gone); update it and the Stage 1 step-5 member-to-member example
      (`kmdb: ^0.1.0-dev.1` → `^0.1.0`) to the stable line. Create
      `docs/releasing/0.1.0.md` from `TEMPLATE.md` for this release.
- [ ] **Re-run the full suite against the promoted `^0.1.0` pins with the
      overrides removed** — the existing CI lanes: VM (`test_dart`), web
      (`test-web` / `make cicd_web`, Chrome), and the Flutter lanes
      (`test-flutter` / `make cicd_flutter`, `test-icloud`) — plus `make
      coverage` ≥ baseline and the §18 benchmarks. This is the load-bearing
      verification: with betto_* overrides gone, a clean re-resolve must land
      every `betto_*` at exactly `0.1.0` (no `-dev`, no conflict) via the member
      constraints alone, and every package must stay green.

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

- [ ] Tag KMDB `0.1.0` once A–C are green. **Irreversible; last.** If W6
      (Phase C) changed any code, re-run the Phase B CI matrix so the tagged
      commit is the one with a green run against the promoted, override-free
      tree — the tag must sit on top of all B+C edits, not on the pre-W6 run.

## Summary

_To be completed when the work is done._
