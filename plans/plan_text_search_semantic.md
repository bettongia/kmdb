# Text Search — Phase 3: Semantic Search

**Status**: Investigated

**PR link**: _pending_

## Problem statement

Phase 3 delivers cosine similarity vector search over nominated `String` fields
using BGE Small En v1.5 (ONNX). It depends on the shared foundations from
Phase 1 (`plan_text_search_shared.md`) and can proceed in parallel with Phase 2
(lexical). Phase 4 (hybrid) must wait for both.

Concretely, this plan:

- Completes the `kmdb_inferencing` package (ONNX FFI bindings, BGE model assets
  via Git LFS, `BertTokenizer`, `OnnxEmbeddingModel`)
- Implements `VecManager` in `kmdb`: write interception (insert, update, delete)
  with SQ8 quantisation, and flat-scan cosine similarity query execution
- Replaces the `search()` stub on `KmdbCollection<T>` for `SearchMode.semantic`
  (and `SearchMode.auto` when no FTS index is present)
- Enforces all write-atomicity, cache-exemption, and inference-failure policies
  from spec §22

This plan does **not** implement the hybrid path — that is Phase 4.

## Open questions

_None — all design decisions resolved in spec §22._

## Investigation

### Design decisions (see spec §22)

- `kmdb_inferencing` is the sole package that holds ONNX FFI and model assets.
  It depends on `kmdb` for `EmbeddingModel` and `Tokeniser`. Keeping FFI out of
  `kmdb` mirrors how `kmdb_zstd` holds Zstd FFI.
- The BGE Small En v1.5 model binary (`bge_small.onnx`, ~127 MB) is tracked via
  **Git LFS**. Supporting assets (`vocab.txt`, `tokenizer_config.json`) are
  small enough to track normally. All assets live under
  `packages/kmdb_inferencing/assets/models/bge-small-en/`.
- `BertTokenizer` accepts a `Tokeniser` in its constructor
  (`RegExpTokeniser` by default). The word segmentation output feeds into
  WordPiece subword splitting; the BERT token IDs are entirely distinct from the
  stemmed tokens produced by the lexical pipeline.
- Inference runs **synchronously, before the `WriteBatch` is committed**. If
  inference fails the document write is rejected — the document store and the
  semantic index remain consistent (Option A from the proposal).
- Quantisation to SQ8 uses the fixed symmetric range for L2-normalized vectors:
  `u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)`. Dequantise with
  `f = u / 255.0 * 2.0 - 1.0`. No per-vector calibration is needed.
- At kmdb's expected scale (<50 k documents) a brute-force flat scan is faster
  than an ANN index. The query path prefix-scans
  `$vec:{ns}:{field}:`, dequantises each stored vector, computes the dot product
  with the (float32) query vector, and returns the top-`candidates` results by
  score descending.
- The truncation marker `$vec:truncated:{ns}:{field}:{docId}` is written when a
  field value exceeds 510 usable tokens. It is diagnostic only — not read on the
  query path.
- All `$vec:` key namespaces are exempt from the session object cache and the
  materialised view cache (same `$`-prefix exclusion as `$fts:` and `$index:`).
- `OnnxEmbeddingModel.load()` is a factory that resolves the model path relative
  to the package assets directory. On native platforms it uses `dart:io`. The
  model asset must exist on disk before `load()` is called; if the file is
  missing, `load()` throws `UnsupportedError` with a clear message.

### Key files to create / modify

