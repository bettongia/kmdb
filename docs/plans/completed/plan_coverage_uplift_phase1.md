# Coverage Uplift — Phase 1 (kmdb core to ≥90%)

**Status**: Completed

**PR link**: _none (landed directly on main)_

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

- [x] Should `storage_adapter_native.dart` be excluded from coverage on CI
      (it is exercised by E2E tests only) or should we add direct unit tests?
      **Decision:** Add unit tests — faster regression detection than E2E.
      `test/engine/storage_adapter_native_test.dart` added (34 tests).
- [x] Are there sync_storage_adapter abstract methods worth covering, or is
      0% expected because all consumers extend it?
      **Decision:** No — abstract methods have no implementation to exercise.
      Coverage comes from testing concrete subclasses.

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

- [x] Add a `coverage:exclude` configuration so vendored and FFI-only files
      do not pollute the headline number.
      Added `// coverage:ignore-file` to 6 platform-specific stub/web files;
      `// coverage:ignore-line` on the iOS/Android branch in
      `_cache_tier_detect_native.dart`.
- [x] Audit `storage_adapter_native.dart`: either gate behind a CI marker or
      add unit tests against a temp-dir adapter.
      Added `test/engine/storage_adapter_native_test.dart` (34 tests, all pass).
- [x] Add tests for `query/exceptions.dart`:
  - [x] `DocumentAlreadyExistsException` toString
  - [x] `DocumentNotFoundException` toString
  - [x] `ReservedFieldException` toString
  - [x] `SchemaValidationException` violations list rendering
  - [x] `StaleIndexException` formatting
  - [x] `ReservedIndexPathException` toString
  - [x] `IndexRebuildEvent` toString
- [x] Add tests for `query/index/index_definition.dart`:
  - [x] Bare `$` path rejection
  - [x] `[*]` rewrite to `[]` round-trip
  - [x] Reserved-prefix validation negative paths
  - [x] `indexNamespace` format, equality, toString
- [x] Add tests for `manifest_reader.dart`:
  - [x] Truncated header (< 12 bytes) yields empty state
  - [x] Record whose declared length exceeds remaining bytes is skipped
  - [x] `replayEdits()` — returns raw edits in order
  - [x] `replayEdits()` — stops at corrupted record
  - [x] `replayEdits()` — missing file returns empty list
- [x] Add tests for `vault_gc.dart` orphan-sweep branches:
  - [x] Sweep idempotence (second sweep finds nothing to do)
- [x] Add tests for `vault_recovery.dart`:
  - [x] Blob only (no manifest) but WITH KV ref — leave alone
- [x] Add tests for `cache/cache_layer.dart`:
  - [x] Write to different namespace does not evict other namespace cache
  - [x] flush, compactAll, listNamespaces, stats, storeInfo delegates
  - [x] tier getter
- [x] Add tests for `hlc_clock.dart`:
  - [x] `current` getter before and after tick
  - [x] Logical counter overflow at `0xFFFF` → `_waitForClockAdvance`
  - [x] `ClockSkewException.toString()`
- [x] Add tests for `fts_manager.dart` failure paths:
  - [x] Search on stale index triggers full rebuild (stale → current)
  - [x] Zero-token document produces no index entries
- [x] Re-run `make coverage` and confirm `kmdb` ≥ 90%.

## Summary

Achieved **90.2%** line coverage on `kmdb` (up from 87.2%). Changes:

- Added `// coverage:ignore-file` to 6 platform-specific web/stub files and a
  single `// coverage:ignore-line` for the iOS/Android branch that cannot be
  reached on a macOS/Linux CI host.
- New test files: `storage_adapter_native_test.dart` (34), `exceptions_test.dart`
  (16), `index_definition_test.dart` (11).
- Extended existing test files: `manifest_test.dart` (+8), `hlc_test.dart` (+5),
  `vault_gc_test.dart` (+1), `vault_recovery_test.dart` (+1),
  `cache_layer_test.dart` (+7), `fts_manager_test.dart` (+2).
- Total: 1245 tests pass (9 E2E skipped by default).
