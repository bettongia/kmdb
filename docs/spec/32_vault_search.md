# Vault Search

## Overview

Vault search extends KMDB's text search capability (§20–23) to vault blobs
(§24). When a blob is ingested, the vault search subsystem extracts its text
content, splits it into overlapping chunks, builds a BM25 inverted index over
the chunks, and optionally generates SQ8-quantised embeddings for semantic
search.

Vault search is **optional and opt-in**: a database opened without a
`VaultSearchConfig` provides no vault search capability, and the vault itself
continues to function normally. When vault search is enabled, `VaultSearchManager`
is attached to the database at open time and orchestrates the full indexing
lifecycle.

Vault search is native-platform only in v1 — this excludes **both** lexical
and semantic vault search, unlike document-field search (§20), where lexical
BM25 search is already supported on web via `BrowserTokenizer`. The missing
ONNX embedding model explains why *semantic* vault search can't run in the
browser, but the deeper reason the *lexical* half is unavailable too is
architectural: all vault indexing (BM25 and vector alike) runs inside
`VaultIndexingIsolate`, a `dart:isolate`-based background isolate, and
`dart:isolate` is not supported on any web compile target. Document-field FTS
has its own non-isolate `FtsManager` path that already works on web; vault
search has no equivalent yet.

## Storage Layout

### KV Namespaces

Vault search uses five KV namespaces. Three carry the `$$` (double-dollar)
prefix and are **local-only** (written to `.local.sst`, never uploaded); one
uses the single `$` prefix and **syncs normally**.

| Namespace prefix             | Syncable? | Contents                                        |
| :--------------------------- | :-------- | :---------------------------------------------- |
| `$$vault:fts:{sha256}:`      | No        | Per-chunk BM25 term-frequency entries           |
| `$$vault:fts:corpus:{sha256}`| No        | Per-blob corpus statistics (chunk count, tokens)|
| `$$vault:vec:idx:{sha256}:`  | No        | Per-chunk SQ8-quantised embedding vector        |
| `$$vault:extract:{sha256}`   | No        | Per-blob extraction status and metadata         |
| `$vault:docref:{sha256}`     | Yes       | Document → blob reference index                 |

### Key Format

All five namespaces store entries whose KV keys must satisfy the
`KeyCodec.keyToBytes` constraint (exactly 32 hex characters, UUIDv7 format:
version nibble at position 12 = `'7'`, variant nibble at position 16 = `'8'`
or `'9'`).

- **Chunk key** (`kVaultChunkKey(index)`): `01900000000070008{15-hex-index}`.
  The chunk index occupies the last 15 hex characters, supporting up to
  2^60 ≈ 10^18 chunks per blob.
- **Sentinel key** (`kVaultCorpusSentinelKey`): `01900000000070009000000000000000`.
  Used as the single entry key for `$$vault:fts:corpus:` and `$$vault:extract:`
  namespaces (each holds exactly one entry per blob). The variant nibble is `'9'`
  to distinguish it from chunk keys.

### Filesystem Artifacts

Each indexed blob gains an `extract/` subdirectory alongside its `blob` and
`manifest.json` files within the vault storage layout:

```
{local-db-dir}/vault/blobs/sha256/{2-char}/{62-char}/
  manifest.json
  blob                              ← absent for stubs
  extract/
    text.txt                        ← UTF-8 decoded full text
    chunks_v1.json                  ← JSON array of chunk objects
    vectors_{modelId}_sq8.bin       ← raw SQ8 binary (absent for lexical-only)
```

There is no fourth `extract_status.json` file — extraction status is
persisted **solely** in the LSM `$$vault:extract:` namespace, which is the
single authoritative source of truth for extraction status (there is no
secondary filesystem copy).

The `extract/` subdirectory is created and managed exclusively by
`VaultSearchManager`. It is **not** synced (it lives inside the local database
directory, not the sync folder). Other devices rebuild the `extract/` directory
independently when they pull and hydrate the same blobs.

#### Encryption (WI-10)

