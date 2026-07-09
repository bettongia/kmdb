# WI-12: Vault search in `kmdb_cli`

**Status**: Open

**PR link**: —

## Problem statement

Vault search (WI-3) is fully implemented and tested at the `kmdb` core level,
but it does not work from `kmdb_cli` at all — for either search mode:

1. **Lexical vault search is unconfigured.** `vault_command.dart`'s
   `search`/`status`/`reindex` subcommands
   (`packages/kmdb_cli/lib/src/commands/vault/`) genuinely call the real
   `KmdbCollection.searchVault()` API, but
   `DatabaseOpener.open()` (`packages/kmdb_cli/lib/src/database_opener.dart`)
   never passes a `vaultSearch:` parameter to `KmdbDatabase.open()`. So
   `ctx.db.vaultSearchManager` is always `null` and all three subcommands fail
   immediately with "Vault search is not configured for this database." This is
   an oversight, not a design decision — `VaultSearchConfig()` needs no
   embedding model.
2. **Semantic/hybrid search does not work from the CLI at all**, for vault
   search *or* document-field search. `kmdb_cli` has no dependency on
   `betto_inferencing` and never constructs an `EmbeddingModel`. This is a
   pre-existing, broader gap than vault search alone:
   `search_command.dart` already contains a comment acknowledging it, and
   fakes a `(hybrid)` output label without ever running real semantic scoring.
   `KmdbConfig.embeddingModel` (`packages/kmdb/lib/src/config/kmdb_config.dart`)
   is parsed from `local/config.json` and guarded against
   (`reindex_command.dart`, `search_command.dart`) but never resolved into a
   real model — the integration was half-finished.

This plan closes both gaps. Because they share one root cause for the semantic
half (no `EmbeddingModel` is ever constructed in `kmdb_cli`), and because
`VaultSearchConfig` deliberately reuses the database-level embedding model
rather than carrying its own (`vault_search_config.dart`, "RQ-3"), the plan is
split into two independently shippable phases rather than two separate plans:

- **Phase A** — wire up lexical vault search only (`VaultSearchConfig()`, no
  new dependencies). Small, low-risk, unlocks `vault search/status/reindex` in
  lexical mode immediately.
- **Phase B** — construct a real `EmbeddingModel` in `kmdb_cli` and wire it
  into `KmdbDatabase.open()`. This fixes semantic/hybrid search for *both*
  vault search and document-field search in one pass (they are fixed by the
  identical change), and removes `search_command.dart`'s fake-hybrid label.

Phase A can ship alone if Phase B needs more review time; Phase B is not
useful without Phase A already having landed the `vaultSearch:` wiring for the
vault side of the fix (document-field search does not depend on Phase A at
all).

## Open questions

- [ ] **Q1 — Default PDF extractor?** Should `kmdb_extractor_pdf`
      (`PdfTextExtractor`) be registered by default in Phase A, or left
      opt-in? It depends on `betto_pdfium`, which carries its own native
      build-hook (a PDFium dylib bundled alongside the ORT dylib once Phase B
      also lands). Recommendation: opt-in via a `--with-pdf` style config
      knob or a documented manual `VaultSearchConfig(extractors: [...])`
      override, not a CLI flag — see Investigation for reasoning. Default
      `VaultSearchConfig()` (plain-text only) ships in Phase A regardless of
      this answer.
- [ ] **Q2 — One-shot command cache-dir source.** `ReplConfig.cacheDir`
      (`~/.kmdbrc`) is currently loaded only by the interactive REPL session.
      One-shot commands (`kmdb <db> vault search ...`, invoked via
      `cli_runner.dart`) never construct a `ReplConfig`. Phase B needs a
      `cacheDir` for `OnnxEmbeddingModel.load()` in the one-shot path too.
      Recommendation: load `ReplConfig` (just the `cacheDir` value) in
      `cli_runner.dart` before calling `DatabaseOpener.open()`, for both the
      one-shot and REPL paths, so there is a single source of truth. Confirm
      this doesn't regress REPL startup (it currently loads `ReplConfig`
      after database open, per the field order in `cli_runner.dart` — order
      may need adjusting).
- [ ] **Q3 — First-run model download UX.** `OnnxEmbeddingModel.load()`
      triggers `ModelDownloader.ensure()` on first use (127 MB for
      `bge-small-en-v1.5`, 470 MB for `multilingual-e5-small`), with no
      built-in consent gate. Options: (a) download silently with a progress
      line to stderr via the `onProgress` callback, gated only by
      `embeddingModel` being present in `local/config.json` (i.e. presence of
      config *is* consent); (b) require an explicit one-time
      `kmdb <db> models download` subcommand before semantic search will run,
      erroring otherwise. Recommendation: (a) — `local/config.json` is
      already an explicit, deliberate user action (nothing sets
      `embeddingModel` automatically), so a second consent step is
      redundant. Needs sign-off before implementation.