| Action | Path |
| :----- | :--- |
| Complete | `packages/kmdb_inferencing/lib/src/ort_session.dart` |
| Create | `packages/kmdb_inferencing/lib/src/bert_tokenizer.dart` |
| Create | `packages/kmdb_inferencing/lib/src/sq8.dart` |
| Complete | `packages/kmdb_inferencing/lib/src/embedding_model.dart` |
| Modify | `packages/kmdb_inferencing/lib/kmdb_inferencing.dart` |
| Create | `packages/kmdb_inferencing/assets/models/bge-small-en/.gitkeep` |
| Modify | `packages/kmdb_inferencing/test/kmdb_inferencing_test.dart` |
| Create | `packages/kmdb/lib/src/search/semantic/vec_manager.dart` |
| Create | `packages/kmdb/lib/src/search/semantic/vec_index_state.dart` |
| Modify | `packages/kmdb/lib/src/search/vec_index_definition.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_database.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart` |
| Create | `packages/kmdb/test/search/semantic/vec_manager_test.dart` |
| Create | `packages/kmdb/test/search/semantic/vec_search_integration_test.dart` |
| Modify | `packages/kmdb_cli/lib/src/commands/search_command.dart` |

### Edge cases

- Inference failure must roll back the entire write — the `WriteBatch` must not
  be committed. The error propagates to the caller as a `StateError`.
- A field value that exceeds 510 BERT tokens must embed the first 510 tokens and
  write the `$vec:truncated:` marker. The write succeeds; only the marker signals
  truncation.
- An empty field value (empty string or whitespace-only) produces an embedding
  of the `[CLS][SEP]` tokens only. This is not an error; the embedding is
  stored normally.
- Deleting a document that was truncated must also delete the
  `$vec:truncated:{ns}:{field}:{docId}` key (safe no-op if absent — use
  `WriteBatch.delete` which is idempotent).
- Updating a document does not require reading the previous vector — the new
  vector overwrites the old entry atomically in the `WriteBatch`. The corpus `n`
  count is unchanged on update.
- `OrtInferenceSession` must be closed explicitly; `OnnxEmbeddingModel.dispose()`
  releases the native resources. `KmdbDatabase.close()` must call
  `embeddingModel.dispose()` if an `embeddingModel` was supplied.
- When `VecIndexDefinition.lazy` is `false` (default), `ensureBuilt()` is called
  on the first `search()` call. Building the full vec index may take several
  seconds for large collections — callers should be aware of the latency on
  first query.
- Multi-field vector search takes the highest per-field cosine similarity score
  as the document overall score. Per-field scores are carried in
  `SearchHit.fieldScores` keyed as `"{field}:cosine"`.

## Implementation plan

### Phase 1 — ORT session (from spike)

- [ ] Move `OrtInferenceSession` from
  `spikes/bge_embeddings/lib/src/ort_session.dart` into
  `packages/kmdb_inferencing/lib/src/ort_session.dart`
  - Update license header year
  - Add doc comments on `create()` and `run()` describing input/output tensor
    shapes (input_ids, attention_mask, token_type_ids all `[1, seqLen]`;
    output is `[1, seqLen, 384]` float32 logits)
  - Update import paths (remove spike-local imports; use package imports)
- [ ] Move `ort_bindings.dart`, `ort_library.dart` from spike into
  `packages/kmdb_inferencing/lib/src/`
  - Update import paths
- [ ] Run `dart analyze packages/kmdb_inferencing`; confirm no issues

### Phase 2 — `BertTokenizer` (from spike)

- [ ] Move `BertTokenizer` from `spikes/bge_embeddings/lib/src/tokenizer.dart`
  into `packages/kmdb_inferencing/lib/src/bert_tokenizer.dart`
  - Change constructor signature to accept `Tokeniser tokeniser` (from `kmdb`)
    with `RegExpTokeniser()` as default; remove the inline
    `RegExpTokeniser().tokenise(normalized)` placeholder
  - Import `package:kmdb/kmdb.dart` for `Tokeniser` and `RegExpTokeniser`
  - Add `IcuTokeniser` note in doc comment: `IcuTokeniser` from
    `package:kmdb_tokenizer_icu` can be supplied as a drop-in substitute
  - Add doc comments on `load()`, `encode()`, `TokenizerOutput`
  - Update license header year
