# Release process documentation (`docs/releasing/`)

**Status**: Investigated

**PR link**: —

## Problem statement

`docs/roadmap/0_09.md`'s "Release Checklist" item calls for a documented
release process: a `docs/releasing/README.md` describing how KMDB packages
are published, plus a per-release checklist template (named after the version
being released, e.g. `0.1.0-dev.1.md`) that incorporates every item from
`docs/spec/28_release_checklist.md` as an `[x]`/`[-]` entry. Package versions
may differ across the workspace on minor/patch but must never differ on
major.

`docs/releasing/` does not currently exist. This is one of three plans split
out of a single combined roadmap item at the `kmdb-architect` agent's
recommendation — see
[plan_0_09_spec_review_and_primer_fold.md](plan_0_09_spec_review_and_primer_fold.md)
for the full split rationale. It was originally scoped as the
smallest/lowest-risk of the three; that held for a GitHub-tag-only release,
but the user's confirmed choice of a **full pub.dev publish** (Q3) grew its
scope to include making the workspace actually publish-ready (LICENSE files,
real dependency constraints, a version bump — see the Implementation plan's
"Prep" section), not just writing a process doc. It remains docs/config-only
(no runtime `kmdb` code changes) and independent of the other two plans.
This plan prepares the workspace and documents the process; it does **not**
execute the real publish — see the final implementation step.

## Open questions

- [x] **Q1 — Per-release checklist template format.** **Decision: literal
      template file**, `docs/releasing/TEMPLATE.md`, copied per release and
      renamed to the version being released (e.g. `0.1.0-dev.1.md`). Lists
      every current §28 item as a checkbox with a note field, plus the
      package publish-order steps as their own checklist section. Minimises
      drift and makes authoring each release's checklist a mechanical
      copy-then-fill.
- [x] **Q2 — Version-discipline enforcement.** **Decision: defer — document as
      convention only**, not a mechanical check, in this plan. A `melos`/CI
      script that fails on major-version divergence pulls in code, a licence
      header, tests, and `make`/`melos` wiring, which would turn this from a
      docs-only, lowest-risk plan into a tooling plan and undercut the
      land-first rationale. Note it as a candidate future roadmap item instead;
      if wanted sooner, it should be its own plan.

- [x] **Q5 — Publish mechanics for the non-workspace Flutter packages
      (`kmdb_flutter`, `kmdb_icloud`).** **Decision: (b) — scope out of Stage 1
      prep.** They already publish last, by hand, on a macOS/Flutter-capable
      runner, and this plan doesn't execute any actual publish (see the final
      implementation step) — so there's no benefit to extending the empirical
      throwaway-workspace investigation to them now. Instead: exclude both
      packages from every automated Stage 1 prep step (`publish_to: none`
      removal, dependency-constraint fixes, version bump) in this plan's
      implementation, and document them as a **hand-publish appendix** in
      `docs/releasing/README.md` that lists the open unknowns as things the
      human publisher must verify at actual hand-publish time — namely: (1)
      their main `dependencies:` block uses a `path:` dependency on `kmdb`,
      which is a hard `dart pub publish` error and must become a real version
      range (`kmdb: ^0.1.0-dev.1`) before publishing, not left as-is; (2)
      whether a `path:` inside their mirrored `dependency_overrides` block is
      stripped/ignored at publish time or must also be removed is unverified —
      the appendix should say so explicitly rather than assert an answer; (3)
      `kmdb_icloud`'s `dev_dependencies: kmdb_harness: {path: ...}` targets a
      permanently-unpublished package and may need removing or relocating
      before a real publish — also flagged as unverified. The appendix's job
      is to warn the future human publisher what to check, not to have already
      solved it.

## Investigation

Grounded by the `kmdb-architect` agent. Key findings:

### `28_release_checklist.md` is current — no gaps found

§28 (843 lines) is the pre-release *test gate*: a catalogue of 23
manual/out-of-band tests (RC-1…RC-23) covering things the automated suite
structurally can't — real-OS durability, real cloud credentials, cross-process
concurrency, etc. It already covers every recently-landed subsystem:

- Encryption: RC-16 (web Argon2id timing), RC-18 (`kmdb_flutter` DEK
  round-trip / native crypto), RC-22 (legacy pre-reconciliation format-break).
- Vault / vault search: RC-21 (vault-search isolate crash recovery, updated
  for WI-10 encrypted artifacts).
- Durability hardening: RC-4 (Linux dir-fsync), RC-19 (two-file flush crash),
  RC-10 (web OPFS durability).
- Local-only namespaces: RC-20 (`$$` isolation across devices).
  Packaging: RC-23 (`dart build cli` native-asset bundling on Linux/Windows).

No stale or missing RC entries were found for currently-shipped work. §28 is
an **input** to each per-release checklist, not itself the missing piece.

### What's actually missing: the process doc

`docs/releasing/README.md` does not exist. The roadmap asks for it to
describe:

- **Package publish order.** The root `pubspec.yaml`'s
  `dependency_overrides` pins external Bettongia packages (`betto_common`,
  `betto_schema`, `betto_zstd`, `betto_mediatype_detector`,
  `betto_builder_tools`, `betto_onnxrt`, `betto_icu`, `betto_lexical`,
  `betto_inferencing`, `betto_pdfium`) — these publish to pub.dev
  independently, and must be published (and any version bump landed) *before*
  `kmdb` core is published against them, which in turn precedes the dependent
  packages (`kmdb_cli`, `kmdb_google_drive`, `kmdb_icloud`, `kmdb_flutter`,
  the `kmdb_extractor_*` family).
- **Version-bump rules.** The current version (`pubspec.yaml`: `0.1.0-dev.1`)
  is the designated release version. Packages may carry different
  minor/patch versions but must never diverge on major — see Q2 for whether
  this plan also mechanises the check.
- **Per-release checklist convention.** A copy of the template created in
  `docs/releasing/`, named after the version being released (e.g.
  `0.1.0-dev.1.md`), with every §28 item given an `[x]` (completed) or `[-]`
  (not applicable to this release) entry.

Two secondary notes to fold into the process doc:

- **§28 is currently at RC-24, not RC-23** (RC-24, "`kmdb_cli` credential store:
  real-OS permission verification", already landed alongside the keychain
  work). Because each per-release checklist is authored from the *current*
  §28 at release time, this is self-correcting — but don't hard-code "RC-23"
  anywhere in the process doc or template.
- The process doc should state explicitly that §28 itself is not duplicated
  into the process doc — each per-release checklist file is generated from
  the current §28 at release time, so the process doc should link to §28
  rather than restate its contents.

### Publish mechanics (`kmdb-architect` investigation, 2026-07-17)

Verified against the live workspace and pub.dev's actual publish validation
(dry-run behaviour reproduced in throwaway test workspaces, since
`publish_to: none` blocks dry-running the real packages).

**Per-package changes needed, beyond removing `publish_to: none`:**

| Package | `publish_to: none` | LICENSE | `repository:` | Notes |
|---|---|---|---|---|
| `kmdb` | remove | has one | has one | foundation, publish first |
| `kmdb_cli` | remove | has one | missing | depends on kmdb + google_drive + 3 extractors |
| `kmdb_google_drive` | remove | **missing** | missing | |
| `kmdb_extractor_pdf`/`_html`/`_markdown` | remove | **missing** (all 3) | missing (all 3) | |
| `kmdb_flutter` | remove (**hand, not this plan**) | **missing** | missing | also missing README; publish from macOS/Flutter runner, last; **out of automated Stage 1 scope per Q5 — hand-publish appendix only** |
| `kmdb_icloud` | remove (**hand, not this plan**) | **missing** | missing | publish from macOS/Flutter runner, last; **out of automated Stage 1 scope per Q5 — hand-publish appendix only** |
| `kmdb_harness` | **keep permanently** | n/a | n/a | internal test harness, never published |

