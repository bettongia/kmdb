# Spec attribute registry and a spec-authoring guide

**Status**: **Complete** (2026-07-24) — implemented on `main` (docs-only, no PR).
`kmdb-spec-auditor` verified every fact-block anchor against code; its three
documentation findings were fixed. See [Summary](#summary). *(Reached
`Investigated` 2026-07-21 after the reviewer's B1–B5 + Phase-3 questions were
resolved — see [Maintainer resolution](#maintainer-resolution-2026-07-21) and the
[confirmation note](#confirmation-pass-2026-07-21).)*

**PR link**: _(none yet)_

> **Provenance.** A structural fix for the defect class the 2026-07-18
> release-readiness review kept surfacing — design facts stated in several places,
> drifting in some, authoritative in none (SC-10, SC-3, SC-11, and the newly-found
> `device_id`/§08 divergence). The worked reference — the registry section roughly
> as it should ship — is **[Appendix A](#appendix-a--registry-seed-content-and-layout-reference)**
> below; this plan turns it into spec. Grounded by a `kmdb-architect` pass
> (2026-07-21).

## Problem statement

KMDB's cross-cutting **attributes** — `$meta` entries, `device_id`, the Hybrid
Logical Clock (HLC), the Data Encryption Key (DEK), index state — are documented
piecemeal across the subsystem chapters, and the pieces drift. The review found
the pattern repeatedly: §16 claimed index state never leaves the device (false);
§15 marked a cache Required that does not exist; §32 documented an unbuilt API;
§08 says `device_id` lives in platform secure storage while the code stores it in
`$meta` and *notes the secure-storage path was deferred*. Each is the same shape:
no single authoritative, code-anchored home for the fact, so every reader inherits
whichever copy they landed on. The §99 glossary compounds this — it carries
implementation detail (e.g. `enc:blob`'s CBOR layout, `Generation counter`'s
storage key) that is a *second* home for facts that can drift from the code.

This plan builds two coupled pieces of spec infrastructure, and reconciles the
glossary against them:

1. **An attribute registry** — a new **early, unnumbered** spec section that is the
   single authoritative, code-anchored home for each attribute: where it is stored,
   whether it is device-local or replicated, whether it is encrypted, how an
   integrator touches it from the CLI, which plan introduced it, and its
   `file:symbol` code coordinates. Reached by **bidirectional links** — every
   section that mentions an attribute links *into* its entry, and the entry links
   back *out*.
2. **A spec-authoring guide — `docs/spec/README.md`** — mirroring
   `docs/plans/README.md`, that **owns** how the spec is built and numbered, the
   registry entry template, the per-section requirements-table pattern, the
   bidirectional-link rule, the code-anchoring discipline and the
   `kmdb-spec-auditor`'s standing job, the **glossary-vs-registry division of
   labour**, and the hard rule: **never resolve a divergence by editing the spec to
   match wrong code.**

The guide is the stronger half: without a written standard, the registry is a
one-off nobody maintains; with it, the pattern is enforceable and the auditor has
something to audit against.

**Scope discipline (target "good", not "perfect").** Seed the registry with what
has already been verified against `main` (the `$meta` family, with full entries
for `device_id` and `gc:tombstoneFloor`); let it grow as later work touches each
attribute. This is not a spec-wide retrofit.

## Open questions

All resolved by the maintainer (2026-07-21).

- [x] **Q1 — Guide consolidation vs cross-reference. → The guide OWNS it.**
      `docs/spec/README.md` owns the spec numbering and spec-format requirements
      outright; `docs/plans/README.md`'s current numbering note (§44-48) becomes a
      cross-reference to the guide, not a second copy.
- [x] **Q2 — Early placement anchor. → After §03.** The registry is
      `03a_attribute_registry.md` with an `{.unnumbered}` heading, sorting after
      `03_architecture_overview.md` (confirm the `03a_` sort position against the
      pandoc glob during implementation).
- [x] **Q3 — Licence headers on spec markdown. → None needed.** Markdown files do
      not carry a licence header; the published site includes a CC-BY licence in its
      footer. Confirm `license_check` is scoped to code files (existing `docs/spec/*.md`
      carry no header and pass) so the new `.md` files do not trip it.

**Maintainer directive (2026-07-21) — glossary reconciliation is in scope.** The
plan must **review and update `docs/spec/99_glossary.md`**: take technical /
implementation detail *out* of the glossary, validate it against code, and move it
into the registry where appropriate. The guide states the division: **the glossary
clarifies terms and provides internal/external links; implementation details and
requirements live in the registry.** See Phase 3.

## Investigation

### Architect grounding (2026-07-21)

- **Numbering is positional and never renumbered.** Pandoc concatenates
  `docs/spec/*.md` lexically with `number-sections: true`, so a level-1 heading's
  §N is its document position. Every cross-reference is by §N, so inserting an
  early *numbered* section would renumber §03→§04… and break every reference in
  the docs and code. → the registry must be **unnumbered** (`{.unnumbered}`), which
  consumes no number and leaves all existing §N intact. This is a **new convention
  for this spec** and must be verified in the built HTML.
- **Build target is `make doc_site_html`** (`make site` silently no-ops — see
  CLAUDE.md). The **SC-17 fence risk is worse for an early section**: because the
  whole spec is one concatenated file, a single unbalanced code fence in the
  registry would swallow *every following section*. Rendering must be verified, not
  assumed.
- **Existing early files:** `00_index.md` (front matter), `01_overview.md` (§1),
  `02_target_workload_profile.md` (§2), `03_architecture_overview.md` (§3). No
  `docs/spec/README.md` exists — the guide is genuinely new.
- **Inbound-link surface (corrected by the architect):**
  - `device_id`: **§03, §04, §08, §11, §12, §13, §31**.
  - `gc:tombstoneFloor`: **§06, §12, §31** (not §17).

### The glossary-vs-registry division of labour

The two must not be a second home for the same fact. The rule this plan
establishes (and records in the guide):

- **Glossary (§99) — clarify terms + links.** "What does this term mean," in one to
  three sentences, plus internal (§N) and external cross-references. It stays the
  first stop for *vocabulary*.
- **Registry — implementation details + requirements.** Storage location,
  device-local vs replicated, encryption, mutability, CLI surface, introducing
  plan, and `file:symbol` code coordinates.

Where a glossary entry currently carries implementation detail, that detail is
validated and moved to the registry, and the glossary keeps a one-line definition
plus a link *into* the registry — the bidirectional-link rule again. The glossary
already contains clear migration candidates: `enc:blob`, `Generation counter`
(= `gen:{ns}`), `Index token` (`tokenMode`/HKDF detail), `$$` / `isLocalOnly`, the
`$vault:*` / `$$vault:*` namespaces, and the key-material entries (`DEK`, `KEK`,
`Wrapped DEK`, `DekCache`). Pure concepts/algorithms stay put: `BM25`, `RRF`,
`SQ8`, `IDF`, `avgdl`, `CAS`, `ISS`, `Compaction`, `Memtable`, `Stemming`.

### Coordination with the `$meta` WIs (the drift risk this must not create)

WI-11/WI-12/WI-13 are actively moving `$meta` entries (index/FTS/Vec state, the
tombstone floor, device identity, `gen:{ns}`). The registry entries therefore show
a **today → target** state with a ⚠ marker until each lands. Two coordination rules
keep the registry from becoming the very thing it exists to prevent:

- **Each `$meta` WI updates its own attribute's registry row when it lands** — drop
  the ⚠, finalise the storage location. This becomes a checklist item in those WIs
  (roadmap note in Phase 6).
- **The false "floor is not replicated" claim: this plan fixes the *spec*
  sentences; WI-11 fixes the *code* comment** (B5, 2026-07-21). The false claim
  appears in both `06_storage_engine.md:205-206` ("Per-device, not synced. The floor
  lives in `$meta`, which is not replicated") and the `meta_store.dart:360` doc
  comment — both false (`$meta` replicates; `isLocalOnly` matches `$$` only). Adding
  a registry inbound link beside an uncorrected §06 sentence would ship a
  self-contradicting section, so **this docs-only plan corrects the §06 spec sentence
  (and audits §12/§31 for the same before linking)**; the `meta_store.dart:360` *code*
  comment stays WI-11's (out of a docs-only plan's scope). See Phase 4/6.

### Edge cases the implementer must handle

- **The registry's worth is checkability, not prose.** Every fact-block claim must
  carry a `file:symbol` anchor a reader (or the auditor) can verify. A row that
  asserts `Encrypted: Yes` without a verifiable anchor is SC-11 with better
  formatting.
- **The `device_id` entry is this plan's own worked cautionary tale.** Its first
  draft said storage was "`$meta`, key `device_id`" — **wrong**: the authoritative
  store is a `DEVICE_ID` file read first (`kv_store_impl.dart:407`). Both the initial
  author *and* the `kmdb-architect` grounding pass got it wrong because both grounded
  in the existing docs (which say `$meta`); the `kmdb-plan-reviewer`, told to hold the
  plan to its own "code-anchored" standard, caught it against `main`. The plan
  designed to fix doc-vs-code drift nearly shipped its flagship entry with exactly
  that drift. **Lesson, recorded in the guide: verify every anchor by symbol against
  the code, never by eyeballing a line or trusting adjacent prose.**
- **`enc:blob` is the genuine encryption exception** — raw CBOR, *not*
  `EncryptionEnvelope`-wrapped, so bootstrap can read it before the DEK exists
  (`meta_store.dart:508-543`). The register must not blanket-claim "everything in
  `$meta` is encrypted."
- **Validate glossary entries before migrating.** The glossary may itself have
  drifted; a migrating entry's technical claims are checked against code first,
  corrected if wrong (never move a false claim into the registry, and never edit to
  match wrong code), then placed.
- **Unverified rows are marked, not asserted.** The settled-replicated entries
  whose encryption has not been individually confirmed carry **(verify)** rather
  than a claim — these are Phase-4 (WI-11) confirmations.
- **The unnumbered heading must still appear in the table of contents.** Verify in
  the built HTML; `{.unnumbered}` removes the number, not the TOC entry.

### Key files

| Concern | File |
| :--- | :--- |
| Worked reference (seed content) | **Appendix A** (below) |
| New guide | `docs/spec/README.md` (to create) |
| New registry section | `docs/spec/03a_attribute_registry.md` (to create; unnumbered) |
| Glossary to reconcile | `docs/spec/99_glossary.md` |
| Inbound links — device_id | `docs/spec/{03,04,08,11,12,13,31}_*.md` |
| Inbound links — floor | `docs/spec/{06,12,31}_*.md` |
| Numbering rule to relocate | `docs/plans/README.md` (§44-48 → cross-reference the guide) |
| Build | `make doc_site_html`; built output `site/spec.html` |

## Implementation plan

### Phase 1 — the spec-authoring guide (`docs/spec/README.md`)

- [ ] Create `docs/spec/README.md`, mirroring `docs/plans/README.md`'s shape, as the
      **owner** of spec mechanics: the pandoc build (`doc_site_html`/`doc_site`),
      positional numbering + the never-renumber rule + `{.unnumbered}` for reference
      sections, cross-ref conventions (§N by number, relative links/anchors), and
      table style.
- [ ] Relocate the spec-numbering note from `docs/plans/README.md` (§44-48): the
      guide owns it; `plans/README.md` keeps a one-line cross-reference (Q1). The
      pointer must **preserve the plan-author-facing imperative** ("a plan must not
      hard-code its spec number") — that audience differs from the guide's
      spec-author-facing mechanics, so redirect *and* retain the imperative, don't
      merely link away (reviewer non-blocking note).
- [ ] Document the **registry entry template**: the fixed fact block (Kind, Format,
      Scope, Storage today/target, Encrypted, Mutability, CLI, Introduced→plan,
      Status), the **⚠ today/target** convention for mid-change attributes, the
      **granularity rule** (full entry for contested/changing/security-relevant;
      one summary row otherwise; the register stays complete), and the
      **bidirectional-link** rule.
- [ ] State the **glossary-vs-registry division of labour**: the glossary clarifies
      terms and provides internal/external links; implementation details and
      requirements live in the registry (maintainer directive; drives Phase 3).
- [ ] Document the **per-section requirements-table** pattern (the future direction:
      each section gains a requirements table linking into the registry) — described
      as the pattern, not applied spec-wide here.
- [ ] Document the **code-anchoring discipline** and the **`kmdb-spec-auditor`'s**
      standing job ("does each anchor still say what the row claims?"), the hard rule
      **never edit the spec to match wrong code**, and the standing rule **verify
      every anchor by symbol against the code, never by eyeballing a line or trusting
      adjacent prose** (B1/B3 — the `device_id` entry proved why).

### Phase 2 — the registry section (`03a_attribute_registry.md`, unnumbered)

- [ ] Create the file with an `{.unnumbered}` level-1 heading, sorting after
      `03_architecture_overview.md` (Q2). Intro: registry-not-appendix, the
      bidirectional-link rule, the glossary relationship.
- [ ] The **complete `$meta` register** table — all twelve entry families, each a
      row, with today→target and the ⚠ markers, matching **Appendix A** (re-verified).
- [ ] **Full entries** for `device_id` and `gc:tombstoneFloor`, ported from
      **Appendix A** with every code coordinate re-checked against `main`.
- [ ] Summary rows for the settled-replicated entries; encryption marked
      **(verify)** where not individually confirmed, `enc:blob` marked raw/exception.

### Phase 3 — glossary review and migration (§99)

- [ ] **Classify every §99 entry** as (a) term / concept / algorithm + links —
      *stays*, or (b) implementation detail / stored-attribute facts — *migrates to
      the registry*. (Candidate lists in the Investigation above.)
- [ ] **Validate before moving.** Check each migrating entry's technical claims
      against code; correct if wrong (never move a false claim into the registry;
      never edit to match wrong code); *then* place. "If appropriate" — some detail
      is simply trimmed, not every entry needs a full registry entry.
- [ ] **Migrate the overlaps now.** Reconcile the entries that overlap the seeded
      `$meta` register — `enc:blob`, `Generation counter`/`gen:{ns}`, and **`Index
      token`** (Q-Phase3a: its `hex`/`hmac` `tokenMode` detail belongs with the
      seeded `index:`/`fts:`/`vec:` index-state rows, so it is a migrate-now overlap,
      not a defer) — so glossary and registry agree. Trim each to a concept definition
      + link; move the storage/scheme detail to the register.
- [ ] **Defer uncovered families as marked "registry candidate" notes** (Q-Phase3b,
      decided): for the vault namespaces and key-material entries (`DEK`, `KEK`,
      `Wrapped DEK`, `DekCache`, `$vault:*`, `$$vault:*`), **do not open new registry
      families in this plan** — leave a one-line "registry candidate" marker on the
      glossary entry and stop there. This keeps Phase 3 bounded.
- [ ] **Leave a glossary stub that links in.** Where content moves, the glossary
      keeps a one-line definition + "See the attribute registry: <entry>", so the
      term stays findable and the bidirectional-link rule holds.

### Phase 4 — inbound links (and the §06 false-sentence fix)

- [ ] Apply this **per-section disposition** (B4) — *definitional* sections keep
      their substance and gain a link; *consumer* sections replace the inline
      fact-of-record with a link. Do not strip a definitional home into an unnumbered
      reference section.

      | Section | device_id / floor role | Disposition |
      | :--- | :--- | :--- |
      | §04 keys | **device_id definitional home** | **Keep** the definition; add a link. Do **not** demote into the registry. |
      | §08 SSTable naming | uses `{deviceId}-…` in place | **Keep** the naming context; add a link. |
      | §03, §11, §13, §31 | consumer mentions of device_id | **Replace** inline description with a link. |
      | §12 sync | device_id + floor | Keep the sync-behaviour context; link the *storage/scope* fact. Audit for any "per-device/not-synced" floor sentence (see below). |
      | §06 storage engine | tombstone floor | Keep compaction/ingest context; link the storage fact — **after** fixing the false sentence (below). |
      | §31 encryption | floor | Link; audit for a "per-device/not-synced" claim. |

- [ ] **Fix the false §06 sentence in this plan (B5).** `06_storage_engine.md:205-206`
      asserts "Per-device, not synced. The floor lives in `$meta`, which is not
      replicated" — false, and one low-risk sentence squarely in the registry's
      domain. Correct it **here** so the inbound link does not sit beside a
      contradiction. **Audit §12/§31 for the same "per-device/not-synced" floor claim
      and fix any before linking.** (The `meta_store.dart:360` *code* comment stays
      WI-11's — out of a docs-only plan's scope.)
- [ ] Confirm no section is left asserting a fact the registry now owns (that is the
      duplication the registry exists to remove), and no inbound link lands beside an
      uncorrected contradiction.

### Phase 5 — build and render verification (the SC-17 guard)

- [ ] Run `make doc_site_html`. Confirm in `site/spec.html`: the registry heading
      renders, appears in the TOC (unnumbered), and **nothing after it is swallowed**
      by a fence (grep the built HTML for a heading that follows the registry).
- [ ] Confirm existing §N numbering is **unchanged** (spot-check e.g. §13 query API,
      §16 secondary indexes still carry their numbers).

### Phase 6 — coordination

- [ ] Add a checklist item to WI-11/WI-12/WI-13 (roadmap) that each updates its
      attribute's registry row when it lands (drop ⚠, finalise storage). **WI-12 is
      re-scoped** (2026-07-21): device_id's authoritative store is already the local
      `DEVICE_ID` file, so WI-12 is a low-risk *cleanup* — stop writing the inert
      `$meta` copy — not a device-identity migration. SC-5's severity is revised down
      accordingly in the review.
- [ ] The §06 **spec** false-sentence fix is owned by **this plan** (Phase 4, B5);
      only the `meta_store.dart:360` **code** comment is left to **WI-11**. Update
      WI-11's spec step to say so, so the two do not both claim the §06 sentence.

**Final step — QA sign-off and pre-commit:**

- [ ] This is a **docs-only** change: no test coverage to run, but hand the seeded
      registry and the migrated glossary entries to **`kmdb-spec-auditor`** to verify
      every fact-block claim against its code anchor (the docs equivalent of tests
      here). Then **`kmdb-qa`** for sign-off. Do not open a PR until received.
- [ ] Run `make pre_commit` (format/analyze/license_check). Per Q3, the new `.md`
      files need no licence header (site footer is CC-BY); confirm `license_check`
      passes on them.
- [ ] Verify the built site one final time (`make doc_site_html`).

## Summary

Implemented on `main` (docs-only; the maintainer authorised committing without a
PR). Landed 2026-07-24, after WI-11 had merged — so the register reflects the
post-WI-11 reality (index/FTS/Vec state and the tombstone floor are already
device-local in `$$` namespaces; only `device_id`/`gen`/`dirty` remain `⚠`
mid-change). Every code coordinate was re-verified against current `main`, not
copied from the pre-WI-11 Appendix A seed.

- **Phase 1 — `docs/spec/README.md`** (the spec-authoring guide): pandoc build,
  positional-numbering + never-renumber rule, `{.unnumbered}` for reference
  sections, the registry entry template, the `⚠ today → target` convention, the
  glossary-vs-registry division, and the code-anchoring discipline (never edit the
  spec to match wrong code; verify anchors by symbol). The numbering note in
  `docs/plans/README.md` now cross-references the guide.
  - **Necessary build fix:** the spec was built with `pandoc docs/spec/*.md`, which
    would have swept the new `README.md` guide into the *published* spec. Changed
    the glob to `docs/spec/[0-9]*.md` in `make_site.mk` (mirroring the roadmap
    build's own numeric-prefix glob). Verified the guide no longer leaks and all 36
    numeric-prefixed sections still render.
- **Phase 2 — `docs/spec/03a_attribute_registry.md`** (unnumbered, sorts after §03):
  the complete `$meta` register plus full `device_id` and `gc:tombstoneFloor`
  entries. Renders as a real section, appears in the TOC, and does not renumber §04+.
- **Phase 3 — glossary reconciliation:** `enc:blob`, `Generation counter`, and
  `Index token` trimmed to concept + link; a division-of-labour intro and a
  registry-candidate list added. The `Index token` entry's stale "`tokenMode` lives
  in `$meta` state" claim was corrected (it moved to `$$indexstate`/`$$ftsstate`
  under WI-11) — a validate-before-migrate catch.
- **Phase 4 — inbound links + audit catches:** floor/device_id links from §06/§12;
  corrected a **WI-11 miss** in §31 (it still listed index/FTS/Vec state as `$meta`
  content). §04/§08 still carry the stale "Keychain" device-id-storage claim, which
  is WI-2's holistic correction — per the B5 lesson those two inbound links are
  deferred to WI-2 rather than placed beside an uncorrected contradiction.
- **Phase 5 — build/render verified:** 36/36 sections render, registry unnumbered
  and in the TOC, README excluded, no renumber, all code fences balanced.
- **Phase 6 — coordination:** the roadmap's `$meta` end-state section now points to
  the live registry and records the WI-12/13/14 "update your row on landing" rule
  and the WI-2 handoffs.

**`kmdb-spec-auditor` sign-off:** verified every register row, both code-coordinate
tables symbol-by-symbol, all `device_id` narrative claims, and the glossary/§31
edits. Three documentation findings, all fixed: (A) `formatVersion` is a *second*
`$meta` encryption exemption, so "the one exemption is `enc:blob`" was false in the
register, the glossary, and §31 (×2) — corrected everywhere; (B) the `Index token`
glossary entry over-reached to `$$vecstate` — `VecIndexState` has no `tokenMode`
(vec uses `modelId`) — narrowed to `$$indexstate`/`$$ftsstate`; (C) two stale *code*
doc-comments (`device_id.dart` "UUIDv7", `vec_index_state.dart` "`$meta` storage")
routed to WI-2 to keep this change docs-only. The register's four "(verify)" markers
were resolved to confirmed answers (schema/version/namespaces = wrapped;
`formatVersion` = raw).

**The registry earned its keep on its first pass** — writing a single code-anchored
home surfaced three pieces of drift (the §31 and glossary `$meta`/`tokenMode`
staleness, and the three-places "one exemption" error) that had survived because no
one place owned the fact.

---

## Plan review (2026-07-21, kmdb-plan-reviewer)

**Verdict: not ready for `Investigated`. Status → `Questions`.** The infrastructure
half of this plan is strong and well-motivated — the registry-vs-glossary division,
the ⚠ today/target convention, the fact-block-as-agent-surface framing, the SC-17
guard, and the unnumbered-section mechanics are all sound, and the `03a_` sort key
was verified correct (see below). But the plan is held to its **own** standard —
*"code-anchored and checkable, not asserted"* — and its **flagship seed entry
(`device_id`) is materially wrong against `main` in exactly the SC-11 way the plan
exists to prevent.** That, plus two under-specified phases, blocks the bar of
"an implementer could execute this with no significant design decisions left."

Everything below was verified against `main` at HEAD `83d54d8`.

### Blocking — factual corrections to the seed (Appendix A)

**B1. `device_id` storage today is wrong — it omits the authoritative `DEVICE_ID`
file.** This is the load-bearing defect. The plan's `device_id` entry says storage
today is "`$meta`, key `device_id`", scope "Device-local ⚠ stored as replicated
today — it syncs via `$meta` (SC-5)", and frames WI-12 as a binary "`$meta` today →
secure-storage-outside-DB *or* `$$`". The code tells a different story:

- `KvStoreImpl.ensureDeviceId` (`kv_store_impl.dart:407-431`) reads a plaintext
  **`DEVICE_ID` file in the db root** (`kDeviceIdFilename`, `kv_store_impl.dart:439`)
  **first**, and only falls back to `$meta` for backward compatibility. Its own doc
  comment (`kv_store_impl.dart:394-406`) states the device ID is stored in *two*
  places and that **"The DEVICE_ID file is therefore always preferred over the
  `$meta` value when both are present."**
- The file lives outside `sst/`, so `SyncEngine` never uploads it — the
  **authoritative** identity is already device-local. `$meta` is "retained for
  backward compatibility only."
- This is not new/in-flight behaviour: it landed in `2c6971c` ("Fix device ID
  corruption when syncing copied databases"), predating the durability track.

Consequences the entry must be reworked around:

- **Storage — today** is `{dbDir}/DEVICE_ID` (authoritative, never synced) **plus** a
  backward-compat `$meta` copy (which does replicate but is read *second*). SC-5's
  bite is far smaller than "it syncs today" implies: a DB that has ever called
  `ensureDeviceId` reads the local file and ignores the synced `$meta` value.
- **The §08 "Tensions" narrative is undercut.** §08:153-155 ("secure storage… must
  not be stored inside the database itself to avoid circular dependency") is
  *substantially already honoured*: the `DEVICE_ID` file is outside the LSM, so
  there's no bootstrap circularity and no encryption dependency. The plan presents a
  binary that misses the existing third path. WI-12's framing needs to start from
  "there is already a local file; what remains" — not "it lives in `$meta`."
- **The encryption tension is largely moot on the primary path.** The `DEVICE_ID`
  file is plaintext (`id.codeUnits`), read with no DEK. Only the `$meta` fallback is
  `EncryptionEnvelope`-wrapped. "Reading it needs the DEK" is true only of the
  fallback, not the path actually taken.

This entry is the one the plan explicitly stakes its credibility on ("Appendix A's
`device_id` encryption field is the cautionary case"). Shipping it with the primary
storage mechanism missing would be the registry's first SC-11. Must be corrected and
re-anchored before `Investigated`. (Note: `reassignDeviceId` should also be checked —
does it rewrite the `DEVICE_ID` file, or only `$meta`? The `new-device-id` CLI note
in the entry currently describes only the `$meta` + hwm story.)

**B2. `ensureDeviceId` is mis-located, and the lifecycle prose conflates three
things.** Appendix A's Code-coordinates row "Generate / ensure |
`device_id.dart:63` (`ensureDeviceId`)" is wrong: `ensureDeviceId` is **not** in
`device_id.dart`. It is `KvStoreImpl.ensureDeviceId` (`kv_store_impl.dart:407`),
surfaced as `KmdbDatabase.ensureDeviceId` (`kmdb_database.dart:781`). `device_id.dart`
has `DeviceId.load` (line 53; the UUIDv4 generation is line 64, not 63). The
Lifecycle sentence — "Minted lazily on first launch by `ensureDeviceId` if absent
(`device_id.dart:63`), defaulting to the sentinel `'00000000'` until then" —
conflates: (a) `DeviceId.load` (generates a real ID); (b) `ensureDeviceId` (file-first
resolution, different file); (c) the `'00000000'` **open-time param default**
(`kv_store_impl.dart:120`, `kmdb_database.dart:303`), which is what an un-`ensure`d
store reports, *not* what `DeviceId.load` returns. Untangle these.

**B3. Minor line-drift (fix in passing, non-blocking on their own):**
`reassignDeviceId` is cited at `lsm_engine.dart:1524`; actual is
`lsm_engine.dart:1428` (doc at `:1408`). `new_device_id_command.dart:47` → class at
`:46`. These are within the "line numbers drift, re-verify" caveat, but B1/B2 show the
caveat needs teeth: **re-verify every anchor by symbol, not by eyeballing the line.**

**Confirmed correct** (so the reviewer isn't only reporting misses):
`putDeviceId`/`getDeviceId` are `EncryptionEnvelope`-wrapped at `meta_store.dart:217`/
`:207`, `deviceIdKey` at `:204`; the misleading `:504-505` comment (mentions
`deviceIdKey` in a "never wrapped" context) is indeed a trap — the values *are*
wrapped. `enc:blob` is genuinely raw CBOR, not wrapped (`meta_store.dart:508-543`),
so the "not everything in `$meta` is encrypted" caveat is right. `gc:tombstoneFloor`
*is* wrapped (`setTombstoneFloor`/`getTombstoneFloor` `:405`/`:380`).
`device_id.dart:37-38`'s "deferred to Phase 8" note, §08:153-155's "must not be stored
inside the database", §06:205-206's false "not synced", and `meta_store.dart:360`'s
false "excluded from sync" all check out exactly as described.

### Blocking — under-specified phases (design decisions left to the implementer)

**B4. Phase 4 (inbound links) is the least mechanical step and needs a per-section
disposition.** "Leave section-local context, remove duplicated fact-of-record" asks a
Sonnet implementer to decide, per section, what is *the fact of record* (strip → link)
versus *local context a reader needs in place* (keep + link) across §03/04/08/11/12/13/
31 (device_id) and §06/12/31 (floor). That is a design judgment on the fly, and two
sections are clearly **not** "strip to a link":

- **§04 is device_id's definitional home** (the keys/identity chapter). Demoting its
  substance into an *unnumbered* early section would move a numbered spec's identity
  definition into what reads as a reference appendix. §04 should keep its definition
  and gain a link, not be stripped.
- **§08's SSTable naming** needs `{deviceId}-…` in place; that is section-local, not
  duplication.

Add an explicit table to Phase 4: for each of the 10 sections, "definitional — keep
substance + add link" vs "consumer — replace inline description with a link", and name
what specifically gets removed. Without it, Phase 4 is not mechanical.

**B5. Phase 4 + Phase 6 together ship a self-contradicting §06.** Phase 4 links §06's
tombstone-floor mention *into* the registry (whose entry correctly says "syncs today,
unsafe"), while Phase 6 defers correcting §06:205-206's **false** "Per-device, not
synced… `$meta`, which is not replicated" to WI-11. Net effect of *this* plan: §06
asserts "not synced" (false) immediately beside a link to a registry entry that says
the opposite. That is worse than either fixing it or leaving it alone. Decide one:
(a) fix that single false sentence in §06 now — it is one sentence, squarely in the
registry's domain, and low-risk — or (b) do **not** add the §06 inbound link until
WI-11 corrects the prose. Deferring the *code* comment (`meta_store.dart:360`) to WI-11
is correct (out of a docs-only plan's scope); the *spec* sentence is this plan's to
either fix or not-yet-link. (Same question applies wherever §12/§31 currently assert
the floor is per-device/not-synced — audit those before linking.)

### Questions for the maintainer (resolve, then this can move to `Investigated`)

- [ ] **B1 — rework the `device_id` entry around the `DEVICE_ID` file.** Confirm the
      corrected framing: storage today = local `DEVICE_ID` file (authoritative, never
      synced) + backward-compat `$meta` copy; SC-5 scoped to the fallback; §08 rationale
      already partly satisfied; WI-12 reframed accordingly. (Also: does
      `reassignDeviceId` rewrite the file? verify and fix the CLI note.)
- [ ] **B2 — correct `ensureDeviceId` location and untangle the lifecycle prose**
      (`DeviceId.load` vs `ensureDeviceId` vs the `'00000000'` open-time default).
- [ ] **B3 — re-anchor by symbol** (`reassignDeviceId` → `lsm_engine.dart:1428`, etc.)
      and adopt "verify by symbol, not line" as the standing rule the guide records.
- [ ] **B4 — add the per-section disposition table to Phase 4** (definitional-keep vs
      consumer-strip; §04 and §08 are keep-with-link).
- [ ] **B5 — decide the §06 false-sentence handling**: fix the one sentence in this
      plan, or hold the §06 inbound link until WI-11. Audit §12/§31 for the same before
      linking.
- [ ] **Q-Phase3a — is `Index token` a "migrate now" overlap or a "defer" family?**
      Its `tokenMode` (`hex`|`hmac`) discriminator lives in the index-state `$meta`
      blobs the register already seeds as rows (`index:`/`fts:`/`vec:`), so it overlaps
      the seed — yet the plan names only `enc:blob` and `Generation counter` as the
      "migrate now" overlaps. Classify it explicitly so Phase 3 stays bounded. (The
      `SQ8` = stays / `Index token` = migrates split is otherwise correct: `SQ8` is an
      algorithm with no storage/sync/encryption axis, like `BM25`/`IDF`; `Index token`
      carries stored-attribute detail.)
- [ ] **Q-Phase3b — collapse the "either open the family OR leave a note" choice.**
      For vault namespaces and key material, Phase 3 offers a design decision at
      implementation time. Pick one now (recommend: leave a marked "registry candidate"
      note; do not open new families in this plan) so Phase 3 is mechanical.

### Non-blocking notes (address, but they don't gate `Investigated`)

- **Q1 cross-reference nuance.** `docs/plans/README.md:44-48` is *plan-author*-facing
  ("a plan must not hard-code its spec number"). The relocation is right, but the
  one-line pointer must **preserve that plan-facing imperative**, not merely redirect to
  `docs/spec/README.md`'s (spec-author-facing) mechanics. State this in the Phase 1
  checklist item.
- **`03a_` sort key: verified correct.** Empirically, `03a_attribute_registry.md`
  sorts after `03_architecture_overview.md` and before `04_keys.md` under `LC_ALL=C`,
  `C.UTF-8` (this repo's locale), and `en_US.UTF-8`. Q2 is settled; keep the
  render-time confirmation in Phase 5 as belt-and-braces.
- **Phase 5 SC-17 guard is adequate and concrete** (render, TOC-presence for the
  unnumbered heading, grep for a heading *after* the registry to prove nothing was
  swallowed, spot-check §13/§16 numbers). Good as written.
- **Register completeness ("all twelve `$meta` families") is un-audited here** and is
  correctly handed to `kmdb-spec-auditor` in the final step. Acceptable for a docs-only
  plan, but note that `fts:`/`vec:`/`schema:`/`version:config:` keys are written by
  other subsystems (not `meta_store.dart`), so the auditor's completeness pass is the
  real check — don't treat the seed table as self-evidently exhaustive.
- **Coordination division (WI-11/12/13) is otherwise clean.** Seeding a ⚠ today/target
  row for a mid-change attribute does not create a maintenance trap *provided* the row
  states the true current fact (it does, for the floor) — the WIs only drop the ⚠ and
  finalise storage. This does **not** block completion of this plan.

Once B1–B5 and the two Phase-3 questions are resolved in the plan text, this clears the
bar and can go to `Investigated` — the underlying design is sound; the gaps are
factual accuracy in the seed and mechanical specificity in Phases 3–4.

### Maintainer resolution (2026-07-21)

All seven items addressed in the plan text above; every code claim re-verified against
`main` **and** against the real `demodb` instance the maintainer created.

- **B1 — done.** The `device_id` entry (Appendix A) is rebuilt around the
  authoritative `DEVICE_ID` file (`kv_store_impl.dart:407`, `:439`), with the `$meta`
  copy demoted to legacy/inert-on-read. Storage, Scope, Encryption, the §08 Tensions,
  and the WI-12 framing are all re-anchored. `reassignDeviceId` verified to rewrite
  **both** the file and `$meta` (so the CLI note is correct). Confirmed empirically:
  `demodb/DEVICE_ID` = `9c6bd81b`, with a `$meta` copy in the syncable SSTable body.
- **B2 — done.** `ensureDeviceId` re-located to `kv_store_impl.dart:407`
  (surfaced `kmdb_database.dart:781`); `DeviceId.load`/`ensureDeviceId`/`'00000000'`
  open-time default untangled in the Lifecycle prose and Code-coordinates table.
- **B3 — done.** Re-anchored by symbol (`reassignDeviceId` → `lsm_engine.dart:1428`,
  CLI → `:46`, etc.); "verify by symbol, not line" added to the guide (Phase 1) and
  to the edge-cases as this plan's own worked cautionary tale.
- **B4 — done.** Phase 4 now carries the per-section disposition table (§04/§08 =
  keep-substance + link; §03/11/13/31 = consumer-strip; §12/§06/§31 audited).
- **B5 — decided: fix the §06 sentence in this plan.** Phase 4 corrects
  `06_storage_engine.md:205-206` (and audits §12/§31) so no inbound link sits beside a
  contradiction; the `meta_store.dart:360` code comment remains WI-11's. Phase 6 and
  the Coordination note updated so the two don't both claim the §06 sentence.
- **Q-Phase3a — decided: `Index token` migrates now** (its `tokenMode` detail folds
  into the seeded index-state rows).
- **Q-Phase3b — decided: registry-candidate notes, no new families** in this plan.

Plus the two roadmap/review consequences (maintainer-approved 2026-07-21): **WI-12
re-scoped** to "retire the inert `$meta` device_id copy" (cleanup, not migration), and
**SC-5's severity revised down** in the review (hygiene/confidentiality, not
wrong-identity). The Keychain/secure-storage move is logged as a separate optional
enhancement.

### Confirmation pass (2026-07-21, kmdb-plan-reviewer)

**Confirmed — moving to `Investigated`.** All five blockers and both Phase-3 questions
are genuinely resolved. Re-verified against `main` at HEAD `83d54d8`:

- **B1 holds up under its own standard.** The rebuilt `device_id` entry now leads with
  the authoritative `DEVICE_ID` file (`ensureDeviceId`, `kv_store_impl.dart:407`;
  `kDeviceIdFilename`, `:439`) and demotes the `$meta` copy to legacy/inert-on-read —
  matching the code (`kv_store_impl.dart:394-406`, "the DEVICE_ID file is therefore
  always preferred"). The one new load-bearing claim — *reassign rewrites both the file
  and `$meta`* — was held to the B1 bar and **passed**: `KvStoreImpl.reassignDeviceId`
  (`kv_store_impl.dart:326`) delegates SSTable renames to `LsmEngine.reassignDeviceId`
  (`lsm_engine.dart:1428`), then `putDeviceId` writes the `$meta` copy (`:337`), then
  durably rewrites the `DEVICE_ID` file (`:342-348`). No new wrong anchor was
  introduced.
- **B2/B3 correct.** `ensureDeviceId` re-located to `kv_store_impl.dart:407`
  (`kmdb_database.dart:781`); `DeviceId.load` (`device_id.dart:53`, UUIDv4 at `:64`)
  and the `'00000000'` open-time default (`kv_store_impl.dart:120`) are untangled;
  `reassignDeviceId` re-anchored to `lsm_engine.dart:1428`, CLI to `:46`. The
  "verify by symbol, not line" rule is folded into the guide.
- **B4/B5 make Phases 3–4 mechanical.** Phase 4's per-section disposition table
  removes the on-the-fly keep-vs-strip judgment (§04/§08 keep+link is correct — they
  are the definitional/naming homes), and the §06:205-206 false-sentence fix is pulled
  into this plan with a §12/§31 audit, so no inbound link lands beside a contradiction.
  Phase 6 cleanly splits the spec fix (this plan) from the `meta_store.dart:360` code
  comment (WI-11).
- **Phase 3 is bounded.** Migrate-now is exactly `enc:blob` + `Generation counter` +
  `Index token`; all other candidates get a "registry candidate" note; no new families.
  The `SQ8`-stays / `Index token`-migrates split is sound.

**Two soft notes for the implementer (non-blocking, do not gate `Investigated`):**

1. **Index-token detail placement.** The seeded `index:`/`fts:`/`vec:` rows are
   *summary* rows; the `tokenMode` (`hex`|`hmac`) / HKDF-`kmdb-index-token` detail
   being migrated from the glossary is richer than a single cell. Either add a compact
   "tokenMode: hex→hmac" note to the rows or promote index-state to a full entry — the
   granularity rule already sanctions both; pick whichever reads cleaner. The
   underlying facts are already prose in the §99 `Index token` entry (validate them per
   Phase 3's "validate before moving" step; the auditor is the final gate).
2. **Register completeness** ("all twelve `$meta` families") remains the
   `kmdb-spec-auditor`'s check — `fts:`/`vec:`/`schema:`/`version:config:` keys are
   written outside `meta_store.dart`, so don't treat the seed table as self-evidently
   exhaustive.

The design is sound, the seed is now code-accurate, and an implementer can execute
Phases 1–6 without significant design decisions. **Cleared for implementation.**

---

## Appendix A — registry seed content and layout reference

> **This is the worked reference for Phases 1–3**, not final spec text. It is the
> registry section roughly as it should ship: the `$meta` register plus two full
> entries (`device_id`, `gc:tombstoneFloor`). Everything here was read from `main`;
> **re-verify every code coordinate at implementation time**, since line numbers
> drift. The "Notes on the layout" at the end record the design decisions behind
> the template.

### Why a registry, and why not an appendix

An appendix is where information goes to be ignored. This is the opposite: a
**registry reached by inbound links**, placed as an early section (after §03
architecture overview, so the vocabulary is established before the subsystem
chapters use it). The rule is bidirectional —

- every spec section that *mentions* an attribute links **into** its registry
  entry (so §08's Sorted-String-Table (SSTable) naming prose links to `device_id`
  rather than re-describing it), and
- each registry entry links back **out** to the sections that define or consume
  it.

So the reader lands on the attribute from wherever they were, and an agent
resolving "where does `device_id` live and is it synced?" has exactly one place
to look — with a `file:symbol` it can verify, not prose it has to trust.

**Relationship to the glossary (§99).** Complementary, not duplicative. The
glossary clarifies terms and provides links; the registry answers "where does this
attribute live, is it synced, is it encrypted, how do I touch it from the CLI, and
what is the code." A glossary entry for "Device ID" links *into* the registry.

### How to read an entry

Two tiers, by the granularity rule:

- **Complete register** — every attribute in the family appears as one row, so the
  register is exhaustive. Settled-and-boring attributes stop here.
- **Full entry** — attributes that are contested, changing, or security-relevant
  get the full treatment: a fixed **fact block** (same fields, same order every
  time — the part an agent parses), then prose for **Role** and **Lifecycle**, a
  **CLI** note (how an integrator touches it without reading code), a **Tensions**
  list for anything unresolved or mid-change, a **Code coordinates** table
  (`file:symbol` — the reality anchor), and **Spec cross-refs**.

**Granularity rule.** Full entries for device-local / changing / security-relevant
attributes; a single summary row for settled-replicated ones. The register stays
complete either way, and a summary row can be promoted to a full entry whenever a
reason appears.

The `Scope`, `Storage`, and `Encrypted` fields carry a **⚠ today vs target**
split whenever an entry is mid-change, so the registry never quietly reads as if
in-flight work were done — the exact trap that produced SC-10.

### Complete register — `$meta` entries

All twelve `$meta` entry families. "Encrypted" reflects whether the value is
`EncryptionEnvelope`-wrapped on an encrypted database; **(verify)** marks a
Phase-4 (WI-11) confirmation, not a settled fact.

| Attribute | Kind | Scope | Storage: today → target | Encrypted | Detail |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `device_id` | Identifier | Device-local (authoritative) — inert `$meta` copy syncs (SC-5) | `DEVICE_ID` file (never synced) **+** legacy `$meta` copy → **WI-12** retires the copy | File: No · `$meta`: yes | **[full entry](#device_id)** |
| `index:{ns}:{path}` | Index state | Device-local ⚠ syncs today (SC-10) | `$meta` → `$$indexstate` | Yes | WI-11 |
| `fts:{ns}:{field}` | Index state | Device-local ⚠ syncs today (SC-10) | `$meta` → `$$ftsstate` | Yes | WI-11 |
| `vec:{ns}:{field}` | Index state | Device-local ⚠ syncs today (SC-10) | `$meta` → `$$vecstate` | Yes | WI-11 |
| `gc:tombstoneFloor` | Watermark (HLC) | Device-local ⚠ syncs today (Q-D) | `$meta` → `$$` *(name unpinned)* | Yes | **[full entry](#gctombstonefloor)** |
| `gen:{ns}` | Counter | **Undecided** | `$meta` → **WI-13** | Yes | WI-13 |
| `dirty` | Flag | Device-local (verify) | `$meta` → verify | Yes | WI-11 Phase 3 |
| `enc:blob` | Key material (wrapped DEK) | Replicated | `$meta` (stays) | **No — raw CBOR** (bootstrap must read it before the DEK exists) | summary |
| `schema:{collection}` + `schema:__registry__` | Schema contract | Replicated | `$meta` (stays) | Yes (verify) | summary |
| `version:config:{collection}` | Retention policy | Replicated | `$meta` (stays) | Yes (verify) | summary |
| `namespaces` | Namespace registry | Replicated | `$meta` (stays) | Yes (verify) | summary |
| `formatVersion` | Format-version marker | Replicated | `$meta` (stays) | (verify) | summary |

> The registry generalises beyond `$meta`: HLC, the DEK/`EncryptionBlob`, and the
> SSTable filename fields are each attribute families that would get their own
> register in the same shape. This seed scopes to `$meta` because that is what
> WI-11/12/13 have just put under the microscope.

### `device_id`

> The stable per-installation identity of a KMDB client. Names every SSTable this
> device writes and is the device's handle in the sync protocol.

| Field | Value |
| :--- | :--- |
| **Kind** | Identifier (opaque) |
| **Format** | 8-char lowercase hex — truncated Universally Unique Identifier v4 (`DeviceId.load`, `device_id.dart:64`). Verified on a real instance: `demodb/DEVICE_ID` = `9c6bd81b`. |
| **Scope** | Device-local. The **authoritative** store is a local file that is never synced; a legacy `$meta` copy *does* replicate but is read **second** and is inert on read (SC-5). |
| **Storage — today** | **Authoritative:** a plaintext `DEVICE_ID` file in the db root (`{dbDir}/DEVICE_ID`), outside `sst/` → never uploaded. **Legacy:** a `$meta` `device_id` copy, written on first open via the fallback (and on every `reassignDeviceId`); it lands in a syncable `.sst` and replicates, but `ensureDeviceId` prefers the file. *(Confirmed on `demodb`: both the `DEVICE_ID` file and a `$meta` copy present; the copy is in the syncable SSTable body.)* |
| **Storage — target** | **WI-12 (cleanup):** stop *writing* the inert `$meta` copy on new databases (keep reading it as the legacy fallback). Moving to OS secure storage (Keychain, per §08) is a *separate optional enhancement*, not required — the local file already resolves the bootstrap concern. |
| **Encrypted at rest** | **File: No** — plaintext (`id.codeUnits`), read with no DEK. **`$meta` copy:** `EncryptionEnvelope`-wrapped (plaintext only when the DB is unencrypted, as in `demodb`). |
| **Mutability** | Set once at first launch; changed only by `reassignDeviceId`, which rewrites the `DEVICE_ID` file **and** the `$meta` copy **and** renames every SSTable (the manifest then records the new filenames). |
| **CLI** | `kmdb new-device-id` (see below) |
| **Introduced** | [`plan_deviceid.md`](completed/plan_deviceid.md) (§04); the `DEVICE_ID` file landed later in `2c6971c` ("Fix device ID corruption when syncing copied databases"). |
| **Status** | 🔧 WI-12 retires the legacy `$meta` copy (low-risk cleanup, before the `0.1.0` freeze) |

**Role.** Two jobs. (1) **Naming:** every SSTable is `{deviceId}-{minHlc}-{maxHlc}.sst`,
and the manifest records those filenames — so `device_id` is load-bearing for the
on-disk layout (§08). (2) **Sync identity:** per-device high-water marks are keyed by
it, consolidation fencing is per-`deviceId`, and `SyncEngine` uses it to *exclude
self* when pulling peers.

**Lifecycle.** Resolved on open by `ensureDeviceId` (`kv_store_impl.dart:407`,
surfaced as `KmdbDatabase.ensureDeviceId`, `kmdb_database.dart:781`): read the
`DEVICE_ID` file **first**; if absent, fall back to `DeviceId.load`
(`device_id.dart:53` — reads the `$meta` copy, or generates a fresh UUIDv4 and writes
it to `$meta`); then write the file so subsequent opens skip `$meta`. An un-`ensure`d
store reports the `'00000000'` **open-time param default** (`kv_store_impl.dart:120`)
— distinct from a resolved identity, and not what `DeviceId.load` returns.

**CLI.** `kmdb new-device-id` mints a fresh identity for a **copied** database — two
copies sharing a `device_id` would write colliding SSTable filenames and clobber each
other's high-water marks in a shared sync folder. It calls `reassignDeviceId`, which
rewrites **both** the `DEVICE_ID` file and the `$meta` copy and renames the SSTables;
if remotes are configured it warns on stderr to delete the stale
`highwater/{oldDeviceId}.hwm`. Emits `{"oldDeviceId":…, "newDeviceId":…}`. *(The value
of an integrator being able to exercise an attribute from the CLI without touching
Dart.)*

**Tensions (what WI-12 actually is, post-correction).**

- **SC-5's bite is smaller than "it syncs today" implies.** The authoritative
  identity is the local file; the synced `$meta` copy is **inert on read** (every
  device prefers its own file). SC-5's real exposure is **hygiene/confidentiality** —
  the copy leaks each peer's `device_id` into the sync folder and is dead weight — not
  a wrong-identity correctness bug. WI-12 = stop writing it.
- **§08's rationale is substantially already honoured.** §08:153-155 ("must not be
  stored inside the database itself to avoid circular dependency during bootstrap") —
  the `DEVICE_ID` file is outside `sst/`, so there is no bootstrap circularity and no
  DEK dependency. §08's "platform secure storage (Keychain…)" is a stronger,
  still-unbuilt form; `device_id.dart:37-38`'s "for now `$meta` is the sole
  persistence mechanism" is now **stale** (the file superseded it) — log for WI-2.
- **The encryption tension is moot on the primary path.** The file is plaintext, read
  with no DEK; only the `$meta` fallback is wrapped.

**Code coordinates.** *(Verify by symbol, not line — B1/B2 showed line-eyeballing is
how the wrong story got written.)*

| Concern | Location |
| :--- | :--- |
| Resolve on open (file-first) | `kv_store_impl.dart:407` (`ensureDeviceId`), surfaced `kmdb_database.dart:781` |
| The `DEVICE_ID` file | `kv_store_impl.dart:439` (`kDeviceIdFilename`) |
| `$meta` fallback + generation | `device_id.dart:53` (`DeviceId.load`), `:64` (UUIDv4) |
| `$meta` read / write / key | `meta_store.dart:207` (`getDeviceId`), `:217` (`putDeviceId`), `:204` (`deviceIdKey`) — both `EncryptionEnvelope`-wrapped |
| Stale "secure storage deferred" note | `device_id.dart:37-38` |
| Reassign (file + `$meta` + SSTable rename) | `lsm_engine.dart:1428` (`reassignDeviceId`), `kv_store_impl.dart:326` |
| `'00000000'` open-time default | `kv_store_impl.dart:120`, `kmdb_database.dart:303` |
| CLI | `new_device_id_command.dart:46` |
| Consumed — SSTable naming / manifest | §08 (`{deviceId}-…`), manifest `add.filename` |
| Consumed — sync | `sync_engine.dart:365` (exclude self), `highwater.dart:270` |

**Spec cross-refs.** §04 (identity — definitional home), §08 (SSTable naming), §12 (sync).

### `gc:tombstoneFloor`

> The highest Hybrid Logical Clock (HLC) horizon at which *this device* has
> already garbage-collected (GC'd) tombstones. A recipient-side guard that stops
> already-collected deletions from being resurrected by an incoming SSTable.

| Field | Value |
| :--- | :--- |
| **Kind** | Monotonic watermark (HLC) |
| **Format** | 64-bit HLC, big-endian uint64 (physical + logical) |
| **Scope** | Device-local **by design** ⚠ **stored as replicated today** — it syncs via `$meta` (Q-D) |
| **Storage — today** | `$meta`, key `gc:tombstoneFloor` |
| **Storage — target** | A `$$` local-only namespace (**name not yet pinned** — it has no data-namespace sibling to mirror). WI-11. |
| **Encrypted at rest** | Yes, when the DB is encrypted — `EncryptionEnvelope`-wrapped in `setTombstoneFloor`/`getTombstoneFloor` |
| **Mutability** | Monotonic — only ever raised (`max`), never lowered, under correct operation |
| **CLI** | None — managed automatically by compaction/ingest (no integrator-facing surface) |
| **Introduced** | [`plan_tombstone_gc_ingest_floor.md`](completed/plan_tombstone_gc_ingest_floor.md) (H4-FU3, durability hardening v0.02.01) |
| **Status** | 🔧 Changing under **WI-11** (before the `0.1.0` format freeze) |

**Role.** After a compaction drops at least one tombstone at horizon *H*, the
floor advances to *H*. On ingest, `LsmEngine.ingestAt0` rejects any incoming
SSTable whose `maxHlc <= floor` with `StaleSstableIngestException` — the file
covers an HLC range this device has already collected, so re-ingesting it would
resurrect deleted rows. It is a defence-in-depth backstop to the sync horizon.

**Lifecycle.** Absent on a fresh DB → `getTombstoneFloor` returns `Hlc(0,0)`
(accepts everything). Raised by `setTombstoneFloor` after each tombstone-dropping
`_compactAll`. Reset only by the explicit `resetTombstoneFloor` path.

**Tensions (why Q-D reclassified it as "wrong today").**

- **Device-local by design, replicated by storage.** The doc comment
  (`meta_store.dart:358-364`) and §12:203 both say "per-device" — but it lives in
  synced `$meta`, so it replicates.
- **Replication here is actively unsafe, not merely wasteful.** `$meta` is
  Last-Write-Wins (LWW) by HLC and keeps the *most-recent write*, **not the
  maximum floor**. A peer's later-HLC write can therefore **lower** this device's
  floor, re-opening exactly the resurrection window the floor exists to close.
  That is why the fix is a move, not "leave it, it's harmless."
- **The doc comment's own rationale is false.** It reads "stored in `$meta`, which
  is excluded from sync" — `$meta` is *not* excluded (`isLocalOnly` matches `$$`
  only). Fixing that sentence is part of the move.

**Code coordinates.**

| Concern | Location |
| :--- | :--- |
| Read / write / key | `meta_store.dart:380` (`getTombstoneFloor`), `:405` (`setTombstoneFloor`), key `gc:tombstoneFloor` |
| "device-local by design" doc | `meta_store.dart:358-364` |
| Enforced (ingest guard) | `LsmEngine.ingestAt0` — rejects `maxHlc <= floor` |
| Advanced | `LsmEngine._compactAll` (after a tombstone-dropping compaction) |
| Reset | `KvStoreImpl.resetTombstoneFloor` |

**Spec cross-refs.** §06 (compaction), §12 (sync — per-device floor, §12:203).

### Notes on the layout itself (design rationale)

- **The fact block is the agent surface.** Fixed fields in a fixed order means an
  agent — or the `kmdb-spec-auditor` — can diff "what the row claims" against the
  code coordinate directly. The registry is only trustworthy if `Encrypted at rest:
  Yes` is *checkable*, not asserted.
- **The ⚠ today/target split is load-bearing.** Without it, this very seed would
  have said `device_id` scope = "device-local" and read as done — reproducing
  SC-10's exact mistake in a document meant to prevent it. Attributes mid-change
  must show both states until the change lands.
- **`Introduced` points at the plan, not the phase.** A plan link is a durable,
  verifiable provenance anchor; "Phase 1" is a label that ages. (Phase kept in
  parens as human orientation.)
- **CLI alignment is deliberate.** Every attribute with an integrator-facing
  surface names its CLI command, so an integrator can experiment with the attribute
  (`kmdb new-device-id`) before ever opening Dart. Attributes with no CLI say so
  explicitly rather than leaving it ambiguous.
