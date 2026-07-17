# Specification review, front-matter reconciliation & primer fold

**Status**: Investigated

**PR link**: —

## Problem statement

`docs/spec/` has grown organically across twelve implementation phases plus
the v0.02.01 durability track and the 0.08 encryption confidentiality
reconciliation. The roadmap (`docs/roadmap/0_09.md`, "Specification review and
editing") calls for a pass that (a) makes the spec cohesive and comprehensive,
and (b) validates it against the codebase, resolving any gap by updating
either the spec or the code.

Separately, `docs/primer.md` (893 lines, a narrative "why it works this way"
onboarding doc) predates several shipped subsystems and contains claims that
are now actively wrong. The user has proposed folding the primer into the spec
itself as a new front-matter overview section rather than keeping it as a
standalone document — this plan evaluates and executes that idea alongside the
review.

This is one of three plans split out of the single roadmap item at the
`kmdb-architect` agent's recommendation (see its grounding report, summarised
in the Investigation section below): a combined plan bundling spec review,
the Integration Guide + sample app, and the release process doc could not
reach "Investigated" cleanly, since each has independent blocking decisions.
The other two are [plan_0_10_integration_guide.md](plan_0_10_integration_guide.md)
and [plan_0_09_release_process_doc.md](plan_0_09_release_process_doc.md).
This plan is docs-only (spec + primer); no `kmdb` runtime code is expected to
change unless the validation sweep (below) turns up a genuine spec/code
divergence, in which case that divergence is raised as its own follow-up
rather than absorbed into this plan's scope.

## Open questions

- [x] **Q1 — `14_reactivity.md` (28 lines):** fold into `13_query_api.md` as a
      subsection, or leave it as its own file? **Decision: leave standalone.**
      Folding it would delete a section number, creating the exact cross-ref
      churn Q2 (below) is trying to avoid — inconsistent to avoid renumbering
      §31/§32 for that reason and then do the equivalent to §14. Cross-links
      between §13 and §14 should be tidied for clarity but the file stays.
- [x] **Q2 — Renumbering §31 (encryption) and §32 (vault search):** these are
      core, cross-cutting features numerically stranded after the test harness
      (§27) and cloud adapters (§29/§30). **Decision: do not renumber.**
      Renumbering means rewriting every `§NN` cross-reference across ~10,200
      lines and risks broken links in the built site for no reader-facing
      benefit beyond number aesthetics. Both the architect and reviewer
      independently recommended against it; §33's arrival (Q4) reinforces the
      case further. Express topical grouping only via Parts in `00_index.md`.
- [x] **Q3 — `primer.md`'s "Navigating the Code" table:** the primer ends with
      a `lib/src/` file-map table (`docs/primer.md:837–858`), the one part of
      the primer that is *currently accurate*. **Decision: preserve it, folded
      into the spec itself** (not moved to `CONTRIBUTING.md`) — place it in the
      expanded System Overview (`01_overview.md`) or as a short dedicated
      subsection near it, so a spec reader has the code-navigation map
      alongside the architectural narrative it supports. Update its file paths
      if any have drifted since it was last written, same as the rest of the
      primer-fold content.
- [x] **Q4 — `33_cli_credential_store.md` exists and this plan does not account
      for it (reviewer-added).** A committed-imminent §33 (currently untracked
      on `main`, produced by the sibling
      [plan_0_09_cli_keychain_credentials.md](plan_0_09_cli_keychain_credentials.md)
      work) already sits in `docs/spec/`. **Decisions:** (a) every "§32" ceiling
      in this plan is restated as "the highest section present at
      implementation time" (already applied in the Implementation plan below —
      do not hard-code a number); (b) §33 (CLI credential storage) is
      security-adjacent, not its own topic area, so it **extends Part 7
      ("Security")** alongside §31 rather than getting a new "CLI & tooling"
      Part — a dedicated CLI Part isn't warranted for a single section. (c)
      **Sequencing:** this plan owns the `00_index.md` Part-list edit and
      should run its `00_index.md` work *after*
      [plan_0_09_cli_keychain_credentials.md](plan_0_09_cli_keychain_credentials.md)
      has landed §33 on `main`, so there's a real file to slot in rather than a
      speculative placeholder. If this plan's implementation starts first,
      check `docs/spec/` for the highest-numbered file present at that time
      rather than assuming §32 or §33.
