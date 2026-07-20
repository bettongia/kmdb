# Text Search

## Overview

Text search extends the Query Layer with two complementary index types and a
hybrid ranking mode that combines them:

| Mode        | Index type        | Ranking algorithm          | Best for                              |
| :---------- | :---------------- | :------------------------- | :------------------------------------ |
| `lexical`   | Inverted index    | BM25                       | Exact keywords, technical identifiers |
| `semantic`  | Flat vector index | Cosine similarity          | Conceptual meaning, paraphrases       |
| `hybrid`    | Both              | Reciprocal Rank Fusion     | General-purpose search                |

Text search indexes are **device-local** — each device independently builds and
maintains its own indexes against the documents it holds, and a device never
relies on a peer's index. Their backing namespaces use the `$$` (double-dollar)
local-only prefix (`$$fts:*`, `$$vec:*`) so they are **never uploaded to the
sync folder** (see §20.7 and §12). Each receiving device rebuilds these
indexes from the synced document data.

See §21 (Lexical Search), §22 (Semantic Search), and §23 (Hybrid Search) for
the detail of each mode.

Text search also extends to vault blobs via **Vault Search** (§32). Vault
search applies the same BM25 and semantic modes to the text extracted from
vault-stored binary objects (PDF, plain text, DOCX, etc.), making file
attachment content searchable through `KmdbCollection.searchVault()`. The
vault search indexes use the same `$$` local-only namespace convention and are
never uploaded to the sync folder.

## Scope

### Supported

- Single `String`-valued document fields encoded as UTF-8 plain text.
- **Word segmentation for all scripts.** UAX #29-conformant on every
  platform — `IcuTokenizer` (ICU) native, `BrowserTokenizer`
  (`Intl.Segmenter`) web — so CJK, Thai, Arabic, Cyrillic, Devanagari etc.
  segment correctly (§21).
- **English by default, multilingual where opted in.** Lexical stemming is
  language-aware, auto-selected per field/query across Snowball-supported
  languages, defaulting to English when detection is inconclusive (§21).
  Semantic defaults to English-only `bge-small-en-v1.5`;
  `multilingual-e5-small` (~100 languages) is a registered opt-in
  alternative via `EmbeddingModelConfig` (§22).

### Out of scope / current limitations

- **Stop-word lists — English only.** Off by default; only Stopwords ISO
  `en` ships (§21).
- **No stemming for non-Snowball scripts.** CJK/Thai/Hebrew/Bengali etc. are
  segmented and indexed but unstemmed — matched literally, not incorrectly
  stemmed (§21).
- **Semantic search on web** — ONNX inference on web is deferred. Lexical
  search is fully supported on web.
- **Plain text extraction** — direct-index content must be plain text;
  extraction is the caller's job. (Vault search §32 handles blob
  extraction.)
- **Autocomplete / search-as-you-type** — full-term keyword search only.

## Opening with Search Indexes

Search indexes are declared at `KmdbDatabase.open()` time alongside secondary
indexes. Both `ftsIndexes` (lexical) and `vecIndexes` (semantic) are optional:

```dart
final db = await KmdbDatabase.open(
  store,
  collections: {
    'books': KmdbCollection<Book>(codec: BookCodec()),
  },
  ftsIndexes: [
    FtsIndexDefinition(collection: 'books', field: 'description'),
    FtsIndexDefinition(collection: 'books', field: 'title'),
  ],
  vecIndexes: [
    VecIndexDefinition(collection: 'books', field: 'description'),
  ],
);
```

Declarations register the index configuration — no entries are written at open
time unless the index already exists in the KV store.

## Index Management

`FtsManager` manages lexical indexes; `VecManager` manages semantic indexes.
Both are accessible as properties on `KmdbDatabase` and follow the same
lifecycle (create → build → current / stale):

```dart
// Lexical index management
await db.ftsManager.createIndex('books', 'description', lazy: false);
await db.ftsManager.buildIndex('books', 'description', force: false);
final ftsState = await db.ftsManager.getState('books', 'description');
await db.ftsManager.deleteIndex('books', 'description');

// Semantic index management
await db.vecManager.createIndex('books', 'description', lazy: false);
await db.vecManager.buildIndex('books', 'description', force: false);
final vecState = await db.vecManager.getState('books', 'description');
await db.vecManager.deleteIndex('books', 'description');
```

Index state is stored in `$meta` under `fts:{ns}:{field}` and `vec:{ns}:{field}`
respectively, using the same four lifecycle states as secondary indexes: 
`undefined` → `building` → `current` (or `stale`). See §16 for the lifecycle
model.

