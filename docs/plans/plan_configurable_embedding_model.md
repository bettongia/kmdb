# Configurable embedding model with download-on-demand

**Status**: Complete

**PR link**: —

## Problem statement

`kmdb_inferencing` currently hardcodes the BGE Small En v1.5 model. The model
binary and vocabulary are bundled in Git LFS and must be present on disk before
`OnnxEmbeddingModel.load()` is called. This has several problems:

1. **No download-on-demand.** Git LFS is unsuitable for production distribution;
   mobile platforms (iOS, Android) cannot use it at all. Model files must be
   downloaded at runtime and cached in a platform-appropriate location.
2. **Single hardcoded model.** Supporting additional models (e.g. BGE-M3 for
   multilingual search, planned in v0.08) requires structural changes that are
   easier to make before the first production release.
3. **No model identity tracking.** `$vec:` indexes are built by a specific model
   and are incompatible across models (BGE Small En produces 384-dimensional
   vectors; BGE-M3 produces 1024-dimensional vectors). If the active model
   changes, stale indexes must be invalidated and rebuilt. Currently nothing
   records which model built a given index.

## Open questions

- [x] Should BGE-M3 be a fully tested, shippable option in this plan, or should
      the plan only establish the infrastructure so that BGE-M3 can be added in
      v0.08 with minimal friction? **Decision:** Infrastructure only.
      `ModelCatalog` defines the set of permitted models as an explicit
      allowlist — attempting to load an unknown model ID throws. BGE-M3 is
      registered in the catalog but not yet tested or shipped; that work is
      deferred to v0.08.
- [x] What is the platform cache directory for downloaded models? **Decision
      (revised 2026-06-05, Q4):** The cache directory lives **only** on
      `OnnxEmbeddingModel.load(cacheDir: ...)` in `kmdb_inferencing`. The
      download happens _before_ `KmdbDatabase.open()` and is the caller's
      responsibility. The earlier idea of a `modelCacheDir` field on
      `KmdbConfig` threaded through `VecManager` was an architectural error —
      `KmdbConfig` is the serialised per-database `local/config.json` object and
      is never passed to `open()`, and `VecManager` has no download/HTTP
      concerns. All mentions of `modelCacheDir` on `KmdbConfig` and of threading
      a cache dir through `VecManager` are dropped. For the CLI, `ReplConfig`
      resolves a cache dir (default `~/.kmdb_cache`, overridable via a
      `cacheDir` key in `~/.kmdbrc`) and passes it directly to
      `OnnxEmbeddingModel.load()` when constructing the model before `open()`.
      Flutter app developers supply their own path (e.g. `path_provider`'s
      `getApplicationSupportDirectory()`) to `load()`.
- [x] What happens when the active model changes (e.g. user upgrades from BGE
      Small En to BGE-M3): automatic index rebuild on next open, or require an
      explicit `kmdb reindex` CLI command / API call? **Decision (revised
      2026-06-05, Q2):** On open, `VecManager` detects the model identity
      mismatch and marks the affected `$vec:` namespaces **`stale`**. There is
      **no background scheduler or isolate** — none exists in this codebase. The
      existing lazy path handles the rebuild: the next `search()` call invokes
      `ensureBuilt`, which rebuilds the stale index inline (blocking that one
      query), exactly as it does for any other stale index today.
      `KmdbDatabase.reindex()` (CLI: `kmdb reindex`) is the **only** way to
      force an immediate _foreground_ rebuild without waiting for the next query
      — useful after a planned model upgrade or to reclaim disk from the stale
      index sooner. "Queue a background rebuild" in earlier drafts meant exactly
      this lazy-on-next-query behaviour, not a new job system.

## Investigation

### Current architecture

`OnnxEmbeddingModel.load({String? modelPath})` in
`packages/kmdb_inferencing/lib/src/embedding_model.dart` resolves a model path
(defaulting to `<executableDir>/assets/models/bge-small-en/bge_small.onnx`) and
throws `UnsupportedError` if the file is absent. The caller — typically
`KmdbDatabase.open(embeddingModel: ...)` — is responsible for loading the model
before opening the database.

`EmbeddingModelConfig` in `packages/kmdb/lib/src/config/kmdb_config.dart` stores
`{type, modelPath}` in `config.json`. `type` is currently always `"onnx"` and
`modelPath` is a raw filesystem path. There is no concept of model identity or
version.

