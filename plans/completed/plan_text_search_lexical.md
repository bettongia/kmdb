# Text Search — Phase 2: Lexical Search

**Status**: Implemented

**PR link**: _pending_

## Problem statement

Phase 2 delivers BM25 keyword search over nominated `String` fields in a
`KmdbCollection<T>`. It depends on the shared foundations from Phase 1
(`plan_text_search_shared.md`) and can proceed in parallel with Phase 3
(semantic). Phase 4 (hybrid) must wait for both.

Concretely, this plan:

- Adds the `snowball_stemmer` package dependency to `kmdb`
- Implements the four-stage text preprocessing pipeline in `kmdb` (tokenise →
  normalise → [stop-word filter] → stem)
- Implements `FtsManager` in `kmdb`: write interception (insert, update, delete)
  and BM25 query execution
- Replaces the `search()` stub on `KmdbCollection<T>` for `SearchMode.lexical`
  (and `SearchMode.auto` when no vector index is present)
- Adds the `search` command to the CLI with `--fields`, `--mode`, `--limit`,
  `--offset`, and `--output` flags
- Enforces all write-atomicity and cache-exemption requirements from spec §21

## Open questions

_None — all design decisions resolved in spec §21._

## Investigation

### Design decisions (see spec §21)

- The preprocessing pipeline is implemented as a series of pure functions in
  `kmdb/lib/src/search/lexical/pipeline.dart`. Each stage is independently
  testable. The pipeline is applied identically to indexed values and query
  strings.
- Stop-word filtering is **disabled by default** (`stopWords: false` on
  `FtsIndexDefinition`). When enabled, the Stopwords ISO `en` list is used. A
  user may pass a custom list; the pre-defined list is the default when
  `stopWords: true`.
- Stemming uses the `snowball_stemmer` Dart package (English only for Phase 2).
  This is the only external dependency added by this plan.
- `FtsManager` mirrors the structure of `IndexManager` (spec §16): it holds the
  in-memory index state, intercepts writes via `KmdbCollection`, and is
  initialised on `KmdbDatabase.open()` from the `ftsIndexes` list.
- All FTS key writes are in the same `WriteBatch` as the document write
  (atomicity). No separate flush or background worker is needed.
- The overlay pattern (base index + overlay + compaction) matches spec §21
  exactly. `FtsManager` exposes a `compact(String namespace, String field)`
  method for future use; it is not called automatically in Phase 2.
- `FtsIndexDefinition.lazy` (default `false`): when `false`, the full namespace
  is scanned and indexed on the first `search()` call if the index has not yet
  been built. When `true`, indexing only begins at the first write after
  `open()`. Lazy is provided for opt-in when the collection is very large.
- The `$fts:` key namespaces are always excluded from the session object cache
  and the materialised view cache (cache-exemption is enforced in `CacheLayer`
  using the same `$`-prefix exclusion already applied to `$meta`, `$index`, and
  `$cache`).

### Key files to create / modify

| Action | Path |
| :----- | :--- |
| Modify | `packages/kmdb/pubspec.yaml` |
| Create | `packages/kmdb/lib/src/search/lexical/pipeline.dart` |
| Create | `packages/kmdb/lib/src/search/lexical/fts_manager.dart` |
| Create | `packages/kmdb/lib/src/search/lexical/fts_index_state.dart` |
| Modify | `packages/kmdb/lib/src/search/fts_index_definition.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_database.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart` |
| Modify | `packages/kmdb/lib/kmdb.dart` |
| Create | `packages/kmdb/test/search/lexical/pipeline_test.dart` |
| Create | `packages/kmdb/test/search/lexical/fts_manager_test.dart` |
| Create | `packages/kmdb/test/search/lexical/fts_search_integration_test.dart` |
| Create | `packages/kmdb_cli/lib/src/commands/search_command.dart` |
| Modify | `packages/kmdb_cli/lib/src/kmdb_cli.dart` |
| Modify | `packages/kmdb_cli/test/` |

