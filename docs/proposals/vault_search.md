# Technical Proposal: Vault File Search

## 1. Overview

The vault (§24) provides content-addressable binary object storage for file
attachments. Today, the text search subsystem (§20–23) indexes only `String`
fields on documents — vault blob _content_ is opaque to the search engine. This
proposal defines an architecture for making text inside vault blobs searchable
using the same lexical and semantic modes already provided by
`KmdbCollection.search()`.

### Goals

- Index plain-text vault content for lexical (BM25) and semantic (vector)
  search.
- Expose a search API consistent with the existing `KmdbCollection.search()`
  surface.
- Provide a pluggable text extraction interface so that additional format
  support (HTML, PDF, etc.) can be added in separate packages without changes to
  the core library.
- Keep all indexing local and offline-capable, consistent with kmdb's
  local-first design principles.

### Non-goals (v1)

- Text extraction for non-plain-text formats (HTML, Markdown, PDF, DOCX). These
  are explicitly deferred; see §8.
- Web platform support (consistent with §20–23 exclusion of web for FTS and
  vector search).
- Syncing computed index artifacts (vectors, inverted index terms) across
  devices. Each device builds its own index independently.
- Multilingual support beyond English. Both the default embedding model (BGE
  Small En v1.5) and the BM25 tokenization pipeline (§21) are English-oriented.
  A multilingual path requires charset detection, language detection, an
  alternative embedding model, and a language-aware tokenizer; these are
  addressed in §10 (Multilingual Support).

---

## 2. Text Extraction

### 2.1 Supported formats in v1

Only `text/plain` (UTF-8) is supported in the initial implementation. The vault
`manifest.json` already carries the `mediaType` field detected by
`FreedesktopMediaTypeDetector` at ingest time (§24). This value is used to route
blobs to the appropriate extractor — in v1, any blob whose `mediaType` is not
`text/plain` is left unindexed, and the extraction status is recorded as
`unsupported` (see §4.2).

The indexing isolate (§5.2) is native-only and can run a second-pass media type
check using Google's Magika model (available as an example in `betto_onnxrt`).
Magika provides two signals not available from the rule-based detector:

- **`is_text` flag** — a direct gate on whether extraction is worth attempting,
  independent of MIME routing. A blob stored as `text/plain` whose Magika score
  is below a confidence threshold (e.g. 0.5) is skipped and recorded as
  `unsupported` rather than producing garbled index content.
- **Confidence score** — surfaced in `extract_status.json` under a `"detectorScore"`
  field for diagnostics, and usable by future format extractors to decide whether
  to attempt parsing ambiguous input.

The rule-based `FreedesktopMediaTypeDetector` remains the canonical detector at
ingest time (it works on all platforms including web). Magika is an optional
validation step within the indexing isolate only; it does not modify
`manifest.json`.

### 2.2 VaultTextExtractor interface

A `VaultTextExtractor` interface is defined in the core `kmdb` package:

```dart
abstract interface class VaultTextExtractor {
  /// The MIME types this extractor handles.
  Set<String> get supportedMediaTypes;

  /// Extract plain UTF-8 text from raw blob bytes.
  ///
  /// Returns null if extraction is not possible (e.g. encrypted or
  /// malformed input). The returned string must be valid UTF-8.
  Future<String?> extract(Uint8List bytes, VaultManifest manifest);
}
```

The concrete `PlainTextExtractor` (included in core) handles `text/plain` by
decoding the bytes as UTF-8, normalising line endings, and stripping BOM if
present.

### 2.3 Extractor package naming

Additional format extractors live in dedicated optional packages following the
convention `kmdb_extractor_<name>`, analogous to `betto_zstd` and
`betto_inferencing`. Examples:

| Package                   | Format            |
| ------------------------- | ----------------- |
| `kmdb_extractor_html`     | `text/html`       |
| `kmdb_extractor_markdown` | `text/markdown`   |
| `kmdb_extractor_pdf`      | `application/pdf` |

This is inspired by the Apache Tika approach of a pluggable, format-aware text
extraction layer. Each package is independently versioned and optional —
applications include only the extractors they need.