- [ ] Tests (`packages/kmdb_inferencing/test/bert_tokenizer_test.dart`):
  - [ ] `encode()` produces `[CLS]` and `[SEP]` sentinels
  - [ ] Known token IDs for `jekyll` (`[16368, 8739, 2140]` or equivalent for
        the BGE vocabulary — update expected IDs from actual vocab.txt once
        assets are committed)
  - [ ] Text exceeding 512 tokens is truncated to 512 (510 usable + CLS/SEP);
        `truncated` flag set in output
  - [ ] Empty string produces `[CLS][SEP]` tokens only; no error
  - [ ] `IcuTokeniser` can be substituted for `RegExpTokeniser` without error

### Phase 3 — SQ8 quantisation helpers

- [ ] Create `packages/kmdb_inferencing/lib/src/sq8.dart`:
  - `Uint8List quantise(Float32List vector)` — applies
    `u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)` element-wise
  - `Float32List dequantise(Uint8List vector)` — applies
    `f = u / 255.0 * 2.0 - 1.0` element-wise
  - Both functions must handle 384-element vectors; length assertion in debug
    mode only
  - Doc comments including the formula and the assumption of L2-normalized
    input (fixed range [-1, 1])
- [ ] Tests (`packages/kmdb_inferencing/test/sq8_test.dart`):
  - [ ] Round-trip: `dequantise(quantise(v))` is within ≤ 0.004 of `v` for all
        elements (quantisation error bound for 256 levels over [-1, 1])
  - [ ] `1.0` quantises to `255`; `-1.0` quantises to `0`; `0.0` quantises to
        `127` or `128` (both acceptable — document expected value)
  - [ ] Clamping: values slightly outside [-1, 1] due to float rounding are
        clamped, not panicked
  - [ ] 384-element zero vector round-trips without error

### Phase 4 — `OnnxEmbeddingModel`

- [ ] Complete `packages/kmdb_inferencing/lib/src/embedding_model.dart`:
  - `class OnnxEmbeddingModel implements EmbeddingModel`
  - `static Future<OnnxEmbeddingModel> load({String? modelPath, Tokeniser?
    tokeniser})` factory — resolves `modelPath` to the package asset path if
    null; throws `UnsupportedError` if the file is missing; creates
    `OrtInferenceSession` and loads `BertTokenizer` from `vocab.txt` in the
    same directory
  - `@override Future<(Float32List embedding, bool truncated)> embed(String
    text)` — tokenizes `text` using `BertTokenizer`, runs ONNX inference,
    mean-pools the output embeddings, L2-normalises, returns `(embedding,
    truncated)`
  - `void dispose()` — releases `OrtInferenceSession` native resources
  - Doc comments noting the `~127 MB` cold-load time, that `dispose()` must be
    called, and that `embed()` runs synchronously on the calling isolate
- [ ] Update `packages/kmdb_inferencing/lib/kmdb_inferencing.dart` barrel to
  export `OnnxEmbeddingModel`, `BertTokenizer`, and `sq8.dart` helpers
- [ ] Tests (require model assets — mark with `@TestOn('vm')` and skip if model
  file is absent):
  - [ ] `embed()` returns a 384-element `Float32List`
  - [ ] `embed()` output is L2-normalized (norm ≈ 1.0, tolerance 0.001)
  - [ ] Semantically similar sentences produce cosine similarity > 0.85
  - [ ] Semantically dissimilar sentences produce cosine similarity < 0.5
  - [ ] `embed()` of empty string does not throw
  - [ ] `dispose()` can be called without error

### Phase 5 — Git LFS setup and model asset migration

- [ ] Confirm `.gitattributes` has `*.onnx filter=lfs diff=lfs merge=lfs -text`
  (added in Phase 1 scaffold; verify it is present)
- [ ] Copy all model assets from `spikes/bge_embeddings/assets/` into
  `packages/kmdb_inferencing/assets/models/bge-small-en/`:
  - `bge_small.onnx` — model binary (~127 MB, tracked via Git LFS)
  - `vocab.txt` — WordPiece vocabulary (30k entries)
  - `tokenizer_config.json` — tokenizer settings
  - `tokenizer.json` — full tokenizer definition
  - `config.json` — model configuration
  - `special_tokens_map.json` — special token definitions