- [ ] **Q4 — Scope of the fake-hybrid removal.** Confirm it's acceptable for
      Phase B to change `search_command.dart` output behavior for existing
      users who have `embeddingModel` configured today — the `(hybrid)` label
      currently appears whenever `embeddingModel` + FTS index are both
      configured, regardless of whether a vector index actually exists yet
      (see `_search`'s `isHybrid` computation). Once real semantic scoring is
      wired in, first-time hybrid search on an existing collection will incur
      a full local vector-index build (foreground, synchronous per §18)
      before results appear. This is expected/correct behavior but is a
      user-visible latency change worth flagging explicitly, not silently.

## Investigation

### Current state (confirmed by reading the code)

- `packages/kmdb_cli/lib/src/database_opener.dart`: `DatabaseOpener.open()`
  calls `KmdbDatabase.open()` with `path`, `adapter`, `deviceId`, `indexes`,
  `ftsIndexes`, `encryptionConfig` — no `vaultSearch:`, no `embeddingModel:`.
- `packages/kmdb_cli/lib/src/commands/vault/vault_search_command.dart`,
  `vault_status_command.dart`, `vault_reindex_command.dart`: all three check
  `ctx.db.vaultSearchManager == null` and fail with an identical error message
  pointing at the exact fix (`Open the database with vaultSearch:
  VaultSearchConfig() to enable it.`) — confirming this is a known,
  documented gap in the code itself.
- `packages/kmdb/lib/src/vault/search/vault_search_config.dart`:
  `VaultSearchConfig()` needs no embedding model parameter — it reuses
  whatever `EmbeddingModel` was passed to `KmdbDatabase.open(embeddingModel:
  ...)` (doc comment "RQ-3"). Semantic vault indexing activates automatically
  if and only if that model is non-null. `effectiveExtractors` always
  prepends `PlainTextExtractor` regardless of what the caller supplies, so
  `VaultSearchConfig()` with an empty extractor list still handles
  `text/plain` blobs with zero configuration.
- `packages/kmdb/lib/src/config/kmdb_config.dart`: `EmbeddingModelConfig`
  (`{type, modelId}`) is parsed from `local/config.json`'s `embeddingModel`
  key and exposed as `KmdbConfig.embeddingModel`. Nothing in `kmdb_cli`
  currently resolves this into an actual `EmbeddingModel` instance —
  `reindex_command.dart` and `search_command.dart` both null-check it as a
  guard but never construct one.
- `packages/kmdb_cli/pubspec.yaml`: depends on `kmdb`, `kmdb_google_drive`,
  `googleapis_auth`, `http`, `args`, `uuid`. No `betto_inferencing`.
- `packages/kmdb_cli/lib/src/repl/repl_config.dart`: `ReplConfig` already
  implements the `~/.kmdbrc`-backed `cacheDir` (default `~/.kmdb_cache`),
  matching §22's "Model acquisition" design (cache location lives outside
  `local/config.json`, deliberately not synced/shared with the database).
  Currently constructed only in the REPL startup path — see Q2.
- `packages/kmdb_cli/lib/src/cli_runner.dart` (~line 356): the one-shot
  command path calls `DatabaseOpener.open()` directly, with `KmdbConfig`
  loaded just before it. This is the integration point for both Phase A
  (`vaultSearch:`) and Phase B (`embeddingModel:` + `cacheDir` from
  `ReplConfig`).

### Extractor inventory (Phase A default, Q1)

- `PlainTextExtractor` (`packages/kmdb/lib/src/vault/search/`) — zero
  dependencies, `text/plain`, always auto-prepended by
  `VaultSearchConfig.effectiveExtractors`. Ships by default with no
  configuration.
- `PdfTextExtractor` (`kmdb_extractor_pdf` package) — depends on
  `betto_pdfium`, which has its own native-assets build hook (bundles a
  PDFium dylib). Registering it by default in the CLI means an unconditional
  new direct dependency and more native weight in every CLI build/bundle,
  even for users who never touch PDFs.
- HTML/Markdown extractors (WI-9) — **do not exist yet.** WI-9's plan status
  is `Investigated` but unimplemented; no `kmdb_extractor_html` or
  `_markdown` package exists in the workspace. Out of scope for this plan;
  do not reference them as available.

