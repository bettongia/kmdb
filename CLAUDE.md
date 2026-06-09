# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## General

Work is planned using specifications in the `docs/plans` directory. When working on
plans make sure you review `docs/plans/README.md` file for guidance. When asked to
plan something do not commence implementation until explicitly told to do so.

The `docs/roadmap/` directory is used to track future work items and their priority.
This is informational only but worth reviewing when working on the codebase as
current work may intersect with the roadmap.

Larger ideas often start as a proposal in `docs/proposals/` (pre-planning
exploration of an approach and its alternatives — e.g. `vault_search.md`) before
becoming a concrete plan. Consult these for intent and considered alternatives
when planning related work.

We'll create plans for our work and place them in the `docs/plans/` directory. When
the planned work has been completed we'll move them to `docs/plans/completed`.

Quality assurance is critical to this project and you need to maintain a minimum
of 90% test coverage at all times. You must also run all tests successfully
before considering a task to be complete.

Consider edge-cases and failure scenarios when preparing tests - it is critical
not just to focus on easy, "golden-path" tests. Durability and crash-safety in
particular must be exercised with fault injection, not just the golden path —
the 2026-05-22 code review (`docs/reviews/code-review-2026-05-22.md`) found that
in-memory test adapters hide an entire class of data-loss bugs. Beyond unit
tests, work that touches the storage/sync paths should be checked against the
§18 performance benchmarks (`packages/kmdb/benchmark/main.dart`) and the
multi-device `kmdb_harness` package.

Keep the codebase clean as you go: prefer existing primitives over re-rolling
them (e.g. use `ValueCodec`/CBOR rather than hand-written parsers), and do not
leave dead or unreachable code behind. The same review had to clean up
hand-rolled CBOR parsers and never-called code paths — avoid reintroducing that
class of problem.

All public classes, methods and properties must have appropriate doc comments.
You may include examples in dec comments if you believe it will help another
developer.

Any complex segments of code should be commented so as to describe the process
and rationale for the approach.

All code files must have a license at the top. The template file is
@header_template.txt. You must add the comment syntax appropriate to the
programming language. Also replace `{{.Year}}` to match the current year. The
`kmdb-pre-commit` agent enforces this via `license_check`.

## Workflow & Agents

This project runs a plan-driven workflow backed by specialised subagents. The
main session (Opus) owns conversation and planning; specialised and mechanical
work is delegated to agents so each stays focused and the architecture, tests,
and docs stay healthy. Prefer delegating to these agents over doing their work
inline.

**The pipeline:**

1. **Plan (Opus, main session).** Author the plan in `docs/plans/` per
   `docs/plans/README.md`. Consult the **`kmdb-architect`** agent up front to
   ground the plan in the existing spec and surface affected subsystems, prior
   art, gaps, and invariants. Do not start implementation until told to.
2. **Review — `kmdb-plan-reviewer`.** Drives the plan to `Investigated` status.
   The bar: an implementer could execute it with no significant design decisions
   left. Do not implement a plan that is not `Investigated`.
3. **Implement — `kmdb-plan-implement`.** Executes an `Investigated` plan on a
   dated branch + worktree under `.worktrees/`, keeps the plan file/checklists
   current, writes tests + docs, and opens a PR.
4. **QA — `kmdb-qa`.** Quality sign-off before commit: spec alignment, doc
   comments, test adequacy/coverage, benchmark/harness impact, and code health.
   Also runs full-codebase audits on request (e.g. before a release).
5. **Pre-commit — `kmdb-pre-commit`.** Mechanical gate: runs `make pre_commit`
   (format_check, analyze, license_check, scoped tests) and reports.

**When to reach for an agent:**

- Architecture questions, spec lookups, doc/spec/roadmap maintenance, or
  proposal review → **`kmdb-architect`** (authoritative on `docs/spec/`,
  `docs/plans/`, `docs/proposals/`, `docs/roadmap/`). Prefer it over
  re-deriving architecture from the code.
