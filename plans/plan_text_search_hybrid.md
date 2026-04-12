# Text Search — Phase 4: Hybrid Search

**Status**: Investigated

**PR link**: _pending_

## Problem statement

Phase 4 delivers hybrid search by combining BM25 lexical results (Phase 2) and
cosine similarity semantic results (Phase 3) using Reciprocal Rank Fusion (RRF).
It depends on both Phase 2 and Phase 3 being complete.

Concretely, this plan:

- Implements the RRF scoring function and the `HybridManager` that orchestrates
  the two result sets
- Wires `SearchMode.auto` to activate hybrid automatically when both a lexical
  and a vector index exist for the searched field
- Populates `SearchHit.fieldScores` with the per-field hybrid key structure
  (`"{field}"`, `"{field}:bm25"`, `"{field}:cosine"`)
- Extends the CLI `search` command with `--mode auto` routing and
  `--candidates <n>` support (candidates already plumbed in Phase 3; this plan
  ensures it applies to both legs of the hybrid query)
- Adds integration tests covering partial-index states and multi-field hybrid
  search

Phase 4 does not add new index infrastructure — RRF is a post-retrieval ranking
step applied to the candidate sets returned by `FtsManager` and `VecManager`.

## Open questions

_None — all design decisions resolved in spec §23._

## Investigation

### Design decisions (see spec §23)

- RRF formula: `RRF(d) = Σ_{r ∈ R} 1 / (k + r(d))` where `k = 60` (default,
  configurable). A document absent from one list contributes 0 from that list
  (rank = ∞).
- `SearchMode.auto` is the default. When both a lexical and a vector index exist
  for a searched field, `auto` activates hybrid. When only one index exists for
  a field, `auto` falls back to whichever index is available. The user can force
  a single mode with `mode: SearchMode.lexical` or `mode: SearchMode.semantic`.
- The `HybridManager` is not a persistent class — it is a stateless function
  that accepts two ranked candidate lists and returns an RRF-ranked
  `SearchResult`. It is called from `KmdbCollection.search()`.
- Per-field `fieldScores` keys in hybrid mode:
  - `"{field}"` → per-field RRF score
  - `"{field}:bm25"` → per-field BM25 score (absent if document not in lexical
    results for that field)
  - `"{field}:cosine"` → per-field cosine similarity (absent if document not in
    semantic results for that field)
  - `SearchHit.score` holds the overall RRF score across all searched fields
- Candidate set: each index contributes at most `candidates` results (default
  100). Total candidates before RRF: up to `2 × candidates`. The final result
  set is reduced to `limit` after RRF scoring.
- Partial-index correctness: if the vector index build is incomplete for some
  documents, those documents still appear via their BM25 score. The absent-list
  rank ∞ rule ensures single-index matches are returned, not silently dropped.
- The `k` smoothing constant defaults to 60. It is not exposed in
  `FtsIndexDefinition` or `VecIndexDefinition` (the RRF `k` value is not
  per-index); instead it is an optional parameter of `search()` (`rrfK:`,
  defaulting to 60). Advanced users can tune it per query.

### Key files to create / modify

| Action | Path |
| :----- | :--- |
| Create | `packages/kmdb/lib/src/search/hybrid/hybrid_manager.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart` |
| Modify | `packages/kmdb/lib/kmdb.dart` |
| Create | `packages/kmdb/test/search/hybrid/hybrid_manager_test.dart` |
| Create | `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart` |
| Modify | `packages/kmdb_cli/lib/src/commands/search_command.dart` |
| Create | `packages/kmdb_cli/test/search_hybrid_command_test.dart` |

### Edge cases

- A document that appears only in the BM25 list contributes `1 / (k + rank)`
  from BM25 and `0` from cosine. Its `fieldScores` map has `"{field}:bm25"` but
  no `"{field}:cosine"`.
- A document that appears only in the cosine list (e.g. vector index built after
  the document was inserted) contributes `0` from BM25 and `1 / (k + rank)` from
  cosine. Its `fieldScores` map has `"{field}:cosine"` but no `"{field}:bm25"`.