> **Scope note (Q5):** the `kmdb_flutter`/`kmdb_icloud` rows describe the
> *eventual* hand-publish end-state. This plan does **not** touch their pubspecs
> or add their LICENSE files — those are documented in the hand-publish appendix
> for a future human publisher, not executed here. The automated Stage 1 prep
> below covers the 6 Dart-publishable workspace members only.

**LICENSE is a hard blocker, not a nice-to-have** — `dart pub publish`
hard-errors ("*You must have a LICENSE file*") without one *in the package
directory*; the root `LICENSE` doesn't satisfy this per-package. 6 of the 8
publishable packages lack one (`kmdb_google_drive`, the 3 extractors,
`kmdb_flutter`, `kmdb_icloud`) — but only 4 of those fall in this plan's
automated Stage 1 scope, since `kmdb_flutter`/`kmdb_icloud` are hand-publish
(Q5); `kmdb_harness` is missing one too but never publishes. No package has a
`CHANGELOG.md` — a warning, not an error, but the process doc should require
one going forward.

**No Melos publish/version tooling exists to lean on.** The root
`pubspec.yaml`'s `melos:` block has no `command:` section — `melos version`'s
constraint-rewriting and `melos publish`'s ordering have never been
configured or used here. Don't assume it; if wanted later, that's a separate
tooling proposal, not something this docs-only plan can rely on.

**How constraints actually get resolved:**
- `resolution: workspace` is **stripped from the published archive** — not a
  publish blocker by itself (confirmed against live pub.dev pubspecs for
  `betto_lexical`/`betto_inferencing`/`betto_common`, which are workspace
  members in their own repos and carry no `resolution`/`workspace` key once
  published).