When the database has an `EncryptionProvider` configured (§31), each of the
three files above is encrypted with the DEK before being written, via
`VaultSearchManager.writeExtractArtifact` / `readExtractArtifact`. Because
`extract/` files have no accompanying manifest to record an `encrypted` flag
(unlike vault blobs — see §24 _Encryption_), each file is prefixed with a
single self-describing `EncryptionFlag` byte (the same enum §31 defines for
the `ValueCodec` wire format, applied here to whole files):

```
[EncryptionFlag.none  (0x00)] plaintext body follows verbatim
[EncryptionFlag.aesGcm (0x01)] nonce(12B) || AES-256-GCM ciphertext || tag(16B)
```

This makes every artifact independently readable regardless of the database's
current encryption state or when the file was written — the property needed
for a database whose encryption is toggled on after some blobs are already
indexed: pre-existing plaintext (`0x00`) artifacts remain readable without a
migration step, while newly indexed or reindexed blobs (via
`VaultSearchManager.reindexVault()`) write encrypted (`0x01`) artifacts. Both
flag states can coexist across blobs in the same database indefinitely. See
§31's "Vault `extract/` filesystem artifacts" gap entry for the full
confidentiality discussion, including read-site failure policy (self-healing
on startup recovery vs. propagating out of `searchVault()` at query time).

## Lifecycle State Machine

Each vault blob progresses through the following lifecycle states, recorded in
`$$vault:extract:{sha256}` (keyed by `kVaultCorpusSentinelKey`):

```
(new blob ingested)
       │
       ▼
    pending
       │  VaultSearchManager picks blob from queue
       ▼
  extracting              ← crash-recovery checkpoint
       │
       ├──→ indexed       (extraction and indexing succeeded)
       │
       ├──→ failed        (error during extraction or embedding)
       │
       └──→ unsupported   (no extractor supports this media type)
```

**State transitions:**

| From         | To            | Trigger                                                    |
| :----------- | :------------ | :--------------------------------------------------------- |
| (absent)     | `pending`     | Blob ingested via `VaultStore.ingest()`                    |
| `pending`    | `extracting`  | `VaultSearchManager` picks blob from queue                 |
| `extracting` | `indexed`     | All artifacts written and LSM entries committed            |
| `extracting` | `failed`      | Exception thrown during extraction or embedding            |
| `extracting` | `unsupported` | No `VaultTextExtractor` supports the blob's media type     |
| `extracting` | `pending`     | Startup recovery: `extracting` + missing artifacts → reset |
| `indexed`    | `pending`     | `KmdbDatabase.reindexVault()` called                       |
| `failed`     | `pending`     | `KmdbDatabase.reindexVault()` called                       |

A stub blob (manifest present, `blob` file absent) transitions to `pending`
when the blob is hydrated (on-demand download inside `VaultStore.getBytes()`).
The `VaultSearchManager` registers a `_onBlobHydrated` callback with
`VaultStore` at open time to receive this notification without polling.

## Startup Recovery

`VaultSearchManager._recover()` runs immediately after the manager is
initialised (as part of `KmdbDatabase.open()`). It scans `$$vault:extract:`
for blobs in the `extracting` state and applies the following recovery logic:

1. **All filesystem artifacts present** (`text.txt`, `chunks_v1.json`, and
   `vectors_{modelId}_sq8.bin` if a model is active): rebuild the KV entries
   from filesystem data and mark the blob `indexed`. No re-extraction or
   re-embedding is needed.
2. **Any artifact missing**: reset to `pending` for full re-extraction.

This unified recovery path also handles the "database moved / `$$vault:extract:`
entries missing" scenario: if a blob has a complete `extract/` directory but no
KV entry, recovery builds the KV entry from the filesystem data.

**Model change detection:** At open time, if a blob's recorded `modelVersion`
does not match the currently active `embeddingModel.modelId`, the blob is
reset to `pending` and its vector artifacts are deleted. Lexical-only blobs
(`modelVersion: ""`) are not reset by model changes.

## Isolate Architecture

