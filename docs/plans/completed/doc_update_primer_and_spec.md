# Documentation Update: Primer and Spec Files

**Status**: Complete

**PR link**: TBD

## Problem statement

The `docs/primer.md` and `docs/spec/` files need to be brought up to date with
the current implementation. Since the primer was last revised (covering phases
1–7), the codebase has added:

- **§9a–9c / §20–23**: Full-text lexical search (BM25), semantic search (BGE
  embeddings, SQ8 quantisation), and hybrid search (Reciprocal Rank Fusion)
- **§24**: Vault — content-addressable binary object store with deduplication,
  stub-based sync, on-demand hydration, and GC via reference counting
- **Packages**: `kmdb_lexical` (tokenizer/stopwords), `kmdb_mediatype` (media
  type detection), `kmdb_inferencing` (ONNX Runtime + BGE model),
  `kmdb_tokenizer_icu` (ICU word tokenizer)

The primer is the "read this first" developer guide. It currently has no mention
of text search or vault. The spec files for §20–24 were written during planning
and need to be validated against the final implementation.

## Open questions

_None — investigation complete._

## Investigation

### docs/primer.md gaps

The primer covers the 6-layer stack, HLC, and sync. It is missing:

1. **Architecture stack diagram** — does not include search or vault
2. **Text search section** — no coverage of `FtsManager`, `VecManager`,
   `HybridManager`, or the `KmdbCollection.search()` API
3. **Vault section** — no coverage of `VaultStore`, content-addressing, stubs,
   ref-counted GC, or vault sync
4. **Package layout** — mentions old monolith structure; new packages
   (`kmdb_lexical`, `kmdb_mediatype`, `kmdb_inferencing`, `kmdb_tokenizer_icu`)
   are absent
5. **Navigation table** — missing entries for search and vault source files
6. **Key Terms glossary** — missing terms: BM25, BM25 index, Vault, KVLT, stub,
   tombstone (vault sense), SQ8, RRF

### docs/spec/ file assessment

Files are grouped by expected effort:

**Likely current — light validation only:**

- `01_overview.md`, `02_target_workload_profile.md` — no structural changes
- `04_keys.md`, `05_value_encoding.md` — unchanged APIs
- `06_storage_engine.md`, `07_wal.md`, `08_sstable.md`, `09_integrity.md` — core
  engine unchanged
- `10_manifest.md`, `11_kv_store.md` — unchanged
- `12_sync.md` — high-water mark and consolidation protocol unchanged
- `13_query_api.md` — query API unchanged (search is an extension)
- `14_reactivity.md`, `15_cache_layer.md`, `16_secondary_indexes.md` — unchanged
- `17_crash_recovery.md`, `18_concurrency.md`, `19_platform.md` — unchanged
- `99_glossary.md` — likely missing vault/search terms

**Requires substantive validation:**

- `03_architecture_overview.md` — layer stack diagram does not show search or
  vault subsystems; vault directory layout already present but search is absent
- `20_text_search.md` — written during planning; verify sync-exclusion rules,
  `$fts:` / `$vec:` namespace conventions, CLI `search` command flags, and
  `SearchResult` type structure match the final code
- `21_lexical_search.md` — verify BM25 scoring parameters, pipeline stages
  (`kmdb_lexical` package split), compaction behaviour, and index namespace keys
  match implementation in `fts_manager.dart` and `pipeline.dart`
- `22_semantic_search.md` — verify SQ8 quantisation details, `$vec:` key format,
  and `VecManager` write/query paths against `vec_manager.dart` and
  `vec_index_definition.dart`
- `23_hybrid_search.md` — verify RRF formula, candidate set logic, and score
  structure against `hybrid_manager.dart`
- `24_vault.md` — verify final directory layout, KVLT package format,
  `VaultManifest` fields, GC algorithm, staging-directory sweep, and sync
  adapter against `vault_store.dart`, `vault_manifest.dart`, `vault_gc.dart`,
  `vault_package.dart`, and `vault_recovery.dart`
- `00_index.md` — abstract/preamble mentions §20–24 at a high level; confirm
  package names are accurate

### Key implementation files to read during validation

| Spec section | Primary source files                                                                                                                                                                              |
| :----------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| §20 shared   | `search/search_result.dart`, `search/search_mode.dart`, `search/sync_delta.dart`                                                                                                                  |
| §21 lexical  | `search/lexical/fts_manager.dart`, `search/lexical/pipeline.dart`, `search/fts_index_definition.dart`                                                                                             |
| §22 semantic | `search/semantic/vec_manager.dart`, `search/semantic/vec_index_state.dart`, `search/vec_index_definition.dart`, `search/embedding_model.dart`                                                     |
| §23 hybrid   | `search/hybrid/hybrid_manager.dart`                                                                                                                                                               |
| §24 vault    | `vault/vault_store.dart`, `vault/vault_manifest.dart`, `vault/vault_gc.dart`, `vault/vault_package.dart`, `vault/vault_recovery.dart`, `vault/vault_ref.dart`, `vault/vault_ref_interceptor.dart` |

## Implementation plan

### Phase 1 — Validate §20–24 spec files against implementation

