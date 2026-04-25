# Coverage Uplift — Phase 1 (kmdb core to ≥90%)

**Status**: Open

**PR link**: _none yet_

## Problem statement

The project quality bar (CLAUDE.md, "General") requires a minimum 90% test
coverage at all times. The 2026-04-25 audit produced the following per-package
real coverage (excluding vendored `third_party/` and code-generated `lib/src/g/`):

| Package              | Real coverage | Bar     |
| :------------------- | :------------ | :------ |
| `kmdb`               | 87.2%         | 90%     |
| `kmdb_cli`           | 78.8%         | 90%     |
| `kmdb_schema`        | 96.2%         | 90% ✅ |
| `kmdb_zstd`          | 82.9%         | 90%     |
| `kmdb_tokenizer_icu` | 69.8%         | 90%     |
| `kmdb_lexical`       | 50.0%         | 90%     |
| `kmdb_mimeinfo`      | 58.5%         | 90%     |
| `kmdb_inferencing`   | 7.9%          | 90%     |
| `kmdb_ui`            | 30.7%         | 90%     |

This plan addresses **only the `kmdb` core package** as Phase 1, since the
core package is the most heavily-tested already and the smallest gap to
close. Phase 2 plans for `kmdb_cli` and the FFI/Flutter packages will be
spawned separately after Phase 1 lands.

## Open questions

- [ ] Should `storage_adapter_native.dart` be excluded from coverage on CI
      (it is exercised by E2E tests only) or should we add direct unit tests?
- [ ] Are there sync_storage_adapter abstract methods worth covering, or is
      0% expected because all consumers extend it?

## Investigation

Lowest-coverage hotspots in `packages/kmdb/lib/src/`:

| File                                          | Hits/Total | %     |
| :-------------------------------------------- | :--------- | :---- |
| `engine/platform/storage_adapter_native.dart` | 0/80       | 0.0%  |
| `sync/sync_storage_adapter.dart`              | 0/4        | 0.0%  |
| `query/index/index_definition.dart`           | 7/16       | 43.8% |
| `query/exceptions.dart`                       | 17/32      | 53.1% |
| `engine/manifest/manifest_reader.dart`        | 39/60      | 65.0% |
| `vault/vault_gc.dart`                         | 39/59      | 66.1% |
| `vault/vault_recovery.dart`                   | 54/81      | 66.7% |
| `cache/cache_layer.dart`                      | 40/57      | 70.2% |
| `sync/hlc_clock.dart`                         | 30/42      | 71.4% |
| `search/lexical/fts_index_state.dart`         | 28/37      | 75.7% |
| `search/lexical/fts_manager.dart`             | 322/411    | 78.3% |

`storage_adapter_native.dart` skews the package average — the file is only
loaded under `dart.library.io` and the existing test suite uses the in-memory
adapter. Excluding it pushes the package to ~89% before any new tests.

The remaining gaps cluster around three themes:

1. **Exception classes** (`query/exceptions.dart`,
   `query/index/index_definition.dart`) — `toString()` and constructor branches
   are unreachable from existing tests.
2. **Recovery / GC paths** (`vault_gc.dart`, `vault_recovery.dart`,
   `manifest_reader.dart`) — happy path is covered but corruption / orphan
   sweeps are not.
3. **HLC edge cases** (`hlc_clock.dart`) — clock-skew clamping and overflow
   paths.

## Implementation plan

- [ ] Add a `coverage:exclude` configuration so vendored and FFI-only files
      do not pollute the headline number.
- [ ] Audit `storage_adapter_native.dart`: either gate behind a CI marker or
      add unit tests against a temp-dir adapter.
- [ ] Add tests for `query/exceptions.dart`:
  - [ ] `DocumentAlreadyExistsException` toString
  - [ ] `DocumentNotFoundException` toString
  - [ ] `ReservedFieldException` toString
  - [ ] `SchemaValidationException` violations list rendering
  - [ ] `StaleIndexException` formatting
- [ ] Add tests for `query/index/index_definition.dart`:
  - [ ] Bare `$` path rejection
  - [ ] `[*]` rewrite to `[]` round-trip
  - [ ] Reserved-prefix validation negative paths
- [ ] Add tests for `manifest_reader.dart`:
  - [ ] Truncated record (length declares more bytes than file holds)
  - [ ] Corrupt XXH64 → recovery falls back to previous record
- [ ] Add tests for `vault_gc.dart` orphan-sweep branches:
  - [ ] Tombstoned blob with surviving ref (must not delete)
  - [ ] Hash directory deletion when last ref tombstoned
  - [ ] Sweep idempotence
- [ ] Add tests for `vault_recovery.dart`:
  - [ ] Crash mid-write (partial blob in vault)
  - [ ] Manifest replay with vault namespace entries
- [ ] Add tests for `cache/cache_layer.dart`:
  - [ ] Generation counter eviction race (concurrent write events)
  - [ ] Materialised view invalidation crossing generations
- [ ] Add tests for `hlc_clock.dart`:
  - [ ] Physical clock regression handling
  - [ ] Logical counter overflow at `0xFFFF`
- [ ] Add tests for `fts_manager.dart` failure paths:
  - [ ] Index rebuild when state is `stale` mid-query
  - [ ] Tokeniser returning empty list (zero-token document)
- [ ] Re-run `make coverage` and confirm `kmdb` ≥ 90%.

## Summary

_(left blank — fill in after implementation)_