- A blank constraint (e.g. `kmdb_cli`'s bare `kmdb:`) publishes as `kmdb: any`
  — a **warning**, not a hard error. Still must be fixed: replace every
  blank member-to-member and member-to-`betto_*` constraint with a real range
  (e.g. `kmdb: ^0.1.0-dev.1`, `betto_zstd: ^0.1.0-dev.3`) before publishing —
  this is what the already-published `betto_*` packages themselves do.
- **The real publish-order enforcement is server-side, and local dry-run
  hides it**: a workspace member depending on an unpublished sibling passes
  `dart pub publish --dry-run` cleanly (it resolves the sibling locally) but
  is rejected by the pub.dev server at actual publish time. The process doc
  must state explicitly that a clean local dry-run does **not** confirm
  publish order — bottom-up publishing in the stated order is mandatory
  regardless of what dry-run reports.

**`betto_*` dependency chain — zero fresh publishes needed.** Every `betto_*`
package the root `dependency_overrides` pins is already published on pub.dev
at that exact version (`betto_common`, `betto_schema`, `betto_zstd`,
`betto_mediatype_detector`, `betto_lexical`, `betto_inferencing`,
`betto_charset_detector`, `betto_lang_detector`, plus transitive
`betto_icu`/`betto_builder_tools`/`betto_onnxrt`). The only fix needed is
mechanical: `kmdb` core's own `betto_*` dependency constraints
(`packages/kmdb/pubspec.yaml:15-24`) are currently blank and must be filled
with the same real ranges already used in the root overrides.

**Concrete publish order:**
1. **Stage 0 (verify only):** confirm all `betto_*` pins are still published
   at the required versions — no action expected.
2. **Stage 1 (prep, no publishing — this plan automates this for the 6
   Dart-publishable workspace members only; `kmdb_flutter`/`kmdb_icloud` are
   scoped out per Q5):** remove `publish_to: none` from `kmdb`, `kmdb_cli`,
   `kmdb_google_drive`, and the 3 extractors; add LICENSE to the ones missing
   it; add `repository:`/`homepage:` and a `CHANGELOG.md` to each; replace
   every blank dependency constraint (member-to-member and
   member-to-`betto_*`) with a real range; bump these packages plus the root
   coordinator to `0.1.0-dev.1` (prerelease lockstep, per the user's decision
   above).
3. **Stage 2 (publish, order enforced server-side):**
   1. `kmdb` (everything depends on it)
   2. `kmdb_google_drive`, `kmdb_extractor_pdf`, `kmdb_extractor_html`,
      `kmdb_extractor_markdown` (depend only on `kmdb`; any order among
      themselves)
   3. `kmdb_cli` (depends on `kmdb` **and** `kmdb_google_drive` and all three
      extractors — must come after all of them)
   4. `kmdb_flutter`, `kmdb_icloud` (Flutter-only, non-workspace, publish last
      from a macOS/Flutter-capable runner, by hand — per Q5, their prep is a
      documented appendix, not an automated Stage 1 step of this plan)
- **Never published:** `kmdb_harness` — state this explicitly in the doc so
  it isn't mistaken for an oversight.

## Implementation plan

**Prep — make the workspace actually publishable (Stage 1, the 6
Dart-publishable workspace members only — `kmdb_flutter`/`kmdb_icloud` are
explicitly out of scope here per Q5, see the hand-publish appendix step
below):**

- [ ] Remove `publish_to: none` from `kmdb`, `kmdb_cli`, `kmdb_google_drive`,
      `kmdb_extractor_pdf`, `kmdb_extractor_html`, `kmdb_extractor_markdown`
      — 6 packages; leave `kmdb_harness` as `publish_to: none` permanently,
      and leave `kmdb_flutter`/`kmdb_icloud` as-is (they're handled by hand,
      not by this plan).
- [ ] Add a `LICENSE` file (copy of the root Apache licence) to the packages
      missing one among these 6: `kmdb_google_drive`, `kmdb_extractor_pdf`,
      `kmdb_extractor_html`, `kmdb_extractor_markdown` (`kmdb` and `kmdb_cli`
      already have one). This is a hard `dart pub publish` error if skipped.
- [ ] Add `repository:`/`homepage:` to the 5 of these 6 missing it —
      `kmdb_cli`, `kmdb_google_drive`, `kmdb_extractor_pdf`,
      `kmdb_extractor_html`, `kmdb_extractor_markdown` (`kmdb` already has
      one). Add a `CHANGELOG.md` to all 6.
- [ ] Replace every blank dependency constraint with a real version range:
      `kmdb` core's `betto_*` constraints
      (`packages/kmdb/pubspec.yaml:15-24`, copy the exact ranges already used
      in the root `dependency_overrides`), and `kmdb_cli`'s member-to-member
      constraints (`kmdb:`, `kmdb_google_drive:`, the 3 extractor deps).
- [ ] Bump these 6 packages plus the root coordinator to `0.1.0-dev.1`
      (prerelease lockstep, per the confirmed version-scheme decision). Leave
      `kmdb_flutter`/`kmdb_icloud`/`kmdb_harness` versions untouched by this
      plan.
- [ ] Write the hand-publish appendix (in `docs/releasing/README.md`, see
      below) covering `kmdb_flutter` and `kmdb_icloud`'s distinct publish
      mechanics and open unknowns, per the Q5 decision — do not attempt to
      change their pubspecs in this plan.

**Process documentation:**

- [ ] Create `docs/releasing/README.md` describing: the two-stage publish
      process (prep, then bottom-up publish per the order in the
      Investigation section above), which packages are publishable vs.
      permanently internal (`kmdb_harness`), the version-bump rules
      (prerelease lockstep for now; members may diverge on minor/patch in
      future releases but never on major, root coordinator tracks members),
      and the per-release checklist convention. Explicitly warn that a clean
      local `dart pub publish --dry-run` does **not** confirm publish order
      — the real ordering constraint is enforced server-side. Include the
      **hand-publish appendix** for `kmdb_flutter`/`kmdb_icloud` (per Q5):
      state that they publish last, by hand, from a macOS/Flutter-capable
      runner, and list the three open unknowns a human publisher must verify
      at that time (path→version-range conversion in `dependencies:`; whether
      the `dependency_overrides` path entry must also be removed or is
      stripped automatically; whether `kmdb_icloud`'s path
      `dev_dependencies: kmdb_harness` needs removing/relocating) rather than
      asserting answers this plan hasn't verified.
- [ ] Create the per-release checklist template (`docs/releasing/TEMPLATE.md`)
      per the Q1 decision.
- [ ] Author the first real per-release checklist file
      (`docs/releasing/0.1.0-dev.1.md`, matching the actual bumped member
      version, not a stale root-only label), populated with `[x]`/`[-]`
      against every current §28 item (currently RC-1…RC-24 — verify the
      count at implementation time rather than hard-coding it), as a worked
      example and to confirm the template is usable.
- [ ] Cross-link `docs/releasing/README.md` from
      `docs/spec/28_release_checklist.md` and from the repo root `README.md`.

**Final step — QA sign-off and pre-commit:**

- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (process doc accuracy
      against the actual workspace dependency graph, template usability, and
      that the Stage 1 pubspec/LICENSE/CHANGELOG changes are complete and
      consistent across the 6 in-scope packages, and that the
      `kmdb_flutter`/`kmdb_icloud` hand-publish appendix accurately flags its
      open unknowns rather than overclaiming). Resolve every blocking item
      before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).