- A plan needs critical review before implementation → **`kmdb-plan-reviewer`**.
- An `Investigated` plan needs building → **`kmdb-plan-implement`**.
- Verify work before a commit/PR → **`kmdb-qa`** (correctness, completeness vs.
  the plan) then **`kmdb-pre-commit`** (mechanical gate).

The agents own the operational detail; the sections below are a quick reference
for the main session.

## Repository Layout

This is a **Pub Workspace**. The root `pubspec.yaml` is a workspace coordinator
only; all source code lives under `packages/`:

```
packages/
  kmdb/                — the core library (lib/, test/, example/, benchmark/)
  kmdb_cli/            — the CLI tool (bin/, lib/, test/)
  kmdb_harness/        — multi-device sync test harness
  kmdb_inferencing/    — ONNX Runtime + BGE embedding model for semantic search
  kmdb_lexical/        — lexical utilities (stemmer, stopwords) used by FTS
  kmdb_google_drive/   — Google Drive SyncStorageAdapter (optional, opt-in)
  kmdb_icloud/         — Apple iCloud (CloudKit) SyncStorageAdapter (iOS/macOS only, optional, opt-in)

External packages pulled in via `git:` refs in `pubspec.yaml`
`dependency_overrides`:
  betto_common         — shared Bettongia Dart utilities (https://github.com/bettongia/common)
  betto_schema         — JSON schema validation (https://github.com/bettongia/schema)
  betto_zstd           — Zstd FFI compression provider (https://github.com/bettongia/zstd)
  betto_registry       — FreeDesktop shared-mime-info file-type identification (https://github.com/bettongia/registry)
  betto_builder_tools  — build helpers shared across Bettongia packages (https://github.com/bettongia/builder_tools)
  betto_icu            — Unicode tokenizer (Tokenizer, IcuTokenizer, RegExpTokenizer) — pub.dev, consumed by kmdb_lexical

Downstream consumer (separate repo, not pulled in here):
  kmdb_ui              — Flutter desktop/browser UI (https://github.com/bettongia/kmdb-ui)
```

Run `make prepare` once (activates `melos` and `coverage`, then bootstraps all
packages); `dart pub get` from the workspace root also resolves dependencies but
skips installing the dev tools.

## Commands

```bash
# Pre-commit gate (format_check, analyze, license_check, then the scoped
# `pre_commit_test` melos script — runs `kmdb` tests). Run this before committing.
# The `kmdb-pre-commit` agent runs and diagnoses this gate for you.
make pre_commit

# Run all tests in every package
make test                  # parallel melos test --no-select
melos test --no-select     # equivalent (when invoked directly)

# Run all tests for a single package — `cd` so native-asset build hooks fire
# (see the note below); equivalent to `melos run pre_commit_test --no-select`
# for `kmdb`.
cd packages/kmdb && dart test
cd packages/kmdb_cli && dart test

# Run a single test file
cd packages/kmdb && dart test test/some_test.dart

# Run tests matching a name pattern
cd packages/kmdb && dart test --name "some pattern"

# Analyze/lint across all packages
make analyze
melos run analyze

# Format across all packages
make format
melos format

# Coverage (writes site/coverage/lcov.info and per-package summaries)
make coverage

# Build docs site (requires pandoc)
make site

# Run performance benchmarks (§18 P99 targets)
cd packages/kmdb && dart run benchmark/main.dart
```

> **Native-asset hooks.** Any package whose dependencies have native-asset
> build hooks (currently `betto_zstd` via `package:betto_zstd`) must have
> `dart test` invoked from **inside** the package directory — `dart test
> <path>` from the workspace root resolves the root package
> (`kmdb_workspace`, no hooks) and the hook silently isn't built, producing
> *"No available native assets … ZSTD_minCLevel"* on a cold cache. All
> `make` / `melos` targets use `melos exec`, which runs `dart test` in each
> package dir, so prefer them over raw `dart test <path>`. The warm artifact
> is `.dart_tool/native_assets.yaml`.

## Implementation Status

