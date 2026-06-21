# WI-3: Vault search — core

**Status**: Questions

**PR link**: —

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
DEK-keyed HMAC tokens (`$fts:{ns}:{field}:{hmacToken}`) to close vocabulary
enumeration leakage. The vault-specific `$vfts:{sha256}:{hexTerm}` namespaces
introduced here have the same leakage characteristic. If the v0.08 Gap B work
lands before WI-3 is implemented, vault FTS should adopt HMAC tokens from day
one (no migration needed). If WI-3 ships first with plaintext hex terms, a
migration will be required when Gap B is applied. Coordinate with the v0.08 plan
author to minimise migration cost.

## Open questions

The seven proposal §8 questions are resolved in the Investigation section. The
review below (2026-06-21) surfaced **new** blocking questions that must be
resolved before this plan can reach `Investigated`:

- [ ] **RQ-1 (BLOCKING): Sync exclusion is built on a false premise.** Replace
      the entire sync-exclusion design with the §20.7 model: index namespaces
      ride in SSTables and are kept private by §31 value-level encryption, not by
      a sync-engine filter. See review §"Architecture Fit". Specifically decide
      and document: (a) do `$vfts:`/`$vvec:`/`$vault:extract` simply ride along
      in SSTables like `$fts:`/`$vec:` (yes, per §20.7 — so Step 10 must be
      rewritten, not "extend the exclusion list")? (b) confirm `$vault:extract`
      riding to the cloud is benign (it carries extraction status/charset/model
      version per blob — is that an acceptable leak, and does it cause incorrect
      behaviour on a peer that has the SSTable but not the blob?).
- [ ] **RQ-2 (BLOCKING): `VaultSearchHit extends SearchHit` will not compile.**
      `SearchHit<T>` is a `final class` (not extendable) and its fields are
      `rank, score, fieldScores, id, document` — not the `key, scores` the
      plan's constructor passes via `super.key`/`super.scores`. Decide the real
      result-type shape (see review §"Implementation Readiness").
- [ ] **RQ-3 (BLOCKING): Two embedding-model parameters, unreconciled.**
      `KmdbDatabase.open()` already takes `EmbeddingModel? embeddingModel` (used
      by `VecManager`). This plan adds a *second* one inside `VaultSearchConfig`.
      Decide: does vault search reuse the database-level model, or is an
      independent model genuinely intended? If independent, justify it and state
      how lifecycle/`dispose` ownership is split.
- [ ] **RQ-4: `VaultRefInterceptor` extension does not match the real seam.**
      `interceptWrite()` operates on `{batch, namespace, docKey, newDoc, oldDoc}`
      and computes added/removed sha256 sets internally — it never sees a
      `sha256`/`docId` pair as Step 4 describes. Restate the extension in terms
      of the actual `WriteAugmentor.interceptWrite` contract, including how
      `docKey` maps to the `{docId}` key segment and how the field path is
      recovered from `_extractVaultUris` (which today returns only sha256s, not
      their field paths — a non-trivial change).
- [ ] **RQ-5: First Isolate in KMDB vs. the synchronous-engine invariant.** The
      plan introduces background-isolate indexing. §18 establishes KMDB as a
      synchronous, no-background-isolate engine (compaction is on the write
      path). Confirm with kmdb-architect that a search-indexing isolate is an
      acceptable boundary (it does not touch the LSM write path; it hands results
      back to the main isolate which commits) and document that boundary
      explicitly so it is not read as licence to move storage work off-thread.

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

