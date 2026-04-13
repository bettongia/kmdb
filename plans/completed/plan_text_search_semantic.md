# Text Search — Phase 3: Semantic Search

**Status**: Implemented

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/14

**Proposal**: [Text Indexing and Search](../../docs/proposals/text_search.md)

## Problem statement

Phase 3 delivers cosine similarity vector search over nominated `String` fields
using BGE Small En v1.5 (ONNX). It depends on the shared foundations from Phase
1 (`plan_text_search_shared.md`) and can proceed in parallel with Phase 2
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
- `BertTokenizer` accepts a `Tokeniser` in its constructor (`RegExpTokeniser` by
  default). The word segmentation output feeds into WordPiece subword splitting;
  the BERT token IDs are entirely distinct from the stemmed tokens produced by
  the lexical pipeline.
- Inference runs **synchronously, before the `WriteBatch` is committed**. If
  inference fails the document write is rejected — the document store and the
  semantic index remain consistent (Option A from the proposal).
- Quantisation to SQ8 uses the fixed symmetric range for L2-normalized vectors:
  `u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)`. Dequantise with
  `f = u / 255.0 * 2.0 - 1.0`. No per-vector calibration is needed.
- At kmdb's expected scale (<50 k documents) a brute-force flat scan is faster
  than an ANN index. The query path prefix-scans `$vec:{ns}:{field}:`,
  dequantises each stored vector, computes the dot product with the (float32)
  query vector, and returns the top-`candidates` results by score descending.
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

| Action   | Path                                                                  |
| :------- | :-------------------------------------------------------------------- |
| Complete | `packages/kmdb_inferencing/lib/src/ort_session.dart`                  |
| Create   | `packages/kmdb_inferencing/lib/src/bert_tokenizer.dart`               |
| Create   | `packages/kmdb_inferencing/lib/src/sq8.dart`                          |
| Complete | `packages/kmdb_inferencing/lib/src/embedding_model.dart`              |
| Modify   | `packages/kmdb_inferencing/lib/kmdb_inferencing.dart`                 |
| Create   | `packages/kmdb_inferencing/assets/models/bge-small-en/.gitkeep`       |
| Modify   | `packages/kmdb_inferencing/test/kmdb_inferencing_test.dart`           |
| Create   | `packages/kmdb/lib/src/search/semantic/vec_manager.dart`              |
| Create   | `packages/kmdb/lib/src/search/semantic/vec_index_state.dart`          |
| Modify   | `packages/kmdb/lib/src/search/vec_index_definition.dart`              |
| Modify   | `packages/kmdb/lib/src/query/kmdb_database.dart`                      |
| Modify   | `packages/kmdb/lib/src/query/kmdb_collection.dart`                    |
| Create   | `packages/kmdb/test/search/semantic/vec_manager_test.dart`            |
| Create   | `packages/kmdb/test/search/semantic/vec_search_integration_test.dart` |
| Modify   | `packages/kmdb_cli/lib/src/commands/search_command.dart`              |

### Edge cases

- Inference failure must roll back the entire write — the `WriteBatch` must not
  be committed. The error propagates to the caller as a `StateError`.
- A field value that exceeds 510 BERT tokens must embed the first 510 tokens and
  write the `$vec:truncated:` marker. The write succeeds; only the marker
  signals truncation.
- An empty field value (empty string or whitespace-only) produces an embedding
  of the `[CLS][SEP]` tokens only. This is not an error; the embedding is stored
  normally.
- Deleting a document that was truncated must also delete the
  `$vec:truncated:{ns}:{field}:{docId}` key (safe no-op if absent — use
  `WriteBatch.delete` which is idempotent).
- Updating a document does not require reading the previous vector — the new
  vector overwrites the old entry atomically in the `WriteBatch`. The corpus `n`
  count is unchanged on update.
- `OrtInferenceSession` must be closed explicitly;
  `OnnxEmbeddingModel.dispose()` releases the native resources.
  `KmdbDatabase.close()` must call `embeddingModel.dispose()` if an
  `embeddingModel` was supplied.
- When `VecIndexDefinition.lazy` is `false` (default), `ensureBuilt()` is called
  on the first `search()` call. Building the full vec index may take several
  seconds for large collections — callers should be aware of the latency on
  first query.
- Multi-field vector search takes the highest per-field cosine similarity score
  as the document overall score. Per-field scores are carried in
  `SearchHit.fieldScores` keyed as `"{field}:cosine"`.

## Implementation plan

### Phase 1 — ORT session (from spike)

- [x] Move `OrtInferenceSession` from
      `spikes/bge_embeddings/lib/src/ort_session.dart` into
      `packages/kmdb_inferencing/lib/src/ort_session.dart`
  - Updated license header year
  - Added doc comments on `create()` and `run()`
  - Updated import paths
- [x] Move `ort_bindings.dart`, `ort_library.dart` from spike into
      `packages/kmdb_inferencing/lib/src/`
- [x] `dart analyze packages/kmdb_inferencing` — no issues

### Phase 2 — `BertTokenizer` (from spike)

