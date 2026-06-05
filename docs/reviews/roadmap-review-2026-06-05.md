# KMDB Roadmap Review — 2026-06-05

**Reviewer:** Claude (Sonnet 4.6, initial draft; Opus fact-check pass
2026-06-05)

**Scope:**

- `docs/roadmap/0_05.md`,
- `docs/roadmap/0_06.md`,
- `docs/roadmap/0_07.md`,
- `docs/roadmap/9_99.md`,
- active plans in `docs/plans/`,
- and proposals in `docs/proposals/`.

**Focus:** Dependency and sequencing soundness, gap analysis, hidden complexity,
candidates for deferral, and the minimum path to a beta release.

**Context note:** KMDB has no existing users at this time. This is a greenfield
project. Concerns around data migration, backward-compatible on-disk formats,
and upgrade paths from earlier releases do not apply. Format decisions can be
made for correctness and simplicity rather than compatibility.

---

## 1. What was reviewed

- **Roadmap files:** `0_05.md` (v0.05 — multi-platform pipelines), `0_06.md`
  (v0.06 — vault search and multilingual), `0_07.md` (v0.07 — encryption),
  `9_99.md` (deferred / never-never items).
- **Active plans:** `plan_configurable_embedding_model.md` (status
  `Investigated`), `plan_simple_api.md` (status `Open`, stub only),
  `plan_vault_export.md` (status `Open`, stub only).
- **Proposals:** `proposals/encryption.md`, `proposals/vault_search.md`,
  `docs/proposals/range_predicate_index_scans.md` (deferred, referenced).
- **CLAUDE.md implementation status table** — used to establish what is complete
  on `main` as of today.

The review took the roadmap at face value as planning intent, not specification.
It does not assess implementation correctness (that is the `kmdb-qa` and
`kmdb-pre-commit` remit); it assesses whether the _sequence and scope_ of the
planned work is coherent.

---

## 2. Dependency and sequencing analysis

### 2.1 v0.05 — Multi-platform pipelines

v0.05 is a pure infrastructure release: cross-platform CI pipelines and binary
distribution for `betto_zstd` and `kmdb_inferencing`. It has no functional
dependencies on unfinished library features.

**Sequencing concern — v0.05 is a prerequisite for everything else, but is not
yet done.** All subsequent releases depend on being able to ship and test on
target platforms. The binary distribution work (ONNX on iOS/Android, Zstd WASM
on web, Windows and Linux native builds) must land _before_ any feature that
touches the affected packages can be considered production-ready. The roadmap
currently implies v0.05 and v0.06 could run concurrently; that is risky.

The `plan_configurable_embedding_model.md` plan (presently `Investigated`,
targeting semantic search infrastructure) depends on `kmdb_inferencing` being
deliverable on mobile platforms — i.e. on v0.05 work landing first. An
implementer who ships model download-on-demand before iOS/Android ORT bundling
is in place will not be able to test or ship the feature on those platforms.

**Verdict:** v0.05 should be treated as a hard predecessor to any feature work
that involves `kmdb_inferencing` (semantic search, embedding model
configurability) or Zstd WASM (web compression parity). The ordering in the
roadmap filenames correctly reflects this, but it should be made explicit in the
plans.

### 2.2 v0.06 — Vault file search and multilingual

v0.06 depends on:

1. **v0.05 complete** — the vault search indexing isolate requires ONNX on all
   target platforms.
2. **`plan_configurable_embedding_model` shipped** — vault search uses the same
   embedding model pipeline and will need the
   `ModelSpec`/`ModelCatalog`/download infrastructure. Building vault search
   before model configurability lands means hard-coding a model path in the
   vault indexer, then re-plumbing it when configurable models arrive. The
   roadmap places these in separate releases (v0.05-era plan vs. v0.06 feature)
   without acknowledging the dependency.
3. **Model identity work complete** (`VecIndexState.modelId`, `VecManager`
   stale-on-mismatch) — vault search stores vectors keyed by model name in
   `vectors_{model}_sq8.bin` filenames. Without model identity tracking, a model
   swap cannot trigger a vault re-index. This is already a prerequisite for
   BGE-M3 in the multilingual §10.3 of the vault search proposal.