### Edge cases

- An empty query string must return an empty `SearchResult` with no hits and no
  error (all preprocessing stages return empty output for empty input).
- A query whose every term is a stop word (when stop-word filtering is on) must
  return an empty `SearchResult`.
- A document deleted before compaction must be excluded from results via the
  overlay TOMBSTONE — not just from future inserts.
- Updating a document that changes the token count must correctly adjust
  `totalTokens` in corpus stats. The old token count is read from
  `$fts:doc:{ns}:{field}:{docId}` before the `WriteBatch`.
- `FtsIndexDefinition.k1` and `b` outside their sensible ranges (e.g. `k1 = 0`,
  `b = 2.0`) must not panic — BM25 remains defined for any positive `k1` and
  `b ∈ [0, 1]`. Validation is optional but any `ArgumentError` must be thrown
  in `FtsIndexDefinition`'s constructor, not at query time.
- Multi-field search (multiple fields specified in `fields:`) scores each
  document per-field and takes the highest per-field score as the document's
  overall score. The raw per-field scores are carried in `SearchHit.fieldScores`.
- A `search()` call with `fields: []` (empty list) must behave as if all FTS
  indexed fields for the collection were specified.
- A field named in `fields:` that has no FTS index must be added to
  `SearchMetadata.skipped`, not cause an error.

## Implementation plan

### Phase 1 — Add `snowball_stemmer` dependency

- [x] Add `snowball_stemmer: ^0.2.x` (or current stable) to
  `packages/kmdb/pubspec.yaml` under `dependencies:`
- [x] Run `dart pub get` from workspace root; confirm resolution
- [x] Verify `dart analyze packages/kmdb` still passes

### Phase 2 — Text preprocessing pipeline

- [x] Create `packages/kmdb/lib/src/search/lexical/pipeline.dart`:
  - `List<String> tokeniseAndNormalise(String text, Tokeniser tokeniser)` —
    calls `tokeniser.tokenise(text)` then lowercases each token
  - `List<String> filterStopWords(List<String> tokens, Set<String> stopWords)` —
    removes tokens that appear in `stopWords`; no-op if `stopWords` is empty
  - `List<String> stem(List<String> tokens)` — applies the Snowball English
    stemmer from `snowball_stemmer` to each token
  - `List<String> preprocess(String text, Tokeniser tokeniser,
      {Set<String> stopWords = const {}})` — chains the three steps; this is
    the function called by both indexing and query paths
  - English stop-word list constant `kEnglishStopWords` (Stopwords ISO `en`
    list as a `const Set<String>`)
- [x] Tests (`packages/kmdb/test/search/lexical/pipeline_test.dart`):
  - [x] Empty string returns empty list at each stage
  - [x] Normalisation lowercases Unicode correctly (`Jekyll` → `jekyll`)
  - [x] Stop-word list removes `the`, `and`, `is`; passes through `jekyll`
  - [x] Stemming: `investigates` → `investig`, `occurring` → `occur`,
        `disturbing` → `disturb`
  - [x] Full pipeline: prose sentence produces expected stemmed token set
  - [x] Technical identifiers survive pipeline (`mTLS`, `0x8004210B`)
  - [x] Query with all stop words returns empty list when filtering enabled
  - [x] Identical output for indexed and query paths (same input → same tokens)

### Phase 3 — FTS index state and key codec