- [ ] **Do not actually run `dart pub publish`** as part of this plan — Stage
      1 (making the workspace publish-ready) and the process doc are this
      plan's deliverable; the real Stage 2 publish is a separate, explicit,
      user-authorised action outside a plan's implementation phase.

## Review (kmdb-plan-reviewer, 2026-07-17)

**Status set to `Questions`.** The problem is real and well-scoped, but the
investigation missed the two hardest facts about releasing *this* workspace, and
those gaps would force the implementer to design the release mechanics on the
fly. This is not yet safe for a mechanical (Sonnet) implementer. Details below.

### Problem statement — sound

A documented release process is genuinely missing (`docs/releasing/` does not
exist), a release is imminent, and the plan tracks the roadmap 0_09 item
faithfully. Splitting this out as the smallest/lowest-risk of the three is the
right call. No objection to the "why".

### Blocking findings (must resolve before `Investigated`)

**B1 — Every KMDB package is `publish_to: none`. The plan's central "publish
order to pub.dev" premise does not match the repo.** All nine
`packages/*/pubspec.yaml` carry `publish_to: none` (verified 2026-07-17). As it
stands, *no* KMDB package can be published to pub.dev at all. The plan describes
a "betto_* → kmdb → dependents" pub.dev publish order as if it were live, but the
workspace is not configured for pub.dev publishing. The process doc cannot be
written accurately until we know what "release" means here:

- Is `0.1.0-dev.1` a pub.dev publish, or a GitHub tag/release only (with the
  downstream `kmdb_ui` consuming `kmdb` via a git ref)? The `betto_*` deps *are*
  on pub.dev (at `-dev.N`), but `kmdb` core has `repository:` set yet
  `publish_to: none` — i.e. it is prepared for pub.dev but deliberately not
  published yet.
- If pub.dev *is* the target, then "remove `publish_to: none` from each package"
  is itself a load-bearing, easily-forgotten release step the doc must spell out
  — and the plan's checklist doesn't mention it.

This is the crux. Captured as **Q3** below.

**B2 — Workspace member cross-dependencies have no version constraints; the doc
must explain how they get real constraints at publish time.** `kmdb_cli`
declares `kmdb:`, `kmdb_google_drive:`, `kmdb_extractor_*:` etc. with *blank*
constraints, relying on `resolution: workspace`. You cannot `dart pub publish` a
member with a bare `kmdb:` dependency — pub.dev requires a resolvable version
constraint (e.g. `^0.1.0`). Likewise `kmdb` core depends on `betto_*` only via
root `dependency_overrides` pinned to `-dev.N` builds; `dependency_overrides`
are not published, so each member's *own* dependency constraints must be
satisfiable from pub.dev at publish time. How member-to-member and member-to-
betto constraints are materialised for a real publish is the actual hard part of
releasing this workspace, and the plan has not investigated it. Captured as
**Q4**.

