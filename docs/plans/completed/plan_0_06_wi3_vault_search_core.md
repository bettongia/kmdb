# WI-3: Vault search — core

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/52

## Problem statement

Vault blobs are opaque to the search engine today. Documents with file
attachments (text, PDFs, HTML pages) cannot be searched by their content — only
by their document-field metadata. This WI implements the core vault search
architecture from
[Technical Proposal: Vault File Search](../proposals/vault_search.md), scoped to
`text/plain` blobs, so that vault content participates in lexical (BM25) and
semantic (vector) search through a new `KmdbCollection.searchVault()` method.

The work is substantial: it introduces the first background `Isolate` in KMDB, a
new text extraction and chunking pipeline, three new KV namespaces, a file-based
artifact store alongside vault blobs, and new public API surface on
`KmdbCollection` and `KmdbDatabase`.

**Dependencies (must be complete before implementation):**

- **WI-1 (model identity & index invalidation):** Complete per roadmap — no
  further action required.
- **WI-2 (charset detection):** The `decodeText` utility
  (`src/vault/search/charset_util.dart`) and the `betto_charset_detector`
  dependency must be in place. WI-2 is `Investigated`; implement it first on the
  same branch before beginning the WI-3 work, or implement WI-2 as the opening
  checklist items of this plan's implementation.

**Sequencing note — v0.08 encryption reconciliation (Gap B, HMAC tokens):** The
v0.08 roadmap includes replacing plaintext hex terms in FTS namespace names with
DEK-keyed HMAC tokens (`$$fts:{ns}:{field}:{hmacToken}`) to close vocabulary
enumeration leakage. The vault-specific `$$vault:fts:{sha256}:{hexTerm}` namespaces
introduced here have the same leakage characteristic. If the v0.08 Gap B work
lands before WI-3 is implemented, vault FTS should adopt HMAC tokens from day
one (no migration needed). If WI-3 ships first with plaintext hex terms, a
migration will be required when Gap B is applied. Coordinate with the v0.08 plan
author to minimise migration cost.

## Open questions

The seven proposal §8 questions are resolved in the Investigation section. The
review below (2026-06-21) surfaced **new** blocking questions that must be
resolved before this plan can reach `Investigated`:

- [x] **RQ-1 (RESOLVED — 2026-06-22, by WI-0 PR #50): Sync exclusion via `$$`
      prefix.** WI-0 (local-only namespace segregation) landed and establishes
      the canonical answer: any namespace prefixed with `$$` routes to a
      `.local.sst` file at flush time and is **never uploaded** by `SyncEngine`.
      This supersedes the §20.7 description in the 2026-06-21 review, which
      described the pre-WI-0 state where `$$fts:`/`$$vec:` had no structural
      exclusion mechanism.

      Decision: vault search namespaces carry the `$$` prefix and are
      structurally local-only. They do NOT ride in regular SSTables. §31
      encryption still applies to `$$` entries when encryption is on, but sync
      exclusion is enforced at the SSTable split (not by encryption alone).

      (a) `$$vault:fts:`, `$$vault:vec:`, `$$vault:extract:` all carry the `$$` prefix
          → `.local.sst` → never uploaded. No sync-engine changes needed.
      (b) Peer contamination is impossible: `$$vault:extract:` can never leave the
          device. The stub-detection concern from the 2026-06-21 review is moot.

      Namespace renames applied to this plan: `$vfts:` → `$$vault:fts:`,
      `$vvec:idx` → `$$vault:vec:idx`, `$vault:extract:` → `$$vault:extract:`.
      `$vault:docref:` retains its single-`$` prefix (syncable).
      Step 10 rewritten: no exclusion list to extend.
- [x] **RQ-2 (RESOLVED — 2026-06-22): `VaultSearchHit` is a standalone class,
      not a `SearchHit` subclass.** `SearchHit<T>`
      (`lib/src/search/search_result.dart:109`) is a `final class` and cannot be
      extended; its fields are `rank, score, fieldScores, id, document` (there is
      no `key` or `scores`). Decision: `VaultSearchHit<T>` is a **standalone
      `final class`** that mirrors the `SearchHit` field names exactly and adds
      `chunkContext`. It does NOT extend or compose `SearchHit`. Rationale: there
      is no shared base to extend, composition would force callers through
      `hit.inner.score`, and the field set is small enough that mirroring is
      cheaper than introducing a non-final shared base (which would weaken the
      existing `final` guarantee on `SearchHit`). The corrected shape is written
      into the "New result types" section below.
- [x] **RQ-3 (RESOLVED — 2026-06-22): Vault search reuses the database-level
      `embeddingModel`; the `VaultSearchConfig.embeddingModel` field is
      removed.** `KmdbDatabase.open()` already owns `EmbeddingModel?
      embeddingModel`, constructs `VecManager` from it, and disposes it in
      `close()` (`kmdb_database.dart:922`, `_embeddingModel?.dispose()`). A second
      model would mean two ORT sessions, two native model loads, ambiguous
      `dispose` ownership, and a second 384-vs-N dimension source of truth.
      Decision: `VaultSearchManager` receives the **same** `EmbeddingModel?`
      instance that `open()` already holds (passed by reference at construction).
      Lexical-only mode is selected by that single instance being `null` — there
      is no per-vault-search model toggle. `KmdbDatabase` remains the sole owner
      and the sole caller of `dispose()`; `VaultSearchManager.close()` must NOT
      dispose the model. `VaultSearchConfig` therefore drops its
      `embeddingModel` field entirely (corrected below).
- [x] **RQ-4 (RESOLVED — 2026-06-22): `VaultRefInterceptor` extension restated
      against the real seam, including field-path recovery.** The real
      `interceptWrite({batch, namespace, docKey, newDoc, oldDoc})` computes
      added/removed sha256 *sets* via `_extractVaultUris`, which recurses through
      `_scanForVaultUris` and collects **only** sha256 strings — the field path
      is discarded. Storing a field path in `$vault:docref` therefore requires a
      new path-aware scan. Decision and corrected design are in the rewritten
      "`VaultRefInterceptor` extension" section below: add a
      `_scanForVaultUrisWithPaths` that yields `Map<String /*sha256*/, String
      /*first field path*/>`, key `$vault:docref:{sha256}` by `docKey` (the
      32-char document UUID hex — confirmed to be the `{docId}` segment), and
      diff old/new path maps to add/remove docref entries in the same `batch`.
- [x] **RQ-5 (RESOLVED — 2026-06-22): the search-indexing isolate is an
      acceptable boundary AND the plan's "embed inside the isolate" data flow is
      WRONG and must change.** §18 keeps the LSM write path synchronous
      (compaction on the write path, no background storage isolate). A *search
      indexing* isolate that never touches the LSM and hands results back to the
      main isolate for commit does not violate that invariant — confirmed
      acceptable. **However**, the plan as written sends the `EmbeddingModel` into
      the spawned isolate and calls `embed()` there. That cannot work:
      `OnnxEmbeddingModel.embed()` runs on a **thread-affine ORT session that must
      be created in the same isolate that calls it**
      (`betto_inferencing/.../onnx_embedding_model.dart:235-237`), and the live
      model instance is owned by the main isolate (RQ-3). Embedding must stay on
      the main isolate (exactly as `VecManager` already does —
      `vec_manager.dart:847 await _model.embed(...)`). The corrected isolate
      scope (extraction + chunking + tokenisation only; embedding on the main
      isolate) and the cancellation protocol are written into the design below.

## Review — 2026-06-21 (kmdb-plan-reviewer)

This is a thorough, well-structured plan with genuine strengths: the crash-safety
sequencing (filesystem-before-WriteBatch with a documented recovery path), the
stub/hydration handling, the model-version staleness detection, and the
edge-case table are all of high quality and clearly the product of real
investigation. The Q1–Q7 resolutions are sound and well-argued (the
`searchVault()`-as-separate-method call in Q1 is correct). However, the plan is
**not implementation-ready** — it rests on three load-bearing claims that are
false against the current code/spec, and a Sonnet implementer following it
verbatim would write code that does not compile and a sync design that
contradicts §20.7.

### Problem statement assessment

Solid and worth solving. Vault content search is a roadmap v0.06 commitment
(`docs/roadmap/0_06.md`, WI-3) backed by a real proposal
(`docs/proposals/vault_search.md`). Scope is appropriately narrowed to
`text/plain`, with extractors (PDF/HTML) correctly deferred to WI-8/WI-9. The
dependency framing (WI-1 complete, WI-2 first) is accurate — I verified
`VecIndexState.modelId` exists and WI-1 is marked Complete in the roadmap.

One scoping note: the §"Sequencing note — v0.08 encryption reconciliation"
references the v0.08 roadmap and "Gap B HMAC tokens." Encryption shipped in Phase
12 and the roadmap numbering has moved; confirm with kmdb-architect that the HMAC
vocabulary-token work is still a live, separately-tracked item before relying on
that sequencing note. This is informational, not blocking.

### Proposed solution assessment

The architecture is mostly coherent and the data-flow narrative is good. The
extract-artifacts-on-disk approach (text.txt + chunks_v1.json + vectors.bin +
status) with filesystem-first write ordering is a reasonable crash-recovery
design and the strongest part of the plan. Reusing `RegExpTokenizer` from
`betto_lexical` and mirroring `FtsManager`/`VecManager` write patterns is the
right instinct.

Weaknesses are concentrated in the integration seams (below), not the core idea.

### Architecture fit

> **[2026-06-22 update: RQ-1 is resolved — see Open Questions. The analysis
> below describes the pre-WI-0 state and is retained as historical record.]**

**FATAL — sync exclusion contradicts §20.7 (RQ-1).** The plan's "New storage
namespaces" section and Step 10 instruct the implementer to "Locate the
namespace-exclusion list in the sync engine" and "add `$$vault:fts:`, `$$vault:vec:`,
`$$vault:extract` to the exclusion list," citing "`$fts:`, `$vec:` exclusion in
§20." This is backwards. Verified facts:

- `grep` for `$fts`/`$vec`/exclusion-by-prefix in `lib/src/sync/` returns **no
  namespace-exclusion mechanism**. It does not exist.
- Spec §20.7 (`docs/spec/20_text_search.md`, lines ~17–246) states `$fts:*` and
  `$vec:*` are *"**not excluded from upload**"* — they "ride in uploaded
  SSTables," "sync is whole-file at the SSTable level," "There is no upload-time,
  server-side, or per-entry namespace filter," and they are kept private "by
  **value-level encryption (§31)**, not by upload filtering." The spec even calls
  out that a filter "is not implemented" as a future possibility.

So the design must flip: the new index namespaces *will* ride to the cloud inside
SSTables (same as `$fts:`/`$vec:`), and privacy comes from §31 encryption — which
the plan's "Encryption compatibility" section already half-acknowledges for
`$$vault:fts:`/`$$vault:vec:idx`. Step 10 should not "extend an exclusion list"; it should
verify these namespaces are encrypted under §31 when encryption is on, and the
test in Step 10 must be rewritten (you cannot assert `$$vault:fts:` keys are "absent
from the set of keys that would be uploaded" — they are present). The `$vault:docref`
"must sync" reasoning is fine and lands in the same place, but for the wrong
stated reason (it's not "not excluded" vs "excluded" — *everything* in an SSTable
is uploaded).

**`extract/` filesystem artifacts** — this part is actually correct: those files
live under the vault blob directory, which is on the *filesystem* and not in the
synced SSTable path, so they are genuinely device-local. The §"known gap" about
plaintext `text.txt` leakage is a good and honest call-out, and WI-10 in the
roadmap already tracks encrypting them. No change needed here beyond not
conflating it with the SSTable-namespace question above.

**First Isolate vs §18 synchronous model (RQ-5).** Flagged as a question, not a
blocker — the boundary looks defensible but must be confirmed and documented.

### Risk & edge cases

The edge-case table is excellent and covers crash points, stubs, model changes,
GC, empty/zero-match, and degraded lexical-only mode. Two gaps:

- ~~**`$$vault:extract` syncing to peers.**~~ *(Moot — resolved by WI-0. The
  `$$vault:extract:` namespace carries the `$$` prefix and lands in `.local.sst`;
  it never reaches a peer. The stub-detection concern does not apply.)*
- **Concurrent `reindexVault()` + isolate cancellation** is listed
  ("Cancel in-flight isolate work") but the isolate cancellation protocol is not
  specified anywhere in the design. Spell out how in-flight work is cancelled
  (Isolate.kill? a cancellation token checked between chunks?).

### Implementation readiness

Not ready. Beyond RQ-1, two seams are specified against code that does not match:

- **`VaultSearchHit extends SearchHit` will not compile (RQ-2).**
  `SearchHit<T>` (`lib/src/search/search_result.dart:109`) is a `final class`
  and cannot be extended. Its fields are `rank, score, fieldScores, id,
  document` — the plan's constructor passes `super.key` and `super.scores`, which
  do not exist. The result-type design must be redone (composition, or a shared
  non-final base, or a standalone `VaultSearchHit`).
- **`VaultRefInterceptor` extension is specified against a non-existent
  signature (RQ-4).** The real `interceptWrite({batch, namespace, docKey,
  newDoc, oldDoc})` computes sha256 deltas internally and `_extractVaultUris`
  returns sha256s without field paths. "Store the field path" requires changing
  URI extraction to also yield the field path — a real change the plan
  under-specifies.
- **Two embedding models (RQ-3).** `KmdbDatabase.open()` already has
  `EmbeddingModel? embeddingModel`. The plan adds another inside
  `VaultSearchConfig` without reconciling them.

Smaller specificity gaps to tighten once the blockers are resolved:

- The BM25 scoring design says "IDF from corpus sentinel" but
  `$$vault:fts:corpus:{sha256}` stores only `{n: chunkCount, totalTokens}` per blob —
  document frequency (how many chunks contain a term) is needed for IDF and is
  not in the schema. Specify where DF comes from, or the BM25 math is
  unimplementable as written.
- `searchVault()` per-blob brute-force vector scan is fine for small corpora;
  note the expected scale and that this is O(chunks) per query, consistent with
  the existing `VecManager` full-scan approach.

### Recommendations

Reconsider-and-revise, do not proceed. The core architecture is salvageable and
mostly good; the failures are at the integration boundary and are correctable:

1. ~~Rewrite the sync story around §20.7 (ride-in-SSTables + §31 encryption),
   delete the "exclusion list" framing, and rewrite the Step 10 test.~~
   *(Done — WI-0 establishes `$$`-prefix sync exclusion; Step 10 rewritten.)*
2. Redo the `VaultSearchHit` result type against the real `SearchHit`.
3. Reconcile the embedding-model parameter with the existing `open()` seam.
4. Restate the `VaultRefInterceptor` and `_extractVaultUris` changes against the
   real signatures, including field-path recovery.
5. ~~Add the peer-`$$vault:extract`/stub-detection scenario to the edge-case table.~~
   *(Moot — `$$vault:extract:` never syncs; see RQ-1 resolution.)*
6. Confirm the isolate boundary with kmdb-architect and specify cancellation.

Once RQ-1 through RQ-4 are resolved in the plan text (RQ-5 confirmed), this is a
strong candidate for `Investigated`.

## Investigation

### Current state

The vault (`packages/kmdb/lib/src/vault/`) stores content-addressable blobs with
ref-count tracking but has no text extraction or search capability. The
document-field search subsystem (`packages/kmdb/lib/src/search/`) provides BM25
(`FtsManager`) and vector (`VecManager`) search over String document fields,
using `$$fts:` and `$$vec:` KV namespaces respectively. The two subsystems are
entirely separate; vault content is not visible to `FtsManager` or `VecManager`.

Key existing files relevant to this plan:

- `src/vault/vault_store.dart` — `VaultStore.ingest()` and `getBytes()` (handles
  encryption-aware blob retrieval)
- `src/vault/vault_ref_interceptor.dart` — intercepts document writes to
  maintain `$vault` ref counts in the same `WriteBatch`; this plan extends it to
  also maintain `$vault:docref`
- `src/vault/vault_manifest.dart` — `VaultManifest` with `mediaType` and
  `sha256`
- `src/search/lexical/fts_manager.dart` — BM25 index write/query pattern to
  replicate for vault content
- `src/search/semantic/vec_manager.dart` — embedding and SQ8 vector write/query
  pattern to replicate for vault vectors
- `src/search/semantic/vec_index_state.dart` — `VecIndexState.modelId` tracking
  (WI-1 complete); vault search mirrors this for its per-blob `modelVersion`
- `src/query/kmdb_database.dart` — `KmdbDatabase.open()` config pattern and
  existing `reindex()` method; this plan adds `vaultSearch` parameter,
  `vaultIndexingStatus()`, and `reindexVault()`
- `src/query/kmdb_collection.dart` — `search()` method; this plan adds
  `searchVault()`

### Resolved open questions (proposal §8)

**Q1 — Unified vs separate search API.** Decision: `searchVault()` is a
dedicated method on `KmdbCollection<T>`, separate from `search()`. Rationale:
BM25 scores computed over document fields and BM25 scores computed over chunks
belong to different corpora and are not directly comparable even after RRF
normalisation. Designing a principled unified surface requires empirical data on
score distributions that only a working implementation can provide. The public
API cost of adding a unified surface later (additive) is lower than splitting a
prematurely unified surface (breaking). A future proposal can revisit once vault
search score behaviour is understood in practice.

**Q2 — Chunk size configurability.** Decision: `chunkSize` and `chunkOverlap`
are global parameters on `VaultSearchConfig`, not per-collection. Per-collection
overrides are a v2 enhancement. Global configuration is simpler and sufficient
for the initial use-case (plain-text files of varied but unknown sizes).

**Q3 — Re-index trigger.** Decision: `KmdbDatabase.reindexVault()` — a new
method parallel to the existing `KmdbDatabase.reindex()` for document vectors.
This forces a full re-extraction and re-embedding of all vault blobs regardless
of their current status. The model-version-encoded artifact filenames
(`vectors_{modelId}_sq8.bin`) detect staleness automatically on startup;
`reindexVault()` is for explicit user-driven re-processing. A CLI command
`kmdb vault reindex` wraps this for the command-line path.

**Q4 — Indexing observability.** Decision: `KmdbDatabase.vaultIndexingStatus()`
returns a `VaultIndexingStatus` value with integer counts for each status bucket
(`total`, `indexed`, `pending`, `failed`, `unsupported`). An optional
`Stream<VaultIndexingStatus>` is also exposed as
`KmdbDatabase.watchVaultIndexingStatus()` so UI layers can observe progress in
real time. Both are implemented by scanning the `$$vault:extract` namespace.

**Q5 — Stub blob interaction.** Decision: Event-driven (not polling).
`VaultStore` gains an internal `_onBlobHydrated` callback field (a
`void Function(String sha256)?`). After a successful on-demand hydration inside
`getBytes()`, the store invokes this callback.
`VaultSearchManager.attach(VaultStore)` registers itself as that callback at
database open time, queuing the newly hydrated blob as `pending`. No isolate
polling loop is introduced.

**Q6 — LSM scan index rebuild.** Decision: Handled inside startup recovery
(`VaultSearchManager._recover()`). For each `$$vault:extract` entry with status
`extracting` (crash mid-index):

1. Check filesystem: does `extract/text.txt`, `extract/chunks_v1.json`, and
   `extract/vectors_{activeModelId}_sq8.bin` all exist?
2. If yes → rebuild `$$vault:fts:`, `$$vault:vec:idx`, and `$$vault:extract` entries from
   filesystem artifacts (no re-embedding). Mark blob `indexed`.
3. If no → reset to `pending` for full re-extraction.

This unified path also handles the "database moved / `$$vault:vec:idx` missing but
vault files present" scenario.

**Q7 — Snippet length.** Decision: `VaultChunkContext.snippet` is the full chunk
text in v1 (no additional trimming). This gives callers maximum flexibility to
implement display-appropriate truncation. A `maxSnippetLength` config parameter
is deferred to v2.

### Architecture

#### Component overview

```
KmdbDatabase.open(vaultSearch: VaultSearchConfig(...))
    │
    ▼
VaultSearchManager                  ← orchestrates the full lifecycle
    ├─ VaultRefInterceptor           (extended) writes $vault:docref
    ├─ VaultIndexingIsolate          background Dart Isolate (extract+chunk+tokenise only)
    │      ├─ VaultTextExtractor     PlainTextExtractor in v1
    │      └─ VaultChunker           chunking + offset computation
    ├─ (main isolate) embeddingModel database-level EmbeddingModel; embeds chunks
    │                                  on the main isolate (ORT session is thread-affine)
    ├─ VaultBm25Writer               writes $$vault:fts: namespace
    └─ VaultVecWriter                writes $$vault:vec:idx namespace

The `embeddingModel` is the **same instance** `KmdbDatabase.open()` already holds
(RQ-3). `VaultSearchManager` does not own it and never disposes it.
```

#### Data flow

1. `VaultStore.ingest()` completes → `VaultRefInterceptor` writes
   `$vault:docref` + ref count (same `WriteBatch`) → `VaultSearchManager` queues
   blob as `pending` (writes `$$vault:extract` key).
2. `VaultSearchManager` sends work item (sha256, mediaType, blob bytes,
   chunkSize, chunkOverlap) to the `VaultIndexingIsolate` via `SendPort`. The
   bytes are read by the main isolate using `VaultStore.getBytes()` **before**
   the send — this keeps encryption handling on the main isolate and avoids
   passing DEK material across the isolate boundary. For text/plain blobs this is
   acceptable; document this as a known design constraint.
3. Isolate: extracts text → chunks → tokenises each chunk (BM25 term/frequency
   maps) → sends back a `VaultIndexResult` message containing: the extracted
   text bytes (for `text.txt`), the chunk metadata (for `chunks_v1.json`), and a
   per-chunk `{term: tf}` map for BM25. **The isolate does NOT embed.** Embedding
   requires the live `EmbeddingModel`, whose ORT session is thread-affine and
   owned by the main isolate (RQ-3, RQ-5); sending the model across the boundary
   is impossible. The isolate is purely CPU-bound extraction + chunking +
   tokenisation, which is exactly the work that benefits from being off the main
   thread.
4. Main isolate: if `embeddingModel != null`, embeds each chunk's text via the
   database-level model (`await embeddingModel.embed(chunkText)`, mirroring
   `VecManager._embed`) and quantises to SQ8 — same code path and thread as the
   existing document-vector embedding. Then applies filesystem writes (text.txt,
   chunks_v1.json, vectors_*.bin, extract_status.json), then commits a
   `WriteBatch` with all LSM entries (`$$vault:fts:`, `$$vault:vec:idx`,
   `$$vault:extract`). The filesystem writes come first; if the process crashes
   between them and the `WriteBatch`, startup recovery rebuilds from the
   filesystem (Q6 path). Embedding on the main isolate adds latency to indexing
   but not to user-facing reads/writes (indexing is already asynchronous to the
   `put()` that triggered it), and it keeps the single ORT session model intact.
5. `searchVault()`: reads `$vault:docref` to find referenced sha256 hashes →
   scores chunks via BM25 (`$$vault:fts:`) and/or dot-product (`$$vault:vec:idx`) →
   deduplicates to blob level → deduplicates to document level → fetches
   documents → reads snippets from `extract/text.txt` using offsets from
   `extract/chunks_v1.json`.

#### Encryption compatibility

`VaultStore.getBytes()` already handles encrypted blobs (Phase 12). The indexing
isolate receives the raw (decrypted) bytes — it never touches ciphertext or the
`EncryptionProvider`. This is the correct boundary.

**LSM entries (`$$vault:fts:`, `$$vault:vec:idx`)** are written via `WriteBatch` through the
normal `ValueCodec.encode(encryption:)` path. When encryption is active they are
encrypted automatically, consistent with the existing `$$fts:` and `$$vec:`
behaviour documented in §31. The implementation must verify that the
`WriteBatch` used by `VaultBm25Writer` and `VaultVecWriter` is created from the
encrypted store (i.e. it carries the `EncryptionProvider`), not from a bare
`KvStore`.

**Filesystem artifacts (`extract/` directory) — known gap.** `text.txt`,
`vectors_*.bin`, `chunks_v1.json`, and `extract_status.json` are written as
plaintext even when the database has encryption enabled. The vault blob itself
is encrypted by `VaultStore`, but the derived extraction artifacts sitting
alongside it are not. `text.txt` in particular is a significant information
leak: it is the full extracted plaintext of a blob whose ciphertext on disk is
otherwise opaque. This is a v1 limitation; encrypting `extract/` artifacts using
the DEK is deferred to a future plan. The spec must document this gap explicitly
so callers understand the threat model.

#### Model identity & re-index

`VaultSearchManager` holds a **borrowed** reference to the database-level
`EmbeddingModel` (the same instance passed to `KmdbDatabase.open`; `null` for
lexical-only mode). It never disposes it (RQ-3). During startup recovery, for
each `$$vault:extract` entry with status `indexed`:

- Read `modelVersion` from the stored CBOR.
- If `embeddingModel != null && modelVersion != embeddingModel.modelId` → reset
  to `pending` (vectors are stale).
- If `embeddingModel == null && modelVersion != ''` → vectors are not needed in
  lexical-only mode; reset only the `$$vault:vec:idx` entries; keep FTS entries; mark
  `indexed`.

### New storage namespaces

(Defined in `src/vault/search/vault_namespaces.dart`.)

| Namespace                  | Key                                                          | Value                                                                                        |
| -------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `$$vault:fts:{sha256}:{hexTerm}` | chunk index (8-digit zero-padded hex)                        | CBOR int — term frequency in chunk                                                           |
| `$$vault:fts:corpus:{sha256}`    | fixed hex sentinel (mirror `FtsManager._corpusKey`, not `"\x00"`) | CBOR `{n: chunkCount, totalTokens: N}`                                                  |
| `$$vault:vec:idx`                | `{sha256}:{chunkIndex}` (chunkIndex 8-digit zero-padded hex) | 384-byte SQ8 vector                                                                          |
| `$vault:docref:{sha256}`   | `{docId}` (32-char hex UUIDv7)                               | CBOR string — field path                                                                     |
| `$$vault:extract:{sha256}`  | fixed hex sentinel (mirror `FtsManager._corpusKey`)          | CBOR `{status, modelVersion?, chunkCount?, chunkingParams?, extractedAt?, error?, charset?}` |

`$$vault:fts:`, `$$vault:vec:idx`, and `$$vault:extract:` carry the `$$` prefix (WI-0
local-only convention) and route to `.local.sst` files at flush time — they are
never uploaded by `SyncEngine`. No sync-engine changes are required; exclusion is
structural. Each device rebuilds these derived indexes independently from the
synced document data (same pattern as `$$fts:`, `$$vec:`, `$$index:`).

`$vault:docref:` has a single `$` prefix and syncs normally alongside other
document data. The existing `$vault` ref-count namespace (maintained by
`VaultRefInterceptor`) also syncs normally.

**BM25 IDF/document-frequency (DF) — how it is computed (resolves the
2026-06-21 review gap).** The corpus sentinel stores only `{n: chunkCount,
totalTokens: N}` — it deliberately does **not** store per-term DF, and that is
correct because `FtsManager` does not store DF either. `FtsManager` derives DF
*dynamically at query time* by scanning the per-term namespace
`$$fts:{ns}:{field}:{hexTerm}` and counting how many doc keys it yields
(`fts_manager.dart:765`, `termDf[term] = (termDf[term] ?? 0) + 1`), then feeds
`df`/`n` into `IDF(t) = ln((n − df + 0.5)/(df + 0.5) + 1)`
(`fts_manager.dart:989`). Vault search mirrors this exactly, with **chunk in
place of document**: for each query term, scan `$$vault:fts:{sha256}:{hexTerm}`,
count the chunk-index keys to get `df` (= number of chunks containing the term
within that blob), and read `n = chunkCount` from the corpus sentinel. Per-blob
corpus scope is intentional (each blob's chunks are its own corpus); a
cross-blob IDF is explicitly out of scope for v1 and would require a different
schema. The BM25 math is therefore fully implementable from the schema as
specified — no DF field needs to be added.

### Filesystem layout (within vault `extract/`)

```
{local-db-dir}/vault/blobs/sha256/{prefix}/{suffix}/
  manifest.json            ← existing
  blob                     ← existing (absent for stubs)
  tombstone.json           ← existing
  extract/
    text.txt               ← UTF-8 extracted text
    chunks_v1.json         ← chunk metadata (index, byteStart, byteEnd, wordCount)
    vectors_{modelId}_sq8.bin  ← packed SQ8 vectors, one per chunk
    extract_status.json    ← lifecycle state (source of truth)
```

The `extract/` directory is never synced (it is inside the vault blob directory
which is local-only per §24).

#### `extract_status.json` schema

```jsonc
{
  "status": "indexed", // "pending"|"extracting"|"indexed"|"failed"|"unsupported"
  "modelVersion": "bge-small-en-v1.5", // active model id at index time; "" for lexical-only
  "chunkingParams": { "chunkSize": 300, "chunkOverlap": 50 },
  "chunkCount": 12,
  "extractedAt": "2026-...", // ISO-8601 wall clock timestamp
  "error": null, // populated on "failed" status
  "charset": "utf-8", // detected charset from WI-2
}
```

#### `chunks_v1.json` schema

```jsonc
[
  { "index": 0, "byteStart": 0, "byteEnd": 1842, "wordCount": 300 },
  { "index": 1, "byteStart": 1612, "byteEnd": 3501, "wordCount": 300 },
]
```

Byte offsets reference `text.txt` (not the original blob). Used for snippet
retrieval without re-reading the blob.

### Public API surface

#### `VaultSearchConfig` (new, in `src/vault/search/vault_search_config.dart`)

```dart
final class VaultSearchConfig {
  const VaultSearchConfig({
    this.extractors = const [PlainTextExtractor()],
    this.chunkSize = 300,
    this.chunkOverlap = 50,
  });

  final List<VaultTextExtractor> extractors;
  final int chunkSize;
  final int chunkOverlap;
}
```

Pass to `KmdbDatabase.open(vaultSearch: config)`. If omitted or `null`, no vault
search indexing occurs.

**Embedding model (RQ-3).** `VaultSearchConfig` does **not** carry an
`embeddingModel`. Vault search reuses the existing top-level
`KmdbDatabase.open(embeddingModel: ...)` instance — the same model that drives
`VecManager`. Semantic vault indexing is enabled iff that model is non-null;
otherwise vault search runs in lexical-only mode. `KmdbDatabase` owns the model
lifecycle and is the only caller of `EmbeddingModel.dispose()`;
`VaultSearchManager` holds a borrowed reference and must not dispose it.

#### `VaultTextExtractor` interface (new, in `src/vault/search/vault_text_extractor.dart`)

```dart
abstract interface class VaultTextExtractor {
  Set<String> get supportedMediaTypes;
  Future<String?> extract(Uint8List bytes, VaultManifest manifest);
}
```

`PlainTextExtractor` (included in core) handles `text/plain` via `decodeText()`
from WI-2's `charset_util.dart`.

#### `KmdbCollection.searchVault()` (new method)

```dart
/// Searches vault blob content for [query].
///
/// Results are limited to blobs that have been downloaded and indexed on this
/// device. On devices using on-demand hydration, blobs that have not yet been
/// downloaded are absent from results — the result set may be silently
/// incomplete. Check [KmdbDatabase.vaultIndexingStatus] and inspect
/// [VaultIndexingStatus.stub] to determine whether results are potentially
/// incomplete, and surface an appropriate warning to the user.
Future<VaultSearchResult<T>> searchVault(
  String query, {
  SearchMode mode = SearchMode.auto,
  List<String>? fields,  // document field paths to consider; null = all VaultRef fields
  int limit = 10,
  int offset = 0,
})
```

Returns a new `VaultSearchResult<T>` (`{SearchMetadata metadata; List<VaultSearchHit<T>> hits}`),
NOT the existing `SearchResult<T>` — see the result-types section (RQ-2). The
`SearchMetadata` type is reused unchanged.

#### New result types (new, in `src/vault/search/vault_search_hit.dart`)

```dart
final class VaultChunkContext {
  final VaultRef ref;
  final int chunkIndex;
  final int totalChunks;
  final String snippet;    // full chunk text from text.txt + offsets
  final String fieldPath;  // document field that held the VaultRef
}

/// A single ranked vault-content match.
///
/// Mirrors the field set of [SearchHit] exactly (`rank, score, fieldScores,
/// id, document`) and adds [chunkContext]. It is a standalone `final class`,
/// NOT a subclass of [SearchHit] — `SearchHit` is `final` and cannot be
/// extended (RQ-2). Keeping the field names identical means callers that
/// already consume `SearchHit` can read a `VaultSearchHit` with no surprises.
final class VaultSearchHit<T> {
  const VaultSearchHit({
    required this.rank,
    required this.score,
    required this.fieldScores,
    required this.id,
    required this.document,
    required this.chunkContext,
  });

  /// 1-based position in the result list (1 = highest relevance).
  final int rank;

  /// Overall relevance score. Interpretation matches [SearchHit.score]
  /// (BM25 normalised, cosine, or RRF depending on [SearchMode]).
  final double score;

  /// Per-component scores, keyed `"vault:bm25"` / `"vault:cosine"`. The vault
  /// corpus is chunk-based, not field-based, so there is no per-document-field
  /// key here (unlike `SearchHit.fieldScores`).
  final Map<String, double> fieldScores;

  /// The owning document key (UUIDv7 hex string).
  final String id;

  /// The fully decoded owning document.
  final T document;

  /// The matching chunk's context (snippet, offsets, originating field path).
  final VaultChunkContext chunkContext;
}
```

`searchVault()` returns `SearchResult<VaultSearchHit<T>>`. Note that
`SearchResult<X>.hits` is typed `List<SearchHit<X>>`
(`search_result.dart:43`) — so the existing `SearchResult` wrapper cannot hold
`VaultSearchHit` elements directly. The implementer must either (a) introduce a
parallel `VaultSearchResult` value type (`{metadata, hits: List<VaultSearchHit<T>>}`)
reusing the existing `SearchMetadata`, or (b) generalise `SearchResult` to
`SearchResult<H>` where `H` is the hit type. **Decision: option (a) —
`VaultSearchResult<T>`** — a new standalone type in
`vault_search_hit.dart`. Generalising `SearchResult` is a wider, riskier change
to a shipped public type for no caller benefit. The `searchVault()` signature
below is corrected to return `VaultSearchResult<T>`.

#### `KmdbDatabase` additions

```dart
// New open() parameter:
static Future<KmdbDatabase> open({
  ...
  VaultSearchConfig? vaultSearch,  // null → no vault search
  ...
})

// New methods:
Future<VaultIndexingStatus> vaultIndexingStatus();
Stream<VaultIndexingStatus> watchVaultIndexingStatus();
Future<int> reindexVault();  // returns count of blobs queued
```

#### `VaultIndexingStatus` (new, in `src/vault/search/vault_indexing_status.dart`)

```dart
final class VaultIndexingStatus {
  const VaultIndexingStatus({
    required this.total,
    required this.indexed,
    required this.pending,
    required this.extracting,
    required this.failed,
    required this.unsupported,
    required this.stub,
  });
  final int total;
  final int indexed;
  final int pending;
  final int extracting;
  final int failed;
  final int unsupported;
  /// Blobs known to exist (manifest present) but not yet downloaded on this
  /// device. These are absent from [searchVault()] results — search results
  /// may be silently incomplete when [stub] > 0.
  final int stub;
  bool get isComplete => pending == 0 && extracting == 0;
  bool get isSearchComplete => isComplete && stub == 0;
}
```

`stub` is populated by cross-referencing `$$vault:extract` entries (which only
exist for downloaded blobs) against `$vault` ref-count entries (which exist for
all known blobs, including stubs). Blobs with a `$vault` ref count but no
`$$vault:extract` entry are stubs.

`isSearchComplete` is the signal a UI should use to decide whether to show an
"incomplete results" warning: `isComplete` alone is not sufficient on devices
that do on-demand hydration.

### Key implementation notes

#### Isolate/LSM race — crash safety

The write sequence is:

1. Write `extract/text.txt`
2. Write `extract/chunks_v1.json`
3. Write `extract/vectors_{id}_sq8.bin` (if semantic)
4. Write `extract/extract_status.json` (with final `"indexed"` status)
5. Apply `WriteBatch` to LSM: `$$vault:fts:`, `$$vault:vec:idx`, `$$vault:extract`

Step 5 is atomic (single `WriteBatch`). A crash between steps 1–4 and step 5
leaves `$$vault:extract` in `extracting` state. On startup recovery, the manager
checks filesystem completeness (step 6 above in Q6 resolution) and either
rebuilds from files or resets to `pending`. Tests must exercise each crash
point.

`$$vault:extract` is written **first** as `extracting` before the isolate starts
work (in step 0, before the filesystem writes). This ensures the blob is not
re-queued by a concurrent `open()` on another database handle during a long
extraction.

#### Isolate boundary vs §18 synchronous model (RQ-5)

§18 (`docs/spec/18_concurrency.md`) commits KMDB to a synchronous storage engine:
the write path, compaction, and all LSM mutation run on the main isolate; there
is no background storage isolate. The `VaultIndexingIsolate` does **not** violate
this and must be documented so it is never read as licence to move storage work
off-thread:

- The isolate touches **no LSM state**: no `KvStore`, no `WriteBatch`, no
  `WriteAugmentor`, no compaction. It receives plain bytes + chunk params and
  returns plain data (extracted text, chunk metadata, per-chunk term/tf maps).
- All durable writes — embedding (RQ-3/RQ-5: ORT session is main-isolate-only),
  `WriteBatch` commit, filesystem artifacts — happen on the **main isolate**,
  synchronously, exactly as today. The isolate is a pure CPU-offload for
  extraction/chunking/tokenisation.
- Indexing is already decoupled from the triggering `put()` (the document write
  commits; indexing is queued afterward), so the isolate adds no latency to the
  synchronous write path. The new spec section must state this boundary
  explicitly.

#### Isolate cancellation protocol

`reindexVault()` and `close()` may need to stop in-flight isolate work. The
protocol:

- The `VaultIndexingIsolate` processes **one work item at a time**, pulled from a
  main-isolate queue. There is no internal multi-item batching inside the
  isolate, so cancellation granularity is one blob.
- `VaultSearchManager` tracks the in-flight sha256 (the work item currently sent
  to the isolate but not yet acknowledged via its `VaultIndexResult`).
- **`close()`** (graceful): stop dequeuing new items; `await` the in-flight
  `VaultIndexResult` (extraction of a single text/plain blob is bounded and
  fast); commit or discard it; then `SendPort` a shutdown message and
  `Isolate.exit`/let it drain. Do **not** `Isolate.kill` mid-result — that risks
  a torn filesystem artifact set with no recovery marker. (Recovery still covers
  a hard crash here via the Q6 path, but graceful close should not rely on it.)
- **`reindexVault()` during active indexing**: clear the pending queue; let the
  single in-flight item complete and be **discarded** (its result is dropped, not
  committed, because its blob is about to be reset to `pending`); then reset all
  `indexed`/`extracting` blobs to `pending` in a `WriteBatch` and re-enqueue.
  Dropping one in-flight result is simpler and safe because that blob is
  re-queued anyway. No mid-extraction cancellation token is required given the
  one-item-at-a-time model; if a future extractor (PDF/HTML, WI-8/9) is slow
  enough that one item dominates, a between-chunks cancellation check can be
  added then — out of scope for v1 text/plain.

#### `VaultRefInterceptor` extension (RQ-4 — restated against the real seam)

The real signature is
`interceptWrite({required WriteBatch batch, required String namespace, required String docKey, required Map<String, dynamic>? newDoc, required Map<String, dynamic>? oldDoc})`
(`write_augmentor.dart:55`). Today it calls `_extractVaultUris(oldDoc)` /
`_extractVaultUris(newDoc)` to get two `Set<String>` of sha256s, then diffs them
into `added`/`removed` and walks `_increment`/`_decrement`. The `docKey`
parameter is the document's UUIDv7 hex key — this is exactly the `{docId}` key
segment used by `$vault:docref:{sha256}` / `{docId}`. (`namespace`/`docKey` are
currently documented as "accepted but unused"; this change starts using
`docKey`.)

`_extractVaultUris` discards field paths: it delegates to `_scanForVaultUris`,
which recurses through maps/lists and adds only `VaultRef(value).sha256` to a
`Set<String>`. Recovering the field path therefore requires a **new** scan.

Changes to `vault_ref_interceptor.dart`:

1. Add a private `Map<String, String> _scanVaultUrisWithPaths(Map<String, dynamic>? doc)`
   returning `{sha256 → fieldPath}`. It mirrors `_scanForVaultUris` but threads a
   dot-path accumulator (e.g. `attachments[0].file`) and records the **first**
   path seen for each sha256 ("first field path wins" — documented limitation; a
   CBOR-list upgrade to carry every path is a v2 enhancement). Keep the existing
   `_extractVaultUris`/`_scanForVaultUris` untouched so the ref-count diff logic
   is unchanged — the new method is additive.
2. In `interceptWrite`, after the existing ref-count loop, compute
   `oldPaths = _scanVaultUrisWithPaths(oldDoc)` and
   `newPaths = _scanVaultUrisWithPaths(newDoc)`, then:
   - For each `sha256` in `newPaths.keys.difference(oldPaths.keys)`:
     `batch.put('$vault:docref:$sha256', docKey, ValueCodec.encode(<string fieldPath>, encryption: encryption))`.
   - For each `sha256` in `oldPaths.keys.difference(newPaths.keys)`:
     `batch.delete('$vault:docref:$sha256', docKey)`.
   - sha256s present in both are left untouched (the docKey→path mapping is
     unchanged for that document).
   Because these operations target the **same** `batch` as the ref-count writes,
   the docref index is always consistent with the ref counts.
3. The docref value is encrypted via `ValueCodec.encode(encryption:)` exactly
   like the ref-count value — `$vault:docref:` is a single-`$` syncable namespace
   that rides in synced SSTables, so it must be encrypted when encryption is on
   (consistent with `$vault` ref counts, §31).

Note: `decrementVersionRefs` (the compaction version-drop callback) does **not**
need a docref counterpart — docref tracks *live document* references, and a
trimmed `$ver:` history entry does not change which live documents reference a
blob. Leave it as ref-count-only.

#### Sync exclusion

Vault search namespaces use the `$$` prefix (WI-0 convention). The LSM engine
routes any namespace where `isLocalOnly(ns)` is true into a `.local.sst` file
at flush time; `SyncEngine.push` skips all `.local.sst` files. No sync-engine
changes are required.

- `$$vault:fts:` — local-only (vault BM25 terms)
- `$$vault:vec:idx` — local-only (vault vector scan index)
- `$$vault:extract:` — local-only (extraction status, device-specific)
- `$vault:docref:` — **syncable** (single `$` prefix); document→blob references
  must reach other devices, same as the existing `$vault` ref-count entries.

#### Lexical-only mode (database-level `embeddingModel: null`)

Lexical-only mode is selected by the top-level `KmdbDatabase.open(embeddingModel:
null)` (RQ-3), not by a vault-search-specific flag. When it is `null`:

- The main isolate skips the embedding/quantisation step (the indexing isolate
  never embedded — it only extracts/chunks/tokenises; see data-flow step 3-4).
- No `vectors_*.bin` file is written.
- `$$vault:vec:idx` entries are not written.
- `modelVersion` in `extract_status.json` and `$$vault:extract` is `""`.
- `searchVault()` with `mode == SearchMode.semantic` or `SearchMode.auto` falls
  back to lexical results with a metadata note (mirrors `FtsManager`
  degraded-mode handling).

#### CLI additions

- `kmdb vault search <query> [--mode lexical|semantic|hybrid] [--limit N]`
  (searches across all collections with vault search configured — requires a way
  to identify the collection; use `--collection <name>` parameter)
- `kmdb vault reindex` (calls `db.reindexVault()`, prints count)
- `kmdb vault status` (calls `db.vaultIndexingStatus()`, prints counts)

These follow existing `kmdb vault` command patterns.

### Edge cases and failure scenarios for tests

| Scenario                                                             | Expected behaviour                                                                                                                                                       |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Crash after `text.txt` written, before `chunks_v1.json`              | Startup recovery: `text.txt` exists but chunks missing → reset to `pending`, full re-extraction                                                                          |
| Crash after all filesystem artifacts, before LSM `WriteBatch`        | Startup recovery: all artifacts present → rebuild LSM from files, mark `indexed`                                                                                         |
| Stub blob at index time                                              | No `$$vault:extract` entry written; blob counted in `VaultIndexingStatus.stub`; absent from search results                                                                |
| Stub hydrated mid-session                                            | `VaultStore` callback → `VaultSearchManager` queues sha256 as `pending`; `stub` count decrements, `pending` increments                                                   |
| Device with many stubs — `searchVault()` called                      | Results are silently incomplete; caller must check `VaultIndexingStatus.stub > 0` to surface a warning                                                                   |
| Embedding model changes between sessions                             | Startup recovery: `modelVersion` mismatch → reset to `pending`; full re-index                                                                                            |
| `reindexVault()` called during active indexing                       | Cancel in-flight isolate work; reset all `indexed` blobs to `pending`; restart isolate                                                                                   |
| `text/plain` blob with Windows-1252 encoding                         | `PlainTextExtractor` uses `decodeText()` (WI-2); correctly decoded; `charset` stored                                                                                     |
| `text/plain` blob with no registered extractor?                      | Impossible: `PlainTextExtractor` is always in the default extractor list                                                                                                 |
| Non-text blob (e.g. `image/png`)                                     | No extractor matches; status written as `unsupported`; blob accessible normally                                                                                          |
| Empty blob (`""`)                                                    | Extracted text is empty string; 0 chunks; status `indexed` with `chunkCount: 0`                                                                                          |
| Blob referenced by two documents                                     | `$vault:docref` has two entries (one per docId); both returned in `searchVault()` results                                                                                |
| GC of indexed blob                                                   | In `VaultGc.sweep()` at the deletion point: delete the `extract/` directory and commit a `WriteBatch` removing `$$vault:fts:`, `$$vault:vec:idx`, `$vault:docref`, `$$vault:extract` entries for the sha256 (sweep has no doc `WriteBatch` — Step 11 seam correction) |
| Database opened without `vaultSearch` on a db that previously had it | `$$vault:extract` entries remain (harmless); search not available; no startup crash                                                                                       |
| Lexical-only mode — `searchVault(mode: semantic)`                    | Degrades to lexical; metadata indicates semantic unavailable                                                                                                             |
| Query returning zero matches                                         | Empty `SearchResult.hits`, `metadata.total = 0`                                                                                                                          |
| `offset` beyond total results                                        | Empty `SearchResult.hits`                                                                                                                                                |

### Spec impact

A new vault search spec section (`NN_vault_search.md`, where NN is the next
available number after 31) must be created. It should document: storage layout,
lifecycle state machine, startup recovery, isolate architecture, API reference,
and sync exclusion rules. Also update `20_text_search.md` to reference the new
section.

The `99_glossary.md` should receive entries for: `VaultTextExtractor`,
`VaultSearchManager`, `VaultSearchConfig`, `$$vault:fts:`, `$$vault:vec:`, `chunk`.

The release checklist (`28_release_checklist.md`) should receive an entry:
"RC-N: Vault search isolate crash recovery — verify on real OS with process kill
at each write step" (not feasible in automated CI).

## Implementation plan

**Prerequisites — complete first:**

- [x] Implement WI-2 (`charset_util.dart` + `betto_charset_detector` dependency)
      if not already merged. Confirm `decodeText` function is available in
      `src/vault/search/charset_util.dart`. ✓ WI-2 was merged in PR #51; `decodeText` confirmed present.

**Step 1 — Core types and config:**

- [x] Add `src/vault/search/vault_text_extractor.dart` — `VaultTextExtractor`
      interface and `VaultManifest` import.
- [x] Add `src/vault/search/plain_text_extractor.dart` — `PlainTextExtractor`
      implementing `VaultTextExtractor`; uses `decodeText()` from WI-2; stores
      detected charset in returned `CharsetDecodeResult`.
- [x] Add `src/vault/search/vault_search_config.dart` — `VaultSearchConfig` with
      `extractors`, `chunkSize`, `chunkOverlap` (NO `embeddingModel` — RQ-3:
      reuse the database-level model).
- [x] Add `src/vault/search/vault_namespaces.dart` — const strings for all five
      namespaces (`$$vault:fts:`, `$$vault:vec:idx`, `$vault:docref:`, `$$vault:extract`).
- [x] Add `src/vault/search/vault_extraction_state.dart` —
      `VaultExtractionStatus` enum and `VaultExtractionState` record.

**Step 2 — Chunking pipeline:**

- [x] Add `src/vault/search/vault_chunk.dart` — `VaultChunk` record
      `{index, byteStart, byteEnd, wordCount}`.
- [x] Add `src/vault/search/vault_chunker.dart` — `VaultChunker` class;
      tokenises text using `RegExpTokenizer` from `betto_lexical`; slides window
      of `chunkSize` words with `chunkOverlap` overlap; computes byte offsets in
      the UTF-8-encoded text string.
- [x] Write unit tests in `test/vault/search/vault_chunker_test.dart` covering:
      empty text, text smaller than one chunk, exact chunk size, multiple chunks
      with overlap, non-ASCII (multi-byte UTF-8 characters verify byte offset
      correctness).

**Step 3 — Search result types:**

- [x] Add `src/vault/search/vault_search_hit.dart` — `VaultChunkContext`,
      `VaultSearchHit<T>` (standalone `final class`, NOT extending `SearchHit` —
      RQ-2), and `VaultSearchResult<T>` (`{SearchMetadata metadata;
      List<VaultSearchHit<T>> hits}`, reusing the existing `SearchMetadata`).
- [x] Add `src/vault/search/vault_indexing_status.dart` — `VaultIndexingStatus`.

**Step 4 — Extend `VaultRefInterceptor`:**

- [x] Edit `src/vault/vault_ref_interceptor.dart`: in `interceptWrite()`, after
      the existing ref-count increment/decrement logic, also write/delete
      `$vault:docref:{sha256}` / `{docId}` → CBOR field-path string. Document
      the "first field path wins" limitation.
- [x] Write tests covering: insert doc with VaultRef → docref entry written;
      update doc (old ref removed, new ref added) → old docref deleted, new
      written; delete doc → docref deleted; doc with two different VaultRef
      fields → both sha256 entries written.

**Step 5 — Indexing isolate:**

- [x] Add `src/vault/search/vault_indexing_isolate.dart` —
      `VaultIndexingIsolate` class encapsulating the Dart `Isolate`: -
      `_entryPoint(SendPort reply)` static function (Isolate main). - Receives
      `VaultWorkItem` (sha256, mediaType, bytes, chunkSize, chunkOverlap). - Calls
      appropriate `VaultTextExtractor.extract()`. - Calls `VaultChunker.chunk()`.
      - Tokenises each chunk into a `{term: tf}` map (BM25 input). **Does NOT
      embed** — the ORT session is thread-affine and main-isolate-only (RQ-3,
      RQ-5). - Returns `VaultIndexResult` via `SendPort`: extracted text bytes +
      chunk metadata + per-chunk term/tf maps + extractor status (no SQ8 vectors;
      embedding happens on the main isolate). - `VaultIndexingIsolate` is spawned
      lazily (first `pending` work item) and processes **one work item at a
      time** (cancellation granularity = one blob; see "Isolate cancellation
      protocol"). - Shutdown is graceful: await the in-flight result, then exit —
      never `Isolate.kill` mid-result.
- [x] Write unit tests for the isolate entry-point function directly (not
      spawned), testing all extractor paths and the per-chunk term/tf output.

**Step 6 — `VaultBm25Writer` and `VaultVecWriter`:**

- [x] Add `src/vault/search/vault_bm25_writer.dart` — writes BM25 term entries
      (`$$vault:fts:{sha256}:{hexTerm}` and `$$vault:fts:corpus:{sha256}`) into a
      `WriteBatch`. Mirrors `FtsManager`'s term-encoding pattern.
- [x] Add `src/vault/search/vault_vec_writer.dart` — writes `$$vault:vec:idx` /
      `{sha256}:{chunkIndex}` entries into a `WriteBatch`. SQ8 vectors are 384
      bytes for the current model; the writer is dimension-agnostic (length
      derived from the model's `dimensions` property).
- [x] Write unit tests for each writer verifying key format, value encoding, and
      `WriteBatch` contents.

**Step 7 — `VaultSearchManager`:**

- [x] Add `src/vault/search/vault_search_manager.dart` — `VaultSearchManager`: -
      Constructed with `VaultSearchConfig`, `KvStore`, `VaultStore`, and the
      **borrowed** database-level `EmbeddingModel?` (RQ-3 — not owned, not
      disposed here). - `attach()` registers the hydration callback on
      `VaultStore`. - `recover()` — called from `KmdbDatabase.open()` after WAL
      replay: scans `$$vault:extract` for `extracting` blobs and applies Q6
      recovery logic; checks model version against active model; identifies blobs
      with `$vault` ref entries but no `$$vault:extract` and marks them `pending`.
      - `queueBlob(String sha256, String mediaType)` — writes `$$vault:extract` as
      `pending` and pushes to the isolate queue. -
      `_processResult(VaultIndexResult)` — **if `embeddingModel != null`, embeds
      each chunk on the main isolate (`await embeddingModel.embed(chunkText)`,
      mirroring `VecManager._embed`) and quantises to SQ8** (the isolate returned
      no vectors, RQ-5); then writes filesystem artifacts; then commits
      `WriteBatch`. - `vaultIndexingStatus()` — scans `$$vault:extract`
      for counts; computes `stub` count by cross-referencing `$vault` ref-count
      entries (all known blobs) against `$$vault:extract` entries (downloaded
      blobs only). - `watchVaultIndexingStatus()` — wraps a `StreamController`
      that emits on each status change. - `reindexVault()` — resets all
      `indexed` blobs to `pending`, returns count. - `close()` — graceful
      shutdown of the isolate.
- [x] Write integration tests using `FaultyStorageAdapter` for each crash
      scenario in the edge-case table (crash at each write step in the
      sequence). These tests are the most critical coverage item for this WI.

**Step 8 — `searchVault()` query engine:**

- [x] Add `src/vault/search/vault_searcher.dart` — `VaultSearcher<T>`: -
      `searchLexical()`: reads `$vault:docref:{sha256}` to find candidate sha256
      hashes for the collection; for each, reads BM25 term entries from
      `$$vault:fts:`; scores chunks using BM25 with `n` (chunkCount) from the
      corpus sentinel and `df` computed dynamically by counting chunk-index keys
      in `$$vault:fts:{sha256}:{hexTerm}` (mirrors `FtsManager`,
      `fts_manager.dart:765/989` — see "BM25 IDF/document-frequency"); TF from
      per-chunk entries; deduplicates chunks to blob (max score per sha256);
      deduplicates blobs to document (max blob score per docId); fetches
      documents; reads snippets. - `searchSemantic()`: embeds query using active
      model; brute-force dot-product scan over `$$vault:vec:idx` entries for candidate
      sha256 hashes; deduplication to document level as above. -
      `searchHybrid()`: runs both legs; applies RRF (k=60, as in §23);
      deduplicates and fetches. - Snippet retrieval: read
      `extract/chunks_v1.json` for offsets, read `extract/text.txt`, slice byte
      range, decode UTF-8.
- [x] Add `searchVault()` method to `KmdbCollection<T>`.
- [x] Write query tests: lexical match, semantic match (with mock embedding
      model), hybrid, empty result, `limit`/`offset`, lexical-only mode with
      `mode: semantic` (graceful degradation), query against collection with no
      vault refs.

**Step 9 — Wire into `KmdbDatabase`:**

- [x] Edit `KmdbDatabase.open()`: accept `VaultSearchConfig? vaultSearch`
      parameter; instantiate `VaultSearchManager` if non-null; call
      `manager.recover()` after WAL replay; attach manager to `VaultStore`.
- [x] Add `KmdbDatabase.vaultIndexingStatus()`, `watchVaultIndexingStatus()`,
      and `reindexVault()` methods delegating to `VaultSearchManager`.
- [x] Verify `KmdbDatabase.close()` calls `VaultSearchManager.close()` to drain
      the isolate.

**Step 10 — Confirm sync exclusion:**

- [x] Verify all vault search namespace constants in `vault_namespaces.dart`
      carry the `$$` prefix. `isLocalOnly('$$vault:fts:...')`, `isLocalOnly('$$vault:vec:...')`,
      and `isLocalOnly('$$vault:extract:...')` must all return `true`; no
      sync-engine code changes are required.
- [x] Verify `$vault:docref:` has a single `$` prefix: `isLocalOnly('$vault:docref:...')`
      must return `false` (it syncs normally).
- [x] Write a sync-exclusion test: open a db, ingest and index a blob, flush,
      then inspect the SSTable files: (a) assert no regular `.sst` file contains
      `$$vault:fts:`, `$$vault:vec:`, or `$$vault:extract:` keys; (b) assert
      `$vault:docref:` keys ARE present in the syncable `.sst` file.
      (Tests in `test/vault/search/vault_sync_exclusion_test.dart`.)

**Step 11 — GC integration:**

> **Seam correction (2026-06-22 review).** `VaultGc` is **two-phase**:
> `onZeroRefs` writes a tombstone inside the document's ref-count `WriteBatch`,
> but the actual blob deletion happens later in `VaultGc.sweep()`
> (`vault_gc.dart:110`), which calls `store.deleteHashDir(sha256)` directly on
> the filesystem with **no `WriteBatch` in scope**. There is no "GC `WriteBatch`"
> to piggy-back on. Derived-entry cleanup must therefore live in `sweep()`, at
> the point a blob is actually deleted (the two `deleteHashDir` branches), and
> needs its own `WriteBatch` committed to the `KvStore` that `VaultGc` already
> holds (`kvStore`).

- [x] In `VaultGc.sweep()`, at each point a blob is deleted (`RefCountAbsent`
      and `RefCountValue(count == 0)` branches), additionally: build a
      `WriteBatch` deleting all `$$vault:fts:{sha256}:*`, `$$vault:vec:idx`
      `{sha256}:*`, `$vault:docref:{sha256}` (all docId sub-keys), and
      `$$vault:extract:{sha256}` entries for that sha256, and commit it. Deleting
      a per-term/per-chunk namespace requires a scan to enumerate keys (mirror how
      FTS removes per-term base entries). Encrypt via the `encryption` provider
      `VaultGc` already carries (for `$vault:docref:`, which is syncable).
      Implementation note: VaultGc.searchStore optional parameter added to
      decouple ref-count reads (sha256 keys, KvStore mock) from vault search
      cleanup (KvStoreImpl required).
- [x] Delete the `extract/` directory for GC'd blobs (filesystem) inside the
      same `sweep()` deletion path, alongside `deleteHashDir`.
- [x] If `VaultSearchManager` is not configured (db opened without
      `vaultSearch`), this cleanup is a harmless no-op scan (no `$$vault:*`
      entries exist) — `VaultGc` does not need a hard dependency on
      `VaultSearchManager`; it operates on namespaces directly.
- [x] Write a test: ingest blob, index it, drop the last reference, run
      `sweep()`, assert the blob dir, the `extract/` dir, and all `$$vault:*` and
      `$vault:docref:` entries for that sha256 are removed.
      (Tests in `test/vault/search/vault_gc_search_integration_test.dart`.)

**Step 12 — Exports and public API:**

- [x] Export new public types from `packages/kmdb/lib/kmdb.dart`:
      `VaultSearchConfig`, `VaultTextExtractor`, `PlainTextExtractor`,
      `VaultSearchResult`, `VaultSearchHit`, `VaultChunkContext`,
      `VaultIndexingStatus`.
- [x] Do **not** export internal types: `VaultSearchManager`,
      `VaultIndexingIsolate`, `VaultBm25Writer`, `VaultVecWriter`,
      `vault_namespaces.dart`, `VaultExtractionState`.

**Step 13 — CLI commands:**

- [x] Add `kmdb vault search <query>` to `kmdb_cli` — requires `--collection`
      flag; prints hits with snippet and score.
      (`vault_search_command.dart`, tests in `vault_search_commands_test.dart`)
- [x] Add `kmdb vault reindex` — calls `db.reindexVault()`, prints queued count.
      (`vault_reindex_command.dart`)
- [x] Add `kmdb vault status` — calls `db.vaultIndexingStatus()`, prints table.
      (`vault_status_command.dart`; `command_metadata_test.dart` updated)

**Step 14 — Spec and docs:**

- [x] Create `docs/spec/32_vault_search.md` (32 = next available after 31)
      covering: overview, storage layout, lifecycle state machine, startup
      recovery sequence, isolate architecture and crash-safety guarantees, sync
      exclusion rules, API reference, encryption compatibility note, and a
      "Multi-device model independence" section noting that: each device builds
      its own index with its locally configured embedding model; different
      devices may use different models without correctness issues because vector
      search is always local and vector spaces are never compared across
      devices; lexical search (`$$vault:fts:`) produces identical results across
      devices for the same downloaded blobs regardless of model choice; and
      `$vault:docref` (document→blob mapping) is synced and consistent across
      all devices even though the derived search indexes are not.
- [x] Update `docs/spec/20_text_search.md`: added forward reference to §32.
- [x] Update `docs/spec/24_vault.md`: added "Vault Search Integration" section
      describing the `extract/` subdirectory and noting it is not synced.
- [x] Add glossary entries to `docs/spec/99_glossary.md`: `VaultTextExtractor`,
      `VaultSearchManager`, `VaultSearchConfig`, `$$vault:fts:`, `$$vault:vec:idx`,
      `chunk (vault)`.
- [x] Add release-checklist entry RC-21 in `docs/spec/28_release_checklist.md`:
      "Vault search isolate crash recovery — kill process at each write step and
      verify startup recovery rebuilds correctly on a real OS."
- [x] Update `docs/roadmap/0_06.md` WI-3 row: Status → Implementing.

**Step 15 — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new files.
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [x] Verify licence headers on all new files (2026).

## Summary

- Implemented `VaultSearchManager` — background Isolate pipeline that extracts
  text from `text/plain` vault blobs, chunks into ≤500-token segments, indexes
  via BM25 (`FtsManager`) and optional dense embeddings (`VecManager`), and
  persists extraction state in the `$$vault:extract:{sha256}` namespace.
- Added `VaultSearchConfig` (+ `VaultSearchConfigBuilder`) to `KmdbDatabase.open()`
  for opt-in enablement; database opens without vault search unless the config is
  supplied.
- Exposed `KmdbCollection.searchVault()` method for hybrid/lexical/semantic search
  over vault content; results are `VaultSearchResult` carrying document key, chunk
  offset, and score.
- Added `KmdbDatabase.vaultIndexingStatus` / `watchVaultIndexingStatus()` for
  observing indexing progress (`VaultIndexingStatus`).
- Introduced three new local-only KV namespaces: `$$vault:extract:{sha256}` (state
  machine), `$$vault:fts:{sha256}:{term}` (BM25 postings), `$$vault:vec:{sha256}`
  (chunk embeddings).
- Added `recover()` to rebuild pending state on crash restart — scans `$vault`
  namespace for blobs missing an extract entry and re-enqueues them.
- CLI: added `kmdb vault search <query>` and `kmdb vault indexing-status` sub-commands.
- New spec section §32 (`docs/spec/32_vault_search.md`) documents the full
  architecture, namespace layout, state machine, and public API surface.
- Updated §20, §24, §28, and §99 to cross-reference vault search.