- When `mode == SearchMode.lexical` or `mode == SearchMode.semantic`, the hybrid
  path is bypassed — no RRF is applied even if both indexes exist.
- When `mode == SearchMode.auto` and only one index type exists for a field, the
  hybrid path is bypassed for that field and the single-index score is used
  directly. `SearchHit.score` equals the per-field single-index score.
- `rrfK: 0` would cause division by zero at rank 1. Validate that `rrfK >= 1`;
  throw `ArgumentError` if not.
- Multi-field hybrid: each field independently produces an RRF score. The
  document's overall `SearchHit.score` is the sum of per-field RRF scores (when
  multiple fields searched). The `fieldScores` map carries each field's
  individual RRF, BM25, and cosine scores separately.
- `candidates` applies independently to each index leg: `FtsManager` returns at
  most `candidates` BM25 results; `VecManager` returns at most `candidates`
  cosine results. The merged pool is at most `2 × candidates`.
- Empty candidate pool from both indexes (e.g. no indexed documents) returns an
  empty `SearchResult` without error.

## Implementation plan

### Phase 1 — RRF scoring function

- [ ] Create `packages/kmdb/lib/src/search/hybrid/hybrid_manager.dart`:
  - `double rrfScore(int rank, {int k = 60})` — `1.0 / (k + rank)` (rank is
    1-based)
  - `SearchResult<T> mergeWithRrf<T>({`
    `  required List<SearchHit<T>> lexicalHits,`
    `  required List<SearchHit<T>> semanticHits,`
    `  required int limit,`
    `  required int offset,`
    `  required SearchMetadata metadata,`
    `  int rrfK = 60,`
    `})` — core merge function:
    1. Build a `Map<String, ({double bm25, double cosine, int bm25Rank,
       int cosineRank})>` keyed by `docId` from both lists
    2. For each unique `docId`, compute RRF score: sum of
       `1 / (rrfK + rank)` from each list the document appears in (absent list
       contributes 0)
    3. Merge per-field `fieldScores` from both hits (BM25 fields under
       `"{field}:bm25"`, cosine under `"{field}:cosine"`, field RRF under
       `"{field}"`)
    4. Sort by overall RRF score descending; apply `offset` and `limit`
    5. Reconstruct `SearchHit<T>` entries with merged `fieldScores` and RRF
       `score`
    6. Return `SearchResult<T>` with the supplied `metadata`
  - Full doc comment covering the RRF formula, the absent-list convention,
    and the `fieldScores` key structure
- [ ] Tests (`packages/kmdb/test/search/hybrid/hybrid_manager_test.dart`):
  - [ ] Document in both lists ranks higher than document in only one list
  - [ ] Document absent from BM25 list contributes 0 from that leg
  - [ ] `fieldScores` map contains `"{field}:bm25"` and `"{field}:cosine"` keys
        correctly populated; absent keys not present
  - [ ] `fieldScores["{field}"]` equals the per-field RRF contribution
  - [ ] `offset` and `limit` applied after RRF sort
  - [ ] Empty both lists returns empty `SearchResult`
  - [ ] `rrfK: 0` throws `ArgumentError`
  - [ ] `rrfK: 1` produces valid scores (no division by zero for rank ≥ 1)
  - [ ] Two documents with identical RRF scores preserve stable ordering
        (by `docId` as tiebreaker)
  - [ ] Multi-field: per-field scores for field A and field B are tracked
        independently; overall score is sum of per-field RRF contributions
  - [ ] Document that appears in both indexes for one field but only BM25 for
        another field has correct partial `fieldScores`

### Phase 2 — Wire hybrid into `KmdbCollection.search()`