The roadmap also notes (in `0_06.md` §"Model identity and index invalidation")
that model identity is a **prerequisite for any model migration**. Yet the same
release plans to introduce BGE-M3. The implication is clear: model identity
tracking must land in the same release _at the latest_, and ideally before any
BGE-M3 work begins.

**Correction (phantom `0_08.md`):** `plan_configurable_embedding_model.md`
references a `docs/roadmap/0_08.md` file in multiple places (lines 17, 196, 396)
and defers BGE-M3 to "v0.08." That file does not exist and the version number is
phantom — BGE-M3 and multilingual work belong to `v0.06` per the actual roadmap.
The plan's stale `0_08.md` references should be corrected to point to `0_06.md`.
The practical effect is that BGE-M3 is a _v0.06_ deliverable, not an unscheduled
future item, and the model identity infrastructure being built in the
configurable model plan is a v0.06 prerequisite rather than something that only
pays off in a later release.

**Verdict:** v0.06 has at least three hard predecessors (v0.05, configurable
embedding model plan, model identity) that are currently presented as parallel
tracks. The sequencing should be made explicit.

### 2.3 v0.07 — Encryption

Encryption (`proposals/encryption.md`) is an opt-in, value-pipeline feature. Its
only library-level dependencies are `package:cryptography` (no native FFI, works
on all platforms including web) and `flutter_secure_storage` (DEK caching).
Neither depends on v0.05 binary infrastructure.

However, the encryption proposal identifies a v1 non-goal that creates a
sequencing risk: **no in-place migration** of existing plaintext databases. This
means encryption is set at database-creation time only. If a significant number
of users have existing databases by the time v0.07 ships, they cannot migrate
without a `kmdb encrypt` command (deferred to future work). This is acceptable
as a deliberate trade-off — but the window to ship encryption _before_ the user
base grows makes it a strong candidate for earlier placement (see §5).

The encryption proposal is well-aligned with v0.07; no dependency concerns
beyond the 10 open questions that must be resolved before planning begins (see
§4.3).

### 2.4 Cross-cutting: range-predicate index scans

`docs/proposals/range_predicate_index_scans.md` is correctly placed as a
deferred proposal with status **Deferred**. The associated
`docs/roadmap/0_04.md` was deliberately deleted — its contents were folded into
`9_99.md` — and the proposal itself documents explicit **trigger conditions**
for when to revisit (a scale trigger if full-scan latency breaches §18 targets,
or an engine trigger if variable-length user keys are needed for another
reason). No milestone assignment is needed; the proposal's trigger conditions
are the milestone.

One housekeeping item: the proposal's header still carries
`Related roadmap: v0.04 (docs/roadmap/0_04.md)` — a dangling reference to the
deleted file. This should be updated to either remove the reference or point to
`9_99.md` where the deferred item now lives.

---

## 3. Gap analysis

### 3.1 No CI/CD plan exists in the repository

v0.05 extensively specifies the _requirements_ for multi-platform CI (GitHub
Actions pipeline, signing, binary provenance) but there is no corresponding plan
file driving that work. Without a plan, the `kmdb-plan-implement` agent cannot
be engaged, reviewers cannot track status, and the work is at risk of being done
ad-hoc without the architectural review and test coverage the rest of the
codebase requires.

**Recommendation:** Convert the v0.05 roadmap content into one or more plan
files under `docs/plans/` covering: (a) binary build infrastructure for
`betto_zstd` (Linux/Windows/Android) and `kmdb_inferencing` (iOS/Android); (b)
CI pipeline for release artifact signing; (c) WASM Zstd build and frame
compatibility verification.

### 3.2 `plan_simple_api.md` and `plan_vault_export.md` are stubs

Both plans have `Open` status and contain only placeholder text. Neither has a
problem statement that is actionable. They occupy space in `docs/plans/` without
providing useful signal. If these are genuine near-term priorities they need
investigation. If they are distant ideas they belong in the roadmap, not in
`docs/plans/`.

`plan_vault_export.md` is the more concrete of the two (a single CLI command
with specified `--output` semantics and a known bug to fix). It could plausibly
be driven to `Investigated` quickly.