**B3 — Root vs member version discrepancy is unaddressed.** The root
`pubspec.yaml` (name `kmdb_workspace`, `publish_to: none`) is `0.1.0-dev.1`, but
every publishable member is `0.1.0` (no `-dev.1`). The plan asserts the root
version is "the designated release version" and wants the first checklist file
named `0.1.0-dev.1.md` — yet nothing actually being released carries that
version. The process doc's "version-bump rules" section must reconcile: is the
coordinator version the release-train label, and if so what is the required
relationship to member versions? Where does the coordinator sit relative to the
"never differ on major" rule (which as written is about members among
themselves)? Fold into **Q4**.

### Non-blocking factual corrections

- **§28 is now at RC-24, not RC-23.** RC-24 ("`kmdb_cli` credential store: real-
  OS permission verification") already landed. So the Investigation's
  "(RC-1…RC-23 as of this writing)" is stale, *and* the secondary note that the
  keychain work "will likely add a new §28 RC entry … not a current gap" is now
  wrong — that entry (RC-24) already exists. Because the checklist is authored
  "from the current §28 at release time", the mechanism is self-correcting, but
  fix the stale parenthetical and drop/soften the keychain-RC note so the
  implementer isn't chasing a phantom future addition.
- The publish-order list omits `kmdb_harness` (correctly — it's an internal test
  harness). Make the exclusion *explicit* in the doc: state which packages are
  publishable and which are `publish_to: none` internal-only, so the implementer
  doesn't have to infer it.

### On the existing open questions

- **Q1 (template mechanism)** — genuinely the user's call and cheap either way,
  but I'd recommend the literal `docs/releasing/TEMPLATE.md`-copied-per-release
  form: it minimises drift and makes "author the first `0.1.0-dev.1.md`" a
  mechanical copy-then-fill, which is exactly what a Sonnet implementer wants.
  Either answer is implementable once chosen; just needs choosing.
- **Q2 (mechanical version-parity check)** — recommend **defer, document as
  convention only** in this plan. Adding a script pulls in code, a license
  header, tests, coverage, and `make`/`melos` wiring — it converts this from a
  docs-only, lowest-risk plan into a tooling plan and undercuts the "land first"
  rationale. Note it as a candidate future roadmap item. (If the user wants it
  now, it should arguably be its own plan.)

### Implementation-readiness verdict

Not ready. The checklist steps are individually clear, but they rest on an
unverified model of "release" (B1) and omit the real publish mechanics (B2/B3).
An implementer following the current checklist would write a plausible-looking
process doc that is *wrong* about how this workspace actually ships. Resolve
Q3/Q4 (and pick Q1/Q2), then this promotes cleanly — it remains a small,
low-risk, docs-first plan.

### Added open questions

- [x] **Q3 — What does "release `0.1.0-dev.1`" actually mean?** **Decision:
      full pub.dev publish.** All publishable KMDB packages need
      `publish_to: none` removed as an explicit, documented release step
      (internal-only packages like `kmdb_harness` keep it). This confirms Q4
      below is in scope, not moot.
- [x] **Q4 — Publish mechanics for a workspace with `resolution: workspace` +
      `dependency_overrides`.** **Resolved by `kmdb-architect` investigation
      (2026-07-17) — see "Publish mechanics" in Investigation below.** Summary:
      no fresh `betto_*` publishes are needed (all already published at the
      exact versions the root overrides pin); `resolution: workspace` is
      stripped from the published archive and isn't itself a blocker; blank
      member-to-member constraints publish as `any` (a warning, not an error)
      but must be replaced with real constraints regardless; the actual
      ordering enforcement is server-side and **local `dart pub publish
      --dry-run` gives false confidence** about publish order because it
      resolves workspace siblings locally even when they're unpublished. Version
      reconciliation: **decided by the user — prerelease lockstep.** All
      publishable members (and the root coordinator) move to `0.1.0-dev.1`,
      matching the `betto_*` ecosystem's convention and avoiding a stable
      package depending on prerelease `betto_*` constraints.

## Review (kmdb-plan-reviewer, 2026-07-17 — second pass)

**Status set back to `Questions` for one focused item (Q5).** Q3 and Q4 are
genuinely resolved and the architect's publish-mechanics investigation is
strong. I cross-checked the "Prep" checklist against the live workspace at HEAD
and against the per-package table. Almost everything holds, but the
investigation covered only the *workspace-member* publish path and skipped the
two non-workspace Flutter packages — which are the exact packages the plan
itself flags as "trickiest, publish last". Their prep step is addressing the
wrong file. One factual count was also off. Details below.

### Verified against the live workspace (HEAD, 2026-07-17)

- LICENSE missing on exactly the 6 named packages — checklist correct.
- CHANGELOG missing on all 9 — "add to all 8 publishable" correct.
- README missing only on `kmdb_flutter` — correct.
- Version: all members `0.1.0`, root `0.1.0-dev.1` — bump-to-lockstep step correct.
- §28 latest is RC-24 — the "verify the count at implementation time" note is correct.

### Corrected inline (mechanical, no decision needed)

- **`repository:` is missing on 7 publishable packages, not 6.** `kmdb_cli` has
  a LICENSE but no `repository:`, so it falls outside the LICENSE-6 set. The
  original checklist said "the 6 packages missing them", which a mechanical
  implementer would almost certainly map onto the same LICENSE-6 and silently
  skip `kmdb_cli`. Fixed the checklist to name all 7 explicitly.

### Blocking finding (Q5) — non-workspace Flutter packages' publish mechanics

`kmdb_flutter` and `kmdb_icloud` are **not workspace members** (they pull
`flutter: sdk: flutter`). Unlike the workspace members, they do **not** use
blank constraints + `resolution: workspace`. Their main `dependencies:` block
carries a **path dependency**:

```
dependencies:
  kmdb:
    path: ../kmdb
```

A `path:` dependency in `dependencies:` is a **hard `dart pub publish` error**,
not a warning — a different and more severe problem than the blank-constraint
`any` warning the architect investigated for workspace members. The "blank
constraint → real range" fix does not apply here; the real fix is
**path → real version range** (`kmdb: ^0.1.0-dev.1`) in the main `dependencies:`
block. The plan's only step for these two packages targets their
`dependency_overrides` mirror instead — and `dependency_overrides` do not
resolve consumer dependencies and are the wrong lever for the published archive.
So as written, the prep step for the two trickiest packages does not remove
their actual publish blocker.

Two further unknowns the workspace-member investigation didn't have to face:

1. **How does pub treat a `path:` inside `dependency_overrides` at publish
   time?** If it triggers the same "no path dependencies" hard error, the
   override block must be removed (not "updated to real constraints") before
   publishing; if overrides are stripped/ignored, keeping `kmdb: {path: ../kmdb}`
   there is actually desirable (it's what makes local `flutter pub get` resolve
   `kmdb` before it exists on pub.dev). The correct end-state hinges on this and
   it was not empirically verified. Note the current checklist instruction —
   "update the mirrored `dependency_overrides` to match the real constraints" —
   is likely *counterproductive*: replacing the path override with a version
   would break local dev until `kmdb` is actually published.
2. **`kmdb_icloud` has `dev_dependencies: kmdb_harness: {path: ../kmdb_harness}`
   on a permanently-unpublished package.** It cannot be converted to a pub.dev
   version constraint (kmdb_harness is `publish_to: none` forever). Whether a
   path *dev*-dependency is a hard publish error or a warning determines whether
   the dev-dependency (or the test that needs it) must be removed/relocated
   before `kmdb_icloud` can be hand-published. Unaddressed.

This is the same class of empirical, throwaway-workspace investigation the
architect already did for members — just extended to the two non-workspace
packages. It is not the user's preference to decide; it needs verifying (or the
packages need scoping out). Because the correct pubspec end-state for
flutter/icloud is genuinely unresolved, an implementer would have to design it
on the fly — which fails the bar.