- [ ] Modify `packages/kmdb/lib/src/query/kmdb_collection.dart` `search()`
  implementation:
  - Determine which indexes are available for each requested field:
    - `hasFts = _db.ftsManager?.hasIndex(namespace, field) ?? false`
    - `hasVec = _db.vecManager?.hasIndex(namespace, field) ?? false`
  - Routing logic per field:
    - `mode == SearchMode.lexical` → use `FtsManager` only (error if no FTS
      index; field goes to `skipped`)
    - `mode == SearchMode.semantic` → use `VecManager` only (error if no vec
      index; field goes to `skipped`)
    - `mode == SearchMode.auto`:
      - Both present → hybrid path: get candidates from both managers, merge
        with `HybridManager.mergeWithRrf()`
      - Only FTS → lexical path
      - Only vec → semantic path
      - Neither → field goes to `SearchMetadata.skipped`
  - Add optional `rrfK` named parameter to `search()` (default 60); pass
    through to `mergeWithRrf()`
  - Update public API doc comment on `search()` to document `rrfK`
- [ ] Export `HybridManager` (or just `mergeWithRrf`) if needed by external
  consumers; otherwise keep package-private

### Phase 3 — Integration tests

- [ ] Create
  `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart`:
  - Setup: open database with both `ftsIndexes` and `vecIndexes` for the
    same field; use a mock `EmbeddingModel` that returns deterministic
    float32 vectors for test inputs (avoids ONNX dependency in unit tests)
  - [ ] `SearchMode.auto` with both indexes activates hybrid path
  - [ ] `SearchMode.auto` with only FTS index activates lexical path
  - [ ] `SearchMode.auto` with only vec index activates semantic path
  - [ ] Document in BM25 top-10 but not cosine top-10 still appears in hybrid
        results (partial-index correctness)
  - [ ] Document in cosine top-10 but not BM25 top-10 still appears in hybrid
        results
  - [ ] `SearchHit.fieldScores` map has correct keys for hybrid results
  - [ ] `SearchHit.fieldScores` map has only `":bm25"` key for BM25-only hit
  - [ ] `SearchHit.fieldScores` map has only `":cosine"` key for cosine-only
        hit
  - [ ] `filter:` predicate correctly excludes documents after RRF merge
  - [ ] `candidates: 5` limits each leg to 5 candidates (10 total pool)
  - [ ] `rrfK: 1` produces valid (extreme) scores without error
  - [ ] Multi-field hybrid: per-field scores tracked independently
  - [ ] `SearchMetadata.searched` contains fields that were searched;
        `skipped` contains fields with no matching index
  - [ ] Deleting a document removes it from both legs; not in hybrid results

### Phase 4 — CLI: `--mode auto` routing and `--candidates`

- [ ] Modify `packages/kmdb_cli/lib/src/commands/search_command.dart`:
  - Confirm `--mode auto` is the default and routes to hybrid when both
    indexes present (this was scaffolded in Phase 2 of Plan 2 and Phase 9 of
    Plan 3; this phase verifies the full routing chain works end to end)
  - Add `--rrf-k <n>` option (default 60) — advanced option; document in help
    text
  - When `--mode auto` and both FTS and vec indexes are configured, the output
    table should include the RRF score in the score column; a `(hybrid)` label
    should follow the mode in the output header line
- [ ] Tests (`packages/kmdb_cli/test/search_hybrid_command_test.dart`):
  - [ ] `--mode auto` with both indexes configured activates hybrid; output
        header shows `(hybrid)`
  - [ ] `--mode auto` with only one index configured activates the available
        single-index path; no `(hybrid)` label
  - [ ] `--rrf-k 1` runs without error
  - [ ] `--candidates 20` limits each leg to 20 candidates

### Phase 5 — Final cleanup and CLAUDE.md update

- [ ] Update `CLAUDE.md` implementation status table: set phases 9a, 9b, 9c
  to `✅ Complete`
- [ ] Run full test suite: `dart test packages/kmdb` and
  `dart test packages/kmdb_cli`; confirm all tests pass and coverage ≥ 90%
- [ ] Run `dart analyze packages/kmdb packages/kmdb_cli
  packages/kmdb_tokenizer_icu packages/kmdb_inferencing`; confirm no issues
- [ ] Run `dart format packages/`; confirm no formatting changes needed

## Summary

_To be completed on implementation._