- [ ] Remove the `.gitkeep` placeholder that was added during the Phase 1
  scaffold (it is superseded by the real asset files)
- [ ] Confirm `git lfs track` lists `*.onnx` and that `git lfs status` shows
  `bge_small.onnx` as a tracked LFS file after staging

### Phase 6 — Vec index state and key codec

- [ ] Create `packages/kmdb/lib/src/search/semantic/vec_index_state.dart`:
  - `VecIndexStatus` enum: `undefined`, `building`, `current`, `stale`,
    `syncing` — `syncing` indicates a sync delta is being applied; queries
    serve from the pre-sync index while catch-up proceeds asynchronously
  - `VecIndexState` class: `namespace`, `field`, `status`, `builtThrough`,
    `builtAt`
  - CBOR encode/decode helpers (`toMap` / `fromMap`) for persistence in `$meta`
  - Static key helpers:
    - `vecKey(ns, field, docId)` → `$vec:{ns}:{field}:{docId}`
    - `corpusKey(ns, field)` → `$vec:corpus:{ns}:{field}`
    - `truncatedKey(ns, field, docId)` → `$vec:truncated:{ns}:{field}:{docId}`
    - `metaKey(ns, field)` → `$meta:vec:{ns}:{field}`

### Phase 7 — `VecManager`

- [ ] Create `packages/kmdb/lib/src/search/semantic/vec_manager.dart`:
  - `class VecManager` — manages all vector indexes for a database instance
  - Constructor: `VecManager(KvStore store, List<VecIndexDefinition> defs,
      EmbeddingModel model)`
  - `void interceptWrite(String ns, String docId, Map<String, dynamic> doc,
      WriteBatch batch)`:
    - For each `VecIndexDefinition` matching `ns`, extract field value
    - Run `model.embed(value)` synchronously (await in async context before
      building batch)
    - Quantise with `sq8.quantise()`
    - Add to batch: `PUT $vec:{ns}:{field}:{docId}` → quantised bytes
    - If truncated: `PUT $vec:truncated:{ns}:{field}:{docId}` → empty bytes
    - Increment `n` in `$vec:corpus:{ns}:{field}`
  - `void interceptDelete(String ns, String docId, WriteBatch batch)`:
    - `DELETE $vec:{ns}:{field}:{docId}`
    - `DELETE $vec:truncated:{ns}:{field}:{docId}` (safe no-op)
    - Decrement `n` in `$vec:corpus:{ns}:{field}`
  - `void interceptUpdate(String ns, String docId,
      Map<String, dynamic> newDoc, WriteBatch batch)`:
    - Same as insert for the vector entry (overwrite); no read-before-write
    - Remove truncation marker if previously set, add if now truncated
    - `n` unchanged
  - `Future<void> ensureBuilt(String ns, String field)` — builds index from
    existing documents; updates `$meta:vec:{ns}:{field}` when done
  - `Future<void> applyDelta(String ns, SyncDelta delta)` — processes a
    post-sync delta (§20.8): transitions index to `syncing`, runs inference
    on each added/updated document and writes the quantised vector, deletes
    entries for removed documents, then transitions to `current`; each
    document committed in its own `WriteBatch`; intended to run in a
    background isolate (inference is CPU-bound)
  - `Future<SearchResult<T>> search<T>(...)` — see Phase 8

### Phase 8 — Flat-scan cosine similarity query

- [ ] Add `Future<SearchResult<T>> search<T>(...)` to `VecManager`:
  - Accept `String query`, `List<String> fields`, `Filter? filter`,
    `SearchMode mode`, `int candidates`, `int limit`, `int offset`
  - Call `model.embed(query)` to get the query float32 vector
  - If `filter` is supplied, resolve `candidateIds` first via secondary index
    lookup (§16) or full namespace scan — this is the pre-filter step
  - For each field: if `candidateIds` is set, fetch vectors via targeted
    key lookups (`$vec:{ns}:{field}:{docId}` per id); otherwise prefix-scan
    `$vec:{ns}:{field}:` to retrieve all `(docId, Uint8List)` pairs
  - Dequantise each stored vector; compute dot product with query vector
    (dot product of L2-normalised vectors = cosine similarity)
  - Keep top-`candidates` results by score descending
  - When multiple fields searched, take max per-field score as document score;
    carry per-field scores in `SearchHit.fieldScores` as `"{field}:cosine"`
  - Sort descending; apply `offset` and `limit`; return `SearchResult<T>`
