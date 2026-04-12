# Text Search — Phase 1: Shared Foundations

**Status**: Investigated

**PR link**: _pending_

## Problem statement

The text search work (lexical, semantic, and hybrid) requires a set of shared
foundations before any indexing logic can be implemented:

- Shared Dart types (`SearchResult<T>`, `SearchHit<T>`, `SearchMetadata`,
  `SearchMode`) consumed by all three search modes
- The `Tokeniser` interface and `RegExpTokeniser` implementation, currently
  living in the spike, moved into the `kmdb` package
- The `EmbeddingModel` abstract interface, allowing `kmdb` to support semantic
  indexing without taking an FFI dependency
- Two new workspace packages: `kmdb_tokenizer_icu` (ICU FFI tokenizer) and
  `kmdb_inferencing` (ONNX runtime + BGE model), each keeping FFI out of `kmdb`
- Extension of `KmdbDatabase.open()` with `ftsIndexes`, `vecIndexes`, and
  `embeddingModel` parameters
- A `search()` stub on `KmdbCollection<T>` that subsequent phases fill in

This plan must be completed before plans 2 (lexical) and 3 (semantic) can begin.
Plans 2 and 3 can proceed in parallel once this plan is complete. Plan 4
(hybrid) depends on plans 2 and 3.

## Open questions

_None — all design decisions resolved in the proposals and spec §20–23._

## Investigation

### Design decisions (see spec §20, proposals `text_search.md`)

- `Tokeniser` interface and `RegExpTokeniser` are pure Dart and belong in `kmdb`
  as the lowest common dependency. All other packages that need tokenisation
  (`kmdb_tokenizer_icu`, `kmdb_inferencing`) depend on `kmdb`.
- `IcuTokeniser` (ICU C FFI) goes in `kmdb_tokenizer_icu` to keep FFI out of
  `kmdb`. This mirrors how `kmdb_zstd` holds Zstd FFI. The implementation can
  be moved directly from `spikes/icu_tokenizer/` with minor adjustments.
- `kmdb_inferencing` holds the ONNX runtime FFI bindings, the BGE model assets
  (tracked in Git LFS), and `BertTokenizer`. It provides `OnnxEmbeddingModel`
  which implements the `EmbeddingModel` interface defined in `kmdb`.
- `EmbeddingModel` is an abstract interface in `kmdb/lib/src/search/semantic/`
  so that `VecManager` (in `kmdb`) can accept it without an FFI dependency.
  `KmdbDatabase.open()` accepts an optional `embeddingModel:` — if `vecIndexes`
  is non-empty but `embeddingModel` is null, `open()` throws `ArgumentError`.
- `SearchMode` is an enum with values `lexical`, `semantic`, and `auto`. Hybrid
  is not a separate mode the user selects; `auto` activates hybrid automatically
  when both indexes are available.
- `search()` on `KmdbCollection<T>` is stubbed to throw `UnimplementedError`
  in this plan. Plans 2 and 3 replace the stub with real implementations.

### Key files to create / modify

| Action | Path |
| :----- | :--- |
| Create | `packages/kmdb/lib/src/search/tokeniser.dart` |
| Create | `packages/kmdb/lib/src/search/regexp_tokeniser.dart` |
| Create | `packages/kmdb/lib/src/search/search_result.dart` |
| Create | `packages/kmdb/lib/src/search/search_mode.dart` |
| Create | `packages/kmdb/lib/src/search/embedding_model.dart` |
| Create | `packages/kmdb/lib/src/search/fts_index_definition.dart` |
| Create | `packages/kmdb/lib/src/search/vec_index_definition.dart` |
| Modify | `packages/kmdb/lib/kmdb.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_database.dart` |
| Modify | `packages/kmdb/lib/src/query/kmdb_collection.dart` |
| Create | `packages/kmdb_tokenizer_icu/` (new package) |
| Create | `packages/kmdb_inferencing/` (new package, scaffold only) |
| Modify | `pubspec.yaml` (workspace root) |
| Modify | `addlicense_config.txt` |
| Modify | `CLAUDE.md` |

### Edge cases

- `KmdbDatabase.open()` with `vecIndexes` non-empty but `embeddingModel: null`
  must throw `ArgumentError` with a clear message.