Vault search uses a **background Dart `Isolate`** for the CPU-intensive
extraction and chunking work. This keeps the main isolate free for document
reads and writes.

```
Main isolate
    ├─ VaultSearchManager            orchestrates lifecycle
    │      ├─ queue (pending blobs)
    │      ├─ VaultBm25Writer        commits BM25 LSM entries
    │      └─ VaultVecWriter         commits vector LSM entries
    └─ KmdbDatabase.embeddingModel   owned by main isolate (ORT is thread-affine)

Background isolate (VaultIndexingIsolate)
    ├─ VaultTextExtractor            text extraction (e.g. PlainTextExtractor)
    └─ VaultChunker                  sliding-window chunking
```

The background isolate receives a blob's raw bytes and returns a list of
`VaultChunk` records (text, offsets, token list). The main isolate then:

1. Calls `embeddingModel.embed()` for each chunk (ORT session cannot cross
   isolate boundaries).
2. Calls `VaultBm25Writer.writeChunks()` to commit BM25 entries.
3. Calls `VaultVecWriter.writeChunks()` to commit vector entries.
4. Writes the final `indexed` status to `$$vault:extract:`.

Writing each phase before the next begins ensures that a crash between phases
leaves the blob in the `extracting` state, which recovery resolves.

## Chunking

Text is split into overlapping windows of words using `VaultChunker`. Default
parameters (set in `VaultSearchConfig`):

| Parameter      | Default | Notes                                         |
| :------------- | :------ | :-------------------------------------------- |
| `chunkSize`    | 300     | Target window size in words                   |
| `chunkOverlap` | 50      | Overlap between consecutive windows (in words)|

Overlap prevents a query term that straddles a chunk boundary from being missed.

Each `VaultChunk` carries:
- `text`: the chunk's text content.
- `wordOffset`: starting word position in the full text.
- `charOffset`: starting character offset in the full text.
- `tokenIds`: the pre-tokenised term list (shared with BM25 indexing and
  passed to the embedding model).

**Tokenisation (WI-6).** `VaultChunker` finds word-token spans using an
`OffsetTokenizer` — `IcuTokenizer` by default, the same UAX #29-conformant
tokenizer the document-field FTS path uses (§21) — rather than a hand-rolled
ASCII-only regex. Prior to WI-6, the chunker used `RegExp(r"\w+(?:'\w+)*")`
without a Unicode flag, so `\w` matched only ASCII letters/digits/underscore;
any blob whose extracted text contained no ASCII word characters at all (a
pure-CJK, Arabic, Cyrillic, Devanagari, or Thai document) produced zero token
spans, an empty chunk list, and a silently-unsearchable (but still `indexed`)
blob. `IcuTokenizer` correctly segments all of these scripts. `VaultChunker`'s
constructor accepts an injectable `OffsetTokenizer` for deterministic testing;
the default resolves via `createDefaultTokenizer()` cast to `OffsetTokenizer`,
safe because vault indexing is native-only (per the project's platform
scope), where that always resolves to `IcuTokenizer`.

## Text Extraction

Text is extracted from blobs by `VaultTextExtractor` implementations:

| Extractor               | Media types        | Notes                                |
| :---------------------- | :------------------ | :------------------------------------ |
| `PlainTextExtractor`    | `text/plain`        | Charset-detected UTF-8 decode (WI-2)  |
| `PdfTextExtractor`      | `application/pdf`   | `kmdb_extractor_pdf` package (WI-8), wraps `betto_pdfium`. Configurable `scannedPageRatio` gate discards predominantly-scanned/image-only documents (returns `""`, still `indexed`). Pages joined with `"\n\n"`. |
| `HtmlTextExtractor`     | `text/html`         | `kmdb_extractor_html` package (WI-9), wraps the `html` package. Custom node walk (not `Element.text`, which fuses adjacent block text and leaks `<script>`/`<style>` source) skips non-prose subtrees and inserts boundary whitespace around block/inline elements. No charset side-channel — see its `README.md`. |
| `MarkdownTextExtractor` | `text/markdown`     | `kmdb_extractor_markdown` package (WI-9), wraps the `markdown` package via `Document(encodeHtml: false, extensionSet: ExtensionSet.gitHubWeb)` (not the bare default, which HTML-escapes AST text and lacks table support). Custom AST walk (not `Node.textContent`) drops fenced/indented code block content (kept: inline code), keeps link text and image alt text while dropping URLs. |