### Native-assets / compiled-binary distribution (sub-question a, resolved)

Verified empirically on this machine (macOS arm64, Dart 3.12.2) as part of
this plan's grounding investigation:

- `dart compile exe` is **already broken today**, before this plan touches
  anything — it refuses outright with `'dart compile' does not support build
  hooks, use 'dart build' instead. Packages with build hooks: betto_onnxrt,
  betto_zstd.` `betto_onnxrt` is already a *transitive* dependency of
  `kmdb_cli` (`kmdb_cli → kmdb → betto_inferencing → betto_onnxrt`), so this
  is a pre-existing issue this plan should fix regardless of Phase B, not
  something Phase B introduces.
- `dart build cli` (the modern replacement) works correctly and was verified
  end-to-end against the real `kmdb_cli` package: it produces
  `build/cli/<platform>/bundle/bin/kmdb` plus a sibling `bundle/lib/`
  containing `libonnxruntime.<ver>.dylib` and `libzstd.dylib`. The compiled
  binary runs correctly from arbitrary working directories (verified from the
  bundle dir, `/tmp`, and `$HOME`).
- **Deployment constraint:** the unit of distribution is the whole `bundle/`
  directory, not a lone binary — copying only the `bin/kmdb` executable away
  from its sibling `lib/` breaks native library loading (`dlopen` failure).
  This must be documented (README fix, see below) and is a hard constraint on
  any future packaging/release automation for `kmdb_cli`.
- **Platform coverage:** only macOS arm64 was verified directly. The loader
  (`betto_onnxrt/lib/src/runtime.dart`) has separate code paths for Linux
  (`DynamicLibrary.open('libonnxruntime.so')`, relying on the dynamic linker
  finding the bundled `.so` — not an absolute path) and Windows
  (adjacent-to-exe absolute path). These are architecturally sound based on
  the loader's code but are **unverified in `dart build cli` output** on
  those platforms and should be smoke-tested in CI as a checklist item, not
  assumed to work identically to macOS.
- **Adding a direct `betto_inferencing` dependency to `kmdb_cli/pubspec.yaml`
  adds zero new native-asset weight** — the ORT native library is already
  staged into CLI builds today via the transitive path above. Phase B only
  makes the `OnnxEmbeddingModel` Dart API importable; it does not change what
  gets bundled.
- `packages/kmdb_cli/README.md` documents the dead `dart compile exe`
  command (line ~12). This plan fixes it regardless of phase, since it's
  broken on `main` today independent of this plan's other changes.

### Model construction and CLI UX (sub-question b, resolved)

- §22 ("semantic search") already specifies the model-acquisition design used
  here: model *identity* (`modelId`) lives in `local/config.json`'s
  `embeddingModel` field (per-database); the *cache directory* for downloaded
  model files lives in `~/.kmdbrc`'s `cacheDir` (per-machine, deliberately
  not per-database / not synced). `ReplConfig` already implements the
  `~/.kmdbrc` side; nothing currently reads `KmdbConfig.embeddingModel` and
  turns it into a model.
- The construction chain is: `config.embeddingModel.modelId` →
  `ModelCatalog.lookup(modelId)` → `OnnxEmbeddingModel.load(spec: ...,
  cacheDir: replConfig.cacheDir, onProgress: ...)` → pass the resulting
  `EmbeddingModel` to `KmdbDatabase.open(embeddingModel: ...)` in
  `database_opener.dart`. `cacheDir` is a required parameter with no built-in
  default — the CLI must supply `ReplConfig.cacheDir` explicitly (see Q2).
  `ModelDownloader.ensure()` performs a SHA-256-verified, crash-safe (atomic
  `.part` rename) download from HuggingFace on first use if the model isn't
  already cached.
- No in-repo reference implementation of `OnnxEmbeddingModel.load()` exists
  outside tests (`packages/kmdb/test/search/semantic/`,
  `packages/kmdb/test/vault/search/`). `betto_inferencing`'s own `example/`
  and §22 are the canonical construction pattern to follow;
  `kmdb_flutter`/`kmdb_ui` (separate repos, not vendored here) are not
  available to consult directly.
- `$$vec:` index staleness is model-identity-keyed already (§22): each vector
  index records the `modelId` that built it, and a mismatch on open marks it
  `stale` for lazy rebuild. The existing `reindex`/`vault reindex` commands
  are already the correct recovery path once a model actually changes — no
  new invalidation logic is needed, only making the model real.

### Scope recommendation (sub-question c, resolved — see Problem statement)