### Scope boundary (stopping short of `dart pub publish`) — endorsed

Not running the real `dart pub publish` is the right boundary. Publishing is
irreversible, per-package server-side ordering means a mistake can't be walked
back, and publishing is consistently the user's own action, not an agent's. The
explicit final-step guard is exactly right. Do not weaken it.

### Everything else — ready

The prep steps for the 6 Dart-publishable packages (`kmdb`, `kmdb_cli`,
`kmdb_google_drive`, the 3 extractors), the version-lockstep bump, the LICENSE
adds, the `betto_*` constraint fills, the process-doc/template/first-checklist
authoring, and the QA/pre-commit close-out are all specific and mechanical. Once
Q5 is resolved (or flutter/icloud are explicitly scoped out of Stage 1 prep and
documented as a hand-publish appendix instead), this promotes cleanly.

## Review (kmdb-plan-reviewer, 2026-07-17 — third pass)

**Status set to `Investigated`.** Q5 is resolved as decision (b): `kmdb_flutter`
and `kmdb_icloud` are scoped out of all automated Stage 1 prep, and their publish
mechanics become a documented hand-publish appendix. I verified the resolution is
applied consistently and the deferral is sound.

### Q5 resolution verified against the live workspace (HEAD, 2026-07-17)

The appendix's three flagged unknowns are grounded in the actual pubspecs:
`kmdb_flutter`/`kmdb_icloud` both carry `kmdb: {path: ../kmdb}` in their main
`dependencies:` (the hard publish error), mirror it in `dependency_overrides`,
and `kmdb_icloud` has `dev_dependencies: kmdb_harness: {path: ../kmdb_harness}`
on a permanently-unpublished package. The plan correctly documents these as
*unknowns to verify at hand-publish time*, not as asserted answers — which is the
right posture given none were empirically tested.