`plan_simple_api.md` is strategically important (developer experience is a
distribution lever) but the problem statement is not yet specific enough to
plan. Consider sketching a target API surface before filing it as a plan.

### 3.3 No plan for iOS ORT integration

v0.05 describes the iOS ONNX Runtime requirement in detail (CocoaPods or Swift
Package Manager, no `onnxruntime-mobile`, opt-in semantic search). The roadmap
notes that `ort_library.dart` currently throws `UnsupportedError` on iOS and
needs an iOS branch. This is a concrete, in-scope gap — but there is no plan
driving the work and it is not referenced from the configurable embedding model
plan (which explicitly marks iOS ORT as out of scope).

The two plans need explicit coordination: the configurable model plan defers iOS
ORT, and someone must own it.

### 3.4 Web Zstd compatibility verification is untracked

The v0.05 roadmap specifies a critical correctness gating requirement: a
WebAssembly Zstd build must produce frames byte-compatible with native
`betto_zstd` (so web-written SSTables decompress on native clients and vice
versa). The `zstandard` pub.dev package is identified as a candidate but must be
verified _before_ adoption. This verification is not tracked anywhere — no plan,
no checklist item, no release-checklist entry in
`docs/spec/28_release_checklist.md`.

More fundamentally, WASM **decompression** support is required for web clients
to participate in a mixed sync pool at all: native devices write Zstd-compressed
values (each with a 1-byte compression flag); a web client with no decompressor
cannot read those values and will silently fail to decode native-written
documents. This is not a write-side parity concern — it is a basic read
correctness requirement. WASM decompression must land in v0.05 regardless of
whether write-side compression is accepted or deferred.

The frame-compatibility verification governs whether web _writes_ can be read
back by native clients. If it fails (incompatible frames), write-side
compression must be deferred — but decompression support remains required. This
is a separate go/no-go gate, not a fallback that removes the decompression
obligation.

### 3.5 Encryption has ten unresolved open questions

The encryption proposal (`proposals/encryption.md` §11) lists ten open
questions, several of which are non-trivial design decisions that must be
resolved in a plan before implementation begins:

- **Q1 (vault nonce determinism — high priority):** random nonces mean two
  devices encrypting the same blob upload two different ciphertext files. The
  proposal evaluates `HKDF(DEK, sha256)` as a deterministic alternative. This is
  a security-relevant decision that must be made by a cryptographer or carefully
  reasoned, not deferred.
- **Q4 (`PlatformIdStore` interface alignment):** the v0.07 roadmap mentions a
  `PlatformIdStore` abstraction backed by `$meta`. If this abstraction is
  planned alongside encryption, it is a co-design requirement. If independent,
  it should be stated so. Currently ambiguous.
- **Q6 (flag byte position):** whether the encryption flag extends the existing
  §5 flag byte or adds a second byte is a storage-format decision with backward
  compatibility implications. It must be resolved before any bytes are written.
- **Q10 (`$meta` bootstrap sequence):** reading the wrapped DEK requires opening
  the store, but opening the store may require decrypting values. The exact
  bootstrap sequence (read unencrypted `$meta` to get the DEK, then proceed)
  must be specified precisely or the implementation will contain a subtle
  ordering bug.

None of these are showstoppers — each has a clear preferred answer — but they
must all be answered and recorded in a plan before `kmdb-plan-implement` can be
engaged.

### 3.6 Vault search proposal has seven open questions

The vault search proposal (`proposals/vault_search.md` §8) similarly carries
seven open questions. The most consequential:

- **Q1 (unified vs. separate search API):** the choice between extending
  `KmdbCollection.search()` and providing a separate `searchVault()` method
  affects the public API surface, which is much harder to change after the first
  release. This decision should be made before the plan is written, not
  deferred.
- **Q3 (re-index trigger API):** `db.reindexVault()` vs. CLI `vault reindex`.
  The configurable embedding model plan adds `KmdbDatabase.reindex()` for the
  document vec path. The vault re-index API should be designed to be consistent
  with (or unified with) that surface.

