# Stop the query planner trusting predicates the index cannot answer

**Status**: **Investigated** (2026-07-21). Three review passes; all five questions
ratified, all blockers closed and re-verified against `main`. Phase 2 moves the
three derived-index state stores (secondary-index/FTS/Vec) to concrete
`$$indexstate`/`$$ftsstate`/`$$vecstate` namespaces with `EncryptionEnvelope`
preserved; Phase 3 is a complete Goal-3 `$meta` audit; Phase 4 gates both `query()`
and `search()` cross-device. Ready for **`kmdb-plan-implement`**. See
[Third confirmation pass](#third-confirmation-pass-2026-07-21).

> **Plan-review pass 2026-07-21 (`kmdb-plan-reviewer`).** See
> [Plan review](#plan-review-2026-07-21) at the end of this document. Root-cause
> framing stress-tested, all four `$meta` classifications verified against code,
> Q-D reclassified (settleable — not undecided), Q-A/Q-B steered with a
> recommendation, two correctness claims corrected (`requireFreshIndex`, the
> "one root cause" thesis), and Phase 4 flagged as still aspirational.
>
> **Maintainer resolution 2026-07-21.** All five questions settled (see
> [Decisions](#decisions-2026-07-21)): Q-A narrow fix + doc contract (ratified),
> Q-B `$$` namespace (ratified), Q-C `gen:{ns}` split to its own roadmap item,
> Q-D floor reclassification accepted, Q-E sampled-matrix + harness. SC-5 device
> identity is *classified only* here and gets its own WI. Every code claim above
> was independently re-verified against `main` before ratification (incl.
> `ingestSstable` not bumping the local `gen`, which is why Q-C is not a clean
> device-local move). Phases rewritten to be mechanical. Ready for the reviewer's
> final pass.

**PR link**: _(none yet)_

> **Provenance.** WI-11 of the [0.10.01 hardening track](../roadmap/0_10_01.md),
> closing findings **SC-10** and **SC-15** of the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md).
> Both were reproduced end-to-end. The review is the evidence base; this plan
> does not restate it.

## Problem statement

**Two independently-found critical defects rhyme: in both, the query planner
selects an index path without establishing that the index can answer the
predicate it was given.** They do **not** share a single fix — SC-15 is a
one-line query-planner-logic bug and SC-10 is a state-placement bug in the
storage/namespace layer, and their fixes touch disjoint files (see the plan
review, §1). What they share is a **test strategy** (the Phase 4 equivalence
matrix) and a **release deadline**, which is why they are bundled here. In both,
the result is the same and is the worst kind — **present, matching documents
silently return nothing**, with `QueryPlan` reporting `indexScan` as though the
index had looked and found nothing.

### SC-15 — the index cannot answer *this predicate*

```
no index declared  -> rows = 1
index declared     -> rows = 0   strategy=indexScan scanned=0 matched=0
control exact case -> rows = 1   strategy=indexScan
```

`FieldFilter.equalityPredicate` is
`_op == _Op.eq ? (_path, _operand) : null`
([field_filter.dart:175](../../packages/kmdb/lib/src/query/filter/field_filter.dart#L175))
— it never consults `caseSensitive`, a field on the **same class four lines
above**. The planner receives an exact-match predicate, `lookupByValue` resolves
the single exact token `token('london')`, and `'London'` — indexed under a
different token — is never found. §13:507 promises an in-memory pass as the
safety net; it never runs, because the index already "answered".

### SC-10 — the index cannot answer *at all, on this device*

§16:229–230 claims *"the sync engine filters out all `$`-prefixed namespaces
during SSTable upload, so index state never leaves the device."* **No such
filter has ever existed** (`git log -S` finds it at no commit), and it could not
exist: `$$` is a strict superset of `$`, and the single-`$` namespaces in use
are `$meta`, `$ver`, `$vault`, `$sync` — all of which **must** sync.

Index state, including `status`, lives in `$meta`. A device that pulls a peer's
`$meta` inherits `status: current` for an index **it never built**, then scans
its own empty `$$index:*` namespaces. `_nameToKey` is a plain XXH64, so it is
device-independent; `builtThrough` and `gen:{ns}` sync together and validate
each other. It self-heals only when that device *writes* to the namespace — so a
**read-mostly second device is worst affected**, which is the common phone-reads,
laptop-writes shape.

**This spans all three derived-index subsystems, not just secondary indexes**
(surfaced 2026-07-21 when Phase 2's routing was pinned). FTS state
(`FtsIndexState`, `status: current`) persists to `$meta` under `fts:{ns}:{field}`
([fts_manager.dart:1438](../../packages/kmdb/lib/src/search/lexical/fts_manager.dart#L1438))
with data in local-only `$$fts:`; Vec state does the same under `vec:{ns}:{field}`
([vec_manager.dart:812](../../packages/kmdb/lib/src/search/semantic/vec_manager.dart#L812))
with data in `$$vec:`. So a read-mostly second device inherits `current` and its
`search()` returns **silent zero results** — the same 🔴, one layer over. Phase 2
fixes all three.

### Why the tests did not catch either

`filter_test.dart:173–196` covers `caseSensitive` thoroughly at the `evaluate()`
level. `index_query_test.dart` covers index selection thoroughly with exact-case
predicates. Both files score well on line coverage. **Nothing anywhere asserts
that the index path and the full-scan path return the same rows.** The halves
are well tested; the seam is not.

## Goals

1. The planner uses an index **only** when that index can answer the predicate.
2. A device never believes it holds an index it did not build.
3. Classify every `$meta` entry as device-local or replicated.
4. Make the seam testable, so this class cannot silently return.

## Non-goals

- Adding new index *capabilities* (case-insensitive indexes, locale folding).
  This plan makes the planner **decline** what it cannot answer; making it able
  to answer more is separate work.
- The wider spec corrections for §13/§16 — those are WI-2.

## Decisions (2026-07-21)

The five open questions were reviewed by `kmdb-plan-reviewer` (see the review
section at the end) and ratified by the maintainer. All are settled; the phases
below are written against these decisions.

- [x] **Q-A — Narrow fix, not a capability contract.** Gate `equalityPredicate`
      on `_op == _Op.eq && caseSensitive`, **and** strengthen its doc-comment into
      an explicit contract (Phase 1). The Phase 4 equivalence matrix — not a new
      subsystem — is what kills the class: it catches any future matcher that
      reintroduces the shape. A capability contract is speculative scope given only
      `eq` is index-eligible today, and new index capabilities are an explicit
      non-goal.
- [x] **Q-B — Index/FTS/Vec state moves to new `$$…state` namespaces.** Concrete
      targets ratified 2026-07-21 (the reviewer's confirmation pass correctly held
      that "a `$$` namespace" was the *option*, not a frozen-format *target*): new
      local-only namespaces **`$$indexstate`**, **`$$ftsstate`**, **`$$vecstate`**,
      each keyed by `XXH64(<existing symbolic name>)` with the existing CBOR state
      value. Guaranteed-local via `.local.sst`, consistent with
      `$$index:`/`$$fts:`/`$$vec:` and with the SC-3 precedent (`$$cache`, not
      `$cache`). Rejected: a sentinel key *inside* the data namespace (couples state
      to entries, needs collision-proofing and scan special-casing); a per-device
      key *within* `$meta` (still uploads device-local state); splitting `$meta`
      (heavy, out of scope before the freeze). Routing: off `MetaStore` (deliberately
      `$meta`-bound) onto direct writes, preserving `EncryptionEnvelope` wrapping —
      see Phase 2. **FTS/Vec folded in 2026-07-21** because they carry the identical
      SC-10 defect (see the SC-10 problem statement); splitting them would leave a
      live 🔴 in `search()` with no risk-reduction benefit, unlike SC-5.
- [x] **Q-C — Split out of this plan.** `gen:{ns}` is a separate cache-correctness
      question and WI-11 does **not** depend on it: with index state device-local
      (Phase 2), `builtThrough` mismatches on a fresh device and triggers a rebuild
      regardless of how `gen` is classified. The classification is subtler than
      device-local-vs-replicated: `ingestSstable`
      ([kv_store_impl.dart:306](../../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L306))
      does **not** bump the local `gen` counter (only the local
      `put`/`delete`/`writeBatch` path does), so today's replicated `gen` is what
      actually drives cross-device cache invalidation — making it device-local
      would silently break that unless the ingest path is also taught to bump it.
      Tracked as a separate item on the [0.10.01 track](../roadmap/0_10_01.md); not
      resolved here.
- [x] **Q-D — Tombstone GC floor is device-local, and wrong today.** Accepted.
      Resolved from code: the floor is device-local *by design*
      ([meta_store.dart:358-364](../../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L358)
      and §12:203 both say "per-device") but stored in synced `$meta` under the
      device-independent key `gc:tombstoneFloor`. `$meta` is **not** local-only
      (`isLocalOnly` matches `$$` only) and LWW keeps the most-recent-HLC write,
      not the max — so a peer can *lower* a device's floor and re-enable the exact
      tombstone resurrection the floor prevents. The doc comment's own rationale
      ("`$meta`, which is excluded from sync") is false. Folded into Phase 3 as a
      mechanical `$meta`→`$$` move.
- [x] **Q-E — Sampled matrix in a unit test; cross-device under the harness.**
      The single-device equivalence test is a sampled filter × operator × case-flag
      matrix (**must** include the `caseSensitive:false` `eq` cell — the only one
      that fails today). The cross-device arm runs in `kmdb_harness` / under `e2e`,
      not in the default unit run. See Phase 4 for the concrete shape.

## Investigation

### The shared shape (not a shared fix)

Both defects are the planner answering *"can I use an index?"* with *"is there
an index on this field, and is this an equality?"* — when the correct question
is *"can **this** index, in **its current state on this device**, answer **this
predicate**?"*

| | SC-15 | SC-10 |
| :--- | :--- | :--- |
| Failing sub-question | Can the index answer this **predicate**? | Can the index answer **at all here**? |
| Boundary crossed | Case folding | Device |
| Wrong assumption | `eq` ⇒ exact-token lookup is valid | `status: current` ⇒ this device built it |

**They share a shape, not a fix.** SC-15's fix is one line in
`field_filter.dart` (Phase 1); SC-10's is a namespace move in the storage layer
(Phase 2). The two phases touch disjoint files and may be done in either order.
What unifies them is the Phase 4 equivalence test — *index-path rows must equal
full-scan rows* — which is the single artefact that would have caught both and
will catch every future instance of the shape.

### Key files

| Concern | File |
| :--- | :--- |
| Predicate exposure (SC-15) | `packages/kmdb/lib/src/query/filter/field_filter.dart` |
| Planner index selection | `packages/kmdb/lib/src/query/kmdb_query.dart` (≈313, 384) |
| Token resolution | `packages/kmdb/lib/src/query/index/index_reader.dart` (≈47) |
| Index state + `$meta` (SC-10) | `packages/kmdb/lib/src/query/index/index_manager.dart` (70, 112, 531) |
| Local-only rule | `packages/kmdb/lib/src/engine/util/namespace_codec.dart` |
| Existing tests (the seam) | `test/query/filter_test.dart`, `test/query/index_query_test.dart` |

### Edge cases the implementer must handle

- **Do not "add the missing `$` filter" that §16 describes.** It is incoherent,
  not merely absent: filtering all `$`-prefixed namespaces would exclude `$meta`,
  `$ver` and `$vault` from upload and **break sync outright**. The defect is
  device-local state living in a synced namespace; the fix is to *move* it.
- **`QueryPlan` currently lies in both cases** — it reports `indexScan` with
  `documentsScanned: 0`, which reads as "the index looked and found nothing"
  rather than "the index was asked a question it cannot answer". Whatever the
  fix, the plan output must not remain misleading.
- **`requireFreshIndex()` does NOT mitigate SC-10** (correcting the review's
  SC-20 characterisation). Traced `_checkIndexFreshness`
  ([kmdb_query.dart:528](../../packages/kmdb/lib/src/query/kmdb_query.dart#L528)):
  it throws only when `status != current`, and device B *inherits* `status:
  current` from the peer's synced `$meta`, so the guard never fires and the query
  still returns zero rows. It guards only the single-device `building`/`stale`
  race. Do not treat it as a safety net for the cross-device defect; flag the
  mischaracterisation for the SC-20 spec work (WI-2).
- **No migration.** KMDB is unreleased; moving index state simply invalidates
  existing local indexes, which rebuild. Confirm that rebuild is triggered rather
  than the state being read as absent-and-current.
- **Index state must not resurrect via sync after the move.** Verify that an old
  database with index state still in `$meta` does not have it re-ingested.

## Implementation plan

### Phase 1 — SC-15: the planner declines what it cannot answer

*Independent of Phase 2 — either order.*

- [ ] Gate `equalityPredicate` on `_op == _Op.eq && caseSensitive`
      ([field_filter.dart:175](../../packages/kmdb/lib/src/query/filter/field_filter.dart#L175)),
      per Q-A. Do **not** build a capability contract.
- [ ] Strengthen the `Filter.equalityPredicate` doc comment
      ([filter.dart:46](../../packages/kmdb/lib/src/query/filter/filter.dart#L46))
      into an explicit contract: *"Return non-null only when an exact-token index
      lookup is a **complete** answer to this predicate. A predicate that needs any
      transform the index did not apply at write time (case folding, accent
      stripping, Unicode normalisation) MUST return null."* This is the durable
      guard against the next matcher reintroducing the bug.
- [ ] Ensure a declined predicate falls through to the full scan, and that
      `QueryPlan` reports the strategy honestly (not `indexScan` with
      `documentsScanned: 0`).
- [ ] Audit every other `Filter` implementation for the same assumption. Only
      `_FieldFilter` overrides `equalityPredicate` and only `eq` returns non-null
      today — confirm that remains true and that no other override silently claims
      index-answerability.

### Phase 2 — SC-10: index, FTS, and Vec state become device-local

*Independent of Phase 1 — either order.* **This covers all three derived-index
subsystems** (secondary indexes, FTS, Vec), folded together on 2026-07-21 because
each carries the identical SC-10 defect via the identical mechanism (state
`status: current` in synced `$meta`; data in a local-only `$$…` namespace). A
read-mostly second device inherits `current` and scans its own empty local
namespace → silent zero results. Fixing only the secondary index would ship a
live 🔴 in `search()`.

- [ ] **DO NOT add a `$`-prefix upload filter.** `isLocalOnly`
      ([namespace_codec.dart:148](../../packages/kmdb/lib/src/engine/util/namespace_codec.dart#L148))
      matches `$$` **only**, by design; `$meta`/`$ver`/`$vault` are single-`$` and
      **MUST** upload (§12). The §16 claim of a `$`-filter is incoherent, not
      merely absent — adding one would break sync. The fix is to *move* state to a
      `$$` namespace, never to filter `$`.
- [ ] Move each state store to a new local-only `$$…state` namespace, sibling to
      its data namespace (concrete targets, Q-B — ratified 2026-07-21). The value
      (existing CBOR state) and key encoding are unchanged; **only the target
      namespace changes** from `$meta`:

      | Subsystem | Current `$meta` symbolic name | New namespace | Key | Persist sites |
      | :--- | :--- | :--- | :--- | :--- |
      | Secondary index | `index:{ns}:{path}` | **`$$indexstate`** | `XXH64(index:{ns}:{path})` | `index_manager.dart` `_loadState`:536, `_persistState`:551, `removeIndex`:298 |
      | FTS | `fts:{ns}:{field}` (`FtsIndexState.metaKey`) | **`$$ftsstate`** | `XXH64(fts:{ns}:{field})` | `fts_manager.dart` `_loadState`:1426, `_saveState`:1438 (+ any delete site) |
      | Vec | `vec:{ns}:{field}` (`VecIndexState.metaKey`) | **`$$vecstate`** | `XXH64(vec:{ns}:{field})` | `vec_manager.dart` `_loadState`:800, `_saveState`:812 (+ any delete site) |

      Each `$$…state` namespace `isLocalOnly` = true (starts with `$$`), so it lands
      in `.local.sst` and never uploads — no new sync wiring. None collides with the
      `$$index:`/`$$fts:`/`$$vec:` data-namespace prefix scans (`$$indexstate` ≠
      `$$index:…`, etc.).
- [ ] **Routing:** replace the `MetaStore.*RawByName` calls at the persist sites
      above with direct `_store` reads/writes to the new `$$…state` namespaces. Do
      **not** generalise `MetaStore`; it is deliberately `$meta`-bound. Build-
      completion status flips stay standalone puts, as today (no atomicity change).
- [ ] **Preserve encryption of the moved state (Blocker 3, 2026-07-21).**
      `MetaStore.*RawByName` wraps/unwraps via `EncryptionEnvelope`
      ([meta_store.dart:476/484](../../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L476)),
      so on an encrypted database all three states are ciphertext at rest today. The
      direct-write path **must** apply the same `EncryptionEnvelope.wrap`/`unwrap`,
      or it silently reverses part of the 0.08 `$meta`-encryption reconciliation and
      leaves index/FTS/Vec metadata as plaintext in `.local.sst`. Keep the wrapping.
- [ ] For each subsystem, confirm a device that has not built the index reports it
      as such (its state-activation path must not read `current` for an index absent
      locally) and builds/rebuilds on demand. For secondary indexes the rebuild
      trigger keys on the device-local `builtThrough`
      ([index_manager.dart:86](../../packages/kmdb/lib/src/query/index/index_manager.dart#L86)),
      independent of `gen:{ns}` (WI-13); verify the FTS/Vec equivalents.
- [ ] Confirm every read path (`_loadState`, `checkTokenModeOnOpen`/its FTS/Vec
      equivalents, the query/search activation checks) consults **only** the new
      `$$…state` namespaces, so old `index:*`/`fts:*`/`vec:*` entries left in `$meta`
      (on disk or in the sync folder) are dead/ignored, not re-ingested
      (no-migration; review §9).

### Phase 3 — the `$meta` classification audit

Every entry classified, and the classification **recorded in the spec** so the
next addition has a rule to follow:

**Complete inventory (Goal 3 — classify *every* entry).** The list below is the
full set of `$meta` entry families; an implementer must confirm none is missing by
grepping the `MetaStore` key constructors and every `*RawByName`/`genKey`/symbolic
name in `lib`. "Verify" rows are expected-correct but must be checked against code
in this phase, not assumed.

| `$meta` entry | Expected | Disposition |
| :--- | :--- | :--- |
| Secondary-index state | Device-local | **Fix here** (Phase 2) — SC-10 |
| FTS index state | Device-local | **Fix here** (Phase 2) — SC-10, same defect |
| Vec index state | Device-local | **Fix here** (Phase 2) — SC-10, same defect |
| Tombstone GC floor | Device-local | **Fix here** — Q-D: mechanical `$meta`→`$$` move; LWW can *lower* the floor → resurrection |
| Device identity | Device-local | **Classify only** — SC-5 → WI-12. `device_id` names SSTable files and is the sync identity; riskier than index state, own WI. Do **not** fold that migration here. |
| `gen:{ns}` counters | Undecided | **Split out** — Q-C → WI-13. WI-11 does not depend on it. Do not touch here. |
| `enc:blob` (wrapped DEK) | Replicated | Correct — no change |
| Schema state (`schema:{collection}` + registry) | Replicated | **Verify** — schemas are a shared data contract; expected correct, confirm it syncs intentionally |
| Version retention config/policy | Replicated | **Verify** — retention is a data-contract decision; expected correct |
| Namespaces registry | Replicated | **Verify** — the set of user namespaces should be consistent; expected correct |
| Format-version marker | Replicated | **Verify** — global format version; expected correct |
| Dirty-open flag | Device-local | **Verify — possible further instance.** It marks *this device's* interrupted session and drives local WAL replay; if it syncs, a peer could inherit "dirty." Confirm whether it is written to `$meta` and, if so, whether that is benign or a latent bug to file separately. |

- [ ] Fix the four "Fix here" rows (index/FTS/Vec state + tombstone floor).
- [ ] Verify the "Verify" rows against code; if the dirty flag (or any other) turns
      out mis-placed, file it — do **not** silently fold new scope into this WI.
- [ ] Record the classification rule for the spec (WI-2 sequences the wording);
      note the deferred rows (SC-5 → WI-12, `gen:{ns}` → WI-13) so they are not lost.

### Phase 4 — the equivalence tests *(the point of this plan)*

- [ ] **Single-device** — new file `test/query/index_full_scan_equivalence_test.dart`.
      For a sampled matrix of filter type × operator × `caseSensitive` flag, assert
      the row set (compared **by `_id`**) from `query(F)` with the index *declared*
      equals the row set with **no** index declared.
      - **Must include the cell that fails today:**
        `Filter.field('city').equals('london', caseSensitive: false)` against a doc
        with `city: 'London'` — index-declared returns 0, full-scan returns 1.
        Without this exact cell the "fails before the fix" gate is untestable,
        because only `caseSensitive:false` `eq` diverges today; every other operator
        full-scans in *both* arms and would pass against the current (broken) code.
- [ ] **Cross-device — secondary index** — a `kmdb_harness` case (runs under
      `e2e`, not the default unit run; per Q-E). Device A writes docs, builds the
      index, and pushes; device B pulls with the index *declared*; assert B's row
      set (by `_id`) equals A's. Fails today because B inherits `status: current`
      and scans its empty `$$index:*`.
- [ ] **Cross-device — search (FTS + Vec)** — the same harness shape for
      `search()`: A builds the FTS (and, where available, Vec) index and pushes; B
      pulls and searches; assert B's results equal A's. Fails today for the same
      reason (B inherits `fts`/`vec status: current`, scans empty `$$fts:`/`$$vec:`).
      This is the regression gate for the FTS/Vec half of Phase 2.
- [ ] Both must **fail against the current code before the fixes land** — run them
      first and record the observed failure, or they are not testing what they
      claim.
- [ ] Add a targeted regression test for the tombstone-floor LWW hazard (Q-D): a
      two-device harness case where A's later-HLC floor write lowers B's higher
      floor, then B ingests an SSTable it should have rejected — assert rejection
      survives the move to `$$`.

### Phase 5 — spec

- [ ] Note the corrections needed in §13 and §16 for **WI-2** to sequence; do not
      edit `docs/spec/` here beyond the §meta classification rule (Phase 3).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — judge by whether the seam is covered, not by the line
      percentage. Both halves of this defect were already well covered.
- [ ] Hand off to **`kmdb-qa`** for sign-off. Do not open a PR until received.
- [ ] Run `make pre_commit` — note it is scoped to `packages/kmdb`.
- [ ] Verify licence headers (2026) on new files.

## Plan review (2026-07-21)

`kmdb-plan-reviewer` pass. Every code-level claim below was checked against
`main`. **Status stays `Questions`.** The investigation is honest and unusually
well-grounded; what blocks `Investigated` is that two of the five questions are
real maintainer calls (Q-C, Q-E), two need ratification of a recommendation
(Q-A, Q-B), and Phase 4 — the deliverable the plan calls "the point" — is still
specified aspirationally, not mechanically.

### 1. The "one root cause" thesis is half-true — keep the bundle, drop the overstatement

You asked me to stress-test the framing. Verdict: **the two defects rhyme but do
not share a fix.** They are two independent bugs in the index/query path:

- **SC-15** is a pure query-planner-logic bug, one line in
  `field_filter.dart:175` (`equalityPredicate` ignores `caseSensitive`, a field
  three lines above — confirmed).
- **SC-10** is a pure state-placement bug in the storage/namespace layer (index
  state in synced `$meta`), plus the `$meta` audit. **Phase 1 and Phase 2 touch
  entirely disjoint files.**

The *only* genuinely shared artefact is the Phase 4 equivalence-test philosophy
(index-path rows == full-scan-path rows), and even there the two tests differ
(single-device case-folding vs cross-device sync). So the honest statement is:
*two defects in one subsystem that share a test strategy and a release deadline*
— not "one root cause twice." **Recommendation: keep them in one plan** (small,
same subsystem, both pre-freeze, one unifying test deliverable), but rewrite the
problem statement to stop selling a shared *fix* that does not exist, and tell
the implementer Phase 1 and Phase 2 are independent and can be done in either
order. Splitting is not warranted; over-claiming the unity is what would mislead.

### 2. Q-A (narrow fix vs capability contract) — you are over-engineering the one-liner, *given Phase 4*

The landmine is real: the defect is "planner assumes `eq` ⇒ exact-token lookup
is a complete answer," and any future non-exact matcher reintroduces it. But the
capability contract is not what kills the class — **the Phase 4 equivalence
matrix is.** A property test asserting index-path == full-scan-path over every
filter type × both case flags catches *any* future matcher that reintroduces the
shape, one-liner or contract. With that test mandatory, the contract is
speculative scope for a reality where **only one predicate type is index-eligible
today** (`_op == _Op.eq`; verified — only `_FieldFilter` overrides
`equalityPredicate`, and only `eq` returns non-null) and case-insensitivity is
the *only* non-exact variant that even exists as a flag. Adding capabilities is
an explicit non-goal.

**Recommendation:** narrow fix (`_op == _Op.eq && caseSensitive`) **plus** a
strengthened contract in the `Filter.equalityPredicate` doc comment
(`filter.dart:46`) — state the invariant explicitly: *"Return non-null only when
an exact-token index lookup is a **complete** answer to this predicate. A
predicate that needs any transform the index did not apply at write time (case
folding, accent stripping, normalisation) MUST return null."* — **plus** Phase 4
as the enforcement. That kills the class without a new subsystem. The contract
remains a defensible scope call, so this stays a recorded decision, but I am
steering hard against building it now.

### 3. Q-C and Q-D (`gen:{ns}` and tombstone floor) — verified against code

Both classifications were checked in `meta_store.dart` and §12. See the Q-D
checkbox above (**resolved: device-local, wrong today** — the code's own doc
comment and §12:203 both say "per-device," and LWW can *lower* the floor →
resurrection; your suspicion that it is "correctly replicated" is contradicted by
the code). **Verify this with a test, not by reasoning** — a two-device harness
case where device A's floor write with a later HLC overwrites device B's higher
floor, then B ingests an SSTable it should have rejected.

**Q-C stays genuinely open**, and it is the *right* question, but add the hazard
that settles half of it: `gen:{ns}` under `$meta` LWW can move **backwards**
(device B at gen 50 pulls A's gen 10 written at a later HLC → B's staleness
check reads "cached gen 50 ≥ current 10" = not-stale, and serves stale cache).
So "leave it replicated" is not free — it needs max-merge semantics `$meta` does
not provide. The decision is really *device-local, or replicated-with-max-merge*;
plain-replicated is a third, wrong, option that the current code accidentally
picks. This interacts with the SC-10 fix: if index state goes device-local
(Phase 2) but `gen` stays as-is, `builtThrough` (now device-local, absent on a
fresh device) mismatches the synced `gen` → rebuild → self-corrects. So the
SC-10 fix works regardless of Q-C, but Q-C must still be decided for cache
correctness.

### 4. Q-B (where index state moves) — options complete; recommend option 1, reject option 2

Your three options are complete and none is missing. But **option 2 (per-device
key within `$meta`) recreates the problem** and should be rejected, not left as a
live choice: even keyed per-device, it still uploads device-local state to the
cloud and bloats every peer's `$meta` — the exact "device-local state in a synced
namespace" pattern this WI exists to kill. Note the **precedent already set in
this track**: the SC-3 decision (roadmap, 2026-07-20) ruled that a materialised
view cache would go in `$$cache`, **not** `$cache`, for precisely this reason.
Option 1 (`$$`-prefixed namespace, guaranteed-local via `.local.sst`) is
consistent with that ruling and with `$$fts:`/`$$vec:`/`$$index:`. **Recommend
option 1.** Option 3 (split `$meta`) is real but heavy and out of scope for a WI
that must land before the freeze. Until Q-B is ratified, **Phase 2 cannot be
mechanical** — there is no named target namespace/key for the implementer.

### 5. Phase 2/3 boundary — is SC-5 (device identity) *fixed* here or only *classified*?

This is an implementation-readiness gap. Phase 3 says "fix any further instances
found," and the table lists device identity as wrong. But `device_id` is
load-bearing for sync in a way index state is not — it names SSTable files and
is the sync identity — so moving it is a materially larger and riskier change
than moving index state. **Decide explicitly:** does this plan *fix* SC-5, or
only *classify* it and hand the fix to a separate WI? The roadmap has no separate
WI for SC-5, so if this plan does not fix it, someone must create one. My
recommendation: **classify SC-5 here, fix it separately** — do not fold a
device-identity migration into a query-planner plan. The tombstone floor (Q-D),
by contrast, *is* a mechanical `$meta`→`$$` move and belongs in this plan's
Phase 3.

### 6. `requireFreshIndex()` is mischaracterised — it does NOT mitigate SC-10

The Investigation edge-cases and roadmap SC-20 both call `requireFreshIndex()`
"the caller-side mitigation for SC-10." **It is not.** Traced
`_checkIndexFreshness` (`kmdb_query.dart:526`): on device B the inherited state
reads `current` and the synced `gen` matches the synced `builtThrough`, so
`getOrActivate` returns `current` and the freshness check **never throws** — the
query still returns 0 rows. `requireFreshIndex` only guards the single-device
`building`/`stale` race. Correct this in the plan (and flag it for the SC-20 spec
work) so the implementer does not treat it as a safety net that exists.

### 7. The §16 trap warning — correct, but move it into Phase 2

Your instinct is right and the warning content is accurate (`isLocalOnly` matches
`$$` **only** — verified; there is no `$`-filter to add; adding one breaks
`$meta`/`$ver`/`$vault` upload). But it currently lives only in the Investigation
"Edge cases" list. A Sonnet implementer working Phase 2 is editing namespace/sync
code and may never re-read Investigation. **Elevate it to an explicit `DO NOT`
step inside the Phase 2 checklist**, naming the symbol: *"Do not add a `$`-prefix
upload filter. `isLocalOnly` (namespace_codec.dart) matches `$$` only, by design;
`$meta`/`$ver`/`$vault` are single-`$` and MUST upload (§12:455). The fix is to
move index state to a `$$` namespace, never to filter `$`."* As placed today it
is not prominent enough for the phase where the mistake happens.

### 8. Phase 4 is still aspirational — this is the readiness blocker for the *test* deliverable

You flagged this risk yourself; it is real. Phase 4 states the property but not
the cells that make it bite. Concretely, it must specify:

- **The failing cell that proves the single-device test.** Only
  `caseSensitive:false` `eq` over mixed-case data (`Field('city').equals('london',
  caseSensitive: false)` against a doc with `city: 'London'`) fails today; every
  other operator already agrees index vs full-scan (because only `eq` is
  index-eligible, so all others full-scan in *both* arms and prove nothing). A
  matrix of exact-case operators would pass against current code and **falsely
  read as green.** The plan must require the case-insensitive-eq cell explicitly,
  or the "must fail before the fix" gate is untestable.
- **Named test files.** e.g. `test/query/index_full_scan_equivalence_test.dart`
  (single-device) and a `kmdb_harness` case for cross-device — the cross-device
  arm needs two `KvStore` instances over a shared sync folder (device A writes +
  builds index + pushes; B pulls; B queries with the index *declared*), and it
  will need the harness, which ties directly to Q-E.
- **The exact assertion**, not a paraphrase: same row set (by `_id`) from
  `query(F)` with and without the index declared, for each matrix cell.

Until these are pinned, Phase 4 is intent, not a spec — the same shortfall the
last plan's first test-phase draft had.

### 9. No-migration / backward-compat check (as requested)

The plan is clean on no-migration and does not smuggle a compat assumption — good.
One precision: the edge case "old database with index state still in `$meta`"
reads as a migration worry, but under no-migration the real (and benign) vector
is that old `index:*` entries in `$meta` — on disk or already in the sync folder
— become **dead** entries the new code never reads. The correctness check is
simply: the new code reads index state *only* from the new location, so the old
key is orphaned and ignored. Reframe from "must not resurrect" (implies active
defence) to "confirm the new read path never consults the old key" (a one-line
grep-able invariant). No hidden compat assumption remains once Q-B names the new
location.

### What would move this to `Investigated`

1. Ratify **Q-A** (recommend: narrow fix + doc-comment contract on
   `equalityPredicate` + Phase 4 enforcement; do not build the capability
   contract).
2. Ratify **Q-B** (recommend: option 1, `$$`-prefixed namespace) — this unblocks
   a mechanical Phase 2.
3. Decide **Q-C** (device-local, or replicated-with-max-merge; plain-replicated
   is wrong).
4. Accept the **Q-D** reclassification (device-local, folded into Phase 3).
5. Decide **Q-E** (matrix shape + whether cross-device runs by default or under
   `e2e`).
6. Resolve the **Phase 2/3 / SC-5 scope** question (§5 above).
7. Rewrite **Phase 4** with the failing cell, named files, and the exact
   assertion (§8 above).
8. Correct the **`requireFreshIndex`** claim (§6) and **move the §16 trap into
   Phase 2** (§7).

Items 3 and 5 are genuine maintainer calls. The rest I have either resolved or
given a recommendation strong enough to ratify in one pass.

## Confirmation pass (2026-07-21)

`kmdb-plan-reviewer` second pass, verifying the maintainer's reconciliation
against the six conditions from the previous review's "What would move this to
`Investigated`" list. Every code claim below was re-checked against `main`.

**Verdict: one blocker remains. Status stays `Questions`.** The reconciliation is
otherwise faithful and the plan is close.

### Confirmed ✓

- [x] **Q-A** — Phase 1 says exactly the ratified thing: gate on
      `_op == _Op.eq && caseSensitive`, strengthen the `Filter.equalityPredicate`
      doc-comment into an explicit contract, Phase 4 as enforcement, and an
      explicit "Do **not** build a capability contract." The contract is not left
      as a live option. Anchor verified: `equalityPredicate` is
      `_op == _Op.eq ? (_path, _operand) : null` at field_filter.dart:175, with
      `caseSensitive` on the same class at :172.
- [x] **Q-C** — split to WI-13 is sound, and I re-verified the load-bearing claim
      myself: the local write path bumps `gen` (`_appendMetaWrites` →
      `appendGenerationCounterBump`, kv_store_impl.dart:599), while `ingestSstable`
      (kv_store_impl.dart:306) never touches `_meta`. So a pull-only device does
      rely on the peer's replicated `gen` for cache invalidation today — making it
      device-local without also teaching the ingest path to bump it would break
      that. Nothing in Phase 2 or Phase 4 depends on `gen`: Phase 2's rebuild
      trigger keys on device-local `builtThrough` (index_manager.dart:86), which
      is absent on a fresh device and mismatches regardless of `gen`.
- [x] **Q-D** — tombstone floor is classified device-local/wrong-today and folded
      into Phase 3 as a mechanical `$meta`→`$$` move, with the Phase 4 regression
      test for the LWW-lowers-the-floor hazard (checklist item 4 under Phase 4).
- [x] **Q-E** — Phase 4 is now concrete: named file
      `test/query/index_full_scan_equivalence_test.dart`, sampled
      filter × operator × case-flag matrix, the mandatory `caseSensitive:false`
      `eq` cell spelled out with the exact failing example, compare-by-`_id`
      assertion, cross-device arm under `kmdb_harness`/`e2e`, and the
      must-fail-first gate. Executable without further design decisions.
- [x] **SC-5 scope** — device identity is classified-only and split to WI-12 in
      both the Phase 3 table and the roadmap. Rationale (`device_id` names SSTable
      files) is recorded. Not folded into this plan.
- [x] **`requireFreshIndex()` correction** — Investigation edge-cases now state
      plainly it does NOT mitigate SC-10, with the traced reason
      (kmdb_query.dart:528 throws only on `status != current`, and device B
      inherits `current`), and flag the mischaracterisation for WI-2.
- [x] **"One root cause" dropped** — the problem statement, the Investigation
      "shared shape (not a shared fix)" table, and the "either order" notes on
      Phases 1 and 2 now frame SC-10/SC-15 as a shared *shape/test-strategy*, not a
      shared fix. Consistent with the roadmap.
- [x] **§16 trap elevated** — Phase 2's first checklist item is now an explicit
      `DO NOT` step naming `isLocalOnly` (namespace_codec.dart:148, verified to
      match `$$` only) and explaining why a `$`-filter would break sync.
- [x] **Roadmap agreement** — WI-11 row, WI-12/WI-13 spin-outs, the `$meta`
      classification table, the exit-criteria entries, and the "share a shape, not
      a fix" prose all match the plan.

### Blocker (condition #2) — RESOLVED 2026-07-21

The maintainer pinned the concrete `$$indexstate` target (namespace, key
`XXH64(index:{ns}:{path})` via the existing `MetaStore.indexKey` static, value the
unchanged CBOR `IndexState`, routing off the three `MetaStore.*RawByName` sites),
and I re-verified it: `$$indexstate` returns `isLocalOnly` = true
(namespace_codec.dart:148), and it does **not** collide with `removeIndex`'s
per-index prefix scan, which matches `$$index:{ns}:{path}:`
(index_manager.dart:268 — `${def.indexNamespace}:`), a strict `$$index:` prefix
that `$$indexstate` cannot match. Phase 2 is now mechanical for **secondary
indexes**. That closes condition #2.

## Second confirmation pass (2026-07-21)

Pinning the concrete routing let me evaluate two things the earlier vagueness hid.
One is serious. **Status stays `Questions`.**

### 🔴 Blocker 1 — FTS and Vec index state have the identical SC-10 defect and are unaddressed

This is the same bug the WI exists to kill, in two sibling subsystems, and the
plan neither fixes nor classifies it.

- `FtsIndexState` persists its status — including `current` — to **`$meta`** under
  the symbolic name `fts:{ns}:{field}`, via `getRawByName`/`putRawByName`
  (fts_manager.dart:1426, 1438; key `FtsIndexState.metaKey`,
  fts_index_state.dart:252; `FtsIndexStatus` has `current`,
  fts_index_state.dart:31–41). The actual index data is in the local-only `$$fts:`
  namespaces. So a read-mostly second device pulls `$meta`, inherits
  `fts status: current` for an index it never built, and its `search()` scans
  empty `$$fts:` — **silently zero results**. Identical shape, identical 🔴
  impact, one layer over in lexical search.
- `VecIndexState` does the same (vec_manager.dart:800, 812) for semantic search.

Phase 2 moves **only** `IndexManager`'s three sites (298/536/551). The plan must
decide, explicitly, one of:
  - **(a) Fold FTS/Vec state into Phase 2** — move `fts:{ns}:{field}` and the vec
    state key to `$$`-local too (adds the fts_manager/vec_manager call sites), and
    extend the Phase 4 cross-device equivalence test to cover a `search()` on a
    pull-only device; or
  - **(b) Scope WI-11 to secondary indexes and split FTS/Vec** to a named
    follow-up WI — exactly as SC-5→WI-12 and `gen`→WI-13 were handled — but then
    the Phase 3 audit MUST classify them and the roadmap MUST carry the spin-out.

Silently leaving them unaddressed is not an option: it ships a known-shaped 🔴 for
lexical and semantic search on second devices.

### 🟠 Blocker 2 — Phase 3 audit does not meet Goal 3 ("classify *every* `$meta` entry")

The transferable lesson of SC-10 (roadmap) is that *nobody did the full `$meta`
audit*. The Phase 3 table classifies 5 entries but omits at least: **FTS state**
(`fts:{ns}:{field}`), **Vec state**, **schema state** (`schema:{collection}` +
the schema registry, schema_manager.dart:132/152/198/234), **version config**
(version_manager.dart:73/94), the **dirty flag**, the **namespaces registry**, and
the **format-version marker** — all real `$meta` residents (grep
`_nameToKey(`/`putRawByName` in `meta_store.dart` and its callers). Some are
correctly replicated (schema admission gate, version retention policy, `enc:blob`,
namespaces registry); the point is the audit must *say so per entry*, or Goal 3 is
asserted-but-unmet and the next reader assumes it was done. Complete the table:
every `$meta` entry → device-local vs replicated → disposition (fix here /
follow-up WI / correct-as-is).

### 🟡 Blocker 3 — encryption treatment of the moved state is unspecified

`getRawByName`/`putRawByName` wrap/unwrap the value with `EncryptionEnvelope`
(meta_store.dart:476, 484), so today index state is **ciphertext** on an encrypted
database. Phase 2's "direct `_store` reads/writes … value the existing CBOR
`IndexState`, `_encodeState`/`_decodeState` unchanged" stores **plaintext** CBOR in
`$$indexstate`, silently dropping the wrap that the 0.08 `$meta`-encryption
reconciliation deliberately added. Because `.local.sst` never uploads, this is
plausibly the *right* call (the passive-provider threat model in §31 is fully met,
and it is consistent with sibling `$$`-local data) — but it is a decision with
confidentiality implications, and two implementers could diverge (one preserves the
wrap to avoid a behavioural change). Phase 2 must state the decision and its
rationale in one line, and — if Blocker 1(a) is chosen — apply the same decision to
FTS/Vec state. This is a clarification, not a redesign.

### Everything from the first confirmation pass still holds

Q-A, Q-C, Q-D, Q-E, SC-5 scope, the `requireFreshIndex()` correction, the "one root
cause" reframing, the §16-trap elevation, the roadmap agreement, and now the
concrete `$$indexstate` target are all confirmed. The three items above are what
remain. Blocker 1 is material (a shipped 🔴); Blockers 2 and 3 are completeness and
clarification. None is a maintainer-judgment fork requiring new investigation — they
are scope + wording calls the maintainer can close in one pass, after which I can
flip to `Investigated`.

## Third confirmation pass (2026-07-21) — `Investigated`

All three second-pass blockers are resolved and re-verified against `main`. **Status
→ `Investigated`.**

- [x] **Blocker 1 (🔴 FTS/Vec) — folded into Phase 2, verified.** Phase 2's move
      table (secondary/FTS/Vec) is mechanical across all three subsystems.
      Confirmed against code: `VecIndexState.metaKey` = `vec:{ns}:{field}`
      (vec_index_state.dart:223), persisted at vec_manager.dart:800/812;
      `FtsIndexState.metaKey` = `fts:{ns}:{field}` (fts_index_state.dart:252),
      persisted at fts_manager.dart:1426/1438; both statuses include `current`
      (FtsIndexStatus fts_index_state.dart:31–41); data lives in `$$fts:`/`$$vec:`.
      The new `$$ftsstate`/`$$vecstate`/`$$indexstate` namespaces each satisfy
      `isLocalOnly` and cannot collide with the colon-bearing `$$fts:`/`$$vec:`/
      `$$index:` data prefixes. Neither FTS nor Vec has a state-delete site (no
      `deleteRawByName` in either manager), so the table's "(+ any delete site)" is
      a safe grep-and-find-none. Phase 4 adds the `search()` cross-device regression
      gate. The fold (not split) is the right call: unlike SC-5's `device_id`, FTS/Vec
      state is no riskier to move than secondary-index state, and splitting would
      leave a live 🔴 in `search()`.
- [x] **Blocker 2 (🟠 audit) — Phase 3 table completed to Goal 3.** All twelve
      `$meta` families are now listed (three index states, tombstone floor, device
      identity→WI-12, `gen`→WI-13, `enc:blob`, schema, version config, namespaces
      registry, format-version, dirty flag), each with a classification and
      disposition, plus a grep-the-key-constructors instruction to confirm
      completeness. The dirty-open flag is correctly flagged **"Verify — possible
      further instance … file separately if so,"** and the phase explicitly forbids
      folding newly-found scope into this WI — the right handling.
- [x] **Blocker 3 (🟡 encryption) — specified and mechanically feasible.** Phase 2
      now requires preserving `EncryptionEnvelope.wrap`/`unwrap` (meta_store.dart:476/
      484) on the direct-write path, so the move keeps index/FTS/Vec state ciphertext
      at rest and does not reverse the 0.08 `$meta`-encryption work. Verified this is
      mechanical: `MetaStore.encryption` is a public field (meta_store.dart:78) and
      `FtsManager` already calls `EncryptionEnvelope.wrap(…, _encryption)` (e.g.
      fts_manager.dart:967, 1211, 1292); `IndexManager` reaches the provider via
      `_store.meta.encryption`.

**Readiness verdict.** An implementer can execute Phases 1–5 with no significant
design decision left: the predicate gate and doc contract (Phase 1) are one-liners
against named symbols; the three-subsystem state move (Phase 2) has concrete
namespaces, keys, persist sites, routing, and encryption handling; the `$meta` audit
(Phase 3) is a complete, checkable inventory; the equivalence tests (Phase 4) name
the file, the mandatory failing cell, the assertion, and the `query()` + `search()`
cross-device arms with a must-fail-first gate. The remaining `builtThrough`-
equivalent confirmations for FTS/Vec are verification steps, not design forks. The
plan and `docs/roadmap/0_10_01.md` agree on the three-subsystem scope. Handing off
to **`kmdb-plan-implement`**.

## Summary

_To be completed when the work is done._