Extractors are registered at `KmdbDatabase.open()` time, alongside index and
schema definitions:

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  vaultSearch: VaultSearchConfig(
    extractors: [
      PlainTextExtractor(),       // included in kmdb
      // HtmlExtractor(),         // from kmdb_extractor_html
      // PdfExtractor(),          // from kmdb_extractor_pdf
    ],
    chunkSize: 300,               // words per chunk
    chunkOverlap: 50,             // word overlap between adjacent chunks
    embeddingModel: myModel,      // EmbeddingModel? — null disables semantic
  ),
),
```

If `vaultSearch` is omitted or `null`, no vault search indexing takes place.

---

## 3. Chunking

### 3.1 Why chunking is required

The BGE Small En v1.5 embedding model accepts at most 510 WordPiece tokens (≈
350–400 English words). Vault attachments — particularly plain-text files and
future PDF exports — can be arbitrarily long. The existing document-field vector
index silently truncates at this limit (§22), which is acceptable for short
document fields but unacceptable for file content.

Chunking divides extracted text into overlapping fixed-size segments. Each chunk
is embedded independently. At query time, the top-scoring chunks are retrieved
and deduplicated to document level; the winning chunk's text provides a result
snippet.

Lexical (BM25) search does not require chunking for correctness, but uses the
same chunk boundaries for snippet extraction.

### 3.2 Chunking algorithm

1. Tokenise extracted text into words using an `OffsetTokenizer` (`IcuTokenizer`
   by default; injectable for tests). **Implementation note (WI-6):** the
   originally-shipped chunker instead used a hand-rolled `\w+`-based `RegExp`
   with no Unicode flag, producing zero token spans (and a silently
   unsearchable, but still `indexed`, blob) for any text with no ASCII
   letters/digits — see §32's "Tokenisation (WI-6)" note for the fix and
   §21 Stage 1 for the shared `IcuTokenizer`/UAX #29 tokenizer this now
   matches.
2. Slide a window of `chunkSize` words with `chunkOverlap` words of overlap
   across the full token sequence.
3. For each window, record the byte start/end offsets in the original text so
   that the chunk text can be recovered for snippets without re-reading the
   blob.

Default parameters (configurable per `VaultSearchConfig`):

- `chunkSize`: 300 words
- `chunkOverlap`: 50 words

These values keep each chunk well inside the 510-token ceiling while maintaining
semantic continuity at boundaries.

---

## 4. Storage Layout

### 4.1 Vault filesystem: derived artifacts

Extracted text and computed artifacts are stored alongside the blob in an
`extract/` subdirectory of the blob's hash directory. This is a natural fit: the
artifacts are deterministically derived from the blob content, so they share the
same content-addressable identity. If the blob is GC'd, the `extract/` directory
is deleted with it.

```
{local-db-dir}/
  vault/
    blobs/
      sha256/
        {2-char prefix}/
          {62-char suffix}/
            manifest.json                         ← existing
            blob                                  ← existing (absent for stubs)
            tombstone.json                        ← existing (zero-ref marker)
            extract/
              text.txt                            ← extracted UTF-8 plain text
              chunks_v1.json                      ← chunk metadata (offsets, word counts)
              vectors_bge-small-en-v1.5_sq8.bin   ← packed SQ8 vectors, one per chunk
              extract_status.json                 ← extraction lifecycle state