### 3.7 `9_99.md` items have no assigned milestones

The never-never list contains: JSONPath filter expressions, JSONPath recursive
descent, cross-collection references, and Google Cloud Storage adapter. None of
these have dependencies on current work, but the GCS adapter in particular is a
reasonable v0.08–v0.09 candidate (once multi-platform binary infrastructure is
stable and there is a third cloud adapter to validate the adapter interface).
Assigning rough milestones prevents these from silently blocking a beta
readiness assessment.

### 3.8 `betto_*` `git:` refs are a hard pub.dev publishing blocker

All five external Bettongia dependencies (`betto_common`, `betto_schema`,
`betto_zstd`, `betto_registry`, `betto_builder_tools`) are pulled in via
`dependency_overrides` using `git:` refs in the workspace `pubspec.yaml`.
pub.dev **does not permit publishing packages with `dependency_overrides` that
use `git:` refs** — this is a hard publishing gate, not a policy question.

For a beta or any pub.dev release, these packages must either be published to
pub.dev themselves (with a versioned ref) or vendored directly into the
workspace. No current roadmap stage owns this work. It should be added as an
explicit item in whatever release-readiness stage is defined (see §6.4).

---

## 4. Hidden complexity callouts

### 4.1 The vault search isolate is a significant new runtime pattern

The vault file search proposal introduces a **persistent background `Isolate`**
for extraction and embedding. KMDB currently has no background isolates — all
storage engine operations are synchronous on the calling isolate (see CLAUDE.md
architecture notes, §"Compaction: synchronous on the write path"). Introducing
an isolate adds:

- IPC boundary between the isolate and the main store (SendPort/ReceivePort or
  `Isolate.spawn` argument passing).
- Crash recovery for an isolate killed mid-indexing (the proposal covers this
  with a `pending → extracting → indexed` state machine and startup reset, which
  is the right design — but the implementation will be non-trivial).
- The isolate must share access to the same filesystem paths as the main
  `KvStore`. Since all `KvStore` operations are synchronous and single-threaded
  by design, the isolate cannot write to the LSM directly via the store API. The
  proposal handles this by having the isolate write filesystem artifacts
  directly and then fire a `WriteBatch` back to the main isolate — but this
  introduces a race window: if the process crashes between the filesystem writes
  and the `WriteBatch`, the scan index will be out of sync with the vault
  filesystem. The startup recovery path must detect and repair this.

This is not a reason to abandon the proposal — it is the right architecture. But
it is substantially more complex than the current synchronous storage model and
should be scoped and planned with the extra complexity in mind. The plan review
for vault search should specifically exercise the crash scenarios.

### 4.2 Encryption bootstrap sequence requires careful ordering

Open question 10 in the encryption proposal notes that the wrapped DEK is stored
in `$meta`, but reading `$meta` requires opening the database. The proposal
suggests reading unencrypted `$meta` first to get the wrapped DEK, then
proceeding with decryption. This is correct in concept, but:

- It means `$meta` values must be written **without encryption** even when
  encryption is enabled (or encryption of `$meta` must be keyed differently from
  document values — which re-introduces the bootstrapping problem).
- The existing `$meta` namespace is also used by `MetaStore` for device ID,
  generation counters, HWM data, and (after the configurable model plan) model
  identity. If some of these are sensitive and the user has opted into
  encryption for cloud confidentiality, leaving `$meta` plaintext is an
  information leak.

The proposal acknowledges this partially ("wrapped DEK syncs normally" in §10)
but does not specify the precise boot sequence or flag `$meta` as a special
namespace. The plan must.

### 4.3 Model migration + vault search + encryption is a three-way interaction

These three features interact at the vector index level:

1. A model upgrade (v0.06+) marks `$vec:` indexes stale and triggers rebuild.
2. Vault search stores vectors in `$vvec:idx` and per-blob files; a model
   upgrade must also invalidate these.
3. If encryption is enabled (v0.07), the vault blob bytes are ciphertext. The
   vault indexing isolate must have access to the DEK to extract text from
   encrypted blobs for BM25 indexing, and to embed text for vector generation.