### Scoping applied consistently

- **Investigation → Concrete publish order:** Stage 1 (line 193-194) explicitly
  scopes to the 6 Dart-publishable members; Stage 2 step 4 (208-210) marks
  flutter/icloud prep as appendix, not automated.
- **Prep checklist:** every step names the 6 in-scope packages and explicitly
  says "leave `kmdb_flutter`/`kmdb_icloud` as-is"; a dedicated appendix-authoring
  step is present.
- **QA sign-off:** scoped to "the 6 in-scope packages" plus verifying the
  appendix "accurately flags its open unknowns rather than overclaiming".
- **Per-package table + LICENSE count:** these were the only spots that still
  read as if flutter/icloud were in automated scope. Annotated inline this pass
  (table rows now say "hand, not this plan / out of automated Stage 1 scope per
  Q5", plus a scope note under the table; the LICENSE narrative count corrected
  from a loose "7 of 9" to "4 automated / 6 total publishable").

### Deferral to an unverified appendix is acceptable for `Investigated`

This plan deliberately stops short of running `dart pub publish` (the guard at
the final step is endorsed and unweakened). Because no implementation step in
this plan invokes a real publish, no code path exercises the flutter/icloud
unknowns — so leaving them as documented warnings introduces no on-the-fly design
decision for the Sonnet implementer. The appendix deliverable is itself fully
specified: write down the three named unknowns as things a future human publisher
must verify. That is a mechanical documentation task, not an architecture
decision. The implementer is not asked to *resolve* the unknowns, only to
*record* them — which is exactly what a plan should do when a fact is genuinely
unverified and out of the current deliverable's blast radius.

### Nothing else blocking

The 6-package prep steps, version-lockstep bump, LICENSE/CHANGELOG/`repository:`
adds, `betto_*` constraint fills, the process-doc/template/first-checklist
authoring, and the QA/pre-commit close-out are all specific and mechanical. A
competent implementer who wasn't part of this discussion could execute this from
the plan alone. Promoting to `Investigated`.

## Summary

{To be completed once implemented.}