- [x] Create `packages/kmdb/lib/src/search/lexical/fts_index_state.dart`:
  - `FtsIndexStatus` enum: `undefined`, `building`, `current`, `stale`,
    `syncing` — `syncing` indicates a sync delta is being applied; queries
    serve from the pre-sync index while catch-up is in progress (mirrors
    `IndexStatus` in `index_manager.dart`, plus the text-search-specific state)
  - `FtsIndexState` class: `namespace`, `field`, `status`, `builtThrough`
    (key cursor), `builtAt` (ISO timestamp string)
  - CBOR encode/decode helpers (`toMap` / `fromMap`) for persistence in `$meta`
  - Static key helpers:
    - `baseKey(ns, field, term, docId)` → `$fts:{ns}:{field}:{term}:{docId}`
    - `overlayKey(ns, field, docId)` → `$fts:overlay:{ns}:{field}:{docId}`
    - `corpusKey(ns, field)` → `$fts:corpus:{ns}:{field}`
    - `docKey(ns, field, docId)` → `$fts:doc:{ns}:{field}:{docId}`
    - `metaKey(ns, field)` → `$meta:fts:{ns}:{field}`

### Phase 4 — `FtsManager`

- [x] Create `packages/kmdb/lib/src/search/lexical/fts_manager.dart`:
  - `class FtsManager` — manages all FTS indexes for a database instance
  - Constructor: `FtsManager(KvStore store, List<FtsIndexDefinition> defs)`
  - `void interceptWrite(String ns, String docId, Map<String, dynamic> doc,
      WriteBatch batch)` — called by `KmdbCollection` before each write
    - For each `FtsIndexDefinition` matching `ns`, extract the field value;
      if the document has the field, add FTS writes to `batch`:
      - Base index entries (`$fts:{ns}:{field}:{term}:{docId}`)
      - `$fts:doc:{ns}:{field}:{docId}` → token count
      - Corpus stats delta in `$fts:corpus:{ns}:{field}`
  - `void interceptDelete(String ns, String docId, WriteBatch batch)` —
    writes TOMBSTONE in overlay, decrements corpus stats
  - `void interceptUpdate(String ns, String docId,
      Map<String, dynamic> newDoc, WriteBatch batch)` — reads old token count
    from `$fts:doc:{ns}:{field}:{docId}`, writes overlay entry, adjusts stats
  - `Future<void> ensureBuilt(String ns, String field)` — triggers lazy build
    if `FtsIndexState.status == undefined`; scans namespace and indexes each
    document; updates state to `current` in `$meta`
  - `Future<SearchResult<T>> search<T>(...)` — see Phase 6
  - `Future<void> compact(String ns, String field)` — reconciles overlay with
    base index; each document processed as one `WriteBatch`
  - `Future<void> applyDelta(String ns, SyncDelta delta)` — processes a
    post-sync delta (§20.8): transitions index to `syncing`, applies each
    added/updated/deleted `(docId, changeType)` pair using the same
    insert/update/delete write paths as write interception, then transitions
    to `current`; each document committed in its own `WriteBatch`

### Phase 5 — Write interception in `KmdbCollection`

- [x] Modify `packages/kmdb/lib/src/query/kmdb_database.dart`:
  - After `IndexManager` is initialised, create and store a `FtsManager?
    _ftsManager` (null when `ftsIndexes` is empty)
  - Replace the `FtsManager? get ftsManager => null` stub from Phase 1 with
    the real instance
- [x] Modify `packages/kmdb/lib/src/query/kmdb_collection.dart`:
  - In `put()`, `insert()`, `replace()`, `update()`, and `delete()`, call the
    appropriate `FtsManager` intercept method before committing the `WriteBatch`
  - The FTS writes and document write must be in the **same** `WriteBatch`
  - Guard each call with `if (_db.ftsManager != null &&
      _db.ftsManager!.hasIndex(namespace))` to avoid overhead when no FTS index
    is defined for the collection
- [x] Tests (`packages/kmdb/test/search/lexical/fts_manager_test.dart`):
  - [x] `interceptWrite` adds correct keys to batch for a single-term field
  - [x] `interceptUpdate` adjusts corpus stats correctly
  - [x] `interceptDelete` writes TOMBSTONE and decrements `n`
  - [x] `compact` removes stale base index keys for updated document
  - [x] `compact` removes all keys for tombstoned document