## Search API

`KmdbCollection<T>.search()` returns a `Future<SearchResult<T>>`:

```dart
final results = await db.collection<Book>('books').search(
  'Hyde Gothic',
  fields: ['description', 'title'], // omit to search all indexed fields
  filter: Filter.eq('type', 'novel'), // optional pre-filter
  mode: SearchMode.auto,              // default
  limit: 10,
  offset: 0,
);
```

`mode` controls which index is used:

| Value           | Behaviour                                                                    |
| :-------------- | :--------------------------------------------------------------------------- |
| `SearchMode.auto`     | Default. Hybrid if both indexes exist; falls back to whichever is available. No index available → empty result, field listed in `SearchMetadata.skipped`. |
| `SearchMode.lexical`  | BM25 only. No lexical index available → empty result, field listed in `SearchMetadata.skipped`. |
| `SearchMode.semantic` | Cosine similarity only. No semantic index available → empty result, field listed in `SearchMetadata.skipped`. |

### Result Types

```dart
/// The result of a search across one or more fields.
class SearchResult<T> {
  final SearchMetadata metadata;
  final List<SearchHit<T>> hits;
}

/// Metadata describing how the search was executed.
class SearchMetadata {
  /// The original query string.
  final String query;

  /// Fields that were successfully searched.
  final List<String> searched;

  /// Fields that were requested but skipped — no matching index exists.
  final List<String> skipped;

  /// Total matching documents before limit/offset are applied.
  final int total;
}

/// A single ranked result.
class SearchHit<T> {
  /// 1-based rank position.
  final int rank;

  /// Overall relevance score.
  ///
  /// - Lexical: highest per-field BM25 score.
  /// - Semantic: highest per-field cosine similarity score.
  /// - Hybrid: RRF score combining BM25 and cosine ranks.
  final double score;

  /// Per-field scores. Fields where the document did not score are absent.
  ///
  /// Keys follow these conventions across modes:
  ///
  /// | Mode    | Keys present                                                                 |
  /// | :------ | :--------------------------------------------------------------------------- |
  /// | Lexical | `"{field}:bm25"` — BM25 score for that field                                |
  /// | Semantic | `"{field}:cosine"` — cosine similarity for that field                       |
  /// | Hybrid  | `"{field}:bm25"` and/or `"{field}:cosine"` (raw component scores) plus `"{field}"` (per-field RRF contribution) |
  final Map<String, double> fieldScores;

  /// The document key.
  final String id;

  /// The decoded document.
  final T document;
}
```

## CLI: search Command

All text search functionality is surfaced under the `search` command:

```
# Index management
kmdb <db> search list   <collection>
kmdb <db> search create <collection> <field> [--fts | --semantic]
                                             [--stopwords] [--k1 <n>] [--b <n>]
kmdb <db> search delete <collection> <field> [--fts | --semantic]

# Query
kmdb <db> search <collection> "<query terms>"
          [--fields <field1,field2,...>]
          [--mode auto|lexical|semantic]   (default: auto)
          [--candidates <n>]               (default: 100)
          [--rrf-k <n>]                    (default: 60)
          [--limit <n>] [--offset <n>]     (defaults: 10, 0)
          [--explain]
          [--output table|json|ids]        (default: table)
```

The first positional argument after `search` is inspected: if it matches a known
subcommand name (`list`, `create`, `delete`) the invocation is treated as index
management; otherwise it is treated as a query. There are no `info` or `build`
subcommands — an index is built lazily on its first query (see below).

### Index management: `--fts` / `--semantic` are narrowing flags

`search create <collection> <field>` registers **both** an FTS (lexical) index
and a vector (semantic) index for the field by default — "turn on search for a
field" is the mental model, rather than separate index-family commands.
`--fts` and `--semantic` are *narrowing* flags:

| Flags                | `create` / `delete` acts on          |
| :------------------- | :----------------------------------- |
| _(none)_             | both the FTS and the vector index    |
| `--fts`              | the FTS (lexical) index only         |
| `--semantic`         | the vector (semantic) index only     |
| `--fts --semantic`   | both (equivalent to the no-flag default) |

`search list <collection>` takes no narrowing flags — it always reports every
FTS and vector registration for the collection, one row per field, annotated
with `[fts]`, `[semantic]`, or `[fts,semantic]`. The FTS side shows real build
status (`undefined` / `building` / `current` / `stale` / `syncing`); the vector
side shows only registration presence (`registered`), because the embedding
model may not be loaded during a plain `list`.