- [x] **Q5 — `01_overview.md` "Open Questions" table: disposition of all six
      rows, not two (reviewer-added).** **Decision: adopt the reviewer's
      verified row-by-row disposition as final.** Full-text search — shipped
      (§20–23), remove. iCloud CloudKit — shipped (§30), remove. Stale device
      tombstone threshold — shipped as `staleDeviceEvictionAfter`, 90-day
      default (`12_sync.md:172–188`), remove. Pagination cursors — still
      genuinely deferred (`13_query_api.md:446`: offset sufficient at target
      scale, cursor is future work), relocate to a "Future work" note rather
      than drop. Type-safe field paths (FieldPath codegen) — still open, keep.
      Array root documents — still open, keep.

## Investigation

Grounded by the `kmdb-architect` agent (full report retained in this plan's
authoring history). Key findings:

### Spec inventory (34 files, ~10,200 lines)

The heavy content (§04–§32) is **current and well-maintained** — no cohesion
bugs, no stray TODOs, terminology (`betto_*` renames, `$$` local-only
namespace prefixes) has fully propagated except for 4 stray single-`$` tokens
(3 in `22_semantic_search.md`, 1 in `26_document_versioning.md`). Drift is
concentrated entirely in the front-matter:

- **`00_index.md` (21 lines) — stale.** Abstract enumerates additions only up
  to §28; no mention of §26 (versioning), §29 (Drive), §30 (iCloud), §31
  (encryption), §32 (vault search) — five shipped subsystems invisible from
  the index. Also asserts a "100K–500K documents" scale target that conflicts
  with §02's authoritative 100K upper bound.
- **`01_overview.md` (47 lines) — stale.** Its "Open Questions" table lists
  **already-shipped** items as open: full-text search ("Defer to v2" — shipped
  as §20–23) and iCloud CloudKit ("Yes, as a v2 cloud adapter" — shipped as
  §30). No mention of encryption or versioning.
- **`03_architecture_overview.md` (173 lines) — mostly current.** Layer/tier
  diagrams are correct (`$$fts:`/`$$vec:`, `$vault:` ref-counts) but the layer
  stack has no encryption cross-cutting note and no document-versioning
  mention.