```

The model name is encoded in the vector filename. If the embedding model
changes, old files are ignored and recomputed — no migration is needed. The
`_v1` suffix in `chunks_v1.json` similarly provides a versioning escape hatch
for the chunk schema.

The `extract/` directory is **never synced**. Each device builds its own index
independently (consistent with the `$fts:` and `$vec:` exclusion from sync in
§20).

#### `extract_status.json` schema

```jsonc
{
  "status": "indexed", // "pending" | "extracting" | "indexed" | "failed" | "unsupported"
  "modelVersion": "bge-small-en-v1.5",
  "chunkingParams": { "chunkSize": 300, "chunkOverlap": 50 },
  "chunkCount": 12,
  "extractedAt": "2026-04-22T...", // HLC timestamp
  "error": null,          // populated on "failed" status
  // Phase A (§10.1) — charset detection:
  "charset": "UTF-8",     // detected encoding, null if detection failed
  // §2.1 — Magika second-pass confidence:
  "detectorScore": 0.97,  // Magika confidence [0.0–1.0], null if not run
  // Phase B (§10.2) — language detection:
  "language": "en",       // BCP-47 tag, "und" if undetermined, null if not yet run
}
```

#### `chunks_v1.json` schema

```jsonc
[
  { "index": 0, "byteStart": 0,    "byteEnd": 1842, "wordCount": 300 },
  { "index": 1, "byteStart": 1612, "byteEnd": 3501, "wordCount": 300 },
  ...
]
```

Byte offsets reference `text.txt`, not the original blob. This allows snippet
retrieval without re-reading or re-extracting the blob.

### 4.2 LSM: search indexes

The vault filesystem holds the canonical, deduplicated artifacts. The LSM holds
two derived structures optimised for fast search:

#### Inverted index (lexical)

BM25 term lookup requires an inverted index — this cannot be expressed as a flat
file. Term entries follow the same pattern as the document FTS namespaces (§21)
but scoped to vault content:

| Namespace                  | Key                                   | Value                                  |
| -------------------------- | ------------------------------------- | -------------------------------------- |
| `$vfts:{sha256}:{hexTerm}` | chunk index (zero-padded 8-digit hex) | CBOR int — term frequency in chunk     |
| `$vfts:corpus:{sha256}`    | fixed sentinel                        | CBOR `{n: chunkCount, totalTokens: N}` |

The chunk index key ordering enables efficient per-term chunk enumeration.

#### Vector scan index (semantic)

Brute-force vector similarity search requires sequential access to all vectors
for all indexed blobs. The KV store's sequential scan is far more efficient than
per-file filesystem reads across hundreds of blob directories. The LSM scan
index is a compact cache of the vault vectors:

| Namespace   | Key                                   | Value                                    |
| ----------- | ------------------------------------- | ---------------------------------------- |
| `$vvec:idx` | `{sha256}:{chunkIndex}` (zero-padded) | SQ8-quantized 384-dim vector (384 bytes) |

The vault `extract/vectors_*.bin` file remains the **source of truth** — the LSM
entry is a derived cache. If the LSM index is absent but the vault vectors exist
(e.g. after a database move or import), the scan index can be rebuilt cheaply
from the vault files without re-embedding.

#### Reverse index and extraction state

| Namespace                 | Key            | Value                                   |
| ------------------------- | -------------- | --------------------------------------- |
| `$vault:docref:{sha256}`  | `{docId}`      | field path string (e.g. `"attachment"`) |
| `$vault:extract:{sha256}` | fixed sentinel | CBOR `{status, chunkCount?}`            |

`$vault:docref` is maintained by `VaultRefInterceptor` in the same `WriteBatch`
as the document write, consistent with how ref-counts are maintained today
(§24). This reverse index is the bridge from a matching vault blob back to the
documents that reference it.

`$vault:extract` mirrors the `extract_status.json` on-disk file in the KV store
for fast status queries without filesystem access (e.g. progress reporting,
re-index detection).

---

## 5. Indexing Lifecycle

### 5.1 States

Extraction and indexing follow a state machine per blob, parallel to the FTS
index lifecycle (§21):

```
pending
  → extracting   (isolate has claimed the blob)
  → indexed      (all artifacts written; LSM scan index populated)
  → failed       (extraction or embedding error; blob remains accessible)
  → unsupported  (mediaType not handled by any registered extractor)
```

State is persisted in both `extract_status.json` (canonical) and
`$vault:extract` (fast KV lookup). A blob transitions to `pending` immediately
after `VaultStore.ingest()` completes, if vault search is configured.

### 5.2 Async isolate

Extraction and embedding run in a dedicated Dart `Isolate` to avoid blocking the
main thread or UI. The isolate is spawned lazily when the first `pending` blob
is detected and kept alive as a worker pool for the database session.

The isolate receives:

- The blob's `sha256` and `mediaType`
- The vault root path (to locate the blob)
- Registered extractor instances (passed via `SendPort` / `Isolate.spawn`)
- Chunking parameters and embedding model reference

On completion, the isolate writes:

1. `extract/text.txt` — extracted text
2. `extract/chunks_v1.json` — chunk metadata
3. `extract/vectors_*.bin` — SQ8 vectors
4. `extract/extract_status.json` — final status
5. LSM writes via a `WriteBatch`: inverted index terms, `$vvec:idx` entries,
   `$vault:extract` status update

### 5.3 Stub blobs

A stub blob (manifest present, `blob` absent — §24 §5.2) cannot be extracted.
Vault search skips stubs; `extract_status.json` reflects `pending` until the
blob is hydrated. On hydration, the blob transitions back through the normal
`pending → extracting → indexed` flow.

### 5.4 Startup recovery

On `KmdbDatabase.open()`, the vault search manager scans `$vault:extract` for
blobs in `extracting` state (orphaned by a previous crash mid-indexing) and
resets them to `pending` before starting the indexing isolate. This mirrors WAL
replay recovery (§17).

---

## 6. Sync Behaviour

The `extract/` directory and all `$vfts:`, `$vvec:`, and `$vault:extract`
namespaces are **local-only** and excluded from sync. This is consistent with
the exclusion of `$fts:` and `$vec:` namespaces (§20).

The LSM scan index (`$vvec:idx`) is a derived cache of the vault vectors. When a
device receives a blob via vault sync (§24 §5.1) and the blob transitions from
stub to fully hydrated, the indexing isolate picks it up as `pending` and builds
the index locally. This means:

- Immediately after sync, vault search results on the receiving device may be
  incomplete — the blob is present but not yet indexed.
- The `$vault:extract` status key provides a signal that the application can
  expose to the user ("X files are still being indexed").
- The LSM sync index catches up quickly for short documents; long documents take
  proportionally longer.

This allows a fast sync of the LSM (SSTables) while vault content indexes build
in the background — an explicit design goal noted in the proposal discussion.

---

## 7. Search API

### 7.1 Result types

Vault search results extend the existing `SearchHit<T>` type with vault-specific
context:

```dart
final class VaultChunkContext {
  final VaultRef ref;
  final int chunkIndex;
  final int totalChunks;
  final String snippet;    // text of the matching chunk
  final String fieldPath;  // document field that held the VaultRef
}