- `search()` called before any index exists should return an empty
  `SearchResult` (not throw), with all fields listed in `skipped`.
- `RegExpTokeniser` on an empty string must return an empty list without error.
- `IcuTokeniser` construction failure (library not found) must throw
  `UnsupportedError`, not crash the process.

## Implementation plan

### Phase 1 — New workspace packages

- [ ] Scaffold `packages/kmdb_tokenizer_icu/` using `dart create --template=package`:
  - `pubspec.yaml`: `publish_to: none`, `resolution: workspace`,
    depends on `kmdb` and `ffi: ^2.x`
  - `analysis_options.yaml`: include workspace root file
- [ ] Scaffold `packages/kmdb_inferencing/` using `dart create --template=package`:
  - `pubspec.yaml`: `publish_to: none`, `resolution: workspace`,
    depends on `kmdb`, `ffi: ^2.x`, `path: ^1.x`
  - `analysis_options.yaml`: include workspace root file
- [ ] Add both packages to workspace `pubspec.yaml` under `workspace:`
- [ ] Run `dart pub get` from workspace root; confirm resolution
- [ ] Add new package paths to `addlicense_config.txt` (follow existing pattern
  for `kmdb_zstd`)
- [ ] Update `CLAUDE.md` repository layout section to list the two new packages

### Phase 2 — Shared types in `kmdb`

- [ ] Create `packages/kmdb/lib/src/search/tokeniser.dart`:
  - `abstract interface class Tokeniser` with `List<String> tokenise(String text)`
  - Full doc comment including the English-only scope note and UAX #29 reference
- [ ] Create `packages/kmdb/lib/src/search/regexp_tokeniser.dart`:
  - `class RegExpTokeniser implements Tokeniser`
  - Move implementation from `spikes/icu_tokenizer/lib/src/regexp_tokeniser.dart`
  - Update license header year; add doc comment noting English-only scope and
    `IcuTokeniser` as the upgrade path
- [ ] Create `packages/kmdb/lib/src/search/search_mode.dart`:
  - `enum SearchMode { auto, lexical, semantic }`
  - Doc comments for each value
- [ ] Create `packages/kmdb/lib/src/search/search_result.dart`:
  - `class SearchResult<T>` with `metadata` and `hits` fields
  - `class SearchMetadata` with `query`, `searched`, `skipped`, `total`
  - `class SearchHit<T>` with `rank`, `score`, `fieldScores`, `id`, `document`
  - Doc comments on `score` and `fieldScores` covering all three modes and the
    `"{field}:bm25"` / `"{field}:cosine"` key convention for hybrid
- [ ] Create `packages/kmdb/lib/src/search/embedding_model.dart`:
  - `abstract interface class EmbeddingModel`
  - `Future<(Float32List embedding, bool truncated)> embed(String text)`
  - Doc comment noting this is implemented by `kmdb_inferencing`
- [ ] Create `packages/kmdb/lib/src/search/fts_index_definition.dart`:
  - `class FtsIndexDefinition` with `collection`, `field`, `lazy` (default false)
  - `k1` (default 1.2) and `b` (default 0.75) BM25 tuning fields
  - `stopWords` (bool, default false) — when true, applies the Stopwords ISO
    `en` list during preprocessing (Stage 3 of the pipeline)
- [ ] Create `packages/kmdb/lib/src/search/vec_index_definition.dart`:
  - `class VecIndexDefinition` with `collection`, `field`, `lazy` (default false)
- [ ] Export all new types from `packages/kmdb/lib/kmdb.dart`
- [ ] Tests (`packages/kmdb/test/search/`):
  - [ ] `regexp_tokeniser_test.dart`: empty string, single word, prose sentence,
        punctuation filtering, whitespace-only, numbers, multiple spaces,
        technical identifiers (`mTLS`, hex literals)
  - [ ] `search_result_test.dart`: construction, equality, `fieldScores` map
        access patterns

### Phase 3 — `kmdb_tokenizer_icu` package

- [ ] Move `IcuTokeniser` from `spikes/icu_tokenizer/lib/src/icu_tokeniser.dart`
  into `packages/kmdb_tokenizer_icu/lib/src/icu_tokeniser.dart`
  - Update `import` path for `Tokeniser` to reference `package:kmdb/kmdb.dart`
  - Update license header