DOCX remains out of scope for v1 and can be added following the same
`kmdb_extractor_<name>` convention via `VaultSearchConfig.extractors`. The
first extractor whose `supportedMediaTypes` set contains the blob's media
type is used; if none match, the blob is marked `unsupported`.

`PdfTextExtractor`, `HtmlTextExtractor`, and `MarkdownTextExtractor` each
ship in their own optional package (`kmdb_extractor_pdf`,
`kmdb_extractor_html`, `kmdb_extractor_markdown` — none are a core `kmdb`
dependency) — see each package's `README.md` for installation and platform
support notes:

```dart
import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';
import 'package:kmdb_extractor_html/kmdb_extractor_html.dart';
import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';

final db = await KmdbDatabase.open(
  // ...
  vaultSearch: VaultSearchConfig(
    extractors: [
      PdfTextExtractor(),
      HtmlTextExtractor(),
      MarkdownTextExtractor(),
    ],
  ),
);
```

Charset detection uses the `decodeText` utility function from WI-2 (`charset_util.dart`),
which applies the `betto_charset_detector` heuristic and records the detected
IANA label in the extraction state.

## Script and Language Detection (WI-6)

After text extraction and before chunking, the vault indexing isolate records
two further, independently-meaningful fields on `VaultExtractionState`:

| Field      | Type      | Source                        | Populated when |
| :--------- | :-------- | :----------------------------- | :-------------- |
| `script`   | `String?` | `dominantScript()` (ISO 15924) | Extraction succeeded and the text has any scripted letters (e.g. `"Latn"`, `"Cyrl"`, `"Hani"`); `null` for script-less text (digits/punctuation only) |
| `language` | `String?` | `detectLanguageForStemming()` (ISO 639-1) | Detection cleared the same margin/word-count/Stemmer-support gate described in §21's Stage 4; `null` otherwise |

`script` and `language` are stored as **separate fields** rather than a single
combined value, even though `dominantScript()` is a cheap, deterministic
Unicode-property lookup and `detectLanguageForStemming()` additionally runs a
character n-gram model — a script code (ISO 15924) and a language code (ISO
639) answer different questions (e.g. Japanese and Chinese text can both
report `script: "Hani"` while resolving to different `language` values). This
also happens to align with two subtags of a BCP-47 language tag
(`language-script`, e.g. `zh-Hant`), leaving room for a future extractor that
reads file-embedded language metadata (e.g. an HTML `lang` attribute or a PDF
`/Lang` catalog entry) to populate both fields **authoritatively** without a
schema change — not implemented today, as no current `VaultTextExtractor`
surfaces such metadata.

