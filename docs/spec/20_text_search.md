# Text Search

## Overview

Text search extends the Query Layer with two complementary index types and a
hybrid ranking mode that combines them:

| Mode        | Index type        | Ranking algorithm          | Best for                              |
| :---------- | :---------------- | :------------------------- | :------------------------------------ |
| `lexical`   | Inverted index    | BM25                       | Exact keywords, technical identifiers |
| `semantic`  | Flat vector index | Cosine similarity          | Conceptual meaning, paraphrases       |
| `hybrid`    | Both              | Reciprocal Rank Fusion     | General-purpose search                |

Text search indexes are **device-local in intent** — each device independently
builds and maintains its own indexes against the documents it holds, and a
device never *relies* on a peer's index. However, their backing namespaces are
**not excluded from upload**: `$fts:*` and `$vec:*` values ride in uploaded
SSTables and reach cloud storage like every other system namespace (see
§20.7 and §12). Their confidentiality in the cloud is provided by value-level
encryption (§31), not by upload filtering.

See §21 (Lexical Search), §22 (Semantic Search), and §23 (Hybrid Search) for
the detail of each mode.

## Scope

### Supported

- Single `String`-valued document fields encoded as UTF-8 plain text.
- English-language text (`en`). Tokenisation, stop-word lists, and the
  stemmer are tuned for English.

### Out of scope

- **Non-Latin scripts** — CJK, Thai, Arabic, and other scripts that require
  language-specific segmentation are not supported in this version.
- **Web browser** — semantic search (ONNX inference) on the web platform is
  deferred. Lexical search is now supported on web: `FtsManager` uses
  `BrowserTokenizer` (backed by the browser's native `Intl.Segmenter` API) as
  the default tokenizer, giving UAX #29-quality segmentation at zero bundle cost.
- **Plain text extraction** — content submitted for indexing must arrive as
  plain text. Extracting text from PDF, HTML, or DOCX is the caller's
  responsibility.
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
kmdb <db> search list   <collection> [--semantic]
kmdb <db> search create <collection> <field> [--lazy] [--stopwords] [--semantic]
kmdb <db> search info   <collection> <field> [--semantic]
kmdb <db> search delete <collection> <field> [--semantic]
kmdb <db> search build  <collection> <field> [--force] [--semantic]

# Query
kmdb <db> search <collection> "<query terms>"
          [--fields <field1,field2,...>]
          [--filter <json>]
          [--select <field1,field2,...>]
          [--mode auto|lexical|semantic]   (default: auto)
          [--candidates <n>]
          [--limit <n>] [--offset <n>]
          [--verbose]
          [--output table|json]
```

The `--semantic` flag on management subcommands targets semantic (vector)
indexes. Without it, the subcommand targets lexical (FTS) indexes.

The `--stopwords` flag on `create` enables the Stopwords ISO `en` stop-word
list for the new lexical index (Stage 3 of the preprocessing pipeline). It is
silently ignored when `--semantic` is also present, since vector indexes have
no stop-word filtering stage.

The first positional argument after `search` is inspected: if it matches a known
subcommand name (`list`, `create`, `info`, `delete`, `build`) the invocation is
treated as index management; otherwise it is treated as a query.

## Sync Behaviour

Text search uses the following `$`-prefixed system namespaces:

```
$fts:          — lexical base index entries (term → tf per document)
$fts:overlay:  — lexical overlay (recent writes pending compaction)
$fts:corpus:   — lexical corpus statistics (n, totalTokens)
$fts:doc:      — lexical per-document forward index (tokenCount)
$vec:          — semantic vector entries (quantized embeddings)
$vec:corpus:   — semantic corpus statistics (n)
$vec:truncated: — semantic truncation markers
```

These namespaces are written through the shared `WriteBatch` → memtable →
SSTable path, so their values **are uploaded** during sync. As §12 records,
sync is whole-file at the SSTable level: `SyncEngine.push` uploads each local
SSTable's bytes unchanged and the consolidation coordinator merges whole
SSTables. There is no upload-time, server-side, or per-entry namespace filter —
the `syncNamespaces` parameter restricts only which user collections the caller
intends to replicate and is not consulted in `push`, `pull`, or consolidation.
Consequently every `$fts:*` and `$vec:*` entry rides in uploaded SSTables and
reaches cloud storage, alongside `$meta`, `$index:*`, `$ver:*`, and `$vault`.

Confidentiality of these values in the cloud is provided by **value-level
encryption** (§31), not by upload filtering: when database encryption is
enabled, every value written through `ValueCodec` — including all `$fts:*` and
`$vec:*` entries — is stored as ciphertext in SSTables, so the uploaded bytes
carry no plaintext index content.

Text search indexes nevertheless remain **device-local in operation**. A device
does not search a peer's uploaded index entries directly; each device rebuilds
and maintains its own indexes from the documents it holds (see Post-Sync Index
Maintenance below), and high-water mark files track SSTables, not index state.

> **Future work.** Upload-time namespace filtering — stripping `$fts:*`,
> `$vec:*`, and other excluded-namespace entries before upload, or keeping them
> out of synced SSTables entirely — is not implemented. If it is added, this
> section and §12 must be updated together to describe the actual filter. Until
> then, do not document exclusion behaviour the code does not perform.

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