final class VaultSearchHit<T> extends SearchHit<T> {
  final VaultChunkContext chunkContext;
}
```

### 7.2 API sketch

The initial API is a dedicated method on `KmdbCollection<T>` rather than
extending the existing `search()` to avoid conflating document-field scores with
chunk-level scores:

```dart
Future<SearchResult<VaultSearchHit<T>>> searchVault(
  String query, {
  SearchMode mode = SearchMode.hybrid,
  List<String>? fields,  // document fields to search; null = all VaultRef fields
  int limit = 10,
  int offset = 0,
})
```

Internally this:

1. Identifies all document IDs in the collection via `$vault:docref`.
2. For each referenced blob, scores chunks against the query (lexical via BM25,
   semantic via dot-product over SQ8 vectors, or hybrid via RRF — §23).
3. Deduplicates chunks to blob level, then to document level (max chunk score
   per blob; max blob score per document).
4. Fetches matching documents, attaches `VaultChunkContext` (including snippet
   from `extract/text.txt` + offsets from `chunks_v1.json`).

A future unification pass (see §8) could merge vault hits and document-field
hits into a single `search()` call, once score normalisation across the two
domains is well understood.

---

## 8. Open Questions

1. **Unified vs separate search API** — Should `KmdbCollection.search()` be
   extended to optionally include vault content (returning a mixed result list),
   or should `searchVault()` remain a distinct entry point? The key challenge is
   score normalisation: BM25 scores over document fields and BM25 scores over
   chunks are computed on different corpora and are not directly comparable.
   Hybrid RRF merge (§23) could provide a principled normalisation, but the
   design needs careful thought before committing to a unified surface.

2. **Chunk size configurability** — Should `chunkSize` and `chunkOverlap` be
   configurable per `VaultSearchConfig` (global) or per collection (via a
   per-collection `VaultSearchIndexDefinition`)? Global configuration is
   simpler; per-collection configuration allows tuning for known document sizes
   (e.g. short notes vs. long reports).

3. **Re-index trigger** — When the embedding model version or chunking
   parameters change, all computed vectors and chunk metadata are stale. The
   version-encoded artifact filenames detect staleness automatically, but a
   deliberate re-index API is needed to trigger reprocessing (e.g.
   `db.reindexVault()` or a CLI `vault reindex` command). The exact surface is
   TBD.

4. **Indexing observability** — The `$vault:extract` namespace gives per-blob
   status, but the application needs a convenient way to query overall indexing
   progress (e.g. "N of M blobs indexed"). A `VaultSearchStatus` aggregate type
   returned from `db.vaultSearchStatus()` seems reasonable, but the design is
   open.

5. **Stub blob interaction** — When a stub is hydrated mid-session (the user
   explicitly downloads a file), the indexing isolate should pick it up
   automatically. The trigger mechanism (polling vs. event from
   `VaultStore.hydrateBlob()`) is TBD.

6. **LSM scan index rebuild** — If the `$vvec:idx` entries are missing but vault
   vector files exist (e.g. database migrated from another device), the system
   should offer a rebuild path. This is cheap (no re-embedding required — just
   deserialise and write), but needs an explicit code path and recovery hook.

7. **Score snippet length** — Snippets are derived from chunk text. The optimal
   snippet length for display (number of sentences to surface around the match)
   is a UX question that should inform `VaultChunkContext.snippet` trimming.

---

## 9. Future Work

### Format extractors

The `kmdb_extractor_<name>` package pattern provides the extension point for
additional formats. Likely first candidates, in approximate priority order:

- **`kmdb_extractor_html`** — parse and strip HTML tags using the Dart `html`
  package. Low complexity; high value for web-clipped content.
- **`kmdb_extractor_markdown`** — strip Markdown syntax. Most tokens are already
  readable text; a simple pass to remove fenced code blocks and link syntax is
  likely sufficient.
- **`kmdb_extractor_pdf`** — the most complex case. No robust pure-Dart PDF text
  extraction library currently exists. Options include: best-effort with the
  `pdf` package; a native FFI wrapper around poppler or pdfium (similar to how
  `betto_zstd` wraps libzstd); or an external process (`pdftotext`) on desktop.
  This work is analogous to what Apache Tika provides in Java — a structured,
  metadata-aware extraction pipeline that goes beyond raw text. A separate
  proposal should evaluate these options before implementation.

### Unified search surface

Once score normalisation is understood, a follow-on proposal could unify vault
search and document-field search under a single `KmdbCollection.search()` call,
with the hybrid RRF mechanism (§23) providing cross-domain rank fusion.

### Web platform

Web platform support is out of scope. The same constraints that apply to
document-field semantic search (§20 §3.5) apply here: ONNX/WASM inference and
large-scale vector scan in a browser context are unconfirmed as viable. A future
proposal should assess feasibility independently.

### Semantic chunking

The fixed-size word-count chunking proposed here is simple and predictable.
Sentence- or paragraph-boundary chunking produces more semantically coherent
chunks and typically improves retrieval quality. This is a known improvement but
adds tokenisation complexity; deferred until baseline fixed-size chunking is
validated in practice.

---

## 10. Multilingual Support

> **Revised framing.** An earlier draft treated language detection as the central
> problem — triggering model routing and driving the embedding path. That framing
> is heavier than necessary. The system breaks into two independent concerns:
>
> 1. **Semantic / embedding path** — solved by adopting *one* multilingual model
>    into a single shared vector space. This is what delivers broad-language
>    support and enables cross-lingual retrieval. It removes the need for
>    language-based model routing entirely.
> 2. **Lexical / reverse-index path** — language detection is still useful here
>    for analyzer selection and document metadata, but the role is coarse and
>    tolerant of error. A lightweight, pure-Dart detector is sufficient; no FFI
>    or model runtime is needed.
>
> The phases below are listed in dependency order, but note that Phase C
> (multilingual embedding) is **independent** of Phases A and B.

### 10.1 Charset detection

`PlainTextExtractor` currently decodes `text/plain` bytes as UTF-8 and fails
silently on other encodings (BOM stripping aside). Many plain-text files in the
wild are ISO-8859-*, Windows-1252, Shift-JIS, or other legacy encodings.
Incorrect decoding produces garbled text that propagates into the inverted index and
embedding input, corrupting both search paths.

A charset detection step must be inserted before UTF-8 decoding in
`PlainTextExtractor.extract()`. The detected charset (or a confidence-weighted
best guess) should be stored in `extract_status.json` under a `"charset"` field
for diagnostics.

**`betto_charset_detector: ^0.1.0-dev.2` is now available on pub.dev and is the
recommended implementation.** It is pure-Dart (no native dependencies), runs in
the indexing isolate on all platforms, and requires no additional optional
package — it can be added as a direct dependency of `kmdb` alongside
`betto_mediatype_detector`.

### 10.2 Language detection

> **Implementation note (WI-6, 2026-07-07).** Two details below are stale
> relative to what was actually built — noted here rather than rewritten, since
> this section otherwise remains an accurate design sketch of the two-stage
> (script pre-filter + n-gram) approach that `betto_lang_detector` (WI-5)
> actually implements:
>
> - **"a `\"language\"` field in `extract_status.json`"** — no
>   `extract_status.json` file exists in the shipped implementation.
>   `VaultExtractionState` (persisted solely in the `$$vault:extract:{sha256}`
>   KV namespace — see §32) carries `script` (ISO 15924) and `language` (ISO
>   639-1) as two separate fields, not a single combined value; see §32's
>   "Script and Language Detection" section for the shipped field shapes and
>   why they are separate.
> - **Confidence threshold, not used as designed.** The sketched
>   `minConfidence`/`Undetermined` API below matches `betto_lang_detector`'s
>   actual public shape, but the shipped stemmer-routing consumer
>   (`detectLanguageForStemming()` in `kmdb`) does **not** trust raw
>   `LanguageGuess.confidence` at any threshold — it degenerates to `1.0` on a
>   spuriously-won tie, which is common for short/keyword-style text. The
>   actual policy gates on the *margin* between the top two ranked
>   candidates, a minimum word count, and Stemmer-language support — see
>   §21 Stage 4.

