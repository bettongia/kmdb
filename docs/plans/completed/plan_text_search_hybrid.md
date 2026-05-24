# Text Search — Phase 4: Hybrid Search

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/15

**Proposal**: [Text Indexing and Search](../docs/proposals/text_search.md)

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

| Action | Path                                                                   |
| :----- | :--------------------------------------------------------------------- |
| Create | `packages/kmdb/lib/src/search/hybrid/hybrid_manager.dart`              |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart`                     |
| Modify | `packages/kmdb/lib/kmdb.dart`                                          |
| Create | `packages/kmdb/test/search/hybrid/hybrid_manager_test.dart`            |
| Create | `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart` |
| Modify | `packages/kmdb_cli/lib/src/commands/search_command.dart`               |
| Create | `packages/kmdb_cli/test/search_hybrid_command_test.dart`               |

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

- [x] Create `packages/kmdb/lib/src/search/hybrid/hybrid_manager.dart`:
  - `double rrfScore(int rank, {int k = 60})` — `1.0 / (k + rank)` (rank is
    1-based)
  - `SearchResult<T> mergeWithRrf<T>({...})` — core merge function:
    1. Index documents by docId from each list
    2. For each unique `docId`, compute RRF score: sum of `1 / (rrfK + rank)`
       from each list the document appears in (absent list contributes 0)
    3. Merge per-field `fieldScores` from both hits (BM25 fields under
       `"{field}:bm25"`, cosine under `"{field}:cosine"`, field RRF under
       `"{field}"`)
    4. Sort by overall RRF score descending; apply `offset` and `limit`
    5. Reconstruct `SearchHit<T>` entries with merged `fieldScores` and RRF
       `score`
    6. Return `SearchResult<T>` with the supplied `metadata`
  - Full doc comment covering the RRF formula, the absent-list convention, and
    the `fieldScores` key structure
- [x] Tests (`packages/kmdb/test/search/hybrid/hybrid_manager_test.dart`):
  - [x] Document in both lists ranks higher than document in only one list
  - [x] Document absent from BM25 list contributes 0 from that leg
  - [x] `fieldScores` map contains `"{field}:bm25"` and `"{field}:cosine"` keys
        correctly populated; absent keys not present
  - [x] `fieldScores["{field}"]` equals the per-field RRF contribution
  - [x] `offset` and `limit` applied after RRF sort
  - [x] Empty both lists returns empty `SearchResult`
  - [x] `rrfK: 0` throws `ArgumentError`
  - [x] `rrfK: 1` produces valid scores (no division by zero for rank ≥ 1)
  - [x] Two documents with identical RRF scores preserve stable ordering (by
        `docId` as tiebreaker)
  - [x] Multi-field: per-field scores for field A and field B are tracked
        independently; overall score is sum of per-field RRF contributions
  - [x] Document that appears in both indexes for one field but only BM25 for
        another field has correct partial `fieldScores`

### Phase 2 — Wire hybrid into `KmdbCollection.search()`

- [x] Modify `packages/kmdb/lib/src/query/kmdb_collection.dart` `search()`
      implementation:
  - Routing logic per mode:
    - `mode == SearchMode.lexical` → use `FtsManager` only
    - `mode == SearchMode.semantic` → use `VecManager` only
    - `mode == SearchMode.auto`:
      - Both present → hybrid path: get candidates from both managers, merge
        with `mergeWithRrf()`
      - Only FTS → lexical path
      - Only vec → semantic path
      - Neither → field goes to `SearchMetadata.skipped`
  - Filter resolves `candidateIds` once before both legs run
  - Added optional `rrfK` named parameter to `search()` (default 60)
  - Updated public API doc comment on `search()` to document `rrfK`
- [x] Exported `rrfScore` and `mergeWithRrf` from `kmdb.dart`

### Phase 3 — Integration tests

- [x] Created
      `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart`:
  - [x] `SearchMode.auto` with both indexes activates hybrid path
  - [x] `SearchMode.auto` with only FTS index activates lexical path
  - [x] `SearchMode.auto` with only vec index activates semantic path
  - [x] Document in BM25 results but not semantic top results appears in hybrid
        (partial-index correctness)
  - [x] `SearchHit.fieldScores` map has correct keys for hybrid results
  - [x] `SearchHit.fieldScores` map has only `":bm25"` key for BM25-only hit
  - [x] `SearchHit.fieldScores` map has only `":cosine"` key for cosine-only hit
  - [x] `filter:` predicate resolves `candidateIds` once before both legs
  - [x] `candidates: 5` limits each leg to 5 candidates (10 total pool)
  - [x] `rrfK: 1` produces valid (extreme) scores without error
  - [x] Multi-field hybrid: per-field scores tracked independently
  - [x] `SearchMetadata.searched` contains fields that were searched; `skipped`
        contains fields with no matching index
  - [x] Deleting a document removes it from both legs; not in hybrid results

### Phase 4 — CLI: `--mode auto` routing and `--candidates`

- [x] Modified `packages/kmdb_cli/lib/src/commands/search_command.dart`:
  - `--mode auto` is default and shows `(hybrid)` label when embeddingModel is
    configured (signals that a vec index is intended for hybrid mode)
  - Added `--rrf-k <n>` option (default 60) with validation (must be >= 1)
  - Table output includes `mode:` header line with `(hybrid)` when applicable
  - JSON output includes `mode` and `rrfK` fields in hybrid mode
- [x] Tests (`packages/kmdb_cli/test/search_hybrid_command_test.dart`):
  - [x] `--mode auto` with embeddingModel configured shows `(hybrid)` in output
  - [x] `--mode auto` with only FTS index (no embeddingModel) shows no `(hybrid)`
  - [x] `--rrf-k 1` runs without error
  - [x] `--candidates 20` limits each leg to 20 candidates

### Phase 5 — Final cleanup and CLAUDE.md update

- [x] Updated the implementation status table in `CLAUDE.md` — rows 9a, 9b, and
      9c — to `✅ Complete`
- [x] Run full test suite: all tests pass (875 kmdb, 362 kmdb_cli; pre-existing
      ZSTD native library failures in worktree are not caused by this change)
- [x] Run `dart analyze packages/kmdb packages/kmdb_cli`; zero issues
- [x] Run `dart format packages/`; no formatting changes needed

## Summary

- Implemented `hybrid_manager.dart` with `rrfScore()` and `mergeWithRrf<T>()`.
  The RRF merge function uses list position as rank (not the stored `hit.rank`),
  applies `offset`/`limit` after sorting, uses docId as a stable tiebreaker for
  equal scores, and populates `fieldScores` with `:bm25`, `:cosine`, and
  per-field RRF keys.
- Wired the hybrid path into `KmdbCollection.search()`: when `SearchMode.auto`
  and both FTS and vec indexes are present, both legs run independently with
  `candidates` as the per-leg limit, and results are merged via RRF. The
  `rrfK` parameter (default 60) is passed through to `mergeWithRrf()`.
- Added `rrfScore` and `mergeWithRrf` to the public `kmdb.dart` exports.
- Updated the CLI `search` command with `--rrf-k` flag (validated >= 1),
  a `mode:` header line in table output (with `(hybrid)` label when both FTS
  and embeddingModel are configured), and JSON `mode`/`rrfK` fields.
- Added 54 new tests (22 unit, 19 integration, 13 CLI).
- Updated CLAUDE.md implementation status for phases 9a, 9b, 9c to Complete.