`language` here is the **same gated value** used to persist
`VaultExtractionState.language` and the vault write path's stemmer selection
is a *separately-defaulting* view of the identical detection result — see
§21's Stage 4 for the full gating rationale (margin, word count, Stemmer
support) and why the stemming selector defaults to English when the gate
isn't cleared while this persisted `language` field defaults to `null`
instead (misleading to claim a specific language without real confidence, but
harmless — indeed necessary for consistency — to default *stemming* to
English, this project's historical default).

Detection runs entirely within the vault indexing isolate — both
`dominantScript()` and `detectLanguageForStemming()` are pure Dart with no
FFI or native state (unlike `IcuTokenizer`/ONNX Runtime), so there is no
isolate-affinity concern.

## Sync Exclusion

The three `$$vault:*` namespaces follow the WI-0 local-only convention:

- At flush time, the LSM engine routes entries whose namespace starts with `$$`
  into `.local.sst` files (not the regular `{deviceId}-{minHlc}-{maxHlc}.sst`).
- `SyncEngine.push` identifies `.local.sst` files by their filename suffix and
  skips them entirely — they are never uploaded.
- `SyncEngine.pull` ignores `.local.sst` files from remote devices.

The result: each device independently builds and maintains its own vault search
indexes from the vault blobs it holds locally. This mirrors the document text
search behaviour (§20).

The `$vault:docref:` namespace uses a single `$` prefix and **syncs normally**.
This is the document-to-blob reference map: other devices must know which
documents reference which blobs to make correct decisions about pulling missing
blobs (stub hydration) and counting ref counts for GC.

## Multi-Device Model Independence

Each device builds its own vault search indexes with its locally configured
embedding model (`KvStoreConfig.embeddingModel`). Different devices may use
different models without correctness issues because:

- Vector search (`$$vault:vec:idx`) is always local — a device never sends or
  receives vector index entries.
- Each device's vector space is self-contained: the `VaultVecWriter` stores
  SQ8 vectors for the active model; `VaultSearcher` queries the same model to
  produce the query embedding.
- Lexical search (`$$vault:fts:`) produces identical results across devices for
  the same downloaded blobs, regardless of which model (if any) is configured.
- `$vault:docref` (document → blob mapping) is synced and consistent across all
  devices even though the derived search indexes are not.

If a device has no embedding model configured, vault search operates in
**lexical-only mode**: the `$$vault:vec:idx` entries are never written, and
`searchVault()` accepts only `SearchMode.lexical`. The `modelVersion` field in
the extraction state is stored as `""` (empty string) in lexical-only mode.

## GC Integration

`VaultGc.sweep()` cleans up vault search state when a blob's reference count
reaches zero and the blob is eligible for deletion. For each deleted blob:

1. All `$$vault:fts:{sha256}:*` entries are deleted.
2. The `$$vault:fts:corpus:{sha256}` entry is deleted.
3. All `$$vault:vec:idx:{sha256}:*` entries are deleted.
4. The `$$vault:extract:{sha256}` entry is deleted.
5. The `extract/` filesystem directory is removed.

Cleanup requires a `KvStoreImpl` reference (not just the `KvStore` interface)
because it uses `writeBatchInternal` to bypass the system-namespace guard for
`$$`-prefixed namespaces. The `VaultGc` constructor accepts an optional
`searchStore` (`KvStoreImpl?`) parameter; when absent, it casts the `kvStore`
parameter directly (permissible when the caller knows the concrete type). Tests
use the optional parameter to decouple ref-count reads (which use sha256 keys
incompatible with the UUIDv7 constraint) from vault search cleanup (which uses
a real `KvStoreImpl`).

## API Reference

### `VaultSearchConfig`

```dart
VaultSearchConfig({
  List<VaultTextExtractor> extractors = const [],  // additional extractors
  int chunkSize = 300,                             // words per chunk
  int chunkOverlap = 50,                           // overlap between chunks
})
```

Pass to `KmdbDatabase.open(vaultSearch: ...)` to enable vault search.

### `KmdbDatabase`

```dart
// Null when vaultSearch was not passed to open().
VaultSearchManager? get vaultSearchManager;

// Counts per lifecycle state across all known blobs.
Future<VaultIndexingStatus> vaultIndexingStatus();

// Streams periodic status updates (useful for UI progress bars).
Stream<VaultIndexingStatus> watchVaultIndexingStatus();

// Reset all indexed/failed blobs to pending; restart indexing.
Future<int> reindexVault();  // returns count of blobs queued
```

### `KmdbCollection<T>.searchVault`

```dart
Future<List<VaultSearchResult<T>>> searchVault(
  String query, {
  SearchMode mode = SearchMode.lexical,  // lexical | semantic | hybrid
  int limit = 10,
  int offset = 0,
})
```

Returns a ranked list of `VaultSearchResult<T>` objects. Each result carries:

- `document`: the matched document (of type `T`).
- `hits`: a ranked list of `VaultSearchHit` — one per matching chunk.
  - `sha256`: the blob's content address.
  - `fieldPath`: the document field that holds the vault URI.
  - `chunkIndex`: which chunk within the blob matched.
  - `context`: a `VaultChunkContext` with `snippet`, `wordOffset`, `charOffset`,
    and the computed `score`.

When the embedding model is absent, `SearchMode.semantic` and
`SearchMode.hybrid` raise a `StateError`.

### `VaultIndexingStatus`

```dart
final class VaultIndexingStatus {
  int get total;         // all blobs known to this device
  int get indexed;       // successfully indexed
  int get pending;       // queued for processing
  int get extracting;    // currently being processed
  int get failed;        // extraction failed (retryable with reindexVault())
  int get unsupported;   // media type not supported (not retried)
  int get stub;          // not yet downloaded — excluded from indexing

  bool get isSearchComplete;  // pending == 0 && extracting == 0 && stub == 0
  bool get isComplete;        // pending == 0 && extracting == 0
}
```

### CLI commands

```sh
# Search vault blob content across a collection.
kmdb <db> vault search "<query>" --collection <name> [--mode lexical|semantic|hybrid] [--limit N] [--offset N]

# Queue all vault blobs for re-extraction and re-indexing.
kmdb <db> vault reindex

# Display vault search indexing status (counts per lifecycle state).
kmdb <db> vault status
```

## Encryption Compatibility

When the database is opened with an `EncryptionConfig` (see §31), vault blobs
are stored encrypted on disk. Vault search handles encryption transparently,
and — as of the Encryption confidentiality reconciliation plan
(`docs/roadmap/completed/0_08.md`) — every derived vault-search artifact, filesystem
files *and* LSM values alike, is also encrypted when a provider is configured:

1. `VaultStore.getBytes()` decrypts the blob before returning bytes to the
   search indexing isolate.
2. The `extract/` filesystem artifacts (`text.txt`, `chunks_v1.json`, and
   `vectors_{modelId}_sq8.bin`) are each encrypted with the DEK and prefixed
   with a self-describing `EncryptionFlag` byte (WI-10) — see the
   _Encryption (WI-10)_ section above and §31 for the flag-byte format and the
   toggle-on/mixed-state behaviour. This directory lives inside the local
   database directory and is never synced.
3. The LSM index **values** under `$$vault:fts:`, `$$vault:fts:corpus:`,
   `$$vault:vec:idx:`, and `$$vault:extract:` are encrypted at the
   `VaultSearchManager` call site (Encryption confidentiality reconciliation,
   Gap 1): the BM25 term-frequency ints, SQ8 vector bytes, and BM25 corpus
   sentinel via `EncryptionEnvelope`; the `VaultExtractionState` map (charset,
   script, language, modelVersion, chunkCount, error) via `ValueCodec`. These
   namespaces are local-only, so this protects against local disk theft rather
   than a cloud provider.
4. On an encrypted database the `$$vault:fts:` namespace-**name** `{token}`
   segment is an HMAC-SHA256 token (`EncryptionProvider.indexToken`) rather
   than a plaintext hex encoding of the term (Gap 2), so local SSTable access
   cannot enumerate the indexed vocabulary by reading namespace names.
   `VaultExtractionState` persists an `ftsTokenMode` (`hex` | `hmac`)
   discriminator; `VaultSearchManager`'s startup recovery (`_checkTokenMode`)
   detects a software-version upgrade of an already-encrypted database, purges
   the stale-mode `$$vault:fts:{sha256}:*` namespaces, and re-enqueues the blob
   for re-indexing under HMAC tokens — mirroring `FtsManager`/`IndexManager`'s
   equivalent migration. `$$vault:vec:idx:` is keyed by chunk index, never an
   embedded term, so it carries no token to migrate.

If the vault is encrypted and the database is re-opened without an encryption
provider, `VaultStore.getBytes()` will throw a `StateError` before the search
indexing isolate receives any bytes. Vault search on encrypted vaults therefore
requires the same encryption credentials as opening the database itself.