With the multilingual embedding model (§10.3) handling the semantic path, language
detection is no longer load-bearing for embedding routing. Its remaining role is
narrower:

1. **Lexical analyzer selection** — stemming, stop-word filtering, and
   tokenization strategy for the BM25 reverse index are language-specific, but
   degrade gracefully (a generic analyzer still produces a valid index). Coarse
   accuracy on document-length text is sufficient.
2. **Document metadata** — a `"language"` field in `extract_status.json` for
   faceting, filtering, and display.
3. **Script guard rails** — cheap detection of CJK/Cyrillic/Arabic to route to
   `IcuTokenizer` (§10.4) without requiring full language identification.

This narrower role collapses the engine choice. A two-stage pure-Dart detector
is sufficient:

- **Unicode script pre-filter** — resolves or sharply narrows many languages
  from script alone (Han, Hiragana/Katakana, Hangul, Cyrillic, Greek, Arabic,
  Hebrew, Devanagari, Thai, …). Deterministic, near-free, and driven by
  code-generated Unicode tables. For the analyzer-selection use case, script
  alone already routes a large fraction of non-Latin content correctly.
- **Small character n-gram model** — distinguishes same-script languages (e.g.
  English vs. Hungarian vs. German in Latin). Constrained to the vault's known
  languages via `restrictTo`, which keeps the model data tiny and accurate.

