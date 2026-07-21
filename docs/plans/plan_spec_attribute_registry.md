# Spec attribute registry and a spec-authoring guide

**Status**: Open

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
- **The false "floor is not replicated" claim is WI-11's to fix, not this plan's.**
  It appears in both `06_storage_engine.md:205-206` ("Per-device, not synced. The
  floor lives in `$meta`, which is not replicated") and the `meta_store.dart:360`
  doc comment — both false (`$meta` replicates; `isLocalOnly` matches `$$` only).
  The registry entry for the floor **states the corrected fact and references
  WI-11**; it does not duplicate the correction. (Bonus drift site found by the
  architect pass — fold into WI-11's spec step.)

### Edge cases the implementer must handle

- **The registry's worth is checkability, not prose.** Every fact-block claim must
  carry a `file:symbol` anchor a reader (or the auditor) can verify. A row that
  asserts `Encrypted: Yes` without a verifiable anchor is SC-11 with better
  formatting. Appendix A's `device_id` encryption field is the cautionary case: a
  misleading comment at `meta_store.dart:504` nearly recorded it wrong — the truth
  (`putDeviceId`/`getDeviceId` wrap via `EncryptionEnvelope`) came from the code.
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
      guide owns it; `plans/README.md` keeps a one-line cross-reference (Q1).
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
      standing job ("does each anchor still say what the row claims?"), and the hard
      rule **never edit the spec to match wrong code**.

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
- [ ] **Migrate the overlaps now, defer the rest cleanly.** Reconcile the entries
      that overlap the seeded `$meta` register (`enc:blob`, `Generation
      counter`/`gen:{ns}`) so glossary and registry agree. For attribute families
      the registry does not yet cover (vault namespaces, key material), either open
      the corresponding registry family or leave a marked "registry candidate" note
      — do **not** half-migrate.
- [ ] **Leave a glossary stub that links in.** Where content moves, the glossary
      keeps a one-line definition + "See the attribute registry: <entry>", so the
      term stays findable and the bidirectional-link rule holds.

### Phase 4 — inbound links

- [ ] From each of §03/§04/§08/§11/§12/§13/§31, replace inline `device_id`
      description with a link into the registry entry (leave section-local context,
      remove duplicated fact-of-record).
- [ ] From §06/§12/§31, link the tombstone-floor mentions into the registry entry.
- [ ] Confirm no section is left asserting a fact the registry now owns (that is the
      duplication the registry exists to remove).

### Phase 5 — build and render verification (the SC-17 guard)

- [ ] Run `make doc_site_html`. Confirm in `site/spec.html`: the registry heading
      renders, appears in the TOC (unnumbered), and **nothing after it is swallowed**
      by a fence (grep the built HTML for a heading that follows the registry).
- [ ] Confirm existing §N numbering is **unchanged** (spot-check e.g. §13 query API,
      §16 secondary indexes still carry their numbers).

### Phase 6 — coordination

- [ ] Add a checklist item to WI-11/WI-12/WI-13 (roadmap) that each updates its
      attribute's registry row when it lands (drop ⚠, finalise storage).
- [ ] Add the `06_storage_engine.md:205-206` false-claim correction to **WI-11**'s
      spec step (with the `meta_store.dart:360` comment) — referenced, not
      duplicated, by the registry entry.

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

_To be completed when the work is done._

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
| `device_id` | Identifier | Device-local ⚠ syncs today (SC-5) | `$meta` → **WI-12** (secure store *or* `$$`) | Yes | **[full entry](#device_id)** |
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
| **Format** | 8-char lowercase hex — truncated Universally Unique Identifier v4 (`v4().replaceAll('-','').substring(0,8)`) |
| **Scope** | Device-local ⚠ **stored as replicated today** — it syncs via `$meta` (SC-5) |
| **Storage — today** | `$meta`, key `device_id` (`_nameToKey('device_id')`) |
| **Storage — target** | **Undecided (WI-12).** Platform secure storage *(outside the DB)* per §08 intent, **or** a `$$` local-only namespace. Not a settled "→ `$$`". |
| **Encrypted at rest** | Yes, when the DB is encrypted — `EncryptionEnvelope`-wrapped in `putDeviceId`/`getDeviceId` |
| **Mutability** | Set once at first launch; changed only by explicit `reassignDeviceId` (which renames every SSTable) |
| **CLI** | `kmdb new-device-id` (see below) |
| **Introduced** | [`plan_deviceid.md`](completed/plan_deviceid.md) (Phase 1, §04) |
| **Status** | 🔧 Changing under **WI-12** (before the `0.1.0` format freeze) |

**Role.** Two distinct jobs. (1) **Naming:** every SSTable this device flushes is
`{deviceId}-{minHlc}-{maxHlc}.sst`, and consolidation output prepends the epoch —
so `device_id` is load-bearing for the on-disk file layout (§08). (2) **Sync
identity:** per-device high-water marks are keyed by it, consolidation fencing is
per-`deviceId`, and `SyncEngine` uses it to *exclude self* when pulling peers.

**Lifecycle.** Minted lazily on first launch by `ensureDeviceId` if absent
(`device_id.dart:63`), defaulting to the sentinel `'00000000'` until then.
Persisted via `putDeviceId`. Reassignment is a heavyweight operation: it flushes,
renames every SSTable file, and rewrites the stored value.

**CLI.** `kmdb new-device-id` generates a fresh identity for a **copied**
database. This is the answer to "I duplicated a KMDB instance onto another
machine" — two copies sharing a `device_id` would write colliding SSTable
filenames and clobber each other's high-water marks in a shared sync folder. The
command mints a new ID, calls `reassignDeviceId`, and — if remotes are configured
— warns on stderr that the old `highwater/{oldDeviceId}.hwm` must be deleted from
each sync folder. Emits `{"oldDeviceId":…, "newDeviceId":…}` as machine-readable
output. *(This is the value of an integrator being able to exercise an attribute
from the CLI without touching Dart.)*

**Tensions (why WI-12 is more than a namespace move).**

- **§08 describes an unbuilt design as current.** §08 says `device_id` lives in
  "platform-specific secure storage (Keychain on iOS, SharedPreferences on
  Android, localStorage on web)" and **"must not be stored inside the database
  itself to avoid circular dependency during bootstrap."** The code contradicts
  this and *says so*: `device_id.dart:37-38` records that secure storage was
  **deferred to Phase 8** and "for now `$meta` is the store." → a spec-vs-code
  divergence to log (WI-2).
- **Moving to `$$` does not satisfy §08's own rationale.** A `$$` namespace still
  lands in `.local.sst` — *inside* the database. Since `device_id` is needed to
  *name* SSTable files, storing it in one is the bootstrap circular dependency §08
  warns about. Only "outside the DB" (secure storage) resolves both SC-5 *and* the
  bootstrap concern.
- **Encryption compounds the bootstrap tension.** `device_id` is
  `EncryptionEnvelope`-wrapped, so reading it needs the DEK — which is unlocked
  during `open()`. Anything that needs `device_id` earlier than DEK unlock cannot
  read it from encrypted `$meta`. Worth confirming WI-12 doesn't inherit this.

**Code coordinates.**

| Concern | Location |
| :--- | :--- |
| Generate / ensure | `packages/kmdb/lib/src/engine/kvstore/device_id.dart:63` (`ensureDeviceId`) |
| Read / write / key | `meta_store.dart:207` (`getDeviceId`), `:217` (`putDeviceId`), `:204` (`deviceIdKey`) |
| "secure storage deferred" note | `device_id.dart:37-38` |
| In-memory value + rename | `lsm_engine.dart:1727` (`get deviceId`), `:1524` / `kv_store_impl.dart:326` (`reassignDeviceId`) |
| CLI | `packages/kmdb_cli/lib/src/commands/new_device_id_command.dart:47` |
| Consumed — SSTable naming | §08 (`{deviceId}-…`) |
| Consumed — sync | `sync_engine.dart:365` (exclude self), `highwater.dart:270` |

**Spec cross-refs.** §04 (identity), §08 (SSTable naming), §12 (sync).

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