- [ ] Modify `packages/kmdb/lib/src/query/kmdb_collection.dart`:
  - Wire `VecManager` into `KmdbDatabase` (replace stub `get vecManager => null`)
  - In `search()`: if `mode == SearchMode.semantic` or `mode == SearchMode.auto`
    (and no FTS index present for the field), delegate to `vecManager.search()`
  - Guard with `if (_db.vecManager != null &&
      _db.vecManager!.hasIndex(namespace))`
- [ ] Tests (`packages/kmdb/test/search/semantic/vec_manager_test.dart`):
  - [ ] `interceptWrite` stores a 384-byte quantised vector under the correct key
  - [ ] `interceptWrite` writes truncation marker for >510-token field values
  - [ ] `interceptDelete` removes vector and truncation marker
  - [ ] `interceptUpdate` overwrites vector; removes stale truncation marker
  - [ ] Corpus `n` increments on insert, decrements on delete, unchanged on update
- [ ] Tests (`packages/kmdb/test/search/semantic/vec_search_integration_test.dart`):
  - [ ] Semantically similar documents rank above dissimilar ones (requires
        model assets; skip if absent)
  - [ ] Deleted document does not appear in results
  - [ ] Updated document uses new embedding
  - [ ] `filter:` predicate resolves `candidateIds` before fetching vectors;
        only matching documents are scored
  - [ ] Filtered search with secondary index uses targeted key lookups, not
        full prefix scan
  - [ ] `offset` and `limit` applied correctly
  - [ ] `applyDelta` with added documents runs inference and stores vectors;
        they appear in subsequent search results
  - [ ] `applyDelta` with deleted documents removes vector entries
  - [ ] `applyDelta` transitions index `current` → `syncing` → `current`;
        searches during `syncing` serve from the pre-delta index
  - [ ] Process killed during `applyDelta` leaves index in `syncing`; next
        `open()` transitions to `stale` and full rebuild is triggered
  - [ ] Empty query string returns empty `SearchResult` without error
  - [ ] Field not indexed appears in `SearchMetadata.skipped`
  - [ ] `ensureBuilt` indexes pre-existing documents correctly

### Phase 9 — CLI: semantic flags for `search` command

- [ ] Modify `packages/kmdb_cli/lib/src/commands/search_command.dart`:
  - Extend `--mode` option to accept `semantic` (in addition to `auto` and
    `lexical` added in Phase 2)
  - Add `--candidates <n>` option (default 100)
  - When `--mode semantic` or `auto` is used and `embeddingModel` is not
    configured in `local/config.json`, print a clear error and exit with
    code 1: `"Semantic search requires an embedding model; configure
    embeddingModel in local/config.json"`
  - Add `embeddingModel` key to `local/config.json` schema:
    `{ "type": "onnx", "modelPath": "<path>" }` — if absent, semantic search
    is unavailable but lexical search continues to work
- [ ] Tests:
  - [ ] `--mode semantic` without configured model exits with code 1
  - [ ] `--candidates 50` limits candidate set to 50 (verifiable via result
        count with small test corpus)

### Phase 10 — `KmdbDatabase.close()` cleanup

- [ ] Modify `packages/kmdb/lib/src/query/kmdb_database.dart`:
  - In `close()`, call `embeddingModel?.dispose()` after all other cleanup
  - Add doc comment on `open()` parameter `embeddingModel:` noting that
    `close()` calls `dispose()` on the supplied model

## Summary

_To be completed on implementation._