`VecManager` in `packages/kmdb/lib/src/search/semantic/vec_manager.dart` takes
an `EmbeddingModel` interface at construction time and has no knowledge of which
specific model it is using.

The `$vec:` index stores SQ8-quantised 384-dimensional vectors (BGE Small En).
BGE-M3 would require 1024-dimensional vectors — the index is incompatible across
models.

### Required changes

**Model specification type.** Replace the raw `modelPath` approach with a
`ModelSpec` value type capturing:

- `id` — stable identifier (e.g. `bge-small-en-v1.5`, `bge-m3-v1.0`)
- `embeddingDimensions` — `384`, `1024`, etc.
- Download URLs for the `.onnx` file and associated vocabulary/config files
- SHA-256 checksums for integrity verification

**Model catalog.** A `ModelCatalog` class (or const map) in `kmdb_inferencing`
enumerating the supported models with their `ModelSpec`s. Models are referenced
by ID; the catalog is an explicit allowlist — attempting to use an unregistered
model ID throws. BGE-M3 is registered but flagged as not yet validated; shipping
it is deferred to v0.08. The catalog is the single place to add and gate new
models.

**Download-on-demand.** A `ModelDownloader` that:

- Resolves a writable cache directory from a caller-supplied base path
- Checks whether the model files are already present and their checksums match
- Downloads missing files with progress callbacks
- Verifies checksums after download; deletes and re-downloads on mismatch

`OnnxEmbeddingModel.load()` gains a `ModelSpec` parameter and an optional
`cacheDir` parameter. If the model is not cached it triggers the downloader
before opening the ORT session.

**Remove Git LFS assets.** Once download-on-demand is in place, the model files
in `packages/kmdb_inferencing/assets/models/` should be removed from the
repository. Local development uses the download path like production.