| Phase | Scope                                                                                            | Status      |
| :---- | :----------------------------------------------------------------------------------------------- | :---------- |
| 1     | Primitives & platform layer (XXH64, HLC, KeyCodec, ValueCodec, StorageAdapter)                   | ✅ Complete |
| 2     | Storage engine core (SkipList, Memtable, WAL, Bloom filter, SSTable writer/reader)               | ✅ Complete |
| 3     | LSM orchestration (Manifest, MergeIterator, CompactionJob, LsmEngine, CrashRecovery, KvStore)    | ✅ Complete |
| 4     | Value encoding integration & `$meta` (MetaStore, DeviceId, generation counters)                  | ✅ Complete |
| 5     | Sync protocol (HighwaterMark, CloudAdapter, SyncEngine push/pull, ConsolidationCoordinator)      | ✅ Complete |
| 6     | Cache layer (LruMap, SessionCache, CacheTier, CacheLayer with generation invalidation)           | ✅ Complete |
| 7     | Query layer (KmdbDatabase, KmdbCollection, KmdbQuery, Filter DSL, secondary indexes, reactivity) | ✅ Complete |
| 8     | Platform hardening (OPFS web storage, Zstd FFI/WASM, cloud adapters, performance benchmarks)     | ✅ Complete |
| 9a    | Lexical search (BM25 inverted index, tokenisation pipeline, FtsManager, `search` CLI command)    | ✅ Complete |
| 9b    | Semantic search (BGE Small En v1.5, SQ8 vector index, VecManager, ONNX inference)                | ✅ Complete |
| 9c    | Hybrid search (Reciprocal Rank Fusion, `--mode` flag, unified SearchResult types)                | ✅ Complete |
| 10    | Vault (content-addressable blob store, KVLT packaging, ref-counted GC, distributed sync)         | ✅ Complete |
| 11    | Document versioning (`$ver:` history, keep-N / retention window, promote, CLI commands)           | ✅ Complete |

All tests pass on `main`. E2E tests are skipped by default — run them via
`make e2e_test` (`melos e2e-test`).