`search delete` errors only when *none* of the requested index type(s) are
actually registered for the field; deleting a field that has just one of the two
index types (registered via `--fts` or `--semantic` alone) succeeds.

### Vector index without an embedding model (graceful degradation)

A vector index requires `embeddingModel` to be configured in `local/config.json`
(for example `{ "type": "onnx", "modelId": "bge-small-en-v1.5" }`). `search
create` does **not** hard-fail when no model is configured: it writes the
registration and prints a note that search stays lexical-only until a model is
added. The registration lies dormant — the CLI only activates a `vecIndex` once
a model has actually been constructed — so a bare `search create` never bricks
the database.

### Query flags

- `--fields <f1,f2,...>` — comma-separated field list to search. Defaults to the
  union of the collection's FTS- and vector-indexed fields.
- `--mode auto|lexical|semantic` — search strategy (default `auto`). `auto`
  resolves to lexical when only an FTS index is available, semantic when only a
  vector index is available, and hybrid when both are present. `--mode semantic`
  additionally requires `embeddingModel` to be configured and errors if it is
  not; `--mode auto` falls back to lexical when no model/vector index is
  available.
- `--candidates <n>` — maximum candidate documents for semantic/hybrid vector
  scoring (default 100). Higher values improve recall at the cost of speed.
- `--rrf-k <n>` — Reciprocal Rank Fusion smoothing constant (default 60, must be
  ≥ 1). Only affects hybrid results; higher values reduce the advantage of very
  top-ranked documents.
- `--limit <n>` — maximum hits to return (default 10).
- `--offset <n>` — number of top hits to skip (default 0).
- `--explain` — print the resolved search plan (mode, searched fields, skipped
  fields, and total match count) ahead of the results.
- `--output table|json|ids` — output format (default `table`). `ids` prints one
  document key per line; `json` includes per-hit scores and `rrfK` (hybrid only).

The `--stopwords` flag on `create` enables the Stopwords ISO `en` stop-word list
for the new lexical index (Stage 3 of the preprocessing pipeline). Together with
`--k1 <n>` and `--b <n>` (BM25 parameters, defaults 1.2 and 0.75) it applies to
the FTS side only; these flags are accepted but have no effect on a
semantic-only registration.

> **Flag ordering.** The generic flag parser treats `--flag <positional>` as
> consuming the positional as the flag's value, so the bare flags
> (`--fts`, `--semantic`, `--stopwords`) must be placed *after* the positional
> arguments on the command line.

### Resolved mode label

`search` reports the mode it actually ran under. For an explicit
`--mode lexical`/`--mode semantic` it shows that mode directly. For `--mode auto`
the label is derived deterministically from the collection's configured indexes,
not from a runtime heuristic: both an FTS and a vector index ⇒ `hybrid`; FTS
only ⇒ `lexical`; vector only ⇒ `semantic`.

## Sync Behaviour

Text search uses the following `$$`-prefixed (local-only) system namespaces:

```
$$fts:          — lexical base index entries (term → tf per document)
$$fts:overlay:  — lexical overlay (recent writes pending compaction)
$$fts:corpus:   — lexical corpus statistics (n, totalTokens)
$$fts:doc:      — lexical per-document forward index (tokenCount)
$$vec:          — semantic vector entries (quantized embeddings)
$$vec:corpus:   — semantic corpus statistics (n)
$$vec:truncated: — semantic truncation markers
```

These namespaces use the `$$` (double-dollar) local-only prefix, which means
their entries are **never uploaded to the sync folder**. At flush time the
storage engine partitions the memtable: `$$`-prefixed entries are written to a
`.local.sst` file that `SyncEngine.push` identifies and skips when building its
upload list. Both the upload loop and the high-water mark fold operate on the
filtered list, so `$$fts:*` and `$$vec:*` entries never affect the HWM either.
See §6 (Flush Partitioning), §8 (SSTable Naming), and §12 (Sync Protocol) for
the full mechanism.

A device does not search a peer's index entries; each device rebuilds and
maintains its own indexes from the documents it holds (see Post-Sync Index
Maintenance below).

## Post-Sync Index Maintenance

Each device maintains its own text search indexes; it does not query index
entries that arrived from a peer (§20.7). When documents arrive via sync they
bypass the Query Layer's write interception path and are written directly into
the LSM engine as SSTables. FTS and vector indexes are therefore not updated
inline and must be brought current as a separate post-sync step.

### The `syncing` Lifecycle State