**FATAL — sync exclusion contradicts §20.7 (RQ-1).** The plan's "New storage
namespaces" section and Step 10 instruct the implementer to "Locate the
namespace-exclusion list in the sync engine" and "add `$vfts:`, `$vvec:`,
`$vault:extract` to the exclusion list," citing "`$fts:`, `$vec:` exclusion in
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
`$vfts:`/`$vvec:idx`. Step 10 should not "extend an exclusion list"; it should
verify these namespaces are encrypted under §31 when encryption is on, and the
test in Step 10 must be rewritten (you cannot assert `$vfts:` keys are "absent
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

- **`$vault:extract` syncing to peers.** Once RQ-1 is resolved and you accept
  these namespaces ride in SSTables, you inherit a new scenario the table does
  not cover: a peer receives an SSTable containing device-A's `$vault:extract`
  entry (status `indexed`, model X) for a blob that device B has not downloaded
  (a stub on B). B's `vaultIndexingStatus()` and recovery logic must not treat
  that foreign `$vault:extract` entry as "this blob is indexed locally." The
  `stub`-detection logic ("`$vault` ref but no `$vault:extract`") breaks if
  `$vault:extract` entries arrive via sync. This needs an explicit answer.
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
  `$vfts:corpus:{sha256}` stores only `{n: chunkCount, totalTokens}` per blob —
  document frequency (how many chunks contain a term) is needed for IDF and is
  not in the schema. Specify where DF comes from, or the BM25 math is
  unimplementable as written.
- `searchVault()` per-blob brute-force vector scan is fine for small corpora;
  note the expected scale and that this is O(chunks) per query, consistent with
  the existing `VecManager` full-scan approach.

### Recommendations

Reconsider-and-revise, do not proceed. The core architecture is salvageable and
mostly good; the failures are at the integration boundary and are correctable:

1. Rewrite the sync story around §20.7 (ride-in-SSTables + §31 encryption),
   delete the "exclusion list" framing, and rewrite the Step 10 test.
2. Redo the `VaultSearchHit` result type against the real `SearchHit`.
3. Reconcile the embedding-model parameter with the existing `open()` seam.
4. Restate the `VaultRefInterceptor` and `_extractVaultUris` changes against the
   real signatures, including field-path recovery.
5. Add the peer-`$vault:extract`/stub-detection scenario to the edge-case table.
6. Confirm the isolate boundary with kmdb-architect and specify cancellation.

Once RQ-1 through RQ-4 are resolved in the plan text (RQ-5 confirmed), this is a
strong candidate for `Investigated`.

## Investigation

### Current state

The vault (`packages/kmdb/lib/src/vault/`) stores content-addressable blobs with
ref-count tracking but has no text extraction or search capability. The
document-field search subsystem (`packages/kmdb/lib/src/search/`) provides BM25
(`FtsManager`) and vector (`VecManager`) search over String document fields,
using `$fts:` and `$vec:` KV namespaces respectively. The two subsystems are
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
real time. Both are implemented by scanning the `$vault:extract` namespace.

**Q5 — Stub blob interaction.** Decision: Event-driven (not polling).
`VaultStore` gains an internal `_onBlobHydrated` callback field (a
`void Function(String sha256)?`). After a successful on-demand hydration inside
`getBytes()`, the store invokes this callback.
`VaultSearchManager.attach(VaultStore)` registers itself as that callback at
database open time, queuing the newly hydrated blob as `pending`. No isolate
polling loop is introduced.

**Q6 — LSM scan index rebuild.** Decision: Handled inside startup recovery
(`VaultSearchManager._recover()`). For each `$vault:extract` entry with status
`extracting` (crash mid-index):

1. Check filesystem: does `extract/text.txt`, `extract/chunks_v1.json`, and
   `extract/vectors_{activeModelId}_sq8.bin` all exist?
2. If yes → rebuild `$vfts:`, `$vvec:idx`, and `$vault:extract` entries from
   filesystem artifacts (no re-embedding). Mark blob `indexed`.
3. If no → reset to `pending` for full re-extraction.

This unified path also handles the "database moved / `$vvec:idx` missing but
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
    ├─ VaultIndexingIsolate          background Dart Isolate
    │      ├─ VaultTextExtractor     PlainTextExtractor in v1
    │      └─ VaultChunker           chunking + offset computation
    ├─ VaultBm25Writer               writes $vfts: namespace
    └─ VaultVecWriter                writes $vvec:idx namespace
```

#### Data flow

1. `VaultStore.ingest()` completes → `VaultRefInterceptor` writes
   `$vault:docref` + ref count (same `WriteBatch`) → `VaultSearchManager` queues
   blob as `pending` (writes `$vault:extract` key).
2. `VaultSearchManager` sends work item (sha256, mediaType, blob bytes) to the
   `VaultIndexingIsolate` via `SendPort`. The bytes are read by the main isolate
   using `VaultStore.getBytes()` **before** the send — this keeps encryption
   handling on the main isolate and avoids passing DEK material across the
   isolate boundary. For text/plain blobs this is acceptable; document this as a
   known design constraint.
3. Isolate: extracts text → chunks → (if embeddingModel ≠ null) embeds chunks →
   sends back a `VaultIndexResult` message containing: CBOR payload for
   `$vault:extract`, BM25 term entries, SQ8 vectors, and filesystem write
   payloads.
4. Main isolate: applies filesystem writes (text.txt, chunks*v1.json,
   vectors*\*.bin, extract_status.json), then commits a `WriteBatch` with all
   LSM entries. The filesystem writes come first; if the process crashes between
   them and the `WriteBatch`, startup recovery rebuilds from the filesystem (Q6
   path).
5. `searchVault()`: reads `$vault:docref` to find referenced sha256 hashes →
   scores chunks via BM25 (`$vfts:`) and/or dot-product (`$vvec:idx`) →
   deduplicates to blob level → deduplicates to document level → fetches
   documents → reads snippets from `extract/text.txt` using offsets from
   `extract/chunks_v1.json`.

#### Encryption compatibility

`VaultStore.getBytes()` already handles encrypted blobs (Phase 12). The indexing
isolate receives the raw (decrypted) bytes — it never touches ciphertext or the
`EncryptionProvider`. This is the correct boundary.

**LSM entries (`$vfts:`, `$vvec:idx`)** are written via `WriteBatch` through the
normal `ValueCodec.encode(encryption:)` path. When encryption is active they are
encrypted automatically, consistent with the existing `$fts:` and `$vec:`
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

`VaultSearchManager` holds a reference to the active `EmbeddingModel` (or `null`
for lexical-only mode). During startup recovery, for each `$vault:extract` entry
with status `indexed`:

- Read `modelVersion` from the stored CBOR.
- If `embeddingModel != null && modelVersion != embeddingModel.modelId` → reset
  to `pending` (vectors are stale).
- If `embeddingModel == null && modelVersion != ''` → vectors are not needed in
  lexical-only mode; reset only the `$vvec:idx` entries; keep FTS entries; mark
  `indexed`.

### New storage namespaces

(Defined in `src/vault/search/vault_namespaces.dart`.)

| Namespace                  | Key                                                          | Value                                                                                        |
| -------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `$vfts:{sha256}:{hexTerm}` | chunk index (8-digit zero-padded hex)                        | CBOR int — term frequency in chunk                                                           |
| `$vfts:corpus:{sha256}`    | `"\x00"` (sentinel)                                          | CBOR `{n: chunkCount, totalTokens: N}`                                                       |
| `$vvec:idx`                | `{sha256}:{chunkIndex}` (chunkIndex 8-digit zero-padded hex) | 384-byte SQ8 vector                                                                          |
| `$vault:docref:{sha256}`   | `{docId}` (32-char hex UUIDv7)                               | CBOR string — field path                                                                     |
| `$vault:extract:{sha256}`  | `"\x00"` (sentinel)                                          | CBOR `{status, modelVersion?, chunkCount?, chunkingParams?, extractedAt?, error?, charset?}` |

All five namespaces are local-only (excluded from sync, consistent with `$fts:`,
`$vec:` exclusion in §20). The sync-exclusion prefix check in the sync engine
must be extended to cover `$vfts:`, `$vvec:`, and `$vault:extract`.

Note: `$vault:docref` must **not** be excluded from sync. Document→blob
references are part of the document graph and must reach other devices. The
existing `$vault` ref-count namespace (maintained by `VaultRefInterceptor`) is
already synced; `$vault:docref` follows the same rule.

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
    this.embeddingModel,
  });

  final List<VaultTextExtractor> extractors;
  final int chunkSize;
  final int chunkOverlap;
  final EmbeddingModel? embeddingModel; // null = lexical-only mode
}
```

Pass to `KmdbDatabase.open(vaultSearch: config)`. If omitted or `null`, no vault
search indexing occurs.

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
Future<SearchResult<VaultSearchHit<T>>> searchVault(
  String query, {
  SearchMode mode = SearchMode.auto,
  List<String>? fields,  // document field paths to consider; null = all VaultRef fields
  int limit = 10,
  int offset = 0,
})
```

Result type uses existing `SearchResult<T>` wrapper but `VaultSearchHit<T>` as
the element type.

#### New result types (new, in `src/vault/search/vault_search_hit.dart`)

```dart
final class VaultChunkContext {
  final VaultRef ref;
  final int chunkIndex;
  final int totalChunks;
  final String snippet;    // full chunk text from text.txt + offsets
  final String fieldPath;  // document field that held the VaultRef
}

final class VaultSearchHit<T> extends SearchHit<T> {
  const VaultSearchHit({
    required super.key,
    required super.document,
    required super.score,
    required super.scores,
    required this.chunkContext,
  });
  final VaultChunkContext chunkContext;
}
```

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

`stub` is populated by cross-referencing `$vault:extract` entries (which only
exist for downloaded blobs) against `$vault` ref-count entries (which exist for
all known blobs, including stubs). Blobs with a `$vault` ref count but no
`$vault:extract` entry are stubs.

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
5. Apply `WriteBatch` to LSM: `$vfts:`, `$vvec:idx`, `$vault:extract`

Step 5 is atomic (single `WriteBatch`). A crash between steps 1–4 and step 5
leaves `$vault:extract` in `extracting` state. On startup recovery, the manager
checks filesystem completeness (step 6 above in Q6 resolution) and either
rebuilds from files or resets to `pending`. Tests must exercise each crash
point.

`$vault:extract` is written **first** as `extracting` before the isolate starts
work (in step 0, before the filesystem writes). This ensures the blob is not
re-queued by a concurrent `open()` on another database handle during a long
extraction.

#### `VaultRefInterceptor` extension

`interceptWrite()` is extended to also write/delete `$vault:docref:{sha256}`
entries alongside the existing `$vault` ref-count operations. Since both
operations target the same `WriteBatch`, they remain atomic. Value is CBOR
string of the field path. If a document references the same sha256 via multiple
fields, the first encountered field path is stored (documented limitation; a
CBOR list upgrade is a v2 enhancement).

#### Sync exclusion

The sync engine (`SyncEngine`) uses a prefix check to exclude local-only
namespaces. The check must cover:

- `$vfts:` (new — vault BM25 terms)
- `$vvec:` (new — vault vector scan index)
- `$vault:extract` (new — extraction status)

`$vault:docref` must **not** be excluded — it carries semantic information about
which documents reference which blobs and must sync normally.

Review the sync engine's namespace-exclusion list and add the three new
prefixes. The existing exclusion patterns for `$fts:` and `$vec:` are the
reference.

#### Lexical-only mode (`embeddingModel: null`)

When `embeddingModel` is `null`:

- The indexing isolate skips embedding steps entirely.
- No `vectors_*.bin` file is written.
- `$vvec:idx` entries are not written.
- `modelVersion` in `extract_status.json` and `$vault:extract` is `""`.
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
| Stub blob at index time                                              | No `$vault:extract` entry written; blob counted in `VaultIndexingStatus.stub`; absent from search results                                                                |
| Stub hydrated mid-session                                            | `VaultStore` callback → `VaultSearchManager` queues sha256 as `pending`; `stub` count decrements, `pending` increments                                                   |
| Device with many stubs — `searchVault()` called                      | Results are silently incomplete; caller must check `VaultIndexingStatus.stub > 0` to surface a warning                                                                   |
| Embedding model changes between sessions                             | Startup recovery: `modelVersion` mismatch → reset to `pending`; full re-index                                                                                            |
| `reindexVault()` called during active indexing                       | Cancel in-flight isolate work; reset all `indexed` blobs to `pending`; restart isolate                                                                                   |
| `text/plain` blob with Windows-1252 encoding                         | `PlainTextExtractor` uses `decodeText()` (WI-2); correctly decoded; `charset` stored                                                                                     |
| `text/plain` blob with no registered extractor?                      | Impossible: `PlainTextExtractor` is always in the default extractor list                                                                                                 |
| Non-text blob (e.g. `image/png`)                                     | No extractor matches; status written as `unsupported`; blob accessible normally                                                                                          |
| Empty blob (`""`)                                                    | Extracted text is empty string; 0 chunks; status `indexed` with `chunkCount: 0`                                                                                          |
| Blob referenced by two documents                                     | `$vault:docref` has two entries (one per docId); both returned in `searchVault()` results                                                                                |
| GC of indexed blob                                                   | `VaultGc` deletes the `extract/` directory; `VaultSearchManager` deletes `$vfts:`, `$vvec:idx`, `$vault:docref`, `$vault:extract` entries in same `WriteBatch` as the GC |
| Database opened without `vaultSearch` on a db that previously had it | `$vault:extract` entries remain (harmless); search not available; no startup crash                                                                                       |
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
`VaultSearchManager`, `VaultSearchConfig`, `$vfts:`, `$vvec:`, `chunk`.

The release checklist (`28_release_checklist.md`) should receive an entry:
"RC-N: Vault search isolate crash recovery — verify on real OS with process kill
at each write step" (not feasible in automated CI).

## Implementation plan

**Prerequisites — complete first:**

- [ ] Implement WI-2 (`charset_util.dart` + `betto_charset_detector` dependency)
      if not already merged. Confirm `decodeText` function is available in
      `src/vault/search/charset_util.dart`.

**Step 1 — Core types and config:**

- [ ] Add `src/vault/search/vault_text_extractor.dart` — `VaultTextExtractor`
      interface and `VaultManifest` import.
- [ ] Add `src/vault/search/plain_text_extractor.dart` — `PlainTextExtractor`
      implementing `VaultTextExtractor`; uses `decodeText()` from WI-2; stores
      detected charset in returned `CharsetDecodeResult`.
- [ ] Add `src/vault/search/vault_search_config.dart` — `VaultSearchConfig` with
      `extractors`, `chunkSize`, `chunkOverlap`, `embeddingModel`.
- [ ] Add `src/vault/search/vault_namespaces.dart` — const strings for all five
      namespaces (`$vfts:`, `$vvec:idx`, `$vault:docref:`, `$vault:extract`).
- [ ] Add `src/vault/search/vault_extraction_state.dart` —
      `VaultExtractionStatus` enum and `VaultExtractionState` record.

**Step 2 — Chunking pipeline:**

- [ ] Add `src/vault/search/vault_chunk.dart` — `VaultChunk` record
      `{index, byteStart, byteEnd, wordCount}`.
- [ ] Add `src/vault/search/vault_chunker.dart` — `VaultChunker` class;
      tokenises text using `RegExpTokenizer` from `betto_lexical`; slides window
      of `chunkSize` words with `chunkOverlap` overlap; computes byte offsets in
      the UTF-8-encoded text string.
- [ ] Write unit tests in `test/vault/search/vault_chunker_test.dart` covering:
      empty text, text smaller than one chunk, exact chunk size, multiple chunks
      with overlap, non-ASCII (multi-byte UTF-8 characters verify byte offset
      correctness).

**Step 3 — Search result types:**

- [ ] Add `src/vault/search/vault_search_hit.dart` — `VaultChunkContext` and
      `VaultSearchHit<T>` extending `SearchHit<T>`.
- [ ] Add `src/vault/search/vault_indexing_status.dart` — `VaultIndexingStatus`.

**Step 4 — Extend `VaultRefInterceptor`:**

- [ ] Edit `src/vault/vault_ref_interceptor.dart`: in `interceptWrite()`, after
      the existing ref-count increment/decrement logic, also write/delete
      `$vault:docref:{sha256}` / `{docId}` → CBOR field-path string. Document
      the "first field path wins" limitation.
- [ ] Write tests covering: insert doc with VaultRef → docref entry written;
      update doc (old ref removed, new ref added) → old docref deleted, new
      written; delete doc → docref deleted; doc with two different VaultRef
      fields → both sha256 entries written.

**Step 5 — Indexing isolate:**

- [ ] Add `src/vault/search/vault_indexing_isolate.dart` —
      `VaultIndexingIsolate` class encapsulating the Dart `Isolate`: -
      `_entryPoint(SendPort reply)` static function (Isolate main). - Receives
      `VaultWorkItem` (sha256, mediaType, bytes, chunkSize, chunkOverlap,
      modelId? if embeddingModel is null). - Calls appropriate
      `VaultTextExtractor.extract()`. - Calls `VaultChunker.chunk()`. - If
      embeddingModel ≠ null: embed each chunk using the model, quantise to
      SQ8. - Returns `VaultIndexResult` via `SendPort`: filesystem write
      payloads + BM25 term map + SQ8 vector bytes + final status. -
      `VaultIndexingIsolate` is spawned lazily (first `pending` work item). -
      Shutdown is graceful: drain in-flight work before the database closes.
- [ ] Write unit tests for the isolate entry-point function directly (not
      spawned), testing all extractor paths and the chunked embedding output.

**Step 6 — `VaultBm25Writer` and `VaultVecWriter`:**

- [ ] Add `src/vault/search/vault_bm25_writer.dart` — writes BM25 term entries
      (`$vfts:{sha256}:{hexTerm}` and `$vfts:corpus:{sha256}`) into a
      `WriteBatch`. Mirrors `FtsManager`'s term-encoding pattern.
- [ ] Add `src/vault/search/vault_vec_writer.dart` — writes `$vvec:idx` /
      `{sha256}:{chunkIndex}` entries into a `WriteBatch`. SQ8 vectors are 384
      bytes for the current model; the writer is dimension-agnostic (length
      derived from the model's `dimensions` property).
- [ ] Write unit tests for each writer verifying key format, value encoding, and
      `WriteBatch` contents.

**Step 7 — `VaultSearchManager`:**

- [ ] Add `src/vault/search/vault_search_manager.dart` — `VaultSearchManager`: -
      Constructed with `VaultSearchConfig`, `KvStore`, `VaultStore`. -
      `attach()` registers the hydration callback on `VaultStore`. - `recover()`
      — called from `KmdbDatabase.open()` after WAL replay: scans
      `$vault:extract` for `extracting` blobs and applies Q6 recovery logic;
      checks model version against active model; identifies blobs with `$vault`
      ref entries but no `$vault:extract` and marks them `pending`. -
      `queueBlob(String sha256, String mediaType)` — writes `$vault:extract` as
      `pending` and pushes to the isolate queue. -
      `_processResult(VaultIndexResult)` — writes filesystem artifacts, then
      commits `WriteBatch`. - `vaultIndexingStatus()` — scans `$vault:extract`
      for counts; computes `stub` count by cross-referencing `$vault` ref-count
      entries (all known blobs) against `$vault:extract` entries (downloaded
      blobs only). - `watchVaultIndexingStatus()` — wraps a `StreamController`
      that emits on each status change. - `reindexVault()` — resets all
      `indexed` blobs to `pending`, returns count. - `close()` — graceful
      shutdown of the isolate.
- [ ] Write integration tests using `FaultyStorageAdapter` for each crash
      scenario in the edge-case table (crash at each write step in the
      sequence). These tests are the most critical coverage item for this WI.

**Step 8 — `searchVault()` query engine:**

- [ ] Add `src/vault/search/vault_searcher.dart` — `VaultSearcher<T>`: -
      `searchLexical()`: reads `$vault:docref:{sha256}` to find candidate sha256
      hashes for the collection; for each, reads BM25 term entries from
      `$vfts:`; scores chunks using BM25 (IDF from corpus sentinel, TF from
      per-chunk entries); deduplicates chunks to blob (max score per sha256);
      deduplicates blobs to document (max blob score per docId); fetches
      documents; reads snippets. - `searchSemantic()`: embeds query using active
      model; brute-force dot-product scan over `$vvec:idx` entries for candidate
      sha256 hashes; deduplication to document level as above. -
      `searchHybrid()`: runs both legs; applies RRF (k=60, as in §23);
      deduplicates and fetches. - Snippet retrieval: read
      `extract/chunks_v1.json` for offsets, read `extract/text.txt`, slice byte
      range, decode UTF-8.
- [ ] Add `searchVault()` method to `KmdbCollection<T>`.
- [ ] Write query tests: lexical match, semantic match (with mock embedding
      model), hybrid, empty result, `limit`/`offset`, lexical-only mode with
      `mode: semantic` (graceful degradation), query against collection with no
      vault refs.

**Step 9 — Wire into `KmdbDatabase`:**

- [ ] Edit `KmdbDatabase.open()`: accept `VaultSearchConfig? vaultSearch`
      parameter; instantiate `VaultSearchManager` if non-null; call
      `manager.recover()` after WAL replay; attach manager to `VaultStore`.
- [ ] Add `KmdbDatabase.vaultIndexingStatus()`, `watchVaultIndexingStatus()`,
      and `reindexVault()` methods delegating to `VaultSearchManager`.
- [ ] Verify `KmdbDatabase.close()` calls `VaultSearchManager.close()` to drain
      the isolate.

**Step 10 — Sync exclusion:**

- [ ] Locate the namespace-exclusion list in the sync engine (search for `$fts:`
      in `SyncEngine` / `HighwaterMark` / `CloudAdapter`).
- [ ] Add `$vfts:`, `$vvec:`, and `$vault:extract` to the exclusion list.
- [ ] Confirm `$vault:docref` is **not** excluded (it must sync).
- [ ] Write a test that exercises the exclusion: create a db, ingest a blob,
      assert that `$vfts:` keys are absent from the set of keys that would be
      uploaded, and that `$vault:docref:` keys are present.

**Step 11 — GC integration:**

- [ ] Edit `VaultGc` to also delete `$vfts:`, `$vvec:idx`, `$vault:docref:`, and
      `$vault:extract` entries for GC'd blobs in the same `WriteBatch` as the GC
      operation.
- [ ] Delete the `extract/` directory for GC'd blobs.
- [ ] Write a test: ingest blob, index it, GC it, assert all derived entries are
      removed.

**Step 12 — Exports and public API:**

- [ ] Export new public types from `packages/kmdb/lib/kmdb.dart`:
      `VaultSearchConfig`, `VaultTextExtractor`, `PlainTextExtractor`,
      `VaultSearchHit`, `VaultChunkContext`, `VaultIndexingStatus`.
- [ ] Do **not** export internal types: `VaultSearchManager`,
      `VaultIndexingIsolate`, `VaultBm25Writer`, `VaultVecWriter`,
      `vault_namespaces.dart`, `VaultExtractionState`.

**Step 13 — CLI commands:**

- [ ] Add `kmdb vault search <query>` to `kmdb_cli` — requires `--collection`
      flag; prints hits with snippet and score.
- [ ] Add `kmdb vault reindex` — calls `db.reindexVault()`, prints queued count.
- [ ] Add `kmdb vault status` — calls `db.vaultIndexingStatus()`, prints table.

**Step 14 — Spec and docs:**

- [ ] Create `docs/spec/NN_vault_search.md` (NN = next available after 31)
      covering: overview, storage layout, lifecycle state machine, startup
      recovery sequence, isolate architecture and crash-safety guarantees, sync
      exclusion rules, API reference, encryption compatibility note, and a
      "Multi-device model independence" section noting that: each device builds
      its own index with its locally configured embedding model; different
      devices may use different models without correctness issues because vector
      search is always local and vector spaces are never compared across
      devices; lexical search (`$vfts:`) produces identical results across
      devices for the same downloaded blobs regardless of model choice; and
      `$vault:docref` (document→blob mapping) is synced and consistent across
      all devices even though the derived search indexes are not.
- [ ] Update `docs/spec/20_text_search.md`: add a forward reference to the new
      vault search spec section.
- [ ] Update `docs/spec/24_vault.md`: add a paragraph noting that the `extract/`
      subdirectory is created and managed by vault search.
- [ ] Add glossary entries to `docs/spec/99_glossary.md`: `VaultTextExtractor`,
      `VaultSearchManager`, `VaultSearchConfig`, `$vfts:`, `$vvec:idx`,
      `chunk (vault)`.
- [ ] Add release-checklist entry in `docs/spec/28_release_checklist.md`: "RC-N:
      Vault search isolate crash recovery — kill process at each write step and
      verify startup recovery rebuilds correctly on a real OS."
- [ ] Update `docs/roadmap/0_06.md` WI-3 row: Status → Implementing, Plan → link
      to this file.

**Step 15 — Coverage and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Summary

_(to be completed after implementation)_