This requires no FFI, no model runtime, and no per-platform builds.

> **Why not FastText/floret-in-ONNX.** FastText's tokenisation, n-gram
> extraction, and hashing live outside any tensor graph; there is no maintained
> FastText→ONNX exporter. FastText/floret is an embeddings tool, not a
> classifier, and cannot be meaningfully expressed as an ONNX session. If a
> model-grade detector were ever needed, a transformer LID model in ONNX would be
> the route — but the pure-Dart detector suffices for the analyzer-selection task.

#### API

```dart
/// A detected language with its confidence in [0.0, 1.0].
final class LanguageGuess {
  final String code;       // BCP-47 / ISO 639-1 e.g. "en", "hu"
  final double confidence; // 0.0–1.0
  const LanguageGuess(this.code, this.confidence);
}

sealed class DetectionResult {}
final class Detected extends DetectionResult {
  final LanguageGuess best;
  final List<LanguageGuess> ranked;
  Detected(this.best, this.ranked);
}
final class Undetermined extends DetectionResult {
  final List<LanguageGuess> ranked; // below threshold; may be empty
  Undetermined(this.ranked);
}

abstract interface class LanguageDetectorBackend {
  Set<String> get supportedLanguages;
  List<LanguageGuess> score(String text);
}

final class LanguageDetector {
  LanguageDetector({
    required LanguageDetectorBackend backend,
    double minConfidence = 0.5,
    Set<String>? restrictTo, // constrain to a vault's known languages
  });

  /// Zero-dependency default: Unicode script filter + small n-gram model.
  factory LanguageDetector.pureDart({
    double minConfidence,
    Set<String>? restrictTo,
  }) = /* ... */;

  /// Full detection (analyzer selection, metadata).
  DetectionResult detect(String text);

  /// Cheap script-only classification for guard rails and tokenizer routing.
  ///
  /// Returns a Unicode script name (e.g. "Latn", "Cyrl", "Han") or null.
  String? dominantScript(String text);
}
```

Key design points:
- **`restrictTo`** is the biggest practical accuracy lever — constraining to the
  vault's known languages sharpens the n-gram model significantly.
- **`Undetermined` as a first-class result** — never throws on ordinary input.
- **`dominantScript`** provides the cheap guard rail needed for `IcuTokenizer`
  routing (§10.4) without running full detection.