Two prior-session divergence candidates need **re-validation** against
current (post-0.08) code as part of this review, not assumed as fact:
whether `$$fts`/`$$vec` index *values* are actually encrypted post-reconciliation
(§31's leakage claims), and whether web actually emits Zstd (`0x01`) or only
`0x00` (§05's compression claim).

### Primer disposition

`docs/primer.md` is materially redundant with the front-matter it would
absorb into, and is the **most stale document in the tree**:

- Uses single-`$` `$fts:`/`$vec:`/`$index:` throughout (11 occurrences, 0
  double) — pre-dates the WI-0 local-only namespace rename.
- Its Encryption section claims secondary indexes and lexical/vector search
  namespaces are "whole-file synced to the cloud" and that encrypting them is
  "the only thing that keeps document content out of cloud storage" — **this
  is now false**; those namespaces are `$$` local-only and never synced. A
  verbatim fold would inject a wrong security claim into the normative spec.
  containing an important lesson: **do not port this content verbatim.**
- Claims Zstd-on-native/Deflate-on-web and a 1-byte value-encoding prefix —
  both stale (Deflate removed; prefix is now 2 bytes, per current §05).
  Describes `kmdb_flutter` as "forthcoming" — it has shipped.
- No distinct audience justifies keeping it separate: it is explicitly a
  pre-code-reading onboarding doc, the same audience as the spec front-matter
  (contributors/integrators), not a stakeholder/marketing document. The
  closest thing to an end-user doc is the unrelated `docs/user_guide/`.

**Recommendation (adopted by this plan):** author a fresh System Overview
section sourced from current code — absorbing the primer's good framing (the
"sync without a server → immutable files → LSM" through-line, the
encryption-as-value-seam concept) rewritten as normative, currently-accurate
prose — then retire `primer.md`.

### Proposed spec structure

Minimise renumbering (see Q2); express topical grouping through Parts in
`00_index.md` around the existing filenames:

- **Part 0 — Orientation:** `00_index` (fixed), `01_overview` (expanded into
  the System Overview, absorbing the primer fold), `02_target_workload_profile`,
  `03_architecture_overview` (add encryption + versioning notes)
- **Part 1 — Storage engine:** `04`–`11` (unchanged)
- **Part 2 — Sync & consistency:** `12`, `17`, `18`
- **Part 3 — Query, cache & reactivity:** `13`, `14` (see Q1), `15`, `16`
- **Part 4 — Platform:** `19`
- **Part 5 — Text search:** `20`–`23` (normalise stray `$` tokens)
- **Part 6 — Content, schema & versioning:** `24`, `25`, `26`, `32`
- **Part 7 — Security:** `31`, `33` (per Q4 — extends to cover CLI credential
  storage rather than getting its own Part)
- **Part 8 — Cloud adapters:** `29`, `30`
- **Part 9 — Testing & release:** `27`, `28`
- **Part 10 — Reference:** `99`

Add a subsystem → spec section → implementation-status table to `00_index.md`
so future drift between spec and code is visible at a glance — this is the
concrete, verifiable deliverable for "cohesive and comprehensive," rather than
a vague tidy-up.

## Implementation plan

- [ ] Fix `docs/spec/00_index.md`: extend the abstract through the highest
      section present at implementation time (per **Q4** — do not hard-code
      §32; §33 already exists), resolve
      the scale-target conflict with `02_target_workload_profile.md` (defer to
      §02's figure), add the Part-grouping structure, add the subsystem →
      section → status table.
- [ ] Rewrite `docs/spec/01_overview.md` as the expanded System Overview:
      absorb the primer's accurate framing, apply the **Q5** row-by-row
      disposition of the "Open Questions" table (three shipped rows removed —
      full-text search, iCloud, stale-device tombstone threshold — three
      genuinely-open rows kept or relocated to a Future-work note), add
      encryption and versioning coverage.
- [ ] Update `docs/spec/03_architecture_overview.md`: add the encryption
      cross-cutting seam to the layer stack, add a document-versioning
      mention, de-duplicate prose that now lives in the expanded §01.
- [ ] Normalise the 4 stray single-`$` namespace tokens (3 in
      `22_semantic_search.md`, 1 in `26_document_versioning.md`) to `$$`.
- [ ] Re-validate the two divergence candidates against current code and
      correct the spec (or file a follow-up if code needs to change):
      - `31_encryption.md`'s claims about `$$fts`/`$$vec` value encryption
        post-0.08 reconciliation.
      - `05_value_encoding.md`'s web Zstd-compression claim.
- [ ] Leave `14_reactivity.md` standalone per Q1; tidy its cross-links with
      §13 for clarity.
- [ ] Leave §31/§32 (and §33, per Q4) numbered as-is per Q2; express topical
      grouping only through the `00_index.md` Part structure.
- [ ] Retire `docs/primer.md`, having first moved its "Navigating the Code"
      table (per Q3) into the expanded `01_overview.md` (or a short dedicated
      subsection near it), refreshing any drifted file paths in the process.
- [ ] Update the doc-site build to match: `make_site.mk` builds
      `$(SITE_DIR)/primer.html` as its own pandoc target and lists it as a
      hard dependency of `doc_site_html` — remove both if the primer is
      retired. `docs/template/header.html:101` has a nav link
      (`<a href="primer.html">Primer</a>`) to remove/repoint. Confirm nothing
      else in `docs/template/` (e.g. `_index.md`) references `primer.html`.
- [ ] Update `CONTRIBUTING.md:14`, which currently points to
      `docs/primer.md` ("See the [LSM Primer](docs/primer.md) for a
      high-level overview…") — repoint to the new `01_overview.md` section
      (or wherever the System Overview lands) once it's part of `spec.html`.
- [ ] Sweep the rest of `docs/spec/` for any other implementation-status
      claims that have drifted since each file was last touched (spot-check
      against the CLAUDE.md Implementation Status table and recent roadmap
      entries).
- [ ] Update any repo-root references to `docs/primer.md` (e.g. `README.md`,
      `CLAUDE.md`) if it is retired.
- [ ] Run `make doc_site` to confirm the site builds cleanly with the new
      structure (broken cross-refs, pandoc errors).

**Final step — QA sign-off and pre-commit:**

- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment
      against actual code, doc quality, no dangling cross-references).
      Resolve every blocking item before proceeding. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new/retired files as applicable.

## Reviewer assessment (kmdb-plan-reviewer, 2026-07-17)

**Status set to `Questions`** — five open questions remain (three original,
two reviewer-added). The plan is well-grounded, its factual claims verify
cleanly, and the shape of the work is right; it is close, but not yet a
mechanical spec.

### Problem statement — sound

Real problem, correctly scoped. The drift is genuinely concentrated in the
front-matter (`00`/`01`/`03`) and the primer, exactly as claimed. Folding the
primer in rather than maintaining a parallel onboarding doc is the right call:
verified that the primer is materially the most-stale doc in the tree (single-`$`
namespaces, "Deflate-on-web", 1-byte prefix, `kmdb_flutter` "forthcoming"), and
that it has no distinct audience from the spec front-matter. The "do not port
verbatim — its encryption/leakage framing is now false" warning is important and
correct: those `$$fts`/`$$vec` namespaces are local-only and never synced, so the
primer's "encrypting them is the only thing keeping content out of the cloud"
claim would inject a wrong security assertion into a normative spec. Good catch
to flag it.

Keeping the two spec/code divergence candidates as *re-validate against current
code* items (not assumed facts) is the right discipline. I confirmed §05 already
reads "Zstd (native and web)" and matches `compression_flag.dart`
(`zstd = 0x01`) — so that candidate is a code-behaviour spot-check, not a
spec-text rewrite. Bounded, fine to defer to implementation.

### Verified claims

- Stray single-`$` tokens: **confirmed** — `22_semantic_search.md:367–369`
  (`$vec:` in the Index Structure block; the file uses `$$vec:` 16× elsewhere)
  and `26_document_versioning.md:109` (`$index:`). Normalisation to `$$` is
  correct.
- `01_overview.md` stale "Open Questions": **confirmed** shipped rows.
- Build/reference wiring: **confirmed accurate** — `make_site.mk:15` (dep) and
  `:60–61` (pandoc target), `docs/template/header.html:101` (nav link),
  `CONTRIBUTING.md:14` (LSM Primer link). Note: the checklist's "update
  README.md / CLAUDE.md primer refs" item is a safe no-op — grep finds *no*
  primer references in either file; the only live references are the three
  already enumerated. Leave the item as a defensive check but don't expect hits.

### Open questions — my positions

- **Q1 (fold §14):** lean *leave standalone*. Folding §14 into §13 deletes a
  section number, creating exactly the numbering gap / cross-ref churn that Q2
  argues against — so keeping it standalone is the internally-consistent choice.
  Editorial, but decide it in light of Q2.
- **Q2 (renumber §31/§32):** **strongly endorse "do not renumber."** The
  architect's reasoning holds and §33's arrival strengthens it: sections keep
  accreting at the tail, and topical order is far more cheaply expressed through
  Parts in `00_index.md` than through a 10,500-line cross-ref rewrite that would
  churn the built site's anchors for zero reader benefit.
- **Q3:** see the reviewer note inline — the code-nav table is the one
  *accurate* part of the primer, so weigh preservation-in-`CONTRIBUTING.md`
  higher than the architect's default retirement.
- **Q4 / Q5 (reviewer-added):** these are the two gaps that currently block a
  mechanical implementation — the §33 ceiling/placement and the full six-row
  disposition of the §01 table. Both force design decisions the plan hasn't
  made.

### Implementation-readiness — blocked on Q4/Q5

Everything else is concrete enough: named files, exact line numbers, verified
token locations, an ordered checklist, a docs-only scope with a clean follow-up
escape hatch for any code divergence. The two things a Sonnet implementer would
still have to *decide* (not just execute) are (a) whether/where §33 enters the
restructured index and how to avoid colliding with the sibling plan on
`00_index.md`, and (b) the disposition of the four unaddressed §01 rows. Resolve
Q4 and Q5 (and record Q1–Q3) and this clears the bar for `Investigated`.

One process note, not a blocker: this is a docs-only plan with no new runtime
code, so the template's "`make coverage` >95% on new files" gate is N/A — the
plan correctly substitutes `make doc_site` builds-cleanly + kmdb-qa spec-vs-code
sign-off. Worth stating that substitution explicitly so pre-commit isn't
expected to prove coverage on a docs change.

## Reviewer sign-off (2026-07-17, kmdb-plan-reviewer) — follow-up pass → `Investigated`

**Verdict: `Investigated`.** All five open questions (Q1–Q5) are resolved and
each decision is applied correctly and concretely in the Implementation plan.
Verified against the live tree, not just the checkmarks.

**Decisions land in the checklist with no residual hedging.** Spot-checked each
decided question against the checklist item that executes it:

- Q1 (leave §14 standalone) → checklist line "Leave `14_reactivity.md`
  standalone per Q1; tidy its cross-links with §13." Applied.
- Q2 (no renumber) → "Leave §31/§32 (and §33, per Q4) numbered as-is per Q2."
  Applied.
- Q3 (preserve code-nav table in the spec) → "Retire `docs/primer.md`, having
  first moved its 'Navigating the Code' table (per Q3) into the expanded
  `01_overview.md`." Applied — and correctly lands it in the spec, not
  `CONTRIBUTING.md`, per the user's override of the earlier lean.
- Q4 (§33 extends Part 7; highest-section ceiling) → the `00_index.md` item now
  reads "the highest section present at implementation time … do not hard-code
  §32; §33 already exists," and the Proposed structure puts §33 in Part 7
  (Security). Applied.
- Q5 (full six-row disposition) → the `01_overview.md` item enumerates the three
  shipped rows to remove and the three to keep/relocate. Verified against the
  live table (`01_overview.md:40–47`): exactly six rows, matching Q5 one-for-one
  (FTS / iCloud / stale-device-threshold shipped and removed; pagination-cursor
  relocated to Future work; type-safe field paths and array-root kept). Applied.

The only cosmetic residue is the "(see Q1)"/"(see Q2)" pointers in the Proposed
spec structure section — these now reference resolved questions, but they read as
historical cross-refs, not as unresolved hedges, and the structure itself already
encodes the decisions (§14 listed standalone in Part 3; §33 in Part 7). Not a
blocker.

**Q4 sequencing is sufficient — no stronger coordination mechanism needed.** The
decisive fact: the sibling `plan_0_09_cli_keychain_credentials.md` does **not**
edit `00_index.md` (its spec/doc updates create §33 and touch §31 gap 9 + §99
only). This plan is therefore the *sole* editor of the index Part list — there is
no merge-conflict surface between the two plans to coordinate. The sequencing note
plus the "check `docs/spec/` for the highest-numbered file present" fallback fully
covers this plan's own execution regardless of landing order. Current reality
de-risks it further: §33 is already staged in the working tree (`git status`: `A
docs/spec/33_cli_credential_store.md`) and the keychain plan is further along
(Status: Implementing, engineering complete) than this one, so keychain-first is
the realistic order.

One residual, non-blocking: if this plan somehow lands before §33 reaches `main`,
§33 would be temporarily absent from the Part list until re-added — because the
keychain plan won't add its own index entry. This is a soft, self-healing gap
(the next `00_index.md` touch picks it up) and is not this plan's responsibility
to hard-guarantee; the plan already instructs the implementer to slot in whatever
highest-numbered file is present at run time.

**Nothing else blocks.** Named files with exact line numbers, verified token
locations, an ordered checklist, docs-only scope with a clean follow-up escape
hatch for any spec/code divergence (lines re §31 `$$fts`/`$$vec` encryption and
§05 web-Zstd — both bounded read-code-then-correct-or-file-follow-up tasks, no
on-the-fly design). Two non-blocking notes carried forward: (1) the coverage-gate
substitution (docs-only → `make doc_site` builds-cleanly + kmdb-qa spec-vs-code
sign-off in lieu of the 95% coverage gate) is stated in the reviewer assessment
above but is worth restating as a first-class testing note when implementing so
pre-commit isn't expected to prove coverage on a docs change; (2) the "update
README.md / CLAUDE.md primer refs" item is a defensive no-op (grep finds no primer
refs in either). An implementer can now execute this without significant design
decisions.

## Summary

{To be completed once implemented.}
