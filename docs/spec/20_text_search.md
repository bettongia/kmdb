# Text Search

## Overview

Text search extends the Query Layer with two complementary index types and a
hybrid ranking mode that combines them:

| Mode        | Index type        | Ranking algorithm          | Best for                              |
| :---------- | :---------------- | :------------------------- | :------------------------------------ |
| `lexical`   | Inverted index    | BM25                       | Exact keywords, technical identifiers |
| `semantic`  | Flat vector index | Cosine similarity          | Conceptual meaning, paraphrases       |
| `hybrid`    | Both              | Reciprocal Rank Fusion     | General-purpose search                |

Text search indexes are **device-local** — they are never synced (§20.7). Each
device independently builds and maintains its own indexes against the documents
it holds.

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
  deferred; lexical search may be revisited separately.
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
| `SearchMode.auto`     | Default. Hybrid if both indexes exist; falls back to whichever is available. |
| `SearchMode.lexical`  | BM25 only. Error if no lexical index exists on the field.                    |
| `SearchMode.semantic` | Cosine similarity only. Error if no semantic index exists on the field.      |

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
  /// In hybrid mode, individual component scores are available under the keys
  /// "{field}:bm25" and "{field}:cosine" alongside the per-field RRF score.
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
kmdb <db> search create <collection> <field> [--lazy] [--semantic]
kmdb <db> search info   <collection> <field> [--semantic]
kmdb <db> search delete <collection> <field> [--semantic]
kmdb <db> search build  <collection> <field> [--force] [--semantic]

# Query
kmdb <db> search <collection> "<query terms>"
          [--fields <field1,field2,...>]
          [--filter <json>]
          [--select <field1,field2,...>]
          [--mode auto|lexical|semantic]
          [--candidates <n>]
          [--limit <n>] [--offset <n>]
          [--verbose]
          [--output table|json]
```

The `--semantic` flag on management subcommands targets semantic (vector)
indexes. Without it, the subcommand targets lexical (FTS) indexes.

The first positional argument after `search` is inspected: if it matches a known
subcommand name (`list`, `create`, `info`, `delete`, `build`) the invocation is
treated as index management; otherwise it is treated as a query.

## Sync Exclusion

All text search system namespaces are `$`-prefixed and are excluded from sync by
the same rule that excludes `$index:*` and `$meta`:

```
$fts:          — lexical base index entries (term → tf per document)
$fts:overlay:  — lexical overlay (recent writes pending compaction)
$fts:corpus:   — lexical corpus statistics (n, totalTokens)
$fts:doc:      — lexical per-document forward index (tokenCount)
$vec:          — semantic vector entries (quantized embeddings)
$vec:corpus:   — semantic corpus statistics (n)
$vec:truncated: — semantic truncation markers
```

Text search indexes are rebuilt locally on each device from the documents that
device holds. They are never uploaded in SSTables or referenced in high-water
mark files.