### Phase 6 — BM25 query execution

- [x] Add `Future<SearchResult<T>> search<T>(...)` to `FtsManager`:
  - Accept `String query`, `List<String> fields`, `Filter? filter`,
    `SearchMode mode`, `int limit`, `int offset`, `Tokeniser tokeniser`
  - If `filter` is supplied, resolve `candidateIds` first via secondary index
    lookup (§16) or full namespace scan — this is the pre-filter step
  - Apply preprocessing pipeline to query string
  - For each query term, prefix-scan `$fts:{ns}:{field}:{term}:`, restricting
    to `candidateIds` when present, and collect `(docId, tf)` pairs
  - Filter results through overlay (no entry → use base tf; overlay → use
    overlay tf if term present; TOMBSTONE → exclude)
  - Read corpus stats once (`$fts:corpus:{ns}:{field}`) per field
  - Score using BM25; when multiple fields are searched, take max per-field
    score as document score; carry per-field scores in `SearchHit.fieldScores`
  - Sort descending by score; apply `offset` and `limit`
  - Return `SearchResult<T>` with `SearchMetadata` populated
- [x] Replace stub in `packages/kmdb/lib/src/query/kmdb_collection.dart`:
  - If `mode == SearchMode.lexical` or `mode == SearchMode.auto` (and no vec
    index present), delegate to `ftsManager.search()`
  - If no FTS index exists for the requested fields, return stub result with
    those fields in `skipped`
- [x] Tests (`packages/kmdb/test/search/lexical/fts_search_integration_test.dart`):
  - [x] Single-field search returns ranked results in correct order
  - [x] Multi-field search: correct per-field scores in `fieldScores`
  - [x] Deleted document does not appear in results
  - [x] Updated document reflects new content (overlay supersedes base)
  - [x] `filter:` predicate resolves `candidateIds` before scanning; only
        matching documents are scored
  - [x] Filtered search returns correct results when secondary index is
        available vs. full-scan fallback
  - [x] `offset` and `limit` applied correctly
  - [x] Query with all stop words (filtering on) returns empty result
  - [x] Empty query returns empty result
  - [x] Field not indexed appears in `SearchMetadata.skipped`
  - [x] `ensureBuilt` builds index from pre-existing documents correctly
  - [x] BM25 scores increase when term frequency increases
  - [x] `applyDelta` with added documents indexes them correctly; they appear
        in subsequent search results
  - [x] `applyDelta` with deleted documents writes TOMBSTONE; they are excluded
        from results
  - [x] `applyDelta` transitions index `current` → `syncing` → `current`;
        searches during `syncing` serve from the pre-delta index
  - [x] Process killed during `applyDelta` leaves index in `syncing`; next
        `open()` transitions to `stale` and full rebuild is triggered

### Phase 7 — CLI `search` command

- [x] Create `packages/kmdb_cli/lib/src/commands/search_command.dart`:
  - `dart run kmdb_cli search <collection> <query>`
  - Named options:
    - `--fields <field1,field2>` — comma-separated list; defaults to all FTS
      indexed fields for the collection
    - `--mode auto|lexical|semantic` — search mode; default `auto`
    - `--limit <n>` — default 10
    - `--offset <n>` — default 0
    - `--output table|json|ids` — default `table`
  - Reads database path and `ftsIndexes` config from `local/config.json`; if no
    FTS indexes are configured, prints an informative error and exits with code 1
  - Table output: rank, score, id, and each requested field (truncated to 60
    chars)
  - JSON output: full `SearchResult` serialized to JSON
  - IDs output: one document id per line
- [x] Implement `search create` subcommand flags:
  - `--lazy` — sets `FtsIndexDefinition.lazy = true`
  - `--stopwords` — sets `FtsIndexDefinition.stopWords = true`; silently ignored
    when `--semantic` is also present (vector indexes have no stop-word stage)