- [x] Move `BertTokenizer` from spike into
      `packages/kmdb_inferencing/lib/src/bert_tokenizer.dart`
  - Accepts injected `Tokeniser` with `RegExpTokeniser()` as default
  - Doc comments on `load()`, `encode()`, `TokenizerOutput`
- [x] Tests (`packages/kmdb_inferencing/test/bert_tokenizer_test.dart`):
  - [x] `encode()` produces `[CLS]` and `[SEP]` sentinels
  - [x] Known token IDs
  - [x] Truncation at 512 tokens
  - [x] Empty string produces `[CLS][SEP]` only
  - [x] Custom `Tokeniser` substitution

### Phase 3 — SQ8 quantisation helpers

- [x] Created `packages/kmdb_inferencing/lib/src/sq8.dart`
- [x] Tests (`packages/kmdb_inferencing/test/sq8_test.dart`):
  - [x] Round-trip error ≤ 0.004
  - [x] Boundary values (1.0→255, -1.0→0, 0.0→127or128)
  - [x] Clamping
  - [x] Zero vector

### Phase 4 — `OnnxEmbeddingModel`

- [x] Completed `packages/kmdb_inferencing/lib/src/embedding_model.dart`
- [x] Updated barrel to export `OnnxEmbeddingModel`, `BertTokenizer`, `sq8.dart`
      helpers, and re-export `Tokeniser` from `kmdb`
- [x] Tests skip gracefully when model assets are absent

### Phase 5 — Git LFS setup and model asset migration

- [x] `.gitattributes` confirmed with
      `*.onnx filter=lfs diff=lfs merge=lfs -text`
- [x] Model assets staged under
      `packages/kmdb_inferencing/assets/models/bge-small-en/`

### Phase 6 — Vec index state and key codec

- [x] Created `packages/kmdb/lib/src/search/semantic/vec_index_state.dart`:
  - `VecIndexStatus` enum with 5 values
  - `VecIndexState` with CBOR round-trip
  - Static key helpers: `vecNamespace`, `corpusNamespace`, `truncatedNamespace`,
    `metaKey`, `corpusSentinelKey`

### Phase 7 — `VecManager`

- [x] Created `packages/kmdb/lib/src/search/semantic/vec_manager.dart` with full
      write interception (insert/update/delete), lifecycle management
      (`checkAndTransitionOnOpen`, `ensureBuilt`, `applyDelta`), and flat-scan
      search

### Phase 8 — Flat-scan cosine similarity query

- [x] `VecManager.search<T>()` implemented with pre-filter support, cosine
      scoring, pagination, `fieldScores` keyed as `"{field}:cosine"`
- [x] Wired `VecManager` into `KmdbDatabase` and `KmdbCollection.search()`
- [x] Tests (`packages/kmdb/test/search/semantic/vec_manager_test.dart`):
  - [x] Write interception: insert stores vector, truncation marker, corpus n
  - [x] Delete removes vector, truncation marker
  - [x] Update overwrites vector, adjusts truncation marker, n unchanged
  - [x] VecIndexState CBOR round-trip and key helpers
  - [x] Inference failure → StateError, batch not committed
  - [x] `KmdbDatabase.close()` calls `dispose()` on embedding model
- [x] Tests
      (`packages/kmdb/test/search/semantic/vec_search_integration_test.dart`):
  - [x] Semantic ranking, empty query, deleted/updated docs
  - [x] Filter pre-filtering, pagination, fieldScores
  - [x] `ensureBuilt` indexes pre-existing documents
  - [x] `applyDelta` added/deleted docs, state transitions
  - [x] `checkAndTransitionOnOpen` syncing→stale crash recovery
  - [x] Auto mode routing

### Phase 9 — CLI: semantic flags for `search` command

- [x] Extended `--mode` to accept `semantic`; added `--candidates <n>` option
- [x] `--mode semantic` without `embeddingModel` configured → error + exit 1
- [x] `embeddingModel` key added to `local/config.json` schema in `KmdbConfig`
- [x] Tests:
  - [x] `--mode semantic` without configured model exits with code 1
  - [x] `--candidates` flag accepted without error

### Phase 10 — `KmdbDatabase.close()` cleanup

- [x] `close()` calls `embeddingModel?.dispose()` after all other cleanup
- [x] Doc comment on `open()` parameter `embeddingModel:` noting dispose
      behaviour

## Summary

Phases 1–10 of the semantic search plan are complete. The `kmdb_inferencing`
package provides `OnnxEmbeddingModel` (ONNX Runtime + BGE Small En v1.5),
`BertTokenizer`, and SQ8 quantisation helpers. The `kmdb` package now has
`VecManager` for write interception, lazy index builds, delta sync, and
flat-scan cosine similarity search. `KmdbCollection.search()` routes
`SearchMode.semantic` and `SearchMode.auto` (when no FTS index is present)
through `VecManager`. The CLI `search` command validates `--mode semantic`
requires an `embeddingModel` in config. All 1197 tests pass across `kmdb`,
`kmdb_cli`, and `kmdb_inferencing`.