- The detector is intentionally decoupled from the embedding path — nothing in
  semantic indexing calls it.

If no detector is registered, language defaults to `"und"` (undetermined) and
the English-only lexical pipeline is used as a fallback.

#### Package

`betto_lang_id` — pure-Dart, no native dependencies (follows the `betto_*`
convention for reusable Bettongia utilities):

```
betto_lang_id/
  lib/
    betto_lang_id.dart
    src/
      detector.dart
      backend.dart
      script/script_filter.dart
      script/script_ranges.g.dart       # code-generated from UCD
      ngram/ngram_backend.dart
      ngram/profiles/*.g.dart           # code-generated; subset to needed languages
```

### 10.3 Multilingual embedding model

Adopting a single multilingual model is what actually delivers broad-language
support. Two benefits over a per-language routing approach:

- **Single shared vector space.** Per-language models embed into incompatible
  coordinate systems — an English query cannot match a semantically relevant
  Hungarian document. A multilingual model places everything in one space,
  enabling cross-lingual retrieval by construction and without any query-side
  language detection.
- **No misroute failure mode.** A router must assign one language per document
  and can route wrong; mixed-language documents (quotations, names, code,
  citations) have no single right answer. A multilingual model has neither
  failure mode.

#### Model options

| Model | Languages | Dims | Max tokens | Notes |
| ----- | --------- | ---- | ---------- | ----- |
| `intfloat/multilingual-e5-small` | ~100 | 384 | 512 | **Recommended starting point.** Near drop-in: same 384 dims as current BGE model — vector store, SQ8 quantization, and ANN index need no dimensional change. Requires E5 input prefixes (see below). MIT licence. |
| `BAAI/bge-m3` | 100+ | 1024 | 8192 | Long-document context; dense + sparse + multi-vector retrieval in one model. Changes index dimensionality to 1024; requires a full re-index. MIT licence. |

`multilingual-e5-small` is the pragmatic migration path: model size class and
dimensionality match the current BGE model, so the only infrastructure change is
the tokenizer. `bge-m3` is the upgrade if KMDB later wants long-document
embeddings or hybrid dense/sparse retrieval and can absorb a re-index.

#### Tokenizer implication (the one real cost)

The current BGE Small En v1.5 pipeline uses BERT **WordPiece** tokenisation.
Both multilingual candidates are XLM-RoBERTa-based and use **SentencePiece /
Unigram** tokenisation with a large (~250k) vocabulary. A pure-Dart
XLM-R-compatible SentencePiece tokenizer must be written or sourced.

Check pub.dev for an existing implementation before building. If porting,
`transformers.js` (TypeScript, Apache-2.0) is the best direct porting source —
a GC, class-based language close to Dart, already validated against Python
outputs. Use `tokenizers` (Rust, Apache-2.0) and `spm_precompiled` as the byte-
exact reference for resolving ambiguities.

Components the implementation must cover, in complexity order:

1. **Vocab loading** from `tokenizer.json` as `(piece, score)` pairs — avoids
   protobuf parsing entirely.
2. **Precompiled-charsmap normaliser** — a compiled trie of NFKC-like rewrites
   baked into the model. This is *not* plain NFKC; approximating with bare NFKC
   produces parity failures. Port from `spm_precompiled` logic.
3. **Metaspace pre-tokenizer** — replace spaces with ▁ (U+2581) and prepend a
   leading ▁.
4. **Unigram Viterbi** — build the lattice of all vocab-matching substrings;
   select maximum-log-probability segmentation; handle `<unk>`.
5. **fairseq id remapping** — the fairseq XLM-R implementation offsets ids from
   raw SentencePiece output. An off-by-one corrupts every id silently; take the
   exact mapping from the HF/Keras source.
6. **Post-processing** — wrap with `<s> … </s>`, build the attention mask.

Gate the tokenizer in CI against byte-exact token id parity with HuggingFace
`AutoTokenizer` on a fixed multilingual corpus. The charsmap normalizer and
fairseq remapping are where silent parity bugs hide; the Unigram DP and Metaspace
steps are straightforward.

All porting sources (transformers.js, `tokenizers`, `spm_precompiled`) are
Apache-2.0 and directly compatible with this project's licence.

#### E5 input prefixes

The E5 family requires plain-text prefixes prepended before tokenisation:
`passage:` at index time, `query:` at query time. Encode this in the pipeline
and apply it consistently. (BGE uses a query-side instruction only; if BGE-M3 is
chosen, consult its model card for the equivalent convention.)