- [x] Register command in `packages/kmdb_cli/lib/src/kmdb_cli.dart`
- [x] Update `local/config.json` schema to accept `ftsIndexes` array (each entry:
  `{ "collection": "...", "field": "...", "k1": 1.2, "b": 0.75, "stopWords": false }`)
- [x] Tests:
  - [x] `search_command_test.dart`: command runs against a test database with
    pre-seeded documents; verifies ranked output
  - [x] `--output json` produces valid JSON with correct structure
  - [x] Missing `--fields` defaults to all FTS-indexed fields
  - [x] Collection with no FTS index prints error, exits 1
  - [x] `search create` with `--stopwords` creates index with `stopWords: true`
  - [x] `search create` with `--stopwords --semantic` silently ignores `--stopwords`

## Summary

All 7 phases implemented and all tests passing (796 kmdb + 347 kmdb_cli).

**Key design decision: namespace-per-term storage layout.** The KvStore enforces
32-character hex (UUIDv7) keys everywhere. The original design used
`{term}:{docId}` compound keys with prefix scans — incompatible with that
constraint. The final design mirrors `IndexWriter`'s namespace-per-value scheme:
each (collection, field, term) gets its own namespace
`$fts:{ns}:{field}:{hexTerm}` with docIds as keys, and term-namespace scans
replace prefix scans. Terms are hex-encoded via UTF-8 byte representation.

**Doc info carries old terms for compaction.** Each `$fts:doc:` entry stores a
CBOR map `{n: tokenCount, t: [term1, term2, ...]}` where `t` holds the terms
currently in the base index for that document. On update, the old terms are
preserved in the doc info until `compact()` rewrites the base — this is the only
way `compact()` knows which per-term namespaces to clean up for stale entries.

**`_buildIndex` handles overlays inline.** When `ensureBuilt` triggers a build
with pending overlays, the build processes those overlays immediately: tombstoned
documents are skipped; map overlays are used as authoritative content, stale old
base entries are removed, and the overlay is cleared. This prevents the doc-info
"old terms" tracker from being corrupted by a build that ignores in-progress
updates.

**Corpus stats key.** Fixed sentinel `'00000000000000000000000000000001'` — a
valid 32-char hex key that cannot collide with UUIDv7 keys (timestamp bits fill
the high bytes).

**Implemented artefacts:**

| Artefact | Notes |
|---|---|
| `packages/kmdb/lib/src/search/lexical/pipeline.dart` | Tokenise → normalise → stop-word filter → Snowball stem |
| `packages/kmdb/lib/src/search/lexical/fts_index_state.dart` | 5-status lifecycle enum + CBOR state persistence |
| `packages/kmdb/lib/src/search/lexical/fts_manager.dart` | Full BM25 FTS manager: write interception, lazy build, BM25 scoring, compaction, delta application |
| `packages/kmdb/lib/src/query/kmdb_database.dart` | FtsManager wired in at open() |
| `packages/kmdb/lib/src/query/kmdb_collection.dart` | search() delegates to FtsManager |
| `packages/kmdb/lib/kmdb.dart` | FtsManager, SyncDelta, FtsIndexState exports |
| `packages/kmdb_cli/lib/src/config/kmdb_config.dart` | FtsIndexRecord typedef + ftsIndexes CRUD |
| `packages/kmdb_cli/lib/src/commands/search_command.dart` | search / search list / search create / search delete |
| `packages/kmdb_cli/lib/src/cli_runner.dart` | SearchCommand registered + help text |
| `packages/kmdb/test/search/lexical/pipeline_test.dart` | 30 tests |
| `packages/kmdb/test/search/lexical/fts_manager_test.dart` | 20 tests |
| `packages/kmdb/test/search/lexical/fts_search_integration_test.dart` | Integration tests via public Collection.search() API |
| `packages/kmdb_cli/test/commands/search_command_test.dart` | 28 CLI tests |