- [ ] Read `20_text_search.md` and cross-check against `search_result.dart`,
      `search_mode.dart`, `sync_delta.dart`, and `kmdb_collection.dart`
      (`search()` signature). Note any discrepancies.
- [ ] Read `21_lexical_search.md` and cross-check against `fts_manager.dart` and
      `pipeline.dart`. Verify BM25 parameters, tokenizer pipeline stages,
      `$fts:` key format, compaction hook, and `kmdb_lexical` package split.
- [ ] Read `22_semantic_search.md` and cross-check against `vec_manager.dart`
      and `vec_index_definition.dart`. Verify SQ8 quantisation, `$vec:` key
      format, dimension/model constants.
- [ ] Read `23_hybrid_search.md` and cross-check against `hybrid_manager.dart`.
      Verify RRF formula, `k` constant, score fields.
- [ ] Read `24_vault.md` and cross-check against `vault_store.dart`,
      `vault_manifest.dart`, `vault_gc.dart`, `vault_package.dart`,
      `vault_recovery.dart`. Verify directory layout, KVLT format, GC algorithm,
      staging sweep, sync adapter, and `VAULT_OFFLINE` pin list.

### Phase 2 — Update §20–24 spec files

- [ ] Update `20_text_search.md` with any corrections found in Phase 1.
- [ ] Update `21_lexical_search.md` with any corrections (esp. package split,
      pipeline stages, key format).
- [ ] Update `22_semantic_search.md` with any corrections.
- [ ] Update `23_hybrid_search.md` with any corrections.
- [ ] Update `24_vault.md` with any corrections.

### Phase 3 — Update §03 and §00 spec files

- [ ] Update `03_architecture_overview.md` layer stack to show search subsystem
      (FtsManager / VecManager / HybridManager) and vault subsystem
      (`VaultStore`) as separate horizontal concerns alongside (not inside) the
      main 6-layer stack.
- [ ] Confirm `00_index.md` abstract/preamble package names match the actual
      published packages; update if needed.

### Phase 4 — Validate and update §01–19 and §99 spec files

- [ ] Spot-check `13_query_api.md` to confirm `KmdbCollection.search()` is
      documented (it is part of the query API surface).
- [ ] Check `19_platform.md` for package layout — add `kmdb_lexical`,
      `kmdb_mediatype`, `kmdb_inferencing`, `kmdb_tokenizer_icu`.
- [ ] Update `99_glossary.md` with missing terms: BM25, TF-IDF, inverted index,
      embedding, SQ8 quantisation, RRF, vault, KVLT, stub (vault), tombstone
      (vault), content-addressable storage.
- [ ] Skim remaining §01–18 files and make any corrections identified.

### Phase 5 — Update docs/primer.md

- [ ] Update the architecture stack diagram to include search and vault.
- [ ] Add **Text Search** section covering: three modes (lexical, semantic,
      hybrid), `KmdbCollection.search()` entry point, `SearchResult` fields,
      `FtsManager` / `VecManager` / `HybridManager` internals, sync exclusion of
      `$fts:` / `$vec:` namespaces, and platform constraints (native-only,
      English-only).
- [ ] Add **Vault** section covering: content-addressing (SHA-256), KVLT package
      format, stub pattern, ref-counted GC, `VaultRefInterceptor`, staging
      directory sweep on open, and vault sync via `VaultStorageAdapter`.
- [ ] Update package layout paragraph to list the new packages.
- [ ] Update the **Navigation table** with vault and search entry points.
- [ ] Update the **Key Terms glossary** with new terms.

## Summary

- **`docs/primer.md`**: Added Text Search section (three modes, BM25, BGE+SQ8,
  RRF) and Vault section (content-addressing, write path, stubs, ref-counted GC,
  VaultRef). Updated architecture diagram to show search and vault subsystems as
  lateral extensions. Expanded sync folder layout to include vault directory.
  Added 10 new entries to the navigation table and 9 new key terms.
- **`docs/spec/20_text_search.md`**: Corrected `SearchMode.lexical/semantic`
  error behaviour (returns empty result + skipped field, not an exception).
  Clarified `SearchHit.fieldScores` key structure including the `"{field}"`
  hybrid RRF key.
- **`docs/spec/24_vault.md`**: Corrected GC pin behaviour — sweep does not
  automatically update `VAULT_OFFLINE`.
- **`docs/spec/03_architecture_overview.md`**: Added Text Search and Vault
  subsystem boxes to the layer stack diagram.
- **`docs/spec/13_query_api.md`**: Updated `KmdbDatabase.open()` signature to
  include `ftsIndexes`, `vecIndexes`, `embeddingModel`, `onSearchIndexReady`,
  `vaultStore`, and `deviceId`/`adapter`. Added `search()` method documentation
  with example and mode description.
- **`docs/spec/19_platform.md`**: Replaced stale draft package structure with
  accurate pub workspace layout including all current packages (`kmdb_lexical`,
  `kmdb_mediatype`, `kmdb_inferencing`, `kmdb_tokenizer_icu`). Added platform
  feature matrix table.
- **`docs/spec/99_glossary.md`**: Expanded from 1 entry to 25, covering all
  major LSM, search, and vault terms.