The three features can be implemented sequentially — in fact they must be, given
the dependencies above — but each plan must anticipate the next one and leave
the right extension points. The vault search plan in particular must be written
with encryption in mind even though encryption has not yet landed.

### 4.4 Windows binary distribution is a known blocker

The v0.05 roadmap notes that Windows Authenticode signing in CI requires an OV
certificate and flags EV certificates as a potential blocker (hardware-bound,
impractical in CI without a cloud HSM signing service). This is an external
dependency with a non-trivial procurement lead time. If KMDB has Windows as a
target platform, this should be resolved or explicitly accepted as a gap
_before_ claiming v0.05 complete.

---

## 5. Defer candidates

The following items from the roadmap are candidates for explicit deferral to
post-v1, either because they are not required for a functional v1 release or
because they carry disproportionate risk relative to benefit at this stage.

### 5.1 Web Zstd compression (v0.05)

Web compression parity is desirable but not required for a functional v1. The
existing design (web stores uncompressed SSTables) is correct and data-safe.
Real Zstd WASM compression adds: a new native-asset-like web build pipeline,
frame compatibility verification requirements, and a `dart:js_interop` FFI
surface. If the `zstandard` pub.dev package is not confirmed compatible, the
fallback is no-op compression — which is already the deployed behaviour.

**Revised assessment:** This item is only partially deferrable. WASM
decompression (read path) is required for sync compatibility with native
platforms and must land in v0.05 — see §3.4. Write-side compression (web
producing compressed values) is genuinely deferrable and can be accepted as a
v0.x enhancement. The original recommendation to defer the entire feature was
incorrect.

### 5.2 Multilingual vault search (v0.06 §10)

The vault search proposal's multilingual section (§10) describes four staged
capabilities: charset detection, language detection (Lingua + Floret), BGE-M3
model, and ICU-backed BM25. This is a meaningful programme of work on its own.
Charset detection (§10.1) is worthwhile independently (it fixes silent data
corruption for non-UTF-8 files). Language detection and the BGE-M3 model are
better candidates for a v0.08 track once vault search is proven.

**Defer recommendation:** Ship vault search with `text/plain` + UTF-8 + BGE
Small En. Charset detection can land as an incremental improvement. Language
detection, BGE-M3, and ICU-backed BM25 are candidates for a later release once
vault search is proven.

### 5.3 Google Cloud Storage adapter (`9_99.md`)

Purely additive; no existing feature depends on it. Deferred by design. Assign a
milestone (e.g. v0.09) to prevent it from being forgotten.

### 5.4 JSONPath filter expressions and recursive descent (`9_99.md`)

Both require a shared expression evaluator layer that does not yet exist. The
filter expression work in particular overlaps with the Filter DSL and could
introduce inconsistency if not designed carefully. These are correctly deferred;
the `9_99.md` placement is appropriate. They should be reconsidered for a
post-v1 roadmap.

### 5.5 Cross-collection references (`9_99.md`)

No concrete use-case is yet identified. Correctly deferred.

---

## 6. Overall verdict and recommended minimum path to beta

### 6.1 Verdict

The roadmap is well-motivated and the technical proposals are high-quality. The
encryption proposal in particular is notably thorough — it correctly identifies
value-level as the only viable granularity, the key management design is sound,
and the platform-by-platform security level breakdown is genuinely useful for
app developers. The vault search proposal is similarly well-grounded.

The primary risks are:

1. **Implicit dependencies between releases.** v0.06 depends on v0.05 and on the
   configurable embedding model plan in ways that are not stated in the roadmap
   files. If these run in parallel, the v0.06 work will need to be partially
   re-plumbed when the missing prerequisites land.

2. **Plans are missing for v0.05 infrastructure work.** The most important
   prerequisite release has the least plan coverage.

3. **Open questions in proposals are not tracked.** Both the encryption and
   vault search proposals carry unresolved design decisions that must become
   plan artefacts before implementation begins. They are currently invisible to
   the `kmdb-plan-reviewer` agent.

4. **No explicit beta readiness criteria.** The roadmap describes features but
   does not state what a beta release means: which features are required, which
   are optional, and what quality bar (test coverage, platform support, API
   shape) constitutes a shippable beta.