- [ ] Create `packages/kmdb_tokenizer_icu/lib/kmdb_tokenizer_icu.dart` barrel
  exporting `IcuTokeniser`
- [ ] Move tests from `spikes/icu_tokenizer/test/` into
  `packages/kmdb_tokenizer_icu/test/icu_tokeniser_test.dart`
  - All shared `Tokeniser` contract tests
  - ICU-specific UAX #29 tests (hex literals, `mTLS`, punctuation filtering,
    numeric tokens)
- [ ] Run `dart test packages/kmdb_tokenizer_icu`; confirm all tests pass
- [ ] Run `dart analyze packages/kmdb_tokenizer_icu`; confirm no issues

### Phase 4 — `KmdbDatabase.open()` extension

- [ ] Add the following optional named parameters to `KmdbDatabase.open()` in
  `packages/kmdb/lib/src/query/kmdb_database.dart`:
  ```dart
  List<FtsIndexDefinition> ftsIndexes = const [],
  List<VecIndexDefinition> vecIndexes = const [],
  EmbeddingModel? embeddingModel,
  void Function()? onSearchIndexReady,
  ```
  - `onSearchIndexReady` fires when all text search indexes transition out of
    `syncing` or `building` state to `current`; intended for Flutter apps to
    re-enable search UI after a sync delta has been fully applied
- [ ] Add validation: if `vecIndexes.isNotEmpty && embeddingModel == null`,
  throw `ArgumentError('embeddingModel is required when vecIndexes is non-empty')`
- [ ] Store the parameters on the `KmdbDatabase` instance for use by
  `FtsManager` and `VecManager` in later plans; stub both managers as null for
  now
- [ ] Add `FtsManager? get ftsManager` and `VecManager? get vecManager`
  properties returning null (stubbed; populated in plans 2 and 3)
- [ ] Tests:
  - [ ] `open()` with empty `ftsIndexes` / `vecIndexes` succeeds (no regression)
  - [ ] `open()` with `vecIndexes` non-empty and no `embeddingModel` throws
    `ArgumentError`
  - [ ] `open()` with both `ftsIndexes` and `embeddingModel` succeeds

### Phase 5 — `search()` stub on `KmdbCollection<T>`

- [ ] Add `Future<SearchResult<T>> search(String query, {...})` to
  `KmdbCollection<T>` in
  `packages/kmdb/lib/src/query/kmdb_collection.dart`:
  ```dart
  Future<SearchResult<T>> search(
    String query, {
    List<String>? fields,
    Filter? filter,
    SearchMode mode = SearchMode.auto,
    int candidates = 100,
    int limit = 10,
    int offset = 0,
  })
  ```
  - Implementation: return `SearchResult` with empty `hits` and all requested
    fields in `skipped` (stub — replaced in plans 2 and 3)
- [ ] Export `search()` as part of the public API
- [ ] Tests:
  - [ ] `search()` with no indexes returns empty `SearchResult` with `hits`
    empty and fields in `skipped`
  - [ ] `search()` with empty query string returns empty `SearchResult`

### Phase 6 — `kmdb_inferencing` package scaffold

- [ ] Create directory structure:
  ```
  packages/kmdb_inferencing/
    assets/
      models/
        bge-small-en/
          .gitkeep          ← placeholder; real files tracked via Git LFS
    lib/
      src/
        ort_session.dart    ← stub, to be implemented in plan 3
        embedding_model.dart ← OnnxEmbeddingModel stub
      kmdb_inferencing.dart ← barrel export
    test/
      kmdb_inferencing_test.dart
  ```
- [ ] Add `.gitattributes` entry for `*.onnx` files → `filter=lfs diff=lfs
  merge=lfs -text`
- [ ] Create `OnnxEmbeddingModel` class stub in
  `packages/kmdb_inferencing/lib/src/embedding_model.dart`:
  - Implements `EmbeddingModel` from `kmdb`
  - Constructor and `load()` factory stub throwing `UnimplementedError`
- [ ] Export `OnnxEmbeddingModel` from barrel
- [ ] Run `dart analyze packages/kmdb_inferencing`; confirm no issues

## Summary

_To be completed on implementation._