> **Durability hardening (v0.02.01 — post-review).** The 2026-05-22 code review
> (`docs/reviews/code-review-2026-05-22.md`) found a cluster of crash-safety /
> data-loss issues. The hardening track is tracked in
> [docs/roadmap/0_02_01.md](docs/roadmap/0_02_01.md), which is the authoritative
> status board — consult it (or the `kmdb-architect` agent) for live status.
>
> As of 2026-05-30 **all critical and high-severity crash-safety items are
> complete**: C1 (crash-recovery WAL replay), C2+H1+M3 (manifest fsync &
> durability ordering, incl. `syncDir` and the `CURRENT` swap), H3 + H3-FU (vault
> GC fail-safe ref counts + stub-orphan producer fix), H5 (sync lease CAS
> atomicity), H2 (atomic `WriteBatch` WAL frame), and H4 + H4-FU/-FU2/-FU3
> (compaction version collapse + sync-horizon-gated tombstone GC with
> stale-device eviction and an ingest-side horizon floor). Per the review's §8
> recommendation, these were gated on a `FaultyStorageAdapter` fault-injection
> harness rather than the durability-blind in-memory adapter.
>
> All items are now complete: **M1** (SSTable reader caching), **M2** (real
> UTF-8 namespace encoding with NFC normalisation), the **§6** code/doc tidy-up,
> and **§5 trailing** (consolidation epoch monotonicity — `max(previousEpoch + 1,
> nowMs)`, PR #32). The v0.02.01 track is fully closed as of 2026-06-01. Two
> checks that cannot run in CI stay as release-time verifications in
> `docs/spec/28_release_checklist.md`: **RC-4** (Linux real-OS power-loss) and
> **RC-6** (multi-device tombstone non-resurrection).

## Architecture

> The summary below is a fast orientation. For authoritative answers, deep
> subsystem questions, design validation, or doc maintenance, consult the
> **`kmdb-architect`** agent — it grounds answers in `docs/spec/` and tracks the
> implemented-vs-planned-vs-proposed distinction.

KMDB is a local-first document database for Dart/Flutter with a 6-layer stack:

```
Application
    ↓
Query Layer       — typed KmdbCollection<T> API, filter DSL, reactive watch() streams
    ↓
Cache Layer       — session object cache + persistent materialised views ($cache)
    ↓
KvStore           — public LSM API boundary (untyped Uint8List, String keys)
    ↓
Storage Engine    — WAL + memtable + SSTables, Manifest, compaction
    ↓
Platform Layer    — conditional exports: dart:io (native) vs dart:js_interop (web)
```

**Why LSM over SQLite:** Immutable SSTables are the core design constraint. File
creation is atomic in cloud storage; file mutation is not. SSTables are the
natural, sync-safe unit of replication — a first-class requirement, not an
incidental benefit.

### Storage Engine (LSM)

- **Write path:** WAL append + fsync → memtable insert → flush at 64KB → L0
  SSTable
- **Levels:** L0 (2-file trigger), L1 (2MB), L2 (20MB). Single-file shortcut: if
  total data ≤512KB, compact everything to one L2 file (common case).
- **Compaction:** synchronous on the write path — no background isolate. Fires
  before the triggering `put()` returns. Roughly every ~30 writes.
- **Manifest:** append-only VersionEdit log (`MANIFEST-NNNNN`). Each record is
  `[XXH64 8B][length 4B][CBOR VersionEdit]`. `CURRENT` file names the active
  manifest. Rotated when >1MB.
- **WAL:** multi-file (`wal-00001.log`). Local only — never synced to cloud.
  Retired after flush is confirmed in the Manifest.
- **SSTables:** 4KB data blocks, Bloom filter block (10 bits/key, ~0.8% FPR),
  index block, footer. XXH64 checksums throughout.
- **Value encoding (§5):** `KmdbCodec<T>` → CBOR → optional Zstd (native) or
  compression (native only — web stores uncompressed). 1-byte flag prefix on
  each value.
- **Keys:** UUIDv7 (16-byte binary internally, hex string at KvStore boundary).
  HLC timestamps (48-bit physical + 16-bit logical) on WAL records and SSTables.

### SSTable Naming

Two formats — both live under `sst/`:

- **Regular flush:** `{deviceId}-{minHlc}-{maxHlc}.sst` (3 segments)
- **Consolidation output:** `{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst` (4
  segments)

The `epoch` field is a fencing token (sequence number from the lease file) that
identifies which consolidation round produced the file.

### Local Directory Layout

```
{local-db-dir}/
  LOCK
  CURRENT
  MANIFEST-00001
  wal-00001.log
  sst/
    {deviceId}-{minHlc}-{maxHlc}.sst
  local/
    config.json             ← CLI-only: named sync remotes
```

The `local/` subdirectory holds per-machine, non-synced CLI state. It is created
lazily on first `remote add` and is never uploaded or read by `SyncEngine`.

### Sync Folder Layout

```
{sync-root}/
  highwater/
    {deviceId}.hwm        ← per-device high-water mark (JSON)
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst          ← regular flush (3 segments)
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst  ← consolidation output (4 segments)
  .consolidation-lease    ← coordinator lock (JSON)
```

### Cache Layer (§15)

Sits between KvStore and the Query Layer. Two caches:

1. **Session object cache** — decoded `Map<String, dynamic>` objects, keyed by
   `(namespace, key, sequenceNumber)`. 2,000 objects on desktop; 256 on
   mobile/web.
2. **Materialised view cache** (`$cache` namespace) — persisted scan results
   required on mobile/web where processes are killed silently.

Invalidation uses **namespace generation counters** in `$meta`
(`gen:{namespace}`), incremented atomically on every `WriteBatch`. The Cache
Layer subscribes to `KvStore.writeEvents` to evict stale entries.

### Query API (§13)

Core types: `KmdbDatabase`, `KmdbCodec<T>`, `KmdbCollection<T>`, `KmdbQuery<T>`

Filter DSL: comparisons, nested dot-paths, string ops (`startsWith`, `endsWith`,
`contains`), array ops (`containsAll`, `containsAny`), null semantics,
`Filter.not()`.

Query pipeline: `where` → `orderBy` → `limit` / `offset` → terminals (`get()`,
`stream()`, `watch()`, `first()`, `count()`, `any()`).

**Reactivity:** `watch()` re-executes the query on each `writeEvents` emission
for the namespace, debounced at 50ms.

### Secondary Indexes (§16)

Defined at `KmdbDatabase.open()` time. Lazy build on first query. 4 lifecycle
states: `undefined` → `building` → `current` (or `stale` if writes arrived
during build). Index entries stored in `$index:{ns}:{path}` system namespaces.
All index writes are in the same `WriteBatch` as the document write — always
consistent. Dot-path syntax supports nested fields (`address.city`) and array
fan-out (`tags[]`).

### Text Search (§20–23)

Three modes: **lexical** (BM25 inverted index, `$fts:` namespaces), **semantic**
(BGE Small En v1.5 embeddings, SQ8 quantization, `$vec:` namespaces), and
**hybrid** (Reciprocal Rank Fusion combining both). All `$fts:` and `$vec:`
namespaces are excluded from sync and cache. Managed via `FtsManager` and
`VecManager`; queried via `KmdbCollection.search()`. English-language only; web
browser excluded. See §20 for shared types and CLI, §21–23 for each mode.

### Sync Protocol (§12)

- Each device has a stable UUID identity
- SSTables are the sync unit — uploaded after flush/compaction; WAL never synced
- Per-device high-water marks (`.hwm` files) track what each device has seen
- Conflict resolution: Last-Write-Wins via HLC timestamps
- Cross-device consolidation via a `ConsolidationCoordinator` using a lease file

### Crash Recovery (§17)

On `open()`: acquire exclusive lock → read `CURRENT` → replay Manifest → delete
orphan SSTables → replay WAL files above highest `logNumber` → set dirty-open
flag on first write.

## Documentation

Full specification is in [docs/spec/](docs/spec/) (Pandoc Markdown). The built
HTML lives in [site/](site/) and is generated via `make docs`. Key spec files:

- `03_architecture_overview.md` — ADR and layer diagram
- `04_keys.md` — UUIDv7 document keys, device identity, HLC
- `05_value_encoding.md` — CBOR encoding pipeline and compression
- `06_storage_engine.md` — LSM write/read/compaction paths
- `07_wal.md` — WAL record format and file lifecycle
- `08_sstable.md` — SSTable format and naming conventions
- `09_integrity.md` — checksum strategy and Bloom filter notes
- `10_manifest.md` — VersionEdit log format and CURRENT pointer
- `11_kv_store.md` — KvStore interface, WriteBatch, OpenResult, KvStoreConfig
- `12_sync.md` — full sync protocol
- `13_query_api.md` — public API surface
- `14_reactivity.md` — watch() and debounced re-execution
- `15_cache_layer.md` — session cache, materialised views, generation counters
- `16_secondary_indexes.md` — index lifecycle, write interception, lazy build
- `17_crash_recovery.md` — recovery sequence and failure scenarios
- `18_concurrency.md` — synchronous model and performance targets
- `19_platform.md` — platform conditional exports and package layout
- `20_text_search.md` — text search overview, shared types, CLI, sync exclusion
- `21_lexical_search.md` — BM25 inverted index, preprocessing pipeline,
  write/query/compaction
- `22_semantic_search.md` — BGE model, SQ8 quantization, vector index,
  write/query paths
- `23_hybrid_search.md` — Reciprocal Rank Fusion, candidate set, mode flag,
  score structure
- `24_vault.md` — content-addressable blob store and KVLT packaging
- `25_collection_schemas.md` — JSON Schema admission gate for collection writes
- `30_icloud_adapter.md` — Apple iCloud (CloudKit) adapter: zone model, ETag strategy, CAS semantics, developer setup, Phase 4a probe results
- `99_glossary.md` — terminology reference

Full-codebase reviews live in [docs/reviews/](docs/reviews/) — start with
`code-review-2026-05-22.md`, which drives the current durability-hardening track
(see the Implementation Status note above).