Two phases in one plan, not two plans. Rationale is in the Problem statement;
the short version is that Phase B's model-construction change is identical
code regardless of which caller (vault search or document-field search)
benefits, so building it twice (once per plan) would be pure duplication, and
shipping vault-only semantic search while knowingly leaving
`search_command.dart`'s fake `(hybrid)` label in place would be leaving a
known lie in the code for no reason.

## Implementation plan

### Phase A — lexical vault search

- [ ] In `database_opener.dart`, pass `vaultSearch: VaultSearchConfig()` to
      `KmdbDatabase.open()`. Resolve Q1 first — if the answer is "opt-in PDF
      extractor via a documented override," leave the default call as
      `VaultSearchConfig()` and document the override path in the CLI
      README/help text rather than adding a flag.
- [ ] Fix `packages/kmdb_cli/README.md`'s build instructions: replace
      `dart compile exe packages/kmdb_cli/bin/kmdb.dart -o kmdb` with the
      `dart build cli` bundle workflow, and document the "ship the whole
      bundle directory, not just the binary" constraint.
- [ ] Add/update CLI integration tests exercising `vault search`, `vault
      status`, `vault reindex` against a real (in-process) `KmdbDatabase`
      with a populated vault, confirming they no longer fail with "Vault
      search is not configured." Cover: empty vault, lexical hits, stub-blob
      warning path (`status.stub > 0`).
- [ ] Update `docs/spec/20_text_search.md` or `24_vault.md` (whichever
      documents the CLI surface, confirm with `kmdb-architect`) to note that
      `kmdb_cli` now configures vault search by default — consult
      `kmdb-architect` on which spec file is authoritative for this and
      whether a new subsection is warranted versus a short note.

### Phase B — semantic/hybrid search (vault + document-field)

- [ ] Resolve Q2 and Q3 before writing code — both affect the shape of
      `cli_runner.dart`'s changes.
- [ ] Add a direct `betto_inferencing` dependency to
      `packages/kmdb_cli/pubspec.yaml`.
- [ ] In `cli_runner.dart`, load `ReplConfig` (or just its `cacheDir`) ahead
      of `DatabaseOpener.open()` for both the one-shot and REPL paths (per
      Q2's resolution), and resolve `config.embeddingModel` into a real
      `EmbeddingModel` via `ModelCatalog.lookup()` +
      `OnnxEmbeddingModel.load()` when present. Handle download-failure and
      unknown-`modelId` errors with actionable CLI error messages (not a
      raw stack trace) — mirror the tone of existing errors like
      `search_command.dart`'s embedding-model-required message.
- [ ] Pass the resolved model to `DatabaseOpener.open()` →
      `KmdbDatabase.open(embeddingModel: ...)`.
- [ ] Remove the fake-hybrid path in `search_command.dart`: delete the
      `isHybrid` heuristic computation and its comment block, and let
      `KmdbCollection.search()`'s real mode resolution drive the `(hybrid)`
      output label instead. Confirm `_writeResults`' `modeFlag`/`isHybrid`
      parameters are still correct once real hybrid search is running (they
      may simplify).
- [ ] Confirm `vault search --mode semantic` and `--mode auto` now produce
      real vector scores end-to-end against a real (downloaded or
      test-fixture-cached) model — this needs a real or mocked
      `OnnxEmbeddingModel`; check with `kmdb-qa`/existing test infra
      (`vec_manager_test.dart`, `vault_searcher_test.dart`) for the
      established pattern for testing semantic paths without a live network
      download in CI.
- [ ] Update `reindex_command.dart`'s guard message now that
      `embeddingModel` configured ⇒ a real model is loaded at open time
      (the existing message already describes the correct end state; confirm
      it doesn't need wording changes).
- [ ] Add CLI integration tests: `search --mode semantic`, `vault search
      --mode semantic`, and hybrid auto-mode, all against a real
      `EmbeddingModel` (test double or the smallest catalog model, cached
      once for the whole test run — do not re-download per test).
      Explicitly test the Q3-resolved first-run download behavior (or its
      test-double equivalent).
- [ ] Add a release-checklist entry (`docs/spec/28_release_checklist.md`) for
      the Linux/Windows `dart build cli` native-asset bundling verification
      flagged in the Investigation section, since it cannot be exercised in
      this (macOS) development environment or in CI without cross-platform
      compiled-binary smoke tests.
- [ ] Update `docs/spec/22_semantic_search.md` (or confirm with
      `kmdb-architect` which file) to note that `kmdb_cli` now implements the
      model-acquisition flow the spec already describes, rather than leaving
      it as CLI-unimplemented.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Summary

{Dot points highlighting the work undertaken}