#### Query encoding

Queries are embedded with the same multilingual model. Because the vector space
is shared across all languages, **query-side language detection is not required**
for semantic retrieval.

### 10.4 Language-aware BM25 tokenization

> **Implementation note (WI-6, 2026-07-07).** This section's premise turned
> out to be stale on investigation — not just its `extract_status.json`
> reference, but its central claim. `docs/spec/21_lexical_search.md`'s
> document-field FTS pipeline was *already* using `createDefaultTokenizer()`
> (which resolves to `IcuTokenizer` on native, `BrowserTokenizer` on web) at
> every read/write site, independent of language, well before WI-6 — there
> was never a live `RegExpTokenizer`-in-production bug to route away from
> there. The **real, live bug WI-6 found and fixed** was different and
> narrower: `VaultChunker` (the *vault* search chunker, not the document-field
> pipeline this section describes) used its own hand-rolled ASCII-only
> `RegExp(r"\w+(?:'\w+)*")` — no Unicode flag — which matched **zero** tokens
> for any text with no ASCII letters/digits, silently producing an
> unsearchable (but still `indexed`) blob. The fix was to give `VaultChunker`
> an injectable `OffsetTokenizer` (defaulting to `IcuTokenizer`) directly,
> not a `dominantScript()`-driven *routing* decision between two tokenizers as
> sketched below — see §32's "Tokenisation (WI-6)" note and §21 Stage 1 for
> what was actually shipped. `dominantScript()`/`detectLanguageForStemming()`
> are used for **stemming selection** (§21 Stage 4), not tokenizer routing.

The lexical (BM25) pipeline in §21 uses `RegExpTokenizer`, which splits on
Unicode word boundaries. This is adequate for space-delimited languages but
produces incorrect or empty token sequences for:

- **CJK languages** (Chinese, Japanese, Korean) — no inter-word spaces; each
  character or n-gram must be treated as a token.
- **Arabic / Hebrew** — right-to-left scripts with complex morphology.
- **Agglutinative languages** (Finnish, Turkish, Korean) — compound words
  that benefit from morphological decomposition.

The `IcuTokenizer` from `betto_icu` (already used by `betto_lexical`) handles
word segmentation correctly across all Unicode scripts via ICU `BreakIterator`.
Vault search routes to it using the **`dominantScript()`** signal from
`betto_lang_id` (§10.2) — a cheap, pre-detection step that does not require full
language identification:

- Latin-script text: existing `RegExpTokenizer`
- All other scripts (Han, Cyrillic, Arabic, etc.): `IcuTokenizer`

The tokenizer selection is encapsulated in the indexing isolate and requires no
API changes — it is an internal routing decision based on the `"language"` field
stored in `extract_status.json`.

Stop-word filtering and stemming (currently English-only via `betto_lexical`) are
left as language-specific future work; disabling them for non-English content
produces a valid (if unoptimized) BM25 index.

### 10.5 Staging recommendation

| Phase | Capability | Dependency | Package |
| ----- | ---------- | ---------- | ------- |
| A | Charset detection | None | `betto_charset_detector` ✅ published |
| B | Language detection (lexical path + metadata) | Phase A | `betto_lang_id` (pure Dart, script + n-gram) |
| C | Multilingual embedding model | **None** (independent of A/B) | extend `betto_inferencing` — `multilingual-e5-small` (384d, drop-in) or `bge-m3` (1024d, re-index required) |
| D | Language-aware BM25 tokenizer routing | Phase B | `IcuTokenizer` via existing `betto_icu` / `betto_lexical` |

Phase A alone fixes silent data corruption for non-UTF-8 plain-text files and is
worthwhile independently of the multilingual search story. The package is
available now; no new package needs to be written or published before Phase A
can be planned and implemented.

Phase C is independent of language detection because the multilingual model
covers the embedding path without requiring a language label. It can be planned
and shipped in parallel with or ahead of Phase B.

---

## 11. References

- [§20 — Text Search Overview](../spec/20_text_search.md)
- [§21 — Lexical Search](../spec/21_lexical_search.md)
- [§22 — Semantic Search](../spec/22_semantic_search.md)
- [§23 — Hybrid Search](../spec/23_hybrid_search.md)
- [§24 — Vault](../spec/24_vault.md)
- [Text Search Proposal](implemented/text_search.md)
- [Vault Proposal](implemented/vault.md)