Text search indexes extend the four-state lifecycle shared with secondary indexes
(`undefined` → `building` → `current` / `stale`) with a fifth state: `syncing`.
This state indicates that a sync pull has delivered documents the index has not
yet processed.

| State     | Description                                              | Search behaviour                                                                                                                     |
| :-------- | :------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------- |
| `syncing` | A sync delta is being applied to an otherwise current index | Serve directly from the pre-sync index. Results are correct for all locally-written documents; recently synced documents may not yet appear. |

`syncing` is deliberately distinct from `stale`:

- A `stale` index may have missed an unbounded number of writes (e.g. a failed
  build, or writes that arrived while the index was in `building` state).
  Queries fall back to a full namespace scan.
- A `syncing` index is fully current for all local writes; only the bounded sync
  delta is pending. Queries serve directly from the index — the small, temporary
  omission is preferable to the cost of a full scan.

### SyncDelta Events

After ingesting a set of remote SSTables, the sync engine emits a `SyncDelta`
event per affected user namespace. Each event carries the set of
`(docId, changeType)` pairs — one entry per document that was added, updated,
or deleted by the incoming SSTables.

`FtsManager` and `VecManager` subscribe to `SyncDelta` events. On receipt for a
namespace with a `current` index:

1. Transition the index state from `current` → `syncing` in `$meta`.
2. Process each entry in the delta using the same insert / update / delete logic
   as write interception (§21 and §22 respectively).
3. Transition `syncing` → `current` on completion.

### Delta Size and Expected Latency

The delta is always bounded by the number of documents modified on peer devices
since the last sync. For the typical single-user pattern — writing on one device
while another is offline — the delta is the set of documents modified in that
session, which is usually small. FTS delta processing is fast (pure Dart
tokenisation); vec delta processing is bounded by ONNX inference throughput.

The exception is a **first-time device load**, where all documents arrive via
sync against an empty local database. The delta equals the full collection. A
one-time indexing delay is expected and proportional to collection size. For vec
indexes on large collections this can be significant; the application should
surface a progress indicator and process the delta in a background isolate so
the UI remains responsive (see Isolate Recommendation below).

### Crash Recovery

If the process is killed while an index is in `syncing` state, `$meta` retains
the state. On the next `open()`, any index found in `syncing` is transitioned
to `stale`. The next `search()` on that index triggers a full rebuild — the
same recovery path used by secondary indexes (§16).

### Isolate Recommendation (Flutter)

Both delta types are CPU-bound. Applications should run `SyncEngine.sync()` on
a dedicated background isolate. Because `FtsManager` and `VecManager` are
registered listeners on the sync engine, `SyncDelta` processing occurs on the
same isolate — the UI thread is never blocked by tokenisation or ONNX inference.

```dart
// Run sync (and any resulting delta indexing) off the main isolate.
await Isolate.run(() => db.syncEngine.sync());
```

For first-load scenarios on Flutter, consider displaying a progress indicator
and awaiting an `onSearchIndexReady` callback before enabling search in the UI.
The callback fires when all `syncing` indexes transition to `current`.

## Charset Detection for Vault Plain-Text Extraction

When vault search (WI-3) extracts text from `text/plain` blobs for indexing,
it must determine the character encoding of the raw bytes before decoding them
to a string. Treating all bytes as UTF-8 would silently produce garbled text
for files encoded in legacy Western or CJK encodings.

Charset detection is handled by the `decodeText` utility function in
`packages/kmdb/lib/src/vault/search/charset_util.dart`. It calls
`betto_charset_detector`'s `detectCharset(Uint8List)` function, which runs a
three-stage pipeline (BOM inspection → UTF-8 structural validation → candidate
probe) and returns a lowercase IANA encoding label such as `"utf-8"`,
`"windows-1252"`, `"shift-jis"`, or `"euc-jp"`. `decodeText` then dispatches
to the appropriate codec and returns both the detected label and the decoded
string as a `CharsetDecodeResult` record:

```dart
/// ({String charset, String text})
final (:charset, :text) = decodeText(bytes);
```

The detected label is recorded in the `charset` field of the
`$$vault:extract:{sha256}` KV entry (`VaultExtractionState.charset`, see §32)
so that indexing metadata records the original encoding. There is no
filesystem `extract_status.json` manifest — extraction status and metadata are
persisted solely in that KV entry. `ascii` is never returned as a label —
ASCII content passes the UTF-8 structural validation stage and is reported as
`"utf-8"`. This utility is internal to the `kmdb` package and is not exported
from `kmdb.dart`.
