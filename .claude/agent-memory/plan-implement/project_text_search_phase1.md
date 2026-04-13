---
name: Text search Phase 1 shared foundations implementation
description: Key patterns from implementing the text search shared types, new workspace packages, and KmdbDatabase/KmdbCollection extensions
type: project
---

Implemented plan_text_search_shared (PR #12, branch 20260413_plan_text_search_shared).

**Why:** Phase 1 creates all the shared foundations required by the three text search plans (lexical, semantic, hybrid). Plans 2 and 3 can now proceed in parallel.

## Key architectural decisions

- `Tokeniser` interface and `RegExpTokeniser` live in `kmdb` (zero-FFI, no dependency on new packages). `IcuTokeniser` lives in `kmdb_tokenizer_icu` to keep FFI out of core.
- `EmbeddingModel` is an abstract interface in `kmdb/lib/src/search/` so `VecManager` can accept it without an FFI dependency. Concrete `OnnxEmbeddingModel` lives in `kmdb_inferencing`.
- `ftsManager` and `vecManager` properties on `KmdbDatabase` return `dynamic` (null) as stubs. Plans 2 and 3 replace these with typed manager instances. Using `dynamic` avoids forward-declaring the manager types.
- `search()` stub on `KmdbCollection<T>` returns empty `SearchResult` with requested fields in `skipped`. This is the contract plans 2/3 replace, not throw `UnimplementedError`, so callers are not surprised.
- `ArgumentError` is thrown synchronously (before any `await`) in `KmdbDatabase.open()` when `vecIndexes` is non-empty and `embeddingModel` is null. The validation runs before `KvStoreImpl.open()`.

## New package structure

Both new packages follow the same pattern as `kmdb_zstd`:
- `pubspec.yaml`: `publish_to: none`, `resolution: workspace`
- `analysis_options.yaml`: `include: package:lints/recommended.yaml`
- Scaffold generated via `dart create --template=package`, then scaffold files replaced
- Both added to root `pubspec.yaml` `workspace:` list

## Test patterns

- `search_stub_test.dart`: Uses `_FakeEmbeddingModel implements EmbeddingModel` (must import `dart:typed_data` for `Float32List`).
- ICU tests use `setUpAll(() => icu = IcuTokeniser())` (not `setUp`) because the ICU library load is expensive.
- Shared Tokeniser contract tests extracted to `_tokeniserContractTests(String label, Tokeniser t)` — runs same tests against both IcuTokeniser and RegExpTokeniser.

## Pre-existing failures to be aware of

5 tests in `kmdb` and ~26 tests in `kmdb_cli` fail due to Zstd native asset not being available in the test environment (`ZSTD_minCLevel` symbol not found). These pre-existed before this plan and are unrelated.

**How to apply:** When implementing plans 2 (lexical) and 3 (semantic), the stubs in `KmdbCollection.search()`, `KmdbDatabase.ftsManager`, and `KmdbDatabase.vecManager` are the integration points to replace with real implementations.
