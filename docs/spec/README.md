# Authoring the KMDB specification

This guide owns **how the KMDB specification is written, built, and kept true**.
It is the spec-side companion to [`docs/plans/README.md`](../plans/README.md):
that file governs *plans*, this one governs `docs/spec/`.

If you are adding or changing a spec section, read this first.

## What the spec is, and how it is built

The specification is a set of Pandoc-Markdown files in `docs/spec/`, named
`NN_topic.md`. They are **concatenated in filename order** into a single
document and rendered to `site/spec.html`.

- **Build it with `make doc_site_html`** (HTML only) or `make doc_site` (HTML +
  coverage). **`make site` is not a build target** — it names the already
  checked-in `site/` directory and silently no-ops.
- Rendering requires `pandoc`.

Because the whole spec is one concatenated file, **a malformed section can break
the sections that follow it**. The canonical failure is an unbalanced code fence
(```` ``` ````): everything after the stray fence renders as one giant code
block, silently dropping headings, tables, and prose from the published output.
This is a real prior incident (finding SC-17), so:

> **Always run `make doc_site_html` after editing a section, and confirm in
> `site/spec.html` that the section *after* the one you changed still renders as
> headings — not swallowed into a code block.**

## Section numbering — positional, and never renumbered

Pandoc numbers level-1 (`#`) headings **by document position** (`number-sections:
true`). Section §N is simply the Nth top-level heading in filename order — the
number is **not** written in the Markdown.

Two consequences that are strict rules:

1. **Never renumber.** Every cross-reference in the spec *and in the code and
   plans* is by §N. Inserting a numbered section early would shift every later
   §N and break every reference. New numbered sections take the **next available
   `NN`** at the end (a plan must not hard-code the number — see
   [`docs/plans/README.md`](../plans/README.md), which defers to this file for
   the mechanics).

2. **Reference material may be unnumbered.** A section that is vocabulary or
   reference rather than a normative chapter can be placed anywhere in filename
   order with an **unnumbered heading**, so it consumes no number and shifts
   nothing:

   ```markdown
   # The attribute registry {.unnumbered}
   ```

   The [attribute registry](03a_attribute_registry.md) uses this — its filename
   (`03a_…`) sorts it after `03_architecture_overview.md`, and `{.unnumbered}`
   keeps §04 onward untouched. An unnumbered heading **still appears in the table
   of contents** — verify that in the built HTML.

## Cross-references

- Reference a numbered section by **§N** (e.g. "see §12"). Do not embed the
  filename in prose for numbered sections — the number is the stable handle.
- Link to reference material (unnumbered sections, this guide, plans) by
  **relative path** or anchor.
- Anchors in the built HTML are path-prefixed
  (`docs__spec__12_sync.md__some-heading`); rely on §N in prose rather than
  hand-writing anchors.

## The attribute registry

Cross-cutting **attributes** — `$meta` entries, `device_id`, the HLC, the DEK,
index state — must have **one authoritative, code-anchored home**: the
[attribute registry](03a_attribute_registry.md). The registry exists because the
alternative (describing each fact wherever it happens to come up) drifts: the
2026-07-18 review found the same design fact stated in several sections, true in
one and stale in the others, authoritative nowhere.

### Bidirectional links

The registry is **reached by inbound links**, not by being an appendix nobody
opens. The rule runs both ways:

- Every section that *mentions* an attribute links **into** its registry entry
  instead of re-describing its storage/sync/encryption facts.
- Each registry entry links back **out** to the sections that define or consume
  the attribute.

A section keeps the context a reader needs *in place* (§04 keeps the definition
of device identity; §08 keeps `{deviceId}-…` in the SSTable-naming rule) and
adds a link; it hands the *fact of record* (where it is stored, whether it syncs,
whether it is encrypted) to the registry.

### The registry entry template

Each **full entry** opens with a fixed **fact block** — the same fields, in the
same order, every time, because this is the part an agent or the
[`kmdb-spec-auditor`](../../.claude/agents/kmdb-spec-auditor.md) parses and
checks:

| Field | Meaning |
| :--- | :--- |
| **Kind** | Identifier / counter / watermark / key material / flag / … |
| **Format** | On-the-wire / on-disk shape |
| **Scope** | Device-local or replicated |
| **Storage** | Where it lives (namespace + key, or file) |
| **Encrypted at rest** | Yes / No, with the mechanism |
| **Mutability** | Immutable / monotonic / mutable |
| **CLI** | The command that exercises it, or "None" |
| **Introduced** | A link to the **plan** that added it |
| **Status** | Stable, or 🔧 changing under WI-N |

Then prose: **Role**, **Lifecycle**, a **CLI** note, a **Tensions** list for
anything unresolved or mid-change, a **Code coordinates** table (`file:symbol`),
and **Spec cross-refs**.

### Granularity

The register table is **complete** — every attribute in a family is a row.
Beyond that:

- **Full entries** for attributes that are device-local, changing, or
  security-relevant — the ones people get wrong.
- **A single summary row** for settled-and-replicated attributes.

A summary row can be promoted to a full entry whenever a reason appears.

### The `⚠ today → target` convention

An attribute whose storage is **mid-change** (a WI is moving it) shows **both**
its current and target state in `Scope` / `Storage`, marked `⚠`. This is
load-bearing: without it the registry would state the *intended* end state as
though it were done — reproducing the exact drift it exists to prevent. Drop the
`⚠` and finalise the row **when the moving WI lands**, not before.

### Introduced → the plan, not the phase

The `Introduced` field links the **plan** that added the attribute. A plan link
is a durable, verifiable provenance anchor; a phase label ("Phase 4") ages.

## The glossary vs the registry

`docs/spec/99_glossary.md` and the registry must **not** be a second home for the
same fact. The division:

- **Glossary — clarify terms + links.** "What does this term mean," in one to
  three sentences, plus internal (§N) and external cross-references. It is the
  first stop for *vocabulary*.
- **Registry — implementation details + requirements.** Storage location,
  device-local vs replicated, encryption, mutability, CLI surface, introducing
  plan, and `file:symbol` code coordinates.

When a glossary entry carries implementation detail, **validate it against the
code, then move that detail to the registry** and leave a one-line glossary
definition that links *into* the registry entry. Concepts and algorithms
(`BM25`, `RRF`, `SQ8`, `Compaction`) stay in the glossary — they have no
storage/sync/encryption axis.

## Code-anchoring discipline

The registry (and, over time, per-section requirements tables) is only worth
anything if its claims are **checkable against the code**, not asserted. Two
standing rules:

1. **Verify every anchor by symbol, not by eyeballing a line.** Line numbers
   drift; a claim "confirmed" by reading the prose near a remembered line number
   is how a wrong fact gets written down. Grep for the symbol and read it. The
   registry's own `device_id` entry is the cautionary tale: its first draft
   placed device identity in `$meta` — because the author *and* an architect
   pass both grounded in the existing docs, which said `$meta`; only a
   code-grounded review caught that the authoritative store is a `DEVICE_ID`
   file read first.

2. **Never resolve a divergence by editing the spec to match wrong code.** When
   the spec and the code disagree, one of them is a defect. Editing the spec to
   describe a buggy implementation converts a bug into a documented feature and
   destroys the evidence. Report both and let a human decide which is wrong.
   (This is why spec-*truth* is a separate job from spec-*consistency*, and why
   [`kmdb-spec-auditor`](../../.claude/agents/kmdb-spec-auditor.md) grounds in the
   code while `kmdb-architect` grounds in the docs.)

The `kmdb-spec-auditor`'s standing job is exactly this: for each registry
fact-block claim, *does the code coordinate still say what the row claims?* Run
it over new or changed registry entries, and periodically over the whole
register.

## Per-section requirements tables (direction, not yet applied)

The intended next step for the spec is that each section grows a short
**requirements table** at its head — a compact list of the section's normative
requirements, each linking into the registry or to the code that satisfies it.
This is described here as the pattern; it is **not** applied spec-wide yet. Add
one when you substantially revise a section, following the registry's
fact-block-as-checkable-surface principle.

## Licence headers

`docs/spec/*.md` (and this guide) carry **no licence header** — Markdown spec
files are not code files. The published site includes a CC-BY licence in its
footer. `license_check` is scoped to code files and does not inspect these.