**Dimension generalisation (Q1 — generalise now).** `384` is hard-coded on the
hot path and is replaced everywhere with `spec.embeddingDimensions` (or, where
no `ModelSpec` is in scope, the model's `dimensions` accessor) as the single
source of truth. This paves the way for v0.08 (BGE-M3, 1024-dim) instead of
deferring it. The exact sites, confirmed by grep on 2026-06-05:

- `packages/kmdb_inferencing/lib/src/sq8.dart` — `quantise` (line ~45) and
  `dequantise` (line ~75) assert `vector.length == 384`. Change both asserts to
  validate against a caller-supplied expected dimension (pass the dimension in,
  or drop the magic constant and assert only `> 0`). The doc comments at lines
  41–42 and 72 that name 384 are updated.
- `packages/kmdb_inferencing/lib/src/math_utils.dart` — `meanPool` defaults
  `hiddenDim = 384` (line 37) and the doc at line 29. The default is removed;
  `hiddenDim` becomes a required parameter sourced from the active model.
- `packages/kmdb_inferencing/lib/src/ort_session.dart` — `const hiddenDim = 384`
  (line 296) and doc comments at lines 56, 198–199. `hiddenDim` is sourced from
  the loaded `ModelSpec.embeddingDimensions` rather than a constant.
- `packages/kmdb/lib/src/search/semantic/vec_manager.dart` — the
  `bytes.length != 384` guards in `_scoreField` (lines 612 and 621) become
  `bytes.length != model.dimensions` (the SQ8 byte length equals the dimension,
  1 byte per component). Without this, a 1024-dim index would silently score
  zero documents. The storage-layout doc comment at line 43 (and
  `vec_index_state.dart` line 154) that say "384-byte SQ8 vector" are
  generalised.
- `packages/kmdb/lib/src/search/embedding_model.dart` doc at line 44 is updated.

Because `EmbeddingModel` gains a `dimensions` accessor (see below), `VecManager`
reads `model.dimensions` rather than a literal; `kmdb_inferencing` internals
read `spec.embeddingDimensions` from the loaded `ModelSpec`.

**Model identity surface (Q3a — interface change).** Add two members to the
`EmbeddingModel` interface in
`packages/kmdb/lib/src/search/embedding_model.dart`:

```dart
/// Stable identifier of the model that produced these embeddings, matching a
/// `ModelCatalog` entry id (e.g. `bge-small-en-v1.5`). Persisted with each
/// `$vec:` index so a later model swap can be detected and the index rebuilt.
String get modelId;

/// Embedding vector length produced by this model (e.g. 384 for BGE Small En
/// v1.5, 1024 for BGE-M3). Single source of truth for SQ8 byte lengths and
/// score-path length guards.
int get dimensions;
```

This ripples to:

- `packages/kmdb_inferencing/lib/src/embedding_model.dart` —
  `OnnxEmbeddingModel` implements both, sourced from the loaded `ModelSpec`.
- Four test doubles must add the members:
  `packages/kmdb/test/search/semantic/vec_manager_test.dart`
  (`_FakeEmbeddingModel` and `_TrackingEmbeddingModel`),
  `packages/kmdb/test/search/search_stub_test.dart` (`_FakeEmbeddingModel`),
  `packages/kmdb/test/search/hybrid/hybrid_search_integration_test.dart`
  (`_DeterministicEmbeddingModel`),
  `packages/kmdb/test/search/semantic/vec_search_integration_test.dart`
  (`_ClusteredEmbeddingModel`).

**Model identity storage (Q3b — field inside `VecIndexState`).** Model identity
is stored as a **new field on the existing `VecIndexState` CBOR map**, not a
standalone `$meta` key. `VecIndexState` is keyed per-field
(`metaKey(ns, field) => 'vec:$ns:$field'`), so identity is recorded per indexed
field. Add field `modelId` (CBOR string, default `''` for backward-compatible
reads) to:

- `VecIndexState.toCbor` (alongside `namespace`/`field`/`status`/`builtThrough`/
  `builtAt`) — `CborString('modelId'): CborString(modelId)`.
- `VecIndexState.fromCbor` — `modelId: map['modelId'] as String? ?? ''`.
- the constructor, fields, and `copyWith`.

When `VecManager.ensureBuilt` builds an index it records `model.modelId`. On
open, for each defined vec field, `VecManager` compares the stored `modelId`
against `model.modelId`; on mismatch (and on a non-empty stored id only — an
empty id means "pre-identity index, treat as matching to avoid churn", OR
"rebuild once to stamp identity" — **specify: empty stored id is treated as a
match and is stamped on the next build, not eagerly rebuilt**) it transitions
the field's `VecIndexState.status` to `stale`. No background rebuild is queued;
the existing lazy `ensureBuilt`-on-next-query path rebuilds it (Q2). This is the
prerequisite for v0.08 model migration (see
[docs/roadmap/0_06.md](../roadmap/0_06.md)).

**`reindex()` scope (gap).** `KmdbDatabase.reindex()` rebuilds **all stale
`$vec:` namespaces/fields** by calling `ensureBuilt` synchronously in the
foreground for each. It is **vec-only** — it does not touch FTS indexes. It is
reachable via the existing `_vecManager` field (`VecManager? get vecManager`);
no new plumbing is needed. If no embedding model is configured (`_vecManager` is
null), `reindex()` is a no-op that returns normally. The CLI `kmdb reindex`
command prints a message and exits 0 when no embedding model is configured,
rather than erroring.

**`EmbeddingModelConfig` update + legacy migration (gap).** Replace the raw
`modelPath` field with `modelId` (referencing a `ModelCatalog` entry). The
typedef becomes `({String type, String modelId})`. In `_parseJson`, detect the
legacy shape explicitly: **`modelPath` present and `modelId` absent** → throw a
`FormatException` with a clear migration message, e.g.
`"Corrupt config.json: 'embeddingModel.modelPath' is no longer supported. "`
`"Replace it with 'modelId' naming a catalog model (e.g. 'bge-small-en-v1.5')."`
This must fire _before_ the generic "missing modelId" error so the user gets
actionable text. Note: **no CLI command writes an `embeddingModel` config
today** (only tests reference `EmbeddingModelConfig`), so this migration path is
largely defensive — but cheap to get right.

**Cache directory ownership (Q4).** The cache dir lives on
`OnnxEmbeddingModel.load(cacheDir: ...)` only. There is **no** `modelCacheDir`
on `KmdbConfig` and **no** cache-dir threading through `VecManager`. The CLI's
`ReplConfig` resolves the cache dir (default `~/.kmdb_cache`, overridable by a
`cacheDir` key in `~/.kmdbrc`, created lazily on first download) and passes it
to `OnnxEmbeddingModel.load()` when it constructs the model _before_ `open()`.
The `~/.kmdbrc` defaults file written on first run includes a commented-out
`cacheDir` example. Flutter apps pass their own path to `load()`.

**Download crash-safety (gap).** `ModelDownloader` writes each file to a temp
path in the cache dir (e.g. `{name}.onnx.tmp-{pid}` or a `*.part` suffix),
verifies the SHA-256 against the `ModelSpec` checksum, and only then atomically
renames it to the final name. A half-written `.onnx` therefore never passes the
existence/checksum check on a later run. For concurrent CLI invocations sharing
`~/.kmdb_cache`, **no locking is needed: last-writer-wins on the atomic rename
is acceptable** (both writers produce byte-identical, checksum-verified output).
The existence-and-checksum check short-circuits the download when a valid file
is already present.

**Web platform (gap).** This plan is **native-only**. `kmdb_inferencing` and
semantic search are excluded from the web browser by existing design (CLAUDE.md
§20). Nothing here introduces an OPFS/web path; `ModelDownloader` and the cache
dir are `dart:io`-only.

**LFS assets (Q5 — deferred).** Removing the bundled Git LFS model assets is
**deferred entirely to a follow-up plan.** In this plan the existing LFS assets
under `packages/kmdb_inferencing/assets/models/` remain in place, so the
existing inferencing/CLI test suites continue to load the bundled model exactly
as today — no coverage regression, no CI network dependency. `ModelDownloader`
is tested with **mock HTTP / stubbed responses only** (partial download, corrupt
download, checksum mismatch+retry, temp-file-then-rename). The real ~127 MB
end-to-end download cannot run in the automated suite and is captured as a
release-checklist item (see Docs phase).

**Spec update.** §22 (semantic search) needs a new subsection documenting the
model lifecycle: catalog, download, identity key, and invalidation behaviour.

### Affected files

New files (in `packages/kmdb_inferencing/lib/src/`):

- `model_spec.dart` — `ModelSpec` value type
- `model_catalog.dart` — `ModelCatalog` allowlist
- `model_downloader.dart` — download-on-demand with temp-file+rename

Changed files:

- `packages/kmdb/lib/src/search/embedding_model.dart` — add `modelId` +
  `dimensions` to the interface (Q3a); update the "384" doc at line 44.
- `packages/kmdb_inferencing/lib/src/embedding_model.dart` —
  `OnnxEmbeddingModel` gains `ModelSpec` + `cacheDir` on `load()`, implements
  `modelId`/`dimensions`, triggers downloader; update 384 doc comments.
- `packages/kmdb_inferencing/lib/src/sq8.dart` — generalise `quantise`/
  `dequantise` dimension asserts (Q1).
- `packages/kmdb_inferencing/lib/src/math_utils.dart` — `meanPool` `hiddenDim`
  becomes required, no 384 default (Q1).
- `packages/kmdb_inferencing/lib/src/ort_session.dart` — `hiddenDim` sourced
  from `ModelSpec`, drop `const hiddenDim = 384` (Q1).
- `packages/kmdb/lib/src/search/semantic/vec_manager.dart` — `bytes.length`
  guards use `model.dimensions`; write/compare `modelId`; mark stale on mismatch
  (Q1/Q3); `reindex` helper.
- `packages/kmdb/lib/src/search/semantic/vec_index_state.dart` — add `modelId`
  CBOR field; generalise "384-byte" doc (Q3b).
- `packages/kmdb/lib/src/query/kmdb_database.dart` — add `reindex()` over the
  existing `_vecManager` (gap).
- `packages/kmdb/lib/src/config/kmdb_config.dart` — `EmbeddingModelConfig` →
  `modelId`; legacy `modelPath` migration error. **No `modelCacheDir`** (Q4).
- Test doubles (four files, listed in the Model-identity-surface section above).
- `packages/kmdb_cli/` — `ReplConfig` resolves a cache dir and passes it to
  `OnnxEmbeddingModel.load()` before `open()`; `search` first-use download
  progress to stderr; new `kmdb reindex` command.
- `docs/spec/22_semantic_search.md` — model lifecycle subsection.
- `docs/spec/28_release_checklist.md` — real ~127 MB download verification
  entry.

Explicitly **not** in scope: removing Git LFS assets (deferred, Q5);
`ort_library.dart` iOS branch (separate concern); any web/OPFS path
(native-only, gap).

## Implementation plan

### Phase 1 — Model specification and catalog

- [x] Define `ModelSpec` record type (`id`, `embeddingDimensions`, onnxUrl,
      vocabUrl, onnxSha256, vocabSha256) in a new
      `packages/kmdb_inferencing/lib/src/model_spec.dart`
- [x] Create `ModelCatalog` in `model_catalog.dart` with entries for BGE Small
      En v1.5 and (infrastructure only, not yet tested) BGE-M3
- [x] Write unit tests for catalog lookup by ID

### Phase 2 — Dimension generalisation (Q1)

- [x] Generalise `sq8.dart` `quantise`/`dequantise` asserts off the 384 constant
      (validate against a supplied dimension or `> 0`); update doc comments
- [x] Make `math_utils.dart` `meanPool` `hiddenDim` required (no 384 default)
- [x] Source `ort_session.dart` `hiddenDim` from the loaded `ModelSpec`; drop
      `const hiddenDim = 384`
- [x] Replace the two `bytes.length != 384` guards in `vec_manager.dart`
      `_scoreField` with `!= model.dimensions`; generalise the 384-byte doc
      comments in `vec_manager.dart` and `vec_index_state.dart`
- [x] Add `String get modelId` + `int get dimensions` to the `EmbeddingModel`
      interface; implement on `OnnxEmbeddingModel`; update the four test doubles
- [x] Confirm all existing semantic/hybrid tests still pass against 384

### Phase 3 — Download-on-demand

- [x] Implement `ModelDownloader` with progress callback, SHA-256 verification,
      and **download-to-temp-then-atomic-rename** (last-writer-wins, no locking)
- [x] Update `OnnxEmbeddingModel.load()` to accept `ModelSpec` + `cacheDir`;
      short-circuit when a valid checksummed file is present; invoke downloader
      if absent or checksum mismatch
- [x] Write tests with **mock HTTP / stubbed responses only** (partial download,
      corrupt download, checksum mismatch + retry, temp-file-then-rename,
      present-file short-circuit). No real network download in the suite
- [x] Leave the existing Git LFS assets in place (removal deferred to a
      follow-up plan, Q5) so existing tests keep loading the bundled model

### Phase 4 — Model identity and index invalidation (Q3b / Q2)

- [x] Add a `modelId` field to `VecIndexState` (constructor, fields, `copyWith`,
      `toCbor`, `fromCbor` with `?? ''` default for backward-compatible reads)
- [x] `VecManager.ensureBuilt` records `model.modelId` when it builds an index
- [x] On open, `VecManager` compares stored `modelId` vs `model.modelId` per
      field; on a non-empty mismatch, set `status = stale`; an empty stored id
      is treated as a match and stamped on the next build (no eager rebuild)
- [x] Confirm the lazy `ensureBuilt`-on-next-`search()` path rebuilds the stale
      index inline — **no background scheduler is added** (Q2)
- [x] Add `KmdbDatabase.reindex()` over the existing `_vecManager`: rebuild all
      stale `$vec:` fields in the foreground; vec-only (not FTS); no-op when no
      embedding model is configured
- [x] Tests: index built with model A, reopen with model B → field marked
      `stale`, next `search()` rebuilds; reopen with same model → no rebuild;
      empty stored id → no churn, stamped on next build; `reindex()` rebuilds
      all stale fields and is a no-op with no model

### Phase 5 — Config and CLI

- [x] Change `EmbeddingModelConfig` typedef to `({String type, String modelId})`
- [x] In `_parseJson`, detect legacy `modelPath`-present + `modelId`-absent and
      throw the migration `FormatException` before the generic missing-`modelId`
      error; add a test for the migration message
- [x] **Do not** add `modelCacheDir` to `KmdbConfig` or thread a cache dir
      through `VecManager` (Q4)
- [x] `ReplConfig` resolves the cache dir (`cacheDir` key in `~/.kmdbrc`,
      default `~/.kmdb_cache`, created lazily on first download) and passes it
      to `OnnxEmbeddingModel.load()` before `open()`
- [x] Include a commented-out `cacheDir` example in the defaults file written by
      `ReplConfig._writeDefaults()`
- [x] Update CLI `search` command to surface first-use download progress to
      stderr
- [x] Add `kmdb reindex` CLI command calling `KmdbDatabase.reindex()`; print a
      message and exit 0 when no embedding model is configured
- [x] Update CLI integration tests and example code

### Phase 6 — Docs

- [x] Add a model-lifecycle subsection to `docs/spec/22_semantic_search.md`
      (catalog/allowlist, download + temp-file-rename, per-field `modelId`
      identity, stale-on-mismatch + lazy rebuild, `reindex()`)
- [x] Add a `docs/spec/28_release_checklist.md` entry for the real ~127 MB
      end-to-end model download verification (cannot run in automated CI)
- [x] Update `packages/kmdb_inferencing/README.md` (or doc comments) with the
      new `load(ModelSpec, cacheDir:)` API

## Review (kmdb-plan-reviewer, 2026-06-05)

**Verdict: not yet `Investigated`. Status → `Questions`.** The problem is real
and well-motivated, and the three resolved open questions are good decisions.
But the Investigation and Implementation plan rest on several assumptions about
the codebase that do not hold, and the most important architectural question —
how a second embedding dimension (1024) coexists with code that hard-codes 384 —
is not addressed at all. A Sonnet implementer would have to invent that design
on the fly. The new open questions below must be resolved first.

### Problem statement assessment

Sound and worth doing. Git LFS is genuinely unusable on mobile,
download-on-demand is the right call, and model identity is a real correctness
gap (a model swap silently corrupts query results). This aligns with
`docs/roadmap/0_06.md`, which explicitly names model identity + index
invalidation as a **prerequisite** for any model migration. Doing the
infrastructure now, before the first production release, is the right
sequencing.

One scope note: the plan bundles four loosely-coupled changes
(download-on-demand, catalog/allowlist, model identity in `$meta`, CLI cache
config). That is defensible as one plan because they share the
`ModelSpec`/catalog type, but the implementer should land them as separable
phases (the checklist already does this) so a problem in, say, the downloader
doesn't block the identity work.

### Architecture-fit problems (these drive the open questions)

1. **`KmdbConfig` is not a system-level config object.** The plan repeatedly
   says "Add an optional `modelCacheDir` field to `KmdbConfig`" and "thread it
   through to `ModelDownloader` in `VecManager`." But `KmdbConfig`
   (`packages/kmdb/lib/src/config/kmdb_config.dart`) is the serialised
   **per-database `local/config.json`** class — it is _not_ passed to
   `KmdbDatabase.open()`. `open()` takes an already-constructed
   `EmbeddingModel?` directly (see `kmdb_database.dart` line ~271); it never
   sees a `KmdbConfig`, and `VecManager` is constructed with just
   `(store, defs, model)`. There is no existing seam by which `VecManager` could
   obtain a cache directory or trigger a download. The download decision happens
   _before_ `open()`, inside `OnnxEmbeddingModel.load()` in the
   `kmdb_inferencing` package. So "thread `modelCacheDir` through to
   `ModelDownloader` in `VecManager`" describes plumbing that does not exist and
   probably should not exist (it would pull download/HTTP concerns into the core
   storage package). The cache dir belongs on `OnnxEmbeddingModel.load()` (the
   plan also says this, in Phase 2 — the two statements contradict each other).
   This contradiction must be resolved (Q4).

2. **The 384 dimension is hard-coded on the hot path — registering a 1024-dim
   model in the catalog does not make it work.** The "infrastructure only"
   decision for BGE-M3 is reasonable _only if_ the plan is explicit that the
   1024-dim path is deliberately non-functional until v0.08. Right now several
   load-bearing sites assume 384:
   - `vec_manager.dart`: `bytes.length != 384` guards in `_scoreField` (both the
     candidate-lookup and full-scan paths) silently skip any non-384-byte
     vector. A 1024-dim index would score _zero_ documents, not error.
   - `sq8.dart`: `quantise`/`dequantise` assert `vector.length == 384`.
   - `math_utils.dart` `meanPool` defaults `hiddenDim = 384`; `ort_session.dart`
     hard-codes `const hiddenDim = 384`.
   - `VecManager._quantise/_dequantise` (the duplicated copies) iterate by
     length so they tolerate 1024, but the storage-layout doc comment and the
     guards above do not.

   The plan must state the v0.07 contract for these sites. The cleanest answer:
   `ModelSpec.embeddingDimensions` becomes the single source of truth, the `384`
   guards become `!= spec.embeddingDimensions * 1` (i.e. a byte length derived
   from the active model), and the asserts are generalised — but that is a real
   design decision, not a mechanical edit, and it must be specified before
   implementation (Q1). If instead the intent is to leave 384 hard-coded and
   only generalise in v0.08, say so explicitly and have the catalog reject
   _loading_ any non-384 model in v0.07 (the allowlist gate, not just a "not
   validated" flag).

3. **There is no background-rebuild mechanism to "queue."** Open question 3's
   resolution says VecManager "marks the affected `$vec:` namespaces as stale
   and **queues a background rebuild** — the user does not need to do anything."
   There is no background isolate or job scheduler in this codebase. The
   existing model (see `ensureBuilt`) is **lazy + synchronous**: a stale index
   is rebuilt _inline on the next query_, blocking that query. "Marks stale"
   already gives you the desired behaviour for free — the next `search()` calls
   `ensureBuilt`, which rebuilds. There is no separate "queue a background
   rebuild" step to implement, and claiming one will mislead the implementer
   into either building a scheduler (large, unscoped) or writing a no-op and
   calling it done. The plan should restate this as: _on open, if model identity
   mismatches, mark the namespace `stale`; the existing
   lazy-rebuild-on-next-query path handles the rest. `reindex()` is the only way
   to force an immediate (foreground) rebuild._ See Q2.

4. **`EmbeddingModel` (the core-package interface) exposes no identity.**
   `VecManager` holds an `EmbeddingModel`, but that interface
   (`packages/kmdb/lib/src/search/embedding_model.dart`) has only `embed` and
   `dispose` — no `id`, no `dimensions`. For `VecManager` to write
   `vec:model:{namespace}` and compare it on open, the interface needs a model
   identity member (e.g. `String get modelId` / `int get dimensions`). This is
   an additive interface change that ripples to every `EmbeddingModel`
   implementation and test double. The plan does not mention it. It must (Q3).

5. **`$meta` identity key naming.** `VecIndexState.metaKey` is
   `vec:{ns}:{field}` (per-field). The plan proposes `vec:model:{namespace}`
   (per-namespace). A namespace can have multiple indexed fields built by the
   same model, so a per-namespace key is fine — but note it lives _outside_ the
   existing `VecIndexState` blob. Decide whether model identity is a new
   standalone `$meta` key or a new field inside the existing per-field
   `VecIndexState` CBOR map (which already round-trips through `$meta`). The
   latter is less surface area and co-locates identity with status. Either is
   acceptable but the plan must pick one and specify the exact key/field (folded
   into Q3).

### Smaller gaps

- **Legacy `config.json` migration.** The plan says a legacy `modelPath` config
  should "produce a clear migration error." But `EmbeddingModelConfig` is a
  typedef `({String type, String modelPath})` and `_parseJson` currently
  _requires_ `modelPath` (throws `FormatException` if absent). Changing the
  field to `modelId` flips that: old configs with `modelPath` and no `modelId`
  must be detected and rejected with a helpful message rather than the generic
  "missing modelId" `FormatException`. Specify the exact detection (modelPath
  present + modelId absent → migration error) and message text so it is
  mechanical. Also confirm whether the CLI ever _writes_ an embeddingModel
  config today — if not, the migration path may be theoretical.
- **Download integrity / crash-safety.** Downloads are I/O to a shared cache dir
  and must survive interruption. The Phase 2 checklist says "simulate partial/
  corrupt downloads, checksum mismatch retry" — good — but the _write_ strategy
  is unspecified: download to a temp file and atomic-rename on checksum success,
  or you risk a half-written `.onnx` that passes an existence check on the next
  run. State the temp-file-then-rename approach explicitly (this is the same
  durability discipline the rest of the codebase follows). Also: concurrent
  processes sharing `~/.kmdb_cache` (two CLI invocations) — is any locking
  needed, or is last-writer-wins on the atomic rename acceptable? Note it.
- **Web platform.** `kmdb_inferencing` is native-only (the web browser is
  explicitly excluded from semantic search per CLAUDE.md §20). Confirm the plan
  is native-only and that nothing here needs an OPFS/web path. A one-line
  statement avoids the implementer wondering.
- **`reindex()` / `kmdb reindex` scope.** Does `reindex()` rebuild _all_ stale
  vec namespaces, only mismatched ones, or take an optional collection argument?
  Does it also cover FTS, or vec only? The checklist says "all stale vec
  namespaces" — make that the definitive contract in the API doc comment, and
  state the CLI exit/behaviour when no embedding model is configured.
- **Removing Git LFS assets.** Removing the bundled model means _every_ test
  that currently calls `OnnxEmbeddingModel.load()` with the bundled asset now
  needs a network download or a fixture. Confirm how the existing inferencing
  test suite obtains a model after LFS removal (cached in CI? a tiny fixture
  model? skipped unless present?). This directly threatens the 90% coverage bar
  and could make CI flaky/network-dependent. This needs a concrete answer before
  Phase 2 lands (Q5). Removing assets in the _same_ plan that adds the
  downloader is also the riskiest possible ordering — consider deferring asset
  removal to a follow-up once download-on-demand is proven in CI.
- **Spec/§22 and release checklist.** Good that §22 is flagged. Add: any test
  that requires a real network download of a ~127 MB model cannot run in the
  normal automated suite — per `docs/plans/README.md` item 4, add a
  `docs/spec/28_release_checklist.md` entry for the real-download verification.

### Strengths

- Correctly identifies model identity as a correctness issue, not a nicety, and
  ties it to the roadmap prerequisite.
- `ModelCatalog`-as-allowlist is a clean, defensible gate.
- The checksum-verify-and-redownload loop is the right integrity posture.
- Phasing is sensible and the checklists are granular.

### Open questions to resolve before `Investigated`

- [x] **Q1 — 384 generalisation contract.** **Resolved:** generalise now.
      `spec.embeddingDimensions` (surfaced as `EmbeddingModel.dimensions`) is
      the single source of truth; all four hard-coded sites change. See the
      "Dimension generalisation" subsection and Phase 2.
- [x] **Q2 — rebuild mechanism.** **Resolved:** mark `stale` on open; the
      existing lazy `ensureBuilt`-on-next-`search()` path rebuilds inline. No
      scheduler/isolate. `reindex()` is the only forced foreground rebuild. See
      the revised original-Q3 resolution and the Model-identity-storage
      subsection.
- [x] **Q3 — model identity surface + storage.** **Resolved:** (a) add
      `String get modelId` + `int get dimensions` to `EmbeddingModel`, rippling
      to `OnnxEmbeddingModel` and the four named test doubles. (b) store
      identity as a new `modelId` CBOR field inside the existing per-field
      `VecIndexState` (not a standalone `$meta` key). See the
      Model-identity-surface and -storage subsections.
- [x] **Q4 — cache-dir ownership.** **Resolved:** cache dir lives on
      `OnnxEmbeddingModel.load(cacheDir:)` only; no `modelCacheDir` on
      `KmdbConfig`, no `VecManager` threading. CLI `ReplConfig` passes it to
      `load()` before `open()`. See the revised original-Q2 resolution and the
      Cache-directory subsection.
- [x] **Q5 — test model after LFS removal.** **Resolved:** defer LFS asset
      removal entirely to a follow-up plan. Existing assets stay; the downloader
      is tested with mocks/HTTP stubs only; the real ~127 MB download is a
      release- checklist item. See the LFS-assets subsection and Phase 6.

## Second review (kmdb-plan-reviewer, 2026-06-05)

All five open questions answered by the user and recorded above; the smaller
gaps (legacy migration, download crash-safety, web platform, `reindex()` scope,
release checklist) are now specified inline in the Investigation and reflected
in the checklist. Each decision was grounded against the current code on
2026-06-05:

- The four `384` sites and the two `vec_manager.dart` length guards exist as
  described; `EmbeddingModel` exposes only `embed`/`dispose`; `VecIndexState` is
  per-field (`metaKey vec:{ns}:{field}`) with `toCbor`/`fromCbor` carrying
  `namespace/field/status/builtThrough/builtAt`; `KmdbDatabase` already holds
  `_vecManager` with a public getter, so `reindex()` needs no new plumbing; no
  CLI path writes an `embeddingModel` config today (migration is defensive); and
  `kmdb_inferencing` is `dart:io`-only.

One design nuance the implementer must honour (specified above, not left open):
an **empty** stored `modelId` (a pre-identity index) is treated as a _match_ and
stamped on the next build, so existing 384 indexes are not needlessly rebuilt on
first upgrade. Only a non-empty mismatch marks the field `stale`.

**Verdict: `Investigated`.** The plan now names every file, method, field, CBOR
key, error message, and test case an implementer needs, with no architecture
decisions left to make on the fly. Scope is well-bounded (LFS removal and the
iOS ORT branch explicitly excluded). Proceed to implementation.

## Summary

_To be completed after implementation._