### 6.2 Recommended minimum path to beta

The following is the critical-path ordering for a beta release that is
functional, safe, and shippable on the primary target platforms (macOS, iOS,
Android, and Linux):

**Track A — Platform infrastructure (v0.05)**

1. macOS universal binary (`betto_zstd`, `kmdb_inferencing`)
2. iOS ORT integration (CocoaPods/SPM, `ort_library.dart` iOS branch)
3. Android ORT and Zstd-jni integration
4. Linux x86_64 + arm64 native builds
5. GitHub Actions signing pipeline (macOS Developer ID; iOS/Android via Xcode)
6. Windows binary distribution (OV signing; EV risk assessed/accepted)
7. WASM Zstd **decompression** support — required for web sync compatibility
   with native platforms (see §3.4); not deferrable
8. WASM Zstd frame-compatibility verification (write side) — **go/no-go gate**;
   if it fails, defer write-side compression but decompression must still land

**Track B — Embedding model infrastructure (configurable model plan)**

_Depends on: Track A for mobile target confidence, but can be developed in
parallel._

1. `ModelSpec`, `ModelCatalog`, `ModelDownloader` (phases 1–3 of the plan)
2. Dimension generalisation (remove hard-coded `384`)
3. Model identity in `VecIndexState`, `KmdbDatabase.reindex()`
4. CLI cache directory and `kmdb reindex` command

**Track C — Vault usability (active plans)**

_Can run in parallel with Track B after the vault export plan is investigated._

1. `vault export` CLI command (from `plan_vault_export.md` — small,
   self-contained)
2. Fix `vault help` failure on uninitialised vault (noted in the same plan)

**Track D — Encryption (v0.07)**

_Depends on: Track B complete (model identity, `$meta` stability). No dependency
on vault search._

1. Resolve the ten open questions and write a plan
2. Implement `EncryptionProvider` pipeline integration
3. Argon2id + DEK wrapping + recovery code
4. CLI `--passphrase` / `kmdb init --encrypted`
5. Platform-specific secure storage (Keychain, Keystore, DPAPI)

**Track E — Vault search (v0.06)**

_Depends on: Track A + Track B + model identity (Track B step 3). High
complexity (background isolate). Ship after encryption if possible to avoid the
three-way interaction during initial implementation._

**Not on the critical path to v1:**

- Web Zstd write-side compression (accept uncompressed web writes for v1;
  revisit if web storage capacity proves a user-reported problem — WASM
  decompression is on the critical path in Track A above)
- BGE-M3 / multilingual search (post-v1)
- Range-predicate index scans (useful but not blocking)
- `plan_simple_api.md` (strategically valuable but requires the full feature set
  to be stable first)
- GCS adapter, JSONPath extensions, cross-collection references

### 6.3 Suggested next actions

1. **File v0.05 infrastructure plans** in `docs/plans/` covering the binary
   distribution work. The roadmap content is detailed enough to bootstrap these
   plans directly.
2. **Fix the stale `0_08.md` references** in
   `plan_configurable_embedding_model.md` (lines 17, 196, 396) — replace with
   `0_06.md`. Fix the dangling `v0.04` reference in
   `docs/proposals/range_predicate_index_scans.md` (header line 7).
3. **Make the configurable embedding model plan dependencies explicit:**
   annotate it as a v0.05 successor and a v0.06 prerequisite.
4. **Assign open questions from the encryption and vault search proposals** to
   plan files. Both proposals are ready for a planning pass; the open questions
   are the input to that pass.
5. **Define beta readiness criteria** — even a short checklist in
   `docs/spec/28_release_checklist.md` stating required platform support,
   minimum feature set, and API shape would significantly reduce the risk of the
   release milestone drifting.
6. **Plan the `betto_*` dependency publishing** (see §3.8) — decide whether to
   publish these packages to pub.dev or vendor them, and add it to the release
   track.
7. **Move `plan_simple_api.md` and `plan_vault_export.md`** to the roadmap (not
   `docs/plans/`) until they have an actionable problem statement, or
   investigate them now if they are genuine near-term priorities.
