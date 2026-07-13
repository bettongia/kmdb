# WI-12: Vault search in `kmdb_cli`

**Status**: Investigated

**PR link**: —

## Abstract

Vault functionality and semantic/hybrid search are fully built and tested at
the `kmdb` core level, but neither works from the production `kmdb_cli`
binary today. This plan wires both in, in two phases.

**Phase A** fixes the root cause: `DatabaseOpener.open()` never constructs a
`VaultStore`, so *every* vault-touching CLI command — `vault get`, `vault
search`, `vault status`, `vault reindex`, `insert --import`, `update
--vault`, `export`'s vault leg, `backup` — fails today, not just search. The
CLI's own test suite never caught this because it universally bypasses
`DatabaseOpener` with a test double. Phase A wires a `VaultStore`
unconditionally and configures vault search with plain-text, HTML, Markdown,
and PDF extraction enabled by default, fixes the CLI's dead `dart compile
exe` build instructions (broken independently of this plan), and adds the
production-path integration test that would have caught the original gap.

**Phase B** makes semantic and hybrid search genuinely real, for both vault
content and document fields — not just for vault search, and not just a
relabelling of the CLI's existing fake `(hybrid)` output tag. It adds a
`vecIndexes` configuration surface (mirroring the existing `ftsIndexes`
pattern) so users can register semantic search on document fields via
`search create --semantic`, constructs a real embedding model gated to avoid
loading it on every CLI command, and wires both into `KmdbDatabase.open()`.

Both phases were driven through two rounds of plan review that caught a
would-be no-op fix (Phase A's original draft passed `vaultSearch:` without
the `VaultStore` it silently depends on), a scope overclaim (Phase B
originally claimed to fix document-field semantic search "for free," which
was false without the `vecIndexes` surface), and an implementation trap in
that surface (passing `vecIndexes` unconditionally would brick every CLI
command against a database with a registered-but-modelless vector index —
gated construction avoids this). All ten open questions raised across
drafting and review are resolved and recorded inline under "Open questions."

**Deferred:** nothing scope-wise — PDF extraction, originally the one
candidate for deferral (it adds a third native library to every CLI build),
was folded into Phase A instead. The one thing intentionally left outside
this plan is *verification*, not functionality: `dart build cli`'s
native-asset bundling was only tested on macOS arm64 here; Linux/Windows
verification is logged as a `docs/spec/28_release_checklist.md` entry per
project convention, since it needs a machine/CI runner this environment
doesn't have — it is a one-time release gate, not a follow-up work item.

## Problem statement

> **Scope note (2026-07-10):** the plan review below found the root cause is
> broader than "vault search" — `DatabaseOpener.open()` never wires a
> `VaultStore` at all, so every CLI vault command is dead, not just search.
> Separately, the product owner chose to expand semantic search support to
> cover document-field search for real (a `vecIndexes` config surface),
> rather than only vault search. The problem statement below is corrected to
> reflect both; see Q5–Q8 for the full reasoning trail.

Vault functionality (WI-3, core vault, and the general vault store) is fully
implemented and tested at the `kmdb` core level, but almost none of it works
from `kmdb_cli` in production — for three independent reasons:

1. **`DatabaseOpener.open()` never constructs a `VaultStore` at all.**
   (`packages/kmdb_cli/lib/src/database_opener.dart`) never passes
   `vaultStore:` to `KmdbDatabase.open()`, so `db.vaultStore` (and therefore
   `ctx.vaultStore`) is **always `null`** for every CLI-opened database. Every
   vault-touching command — `vault get`, `vault search`, `vault status`,
   `vault reindex`, `insert --import`, `update --vault`, `export`'s vault leg,
   `backup` — fails at the same first guard ("Vault is not available for this
   database."). The CLI's own vault test suite never caught this because it
   universally injects a test-double `VaultStore` and calls `KmdbDatabase.open`
   directly, bypassing `DatabaseOpener` — exactly the in-memory-adapter blind
   spot CLAUDE.md warns about.
2. **Even with a `VaultStore` wired, lexical vault *search* additionally needs
   `vaultSearch: VaultSearchConfig()`** passed to `KmdbDatabase.open()` — also
   currently absent. `vault_command.dart`'s `search`/`status`/`reindex`
   subcommands genuinely call the real `KmdbCollection.searchVault()` API, but
   fail on the `vaultSearchManager == null` guard once the first gap is fixed.
3. **Semantic/hybrid search does not work from the CLI at all**, for vault
   search or document-field search. `kmdb_cli` has no dependency on
   `betto_inferencing` and never constructs an `EmbeddingModel`.
   `search_command.dart` already contains a comment acknowledging this for
   document fields, and fakes a `(hybrid)` output label without ever running
   real semantic scoring. `KmdbConfig.embeddingModel`
   (`packages/kmdb/lib/src/config/kmdb_config.dart`) is parsed from
   `local/config.json` and guarded against (`reindex_command.dart`,
   `search_command.dart`) but never resolved into a real model. Document-field
   *vector* search additionally needs a `vecIndexes:` config surface that does
   not exist anywhere in the CLI or `KmdbConfig` today — a second, independent
   half of gap 3, not automatically fixed by constructing a model.

This plan closes all three gaps in two phases:

- **Phase A** — wire vault into the CLI generally: construct a `VaultStore`
  unconditionally in `DatabaseOpener.open()`, pass `vaultSearch:
  VaultSearchConfig()` with `PlainTextExtractor` + `HtmlTextExtractor` +
  `MarkdownTextExtractor` + `PdfTextExtractor` registered by default (Q1).
  This fixes every vault command in production, with lexical vault search
  (now covering plain text, HTML, Markdown, and PDF blobs) as the motivating
  case.
- **Phase B** — construct a real `EmbeddingModel` in `kmdb_cli` (gated so it
  doesn't load on every command — Q6), add a `vecIndexes` config surface
  mirroring the existing `ftsIndexes` pattern (Q7/Q8), and wire both into
  `KmdbDatabase.open()`. This makes semantic/hybrid search genuinely real for
  *both* vault search and document-field search, and removes
  `search_command.dart`'s fake-hybrid label.

Phase A can ship alone if Phase B needs more review time — it is independently
valuable and fixes a strictly larger set of production bugs than "vault
search". Phase B depends on Phase A having landed (it extends the same
`DatabaseOpener.open()` call).

## Open questions

> Reviewer note (2026-07-10): Q1–Q4 are annotated inline below with decisions
> or pushback. Q5–Q7 are **new blocking questions** the review surfaced — see
> the "Plan review" section at the end for the full reasoning. The plan cannot
> reach `Investigated` until Q5 (the vault-store wiring gap) is resolved and the
> problem statement is corrected, and Q6/Q7 are decided.

> **Decisions recorded (2026-07-10, product owner):** Q1 → register HTML +
> Markdown extractors by default. Q5 → wire `VaultStore` unconditionally and
> re-scope the plan. Q6 → lazy/gated model construction. Q7 → **expanded**,
> not de-scoped: add a `vecIndexes` config surface so document-field
> semantic/hybrid search is actually fixed by this plan, not deferred. This
> is a real scope increase over the reviewed draft — see Q7 and Q8 below and
> the corresponding Implementation plan changes. Resolving Q7 this way
> surfaced a new interaction with Q6 (model loading can't stay purely
> command-gated once `vecIndexes` exist) and a new open question (Q8, the
> CLI UX for defining a vecIndex) — both recorded below.

- [x] **Q5 (BLOCKER) — Phase A must also wire a `VaultStore`, and the problem
      statement is factually wrong about the failure mode.**
      `DatabaseOpener.open()` never passes `vaultStore:` to
      `KmdbDatabase.open()`, so `db.vaultStore` is **always `null`** in the
      production CLI. Two consequences: (1) `KmdbDatabase.open` silently ignores
      `vaultSearch:` unless `vaultStore` is *also* non-null (see its doc:
      "When non-null **and `vaultStore` is also non-null**…"), so the plan's
      single Phase A step — passing `vaultSearch: VaultSearchConfig()` — does
      **nothing** on its own. (2) All three subcommands fail at the *first*
      guard `ctx.vaultStore == null` → "Vault is not available for this
      database.", **not** the `vaultSearchManager == null` guard the problem
      statement quotes. Phase A must construct
      `VaultStore(dbDir: dbPath, adapter: adapter)` and pass both `vaultStore:`
      and `vaultSearch:`. **Decision needed:** confirm wiring a `VaultStore`
      *unconditionally* for every CLI database (this is almost certainly right —
      it makes `insert --import`, `update --vault`, `export`, `backup`,
      `vault get`, etc. work from the production CLI *for the first time*, since
      they are all currently dead for the same reason — but it is a larger,
      more valuable change than "vault search" and needs its own tests and a
      corrected problem statement). Recommendation: yes, wire it unconditionally;
      re-scope the plan title/problem statement to "wire vault into the CLI"
      with vault search as the motivating case.
      - **DECIDED (2026-07-10):** wire `VaultStore` unconditionally in
        `DatabaseOpener.open()` using the confirmed real constructor —
        `VaultStore({required String dbDir, required StorageAdapter adapter,
        MediaTypeDetector detector, String Function()? uuidGenerator,
        EncryptionProvider? encryption})` (verified against
        `packages/kmdb/lib/src/vault/vault_store.dart` and a working call site
        in `packages/kmdb/test/vault/vault_gc_recovery_real_adapter_test.dart`
        — despite the constructor body using `this._dbDir`/`this._adapter`
        field-shorthand, the named parameters are callable as `dbDir`/
        `adapter` from other libraries; confirmed empirically via `dart
        analyze`, not just by reading the doc comment). Problem statement and
        title re-scoped below to reflect that this plan wires vault into the
        CLI generally, with search as the motivating case.
- [x] **Q6 (BLOCKER) — Eager vs. lazy model construction.** Phase B as written
      loads (and, on first use, downloads 127 MB / 470 MB) the embedding model
      inside `cli_runner.dart` *before* `DatabaseOpener.open()`, on **every**
      CLI invocation against a database that has `embeddingModel` configured —
      including `kmdb db get notes x`. A plain `get` would block on ORT session
      init and a first-run 127 MB download. This reframes Q3 entirely: it is not
      "download on first *search*", it is "download/load on first *anything*".
      **Decision needed:** gate model construction on the dispatched command
      actually needing it (inspect the command token in `cli_runner.dart` —
      only `search`, `vault search`, `reindex`, `vault reindex` need the model),
      or accept the eager cost. Recommendation: gate it — construct the model
      only when the command needs it, otherwise pass `embeddingModel: null`.
      This also makes Q2/Q3 moot for the common path.
      - **DECIDED (2026-07-10), refined by Q7's expansion below:** gate
        construction on the dispatched command needing it — **but** this can
        no longer be the *whole* rule, because `KmdbDatabase.open()` throws
        `ArgumentError` if `vecIndexes` is non-empty and `embeddingModel` is
        `null` (`kmdb_database.dart:369-371`). Once a `vecIndex` is registered
        in `local/config.json` (Q7/Q8), the model is structurally required at
        *every* open of that database, not just search commands — exactly
        like `ftsIndexes`/`indexes` already impose maintenance cost on every
        write today regardless of the current command. This is not a new
        inconsistency; it matches KMDB's existing config-time-index
        philosophy. **Final rule:** construct the model when
        `config.embeddingModel != null` AND (`config.vecIndexes.isNotEmpty`
        OR the dispatched command is one of `search`, `vault search`,
        `reindex`, `vault reindex`). A user who has only configured
        `embeddingModel` for vault search (no `vecIndexes`) still gets the
        lazy/gated behavior for all other commands.
- [x] **Q7 (BLOCKER) — Document-field semantic/hybrid search is NOT fixed "by
      the identical change"; de-scope it.** The problem statement and Phase B
      claim that constructing the model fixes semantic/hybrid search for *both*
      vault search and document-field search "in one pass." This is **incorrect**.
      Document-field vector search additionally requires **vector index
      definitions** registered at open (`vecIndexes:`), and there is **no
      vecIndex configuration surface anywhere** — `KmdbConfig` has no
      `vecIndexes` field, no `search`/`index` subcommand defines one, and
      `DatabaseOpener` never passes `vecIndexes:`. So after Phase B,
      `col.search(mode: semantic)` on a document field still finds no vector
      index and cannot produce vector scores. Vault search is different — it
      does **not** need a per-field vecIndex (the `VaultSearchManager` builds its
      own chunk-vector index once `embeddingModel` is non-null), so Phase B
      genuinely fixes *vault* semantic search. **Decision needed:** explicitly
      de-scope document-field semantic/hybrid search from this plan (adding a
      vecIndex config surface is a separate, larger WI). Phase B's honest scope
      is: (a) semantic/hybrid *vault* search, and (b) *removing* the misleading
      `(hybrid)` label from document-field `search` output — not "making
      document-field hybrid search real."
      - **DECIDED (2026-07-10) — expanded, not de-scoped.** Product owner
        chose to add the `vecIndexes` config surface in this plan rather than
        defer it, so document-field semantic/hybrid search is genuinely fixed,
        not just relabelled. This is a real scope increase over the reviewed
        draft — see the new "vecIndex configuration surface" Investigation
        subsection and Q8 (CLI UX for defining a vecIndex) below, and the
        expanded Phase B checklist. `VecIndexDefinition` is confirmed to be a
        small, `FtsIndexRecord`-shaped type (`{collection, field, lazy}` —
        `packages/kmdb/lib/src/search/vec_index_definition.dart`), so the
        `KmdbConfig` addition mirrors the existing `ftsIndexes` pattern
        mechanically rather than inventing new machinery.
- [x] **Q8 (new, from Q7's expansion) — CLI UX for defining a vecIndex.**
      `search create <collection> <field>` today only registers an FTS index
      (with `--stopwords`/`--k1`/`--b`). Proposed: add a `--semantic` boolean
      flag to `search create` that additionally registers a
      `VecIndexRecord(collection, field)` in `config.vecIndexes` (alongside
      the FTS registration, not instead of it — a bare `search create` keeps
      today's lexical-only behavior unchanged). `search list`/`search delete`
      need to show/remove the vecIndex registration alongside the FTS one for
      the same `(collection, field)` pair. This keeps one mental model ("`search
      create` turns on search for a field") rather than introducing a parallel
      `vecIndex create` command family. Needs confirmation before
      implementation — flag if a separate, explicit semantic-only registration
      command would be clearer for users who don't want BM25 on a given field
      at all (e.g. a long free-text field where only semantic search makes
      sense).
      - **DECIDED (2026-07-10):** `search create <collection> <field>`
        defaults to registering **both** an FTS index and a vecIndex for the
        field. `--fts` and `--semantic` are narrowing flags — passing either
        alone limits registration to just that type (`--fts` → FTS only,
        `--semantic` → vecIndex only); passing both explicitly is equivalent
        to the no-flag default. `search list` shows both registrations for a
        `(collection, field)` pair (label which type(s) are active); `search
        delete` removes both by default, or accepts the same `--fts`/
        `--semantic` narrowing flags to remove just one, leaving the other
        intact.
        **Graceful-degradation requirement:** since a `vecIndex` in
        `local/config.json` makes `embeddingModel` mandatory at the *next*
        `KmdbDatabase.open()` (`ArgumentError` per Q7's Investigation), and
        `search create` only writes config (no model is loaded at
        create-time), `search create` must not hard-fail when no
        `embeddingModel` is configured yet. Instead: write the vecIndex
        registration and print a warning — e.g. "Note: semantic index for
        'body' registered, but no embeddingModel is configured in
        local/config.json — search will remain lexical-only until one is
        added." If `embeddingModel` is genuinely never added, the *next*
        `DatabaseOpener.open()` would otherwise surface `KmdbDatabase.open()`'s
        raw `ArgumentError` — catch it in `DatabaseOpener.open()` (or
        `cli_runner.dart`) and rewrap it as a clear, actionable CLI error
        instead of an unhandled exception.

- [x] **Q9 (BLOCKER, new — 2026-07-10 second pass) — the null-model +
      registered-vecIndex open path is self-contradictory and, as written,
      bricks every CLI command.** `KmdbDatabase.open()` throws `ArgumentError`
      when `vecIndexes` is non-empty and `embeddingModel` is `null`
      (`kmdb_database.dart:369`, verified). The Phase B checklist says to pass
      `vecIndexes:` built from `config.vecIndexes` **unconditionally**, while
      Q8's graceful-degradation clause says to *catch and rewrap* the resulting
      `ArgumentError`. Trace the case a user will actually hit — they ran
      `search create <c> <f> --semantic` (or the default, which registers a
      vecIndex) but never added an `embeddingModel` to `local/config.json`:
      - Q6 gating: `config.embeddingModel == null` ⇒ model is **not**
        constructed ⇒ `embeddingModel: null` is passed.
      - `vecIndexes:` built from config ⇒ **non-empty**.
      - `KmdbDatabase.open(vecIndexes: [non-empty], embeddingModel: null)` ⇒
        `ArgumentError` on **every** command — `get`, `scan`, `insert`,
        everything — not just search.
      "Catch and rewrap the `ArgumentError`" therefore **bricks the whole
      database via the CLI** until the user either configures a model or hand-
      edits `config.json` to delete the vecIndex. That directly contradicts the
      warning text Q8 mandates at create time ("search will remain lexical-only
      until one is added"), which promises the database keeps working in
      lexical-only mode. Both cannot be true. **Decision needed — pick one and
      spec it:** (a) *graceful degradation (recommended, matches the promised
      warning):* `DatabaseOpener.open()` passes `vecIndexes:` built from config
      **only when a model is actually available**; otherwise it passes
      `vecIndexes: const []` so `open()` never throws, the registered vec
      indexes lie dormant, and lexical search + all other commands keep working.
      The "rewrap `ArgumentError`" step then becomes a defensive fallback that
      in practice never fires. (b) *hard-fail:* accept that a registered vecIndex
      with no model makes the DB CLI-unopenable and change the create-time
      warning to say so honestly. Recommendation: (a). Whichever is chosen, the
      Phase B checklist item "pass `vecIndexes:` (built from config.vecIndexes)"
      must be rewritten to gate the pass-through on model availability, because
      "unconditionally" is what produces the brick.
      - **DECIDED (2026-07-10):** option (a), graceful degradation — matches
        the promise already made at `search create` time. Phase B checklist
        rewritten accordingly.
- [x] **Q10 (BLOCKER, new — 2026-07-10 second pass) — the `(hybrid)` label
      cannot be "driven by the real resolution from `KmdbCollection.search()`";
      that signal does not exist.** `SearchResult`/`SearchMetadata`
      (`packages/kmdb/lib/src/search/search_result.dart`) expose only `query`,
      `searched`, `skipped`, `total`, and `hits` — **there is no resolved-mode
      field**. So the Phase B instruction "Let the real mode/hybrid resolution
      from `KmdbCollection.search()` drive the `(hybrid)` output label; delete
      the now-dead `isHybrid` heuristic" is not implementable as written: after
      the rewrite there is nothing on the result to read the resolved mode from.
      An implementer would be forced to reinvent a label heuristic on the fly —
      exactly the kind of hidden decision this review exists to prevent. The
      good news is the plan's own Q7 expansion makes a *deterministic* rule
      possible for the first time (the CLI now knows both index types from
      config): specify it explicitly instead of "let the API drive it". Concretely,
      for `--mode auto` compute the label from config presence for the searched
      collection:
      - both `ftsIndexesForCollection(c).isNotEmpty` **and**
        `vecIndexesForCollection(c).isNotEmpty` ⇒ `hybrid`;
      - FTS only ⇒ `lexical`; vec only ⇒ `semantic`;
      and for explicit `--mode lexical|semantic` show that mode. Note this is a
      *full* label resolution (three outcomes), not just a hybrid boolean — the
      current checklist only discusses the hybrid case. **Decision needed:**
      confirm the config-derived label rule above (recommended, since it is now
      deterministic) and rewrite the checklist item to state it, OR add a
      resolved-mode field to `SearchMetadata` (a core-search change the plan has
      otherwise avoided). Recommendation: the config-derived rule — no core
      change required.
      - **DECIDED (2026-07-10):** the config-derived, three-way label rule —
        no `SearchMetadata` change. Phase B checklist rewritten accordingly.

- [x] **Q1 — Default PDF extractor?** Should `kmdb_extractor_pdf`
      (`PdfTextExtractor`) be registered by default in Phase A, or left
      opt-in? It depends on `betto_pdfium`, which carries its own native
      build-hook (a PDFium dylib bundled alongside the ORT dylib once Phase B
      also lands). Recommendation: opt-in via a `--with-pdf` style config
      knob or a documented manual `VaultSearchConfig(extractors: [...])`
      override, not a CLI flag — see Investigation for reasoning. Default
      `VaultSearchConfig()` (plain-text only) ships in Phase A regardless of
      this answer.
      - *Reviewer (agree, with a correction):* opt-in is right for
        `PdfTextExtractor`, but the "documented manual
        `VaultSearchConfig(extractors: [...])` override" is **not actionable
        from the CLI** — a CLI user cannot construct a `VaultSearchConfig`;
        `DatabaseOpener.open()` builds it internally and exposes no knob. So
        PDF registration is **out of scope / deferred to a future WI** (it
        needs a config surface that does not exist).
      - *Re-opened (2026-07-10) — reviewer's verdict was based on stale
        extractor inventory.* At review time the plan (incorrectly) stated
        HTML/Markdown extractors don't exist; they do (WI-9 shipped,
        `kmdb_extractor_html` / `kmdb_extractor_markdown`, see the corrected
        Investigation section above), and unlike `kmdb_extractor_pdf` they add
        **no native-assets weight** — pure Dart, `kmdb` + one small pub
        package each. The PDF reasoning (opt-in, needs a config surface that
        doesn't exist) doesn't automatically apply to them. **New decision
        needed:** should Phase A register `HtmlTextExtractor` and
        `MarkdownTextExtractor` by default alongside `PlainTextExtractor`
        (three zero-native-weight extractors out of the box), or hold the
        line at plain-text-only for this plan and treat all three non-default
        extractors as one follow-up "extractor registration" concern? Leaning
        toward registering HTML/Markdown by default — they cost nothing at
        build time and directly widen what "vault search actually finds
        content in" means for typical vaults (web clippings, notes) — but this
        needs sign-off, not silent inclusion.
      - **DECIDED (2026-07-10):** register `HtmlTextExtractor` and
        `MarkdownTextExtractor` by default alongside `PlainTextExtractor`.
        `kmdb_extractor_pdf` stays opt-in/deferred (native-assets weight).
        Add both packages as direct `kmdb_cli` dependencies.
      - **SUPERSEDED (2026-07-10):** product owner chose completeness over
        deferral — `PdfTextExtractor` (`kmdb_extractor_pdf`, wrapping
        `betto_pdfium`) is now **also registered by default** in Phase A,
        alongside `HtmlTextExtractor`/`MarkdownTextExtractor`. This means
        Phase A now bundles a *third* native library (PDFium) alongside ORT
        and Zstd in every `dart build cli` output, not just two — the
        bundling *mechanism* was verified to work generically for native-
        asset build hooks (see the native-assets Investigation section), but
        specifically bundling three libraries together was not itself
        empirically tested; add a one-time smoke check in Phase A ("does
        `dart build cli`'s `bundle/lib/` contain all three dylibs and does
        the compiled binary still run") rather than assuming the two-library
        result generalises untested.
- [x] **Q2 — One-shot command cache-dir source.** `ReplConfig.cacheDir`
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
      - **DECIDED (2026-07-10), superseded by Q6:** don't call
        `ReplConfig.load()` from the one-shot path — it requires a throwaway
        `SessionState` and writes `~/.kmdbrc` defaults as a side effect on
        first run (reviewer's note). Add a small side-effect-free `cacheDir`
        reader to `ReplConfig` instead and use it in both paths, only when
        Q6's gating rule says a model is actually needed. Tracked as an
        explicit Phase B checklist item.
- [x] **Q3 — First-run model download UX.** `OnnxEmbeddingModel.load()`
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
      - **DECIDED (2026-07-10):** option (a) — download silently (with an
        `onProgress` line to stderr) whenever Q6's gating rule decides a model
        load is needed. No separate consent subcommand.
- [x] **Q4 — Scope of the fake-hybrid removal.** Confirm it's acceptable for
      Phase B to change `search_command.dart` output behavior for existing
      users who have `embeddingModel` configured today — the `(hybrid)` label
      currently appears whenever `embeddingModel` + FTS index are both
      configured, regardless of whether a vector index actually exists yet
      (see `_search`'s `isHybrid` computation). Once real semantic scoring is
      wired in, first-time hybrid search on an existing collection will incur
      a full local vector-index build (foreground, synchronous per §18)
      before results appear. This is expected/correct behavior but is a
      user-visible latency change worth flagging explicitly, not silently.
      - *Reviewer (premise partly wrong at review time — see Q7):* at review
        time there was no document-field vector index to build, because no
        vecIndex surface existed in the CLI. Note also that re-pointing
        `search_command._search` from `FtsManager.search()` to
        `KmdbCollection.search()` is a **rewrite of the result-production
        path**, not "delete the `isHybrid` heuristic" — the command does not
        call `KmdbCollection.search()` today at all. Spell that out as a
        discrete step, and confirm `--fields`/`--candidates`/`--rrf-k` map
        onto `KmdbCollection.search()`'s parameters (they do:
        `search(query, fields:, filter:, mode:, candidates:, limit:, offset:,
        rrfK:)`).
      - **Re-opened (2026-07-10) — Q7's expansion makes the original question
        live again.** Now that this plan adds a `vecIndexes` config surface
        (Q7/Q8), a document field *can* have a real vector index once a user
        runs `search create <collection> <field> --semantic`. The original
        Q4 concern is back, correctly scoped this time: the **first** search
        against a newly-`--semantic`-enabled field triggers a synchronous,
        foreground full-collection embedding pass (§18) before results
        appear — this is the same lazy-build behavior `ftsIndexes` already
        has, just potentially slower per-document (one ONNX inference call per
        document vs. tokenization). **Decision:** this is expected/correct
        behavior (matches the existing lazy-build convention for FTS and
        vault indexes) and does not need special-casing, but the CLI should
        print a one-line notice on first build ("Building semantic index for
        `<collection>.<field>` — this may take a while for large
        collections.") rather than appear to hang silently. Add this as an
        explicit Phase B step.

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
  PDFium dylib). **Decision (2026-07-10, superseding the earlier opt-in
  lean): register by default alongside the other three extractors.** Product
  owner chose completeness — every user gets PDF vault search out of the
  box — over minimising bundle size for users who don't have PDFs in their
  vault. Consequence: Phase A now bundles three native libraries
  (`libonnxruntime`, `libzstd`, PDFium) rather than two once Phase B also
  lands; see the native-assets Investigation note below for the follow-on
  verification this requires.
- **Correction (2026-07-10): HTML/Markdown extractors now exist.** WI-9
  shipped and is `Complete`
  (`docs/plans/completed/plan_0_06_wi9_html_markdown_extractors.md`) — this
  plan's original investigation was stale on this point. `kmdb_extractor_html`
  (`HtmlTextExtractor`, `text/html`, depends only on `kmdb` + the pure-Dart
  `html` package) and `kmdb_extractor_markdown` (`MarkdownTextExtractor`,
  `text/markdown`, depends only on `kmdb` + the pure-Dart `markdown` package)
  both exist in the workspace and — unlike `kmdb_extractor_pdf` — carry **no
  native-assets build hook**. This changes the Q1 calculus: only the PDF
  extractor has the native-weight/bundling concern; HTML and Markdown are
  cheap, pure-Dart additions with no `dart build cli` impact. Re-resolve Q1
  accordingly (see below) — the "plain-text only" default may be leaving easy
  value on the table for two of the three known extractors.

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

### `VaultStore` construction (Q5, confirmed)

`VaultStore`'s real constructor (`packages/kmdb/lib/src/vault/vault_store.dart`,
lines 74-80) is `VaultStore({required String dbDir, required StorageAdapter
adapter, MediaTypeDetector detector = const FreedesktopMediaTypeDetector(),
String Function()? uuidGenerator, EncryptionProvider? encryption})`. Despite
the constructor body using `this._dbDir`/`this._adapter` field-initializing
shorthand against private fields, the named parameters are callable from other
libraries as `dbDir:`/`adapter:` — confirmed both by a working call site
(`packages/kmdb/test/vault/vault_gc_recovery_real_adapter_test.dart:58-62`)
and empirically via `dart analyze` against that file (clean, no issues).
`DatabaseOpener.open()` already has both `dbPath` and `adapter` in scope at
the point it calls `KmdbDatabase.open()`, so construction is a one-line
addition: `VaultStore(dbDir: dbPath, adapter: adapter)`. `encryption` is not
needed at construction time — `KmdbDatabase.open()` wires the
`EncryptionProvider` into the `VaultStore` itself after the encryption
bootstrap runs (per `vault_store.dart`'s `encryption` field doc comment).

### vecIndex configuration surface (Q7 expansion)

`VecIndexDefinition` (`packages/kmdb/lib/src/search/vec_index_definition.dart`)
is a small `const` class: `{required String collection, required String field,
bool lazy = false}` — structurally identical in shape to `KmdbConfig`'s
existing `FtsIndexRecord` typedef. `KmdbDatabase.open()` accepts `vecIndexes:
List<VecIndexDefinition>` (default `const []`) and throws `ArgumentError` if
`vecIndexes` is non-empty while `embeddingModel` is `null`
(`kmdb_database.dart:369-371`) — this is the source of the Q6/Q7 interaction
recorded above.

The mirroring work needed in `KmdbConfig`
(`packages/kmdb/lib/src/config/kmdb_config.dart`) is mechanical, following the
exact pattern already used for `ftsIndexes`:

- A `VecIndexRecord = ({String collection, String field, bool lazy})` typedef.
- A `_vecIndexes` backing list, `vecIndexes` unmodifiable getter,
  `addVecIndex`/`removeVecIndex`/`vecIndexesForCollection` methods mirroring
  `addFtsIndex`/`removeFtsIndex`/`ftsIndexesForCollection` (same duplicate-
  entry `ArgumentError` semantics).
- JSON parsing/serialization in `_parseJson`/`toJson`, added to `knownKeys` for
  forward-compat round-tripping, same shape as the `ftsIndexes` block:
  ```json
  "vecIndexes": [
    { "collection": "docs", "field": "body", "lazy": false }
  ]
  ```

`DatabaseOpener.open()` builds `List<VecIndexDefinition>` from
`config.vecIndexes` the same way it already builds `List<FtsIndexDefinition>`
from `config.ftsIndexes`, and passes it to `KmdbDatabase.open(vecIndexes:
..., embeddingModel: ...)`.

**CLI command-token gating (Q6's final rule).** `cli_runner.dart`'s dispatch
(`_dispatchTokens`, ~line 503) already isolates the command name as
`tokens[0]` before building `flags`/`posArgs`. The one-shot path
(`KmdbCli.run`, ~line 405-408) has the equivalent first inline token available
before `DatabaseOpener.open()` is called (`remaining[1]` when present). Model
construction should check: `config.embeddingModel != null &&
(config.vecIndexes.isNotEmpty || firstToken case 'search' || 'vault' ||
'reindex')` — note `vault` must be included wholesale (not narrowed to `vault
search`/`vault reindex`) because the first-token check happens before
sub-command parsing; a coarser gate here is fine since only `vault search` and
`vault reindex` actually build/query vec indexes, `vault get`/`status` will
simply have a loaded-but-unused model in that case, which is a correctness
no-op (just a wasted load) rather than a bug.

## Implementation plan

### Phase A — wire vault into the CLI (all vault commands, lexical search)

- [ ] In `database_opener.dart`, construct `VaultStore(dbDir: dbPath, adapter:
      adapter)` unconditionally and pass `vaultStore:` to
      `KmdbDatabase.open()`.
- [ ] Same call: pass `vaultSearch: VaultSearchConfig(extractors:
      [HtmlTextExtractor(), MarkdownTextExtractor(), PdfTextExtractor()])`
      (per Q1, superseded decision — `PlainTextExtractor` is auto-prepended
      by `VaultSearchConfig` itself, so it does not need to be listed
      explicitly).
- [ ] Add `kmdb_extractor_html`, `kmdb_extractor_markdown`, and
      `kmdb_extractor_pdf` as direct dependencies of
      `packages/kmdb_cli/pubspec.yaml`.
- [ ] Verify `dart build cli` correctly bundles all three native libraries
      together (`libonnxruntime`, `libzstd`, PDFium) once `kmdb_extractor_pdf`
      (→ `betto_pdfium`) is added — the bundling *mechanism* was verified
      generically for native-asset build hooks with two libraries during this
      plan's grounding investigation, but three together were not empirically
      tested. Confirm `bundle/lib/` contains all three dylibs and the compiled
      binary still runs from an arbitrary working directory.
- [ ] Confirm (add a test if not already covered) that constructing a
      `VaultStore` and running `VaultRecovery.recover()` /
      `VaultGc` construction is cheap when no `vault/` directory exists yet on
      disk — this now runs on **every** CLI open, not just vault commands
      (reviewer's risk note).
- [ ] Fix `packages/kmdb_cli/README.md`'s build instructions: replace
      `dart compile exe packages/kmdb_cli/bin/kmdb.dart -o kmdb` with the
      `dart build cli` bundle workflow, and document the "ship the whole
      bundle directory, not just the binary" constraint.
- [ ] Add a `DatabaseOpener`-level integration test using the **production**
      open path (not a `_TestVaultStore` double) that exercises at least one
      vault write command (e.g. `insert --import` or `update --vault`) and
      confirms it no longer fails with "Vault is not available for this
      database." This is the test the reviewer flagged as missing — it is
      what would have caught the original gap.
- [ ] Add/update CLI integration tests exercising `vault search`, `vault
      status`, `vault reindex` against a real (in-process) `KmdbDatabase`
      with a populated vault, confirming they no longer fail with "Vault
      search is not configured." Cover: empty vault, lexical hits over
      plain-text/HTML/Markdown/PDF blobs (one fixture per extractor), stub-blob
      warning path (`status.stub > 0`).
- [ ] Update `docs/spec/24_vault.md` (confirm with `kmdb-architect` if a
      different file is more authoritative for the CLI wiring surface) to
      note that `kmdb_cli` now constructs a `VaultStore` and configures vault
      search by default for every database it opens.

### Phase B — semantic/hybrid search (vault + document-field, real)

- [ ] Resolve Q8 (vecIndex CLI UX — `--semantic` flag on `search create` vs.
      a separate command) before writing code.
- [ ] Add a direct `betto_inferencing` dependency to
      `packages/kmdb_cli/pubspec.yaml`.
- [ ] Add `KmdbConfig.vecIndexes` (the `VecIndexRecord` typedef,
      `addVecIndex`/`removeVecIndex`/`vecIndexesForCollection`, JSON
      parse/serialize, `knownKeys` update) mirroring the existing
      `ftsIndexes` implementation exactly (see Investigation).
- [ ] Extend `search_command.dart`'s `_create`/`_list`/`_delete` per Q8's
      resolution to manage `vecIndexes` alongside `ftsIndexes`. Three seams the
      reviewer flagged, fold in explicitly rather than treating this as a
      drop-in extension:
      - `--fts`/`--semantic` flags parse generically in
        `cli_runner._dispatchTokens` (not via `configureArgParser`), arriving
        as bare `true` or a `String`. Mirror the existing
        `flags['stopwords'] == true || flags['stopwords'] == 'true'` idiom;
        also register both in `configureArgParser` for help-text parity. The
        generic parser treats `--flag <positional>` as consuming the
        positional as the flag's value, so document that these flags must
        follow the positional args (same pre-existing footgun as
        `--stopwords`).
      - `_delete`'s current guard hard-errors ("no FTS index … found") before
        removing anything, which blocks deleting a vec-only field (one
        registered via `--semantic` alone). This needs a **rework of the
        guard**, not just an extension alongside it — treat it as a discrete
        rewrite step, same class as the `_search` rewrite below.
      - `_list`'s vec-side status must read config-registration presence
        (`ctx.config.vecIndexesForCollection(collection)`), not a
        `vecManager.stateFor` build-state lookup — the model (and therefore
        `vecManager`) may not be loaded during a plain `search list` per Q6's
        gating rule.
- [ ] In `cli_runner.dart`, implement the command-token-gated model
      construction rule from Q6/Investigation: resolve
      `config.embeddingModel` into a real `EmbeddingModel` via
      `ModelCatalog.lookup()` + `OnnxEmbeddingModel.load(cacheDir: ...,
      onProgress: ...)` when `config.embeddingModel != null AND
      (config.vecIndexes.isNotEmpty OR firstToken is search/vault/reindex)`.
      Handle both `ModelCatalog.lookup()` exception branches — `ArgumentError`
      (unknown `modelId`) and `UnsupportedError` (registered but unvalidated
      model) — with actionable CLI error messages, not raw stack traces.
- [ ] Resolve the `cacheDir` source without `ReplConfig.load()`'s
      `SessionState`-argument/`~/.kmdbrc`-write side effects (reviewer's
      note): add a lightweight `ReplConfig` method/static that only reads
      `cacheDir` from `~/.kmdbrc` if present, else returns the
      `~/.kmdb_cache` default, with no file-write side effect. Use it in both
      the one-shot and REPL paths for a single source of truth.
- [ ] Pass the resolved model and `vecIndexes:` to `DatabaseOpener.open()` →
      `KmdbDatabase.open(embeddingModel: ..., vecIndexes: ...)` — **gated per
      Q9's decision:** build `vecIndexes:` from `config.vecIndexes` only when
      a real model was actually constructed (per Q6's gating rule); otherwise
      pass `vecIndexes: const []`. This is what keeps the Q8 create-time
      warning ("search will remain lexical-only until [a model is] added")
      true — `KmdbDatabase.open()` throws `ArgumentError` if `vecIndexes` is
      non-empty and `embeddingModel` is `null`
      (`kmdb_database.dart:369`), so passing the config's vecIndexes
      unconditionally would brick every command (not just search) against a
      database with a registered-but-modelless vecIndex. The registered
      vecIndex lies dormant (config still records it) until a model is added.
- [ ] Rewrite `search_command.dart`'s `_search` to call
      `ctx.rawCollection(collection).search(query, fields:, filter:, mode:,
      candidates:, limit:, offset:, rrfK:)` instead of `FtsManager.search()`
      directly — this is a rewrite of the result-production path, not a
      deletion of the `isHybrid` heuristic (the command doesn't call
      `KmdbCollection.search()` today at all). **Per Q10's decision:**
      `SearchResult`/`SearchMetadata` carry no resolved-mode field, so the
      `(hybrid)`/`(lexical)`/`(semantic)` output label cannot be read off the
      result — compute it deterministically from config instead, for the
      searched collection: both `ftsIndexesForCollection(c)` and
      `vecIndexesForCollection(c)` non-empty ⇒ label `hybrid`; FTS only ⇒
      `lexical`; vec only ⇒ `semantic`. For an explicit `--mode
      lexical|semantic`, show that mode directly rather than computing it.
      Delete the now-dead `isHybrid` heuristic computation and replace it with
      this three-way, config-derived label rule. Map the `--mode` string flag
      (`auto`/`lexical`/`semantic`) onto the `SearchMode` enum before the
      `.search(mode: ...)` call (e.g. `SearchMode.values.byName(modeFlag)`;
      names match auto/lexical/semantic) — trivial, but name it so a `String`
      isn't passed to the enum parameter.
- [ ] Print a one-line notice on first semantic-index build for a
      `--semantic`-enabled field (per Q4's re-opened resolution above) so a
      slow foreground build doesn't look like a hang.
- [ ] Confirm `vault search --mode semantic`/`--mode auto` **and**
      `search <collection> <query> --mode semantic` (document field, newly
      real) both produce genuine vector scores end-to-end against a real (or
      test-fixture-cached) model — check with `kmdb-qa`/existing test infra
      (`vec_manager_test.dart`, `vault_searcher_test.dart`) for the
      established pattern for testing semantic paths without a live network
      download in CI.
- [ ] Update `reindex_command.dart`'s guard message now that `embeddingModel`
      configured ⇒ a real model is loaded (gated per Q6) at open time
      (confirm wording still matches the new end state).
- [ ] Add CLI integration tests: `search --mode semantic` on a
      `--semantic`-enabled field, `vault search --mode semantic`, hybrid
      auto-mode for both, and the command-token gating rule itself (a plain
      `get` against a database with `embeddingModel` configured but no
      `vecIndexes` must NOT trigger a model load — add a test that asserts
      this, e.g. via a load-tracking test double). Explicitly test first-run
      download behavior (or its test-double equivalent) and the
      `ArgumentError`/`UnsupportedError` `ModelCatalog.lookup()` branches.
- [ ] Add a release-checklist entry (`docs/spec/28_release_checklist.md`) for
      the Linux/Windows `dart build cli` native-asset bundling verification
      flagged in the Investigation section, since it cannot be exercised in
      this (macOS) development environment or in CI without cross-platform
      compiled-binary smoke tests.
- [ ] Update `docs/spec/22_semantic_search.md` (or confirm with
      `kmdb-architect` which file) to note that `kmdb_cli` now implements the
      model-acquisition flow and a `vecIndexes` config surface, rather than
      leaving both as CLI-unimplemented.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Plan review (kmdb-plan-reviewer, 2026-07-10)

**Verdict: not ready for `Investigated`. Status set to `Questions`.** The
investigation is unusually thorough on the native-assets / model-acquisition
angle, and the two-phase split is sound in principle. But the plan has one
blocking factual error, one scope overclaim, and one unaddressed design
decision that would each force a Sonnet implementer to guess. Details below.

### Problem statement assessment

The lexical half of the problem is real and worth solving — vault search from
the CLI is genuinely dead. But the *stated root cause is wrong*, and the wrong
diagnosis produces an insufficient fix:

- **The fix is not "pass `vaultSearch:`" — it's "pass `vaultStore:` *and*
  `vaultSearch:`."** `DatabaseOpener.open()`
  (`packages/kmdb_cli/lib/src/database_opener.dart`) passes no `vaultStore:`,
  so `db.vaultStore` is always `null`. `KmdbDatabase.open()` documents that
  `vaultSearch` is honoured only "when non-null **and `vaultStore` is also
  non-null**" — so the plan's Phase A step is a no-op as written. Verified in
  `kmdb_database.dart` (vaultSearch/vaultStore params, ~lines 308–322) and by
  grepping the CLI: the only `VaultStore(...)` constructions in `kmdb_cli` are
  in `test/`; **no production CLI code ever builds one.**
- **The quoted failure message is the wrong one.** All three subcommands check
  `ctx.vaultStore == null` → "Vault is not available for this database." *before*
  the `vaultSearchManager == null` check the problem statement quotes
  (`vault_search_command.dart:79` vs `:130`; same pattern in
  `vault_status_command.dart:51/57` and `vault_reindex_command.dart:53/59`).
- **The real gap is bigger and more valuable than the plan frames it.** Because
  no `VaultStore` is wired, *every* vault command in the production CLI is dead
  today — `insert --import`, `update --vault`, `export` (vault leg), `backup`,
  `vault get`, not just search. This is exactly the class of bug CLAUDE.md warns
  about: the CLI vault tests all inject a `_TestVaultStore` and call
  `KmdbDatabase.open` directly, bypassing `DatabaseOpener`, so the production
  wiring gap is invisible to the suite. Recommend re-scoping to "wire vault into
  the CLI" (see Q5) and adding a `DatabaseOpener`-level integration test that
  exercises the real open path.

### Proposed solution assessment

- **Phase A** is correct in spirit and low-risk once Q5 is fixed. The two
  extra items (README `dart build cli` fix, spec note) are well-judged and the
  native-assets investigation is genuinely valuable — keep it.
- **Phase B overclaims its scope (Q7).** "Fixes semantic/hybrid search for
  *both* vault search and document-field search … by the identical change" is
  false. Vault semantic search needs only the model (the `VaultSearchManager`
  builds its own chunk-vector index). Document-field semantic/hybrid search
  *also* needs `vecIndexes:` registered at open, and there is **no vecIndex
  configuration surface anywhere** in the CLI or `KmdbConfig` (verified: no
  `vecIndex*` references in `packages/kmdb_cli/lib/` or
  `packages/kmdb/lib/src/config/`). So doc-field semantic stays broken after
  Phase B. The plan must de-scope it to "remove the fake `(hybrid)` label" and
  leave real doc-field vector search to a future WI that adds vecIndex config.
- **Eager model load on every command (Q6).** Loading the model in
  `cli_runner.dart` before open couples *all* commands to model availability
  and a first-run multi-hundred-MB download. Gate it on the command needing the
  model, or accept the cost explicitly — but decide it, don't leave it implicit.

### Architecture fit

- Model construction chain is correct and verified against `betto_inferencing`
  HEAD: `ModelCatalog.lookup(id)` → `OnnxEmbeddingModel.load(spec:, cacheDir:,
  onProgress:)`. Note `kmdb.dart` re-exports only `EmbeddingModel` and
  `EmbeddingKind` from `betto_inferencing`, **not** `OnnxEmbeddingModel` /
  `ModelCatalog` / `DownloadProgress` — so the direct `betto_inferencing`
  dependency in Phase B is genuinely required (the plan is right on this).
- **Missing error case:** `ModelCatalog.lookup()` throws **two** exception
  types — `ArgumentError` for an unknown `modelId` *and* `UnsupportedError` for
  a registered-but-unvalidated model. Phase B only mentions "unknown-`modelId`".
  Handle both. (Both current catalog models — `bge-small-en-v1.5`,
  `multilingual-e5-small` — are validated today, but the guard is still needed.)
- Model-identity-keyed `$$vec:` staleness and the `reindex` recovery path are
  correctly identified as already-sufficient — no new invalidation logic needed.

### Risk & edge cases

- **Q2 has an unstated side effect.** `ReplConfig.load()` (a) requires a
  `SessionState` argument and (b) **writes a defaults file to `~/.kmdbrc`** when
  it is absent (`_writeDefaults()`). Calling it in the one-shot path gives every
  first CLI invocation a new file-creation side effect and forces a throwaway
  `SessionState`. Either add a lightweight cacheDir-only reader to `ReplConfig`,
  or accept/di­sclose the `~/.kmdbrc` creation. The `cacheDir` getter already
  falls back to `~/.kmdb_cache` without `load()`, so honouring a *custom*
  `cacheDir` is the only reason to call `load()` at all. Decide this alongside
  Q6 (if the model loads lazily, most invocations never need `cacheDir`).
- Unconditional `VaultStore` wiring makes `KmdbDatabase.open` run
  `VaultRecovery.recover()` + construct `VaultGc` on every CLI open. Confirm
  this is a cheap no-op when no vault dir exists yet (it should be, but the plan
  should note it — it is new work on the hot open path for *every* CLI command).

### Implementation readiness

Not ready. A Sonnet implementer following the current Phase A checklist would
ship a no-op (vaultStore still null), be misled by the wrong failure message,
and — following Phase B — claim to fix doc-field semantic search it cannot
actually fix. The checklist also hides a rewrite ("delete the `isHybrid`
heuristic" is really "re-point `_search` from `FtsManager` to
`KmdbCollection.search()`"). These are design-level gaps, not wording nits.

### Recommendations (to reach `Investigated`)

1. **Correct the problem statement** and Phase A: construct
   `VaultStore(dbDir: dbPath, adapter: adapter)` in `DatabaseOpener.open()` and
   pass both `vaultStore:` and `vaultSearch: VaultSearchConfig()`; quote the
   real first-guard message. Add a `DatabaseOpener`-level integration test that
   opens via the production path (not `_TestVaultStore`) and confirms all vault
   commands (search + at least one write/import) work. (Q5)
2. **Decide unconditional vault wiring** and re-scope the plan title/statement
   to reflect that this fixes *all* CLI vault commands. (Q5)
3. **Decide eager vs. lazy model construction** (Q6) and resolve Q2's side
   effect as a consequence.
4. **De-scope document-field semantic/hybrid** to "remove the fake `(hybrid)`
   label"; make the `FtsManager` → `KmdbCollection.search()` switch an explicit
   step; note doc-field vector search needs a future vecIndex-config WI. (Q7)
5. **Add the `UnsupportedError` (unvalidated model) branch** to Phase B error
   handling.
6. Resolve Q1 as "plain-text only; extractor config out of scope" (no
   actionable CLI override exists).

Once Q5–Q7 are answered and the checklists reflect them, this is a
straightforward plan and can move to `Investigated`.

## Plan review (kmdb-plan-reviewer, 2026-07-10 — second pass)

**Verdict: still not ready for `Investigated`. Status stays `Questions`.** The
rewrite resolves the first-pass blockers well: Q5 (unconditional `VaultStore`
wiring) is correct and the constructor is verified; Q6's config-time-index
philosophy is the right framing; Q1/Q2/Q3 are cleanly decided. The Q7 *expansion*
(the `vecIndexes` config surface) is coherent and I verified it mirrors the real
`ftsIndexes` machinery faithfully. But expanding Q7 introduced **two new
blockers** at the seams the expansion created, plus a few non-blocking gaps. An
implementer could not execute Phase B today without guessing on the two
blockers.

### What I verified as correct (keep as-is)

- **Q7 `vecIndexes` surface mirrors `ftsIndexes` accurately.** `VecIndexRecord =
  ({String collection, String field, bool lazy})` matches `VecIndexDefinition`'s
  real shape (`collection`, `field`, `lazy = false`), and the
  add/remove/`forCollection` + JSON parse/serialize + `knownKeys` pattern maps
  one-to-one onto the existing `FtsIndexRecord` implementation in
  `kmdb_config.dart` (lines 32–38, 444–493, 502–532, 366). Note the one shape
  difference the implementer must respect: unlike `FtsIndexRecord` (which carries
  `stopWords`/`k1`/`b`), `VecIndexRecord` has only the `lazy` extra field —
  don't blindly copy the BM25 params into the vec block.
- **`VaultStore(dbDir:, adapter:)` construction** — confirmed callable.
- **`ctx.rawCollection(collection)`** exists on `CommandContext` and returns
  `KmdbCollection<Map<String,dynamic>>`; its `.search()` returns
  `SearchResult<Map<String,dynamic>>`, the exact type `_writeResults` already
  consumes — so the return-type half of the `_search` rewrite is clean.
- **Q6 token-before-open gating is accurate.** In the one-shot path `remaining`
  (and thus the command token `remaining[1]`) is fully populated by the
  arg-parse loop *before* `DatabaseOpener.open()` is called at
  `cli_runner.dart:356`, so gating model construction on the token is feasible
  without reordering open.
- **Q6/Q7 interaction (model loads whenever `vecIndexes` non-empty)** holds for
  the case where a model *is* configured. It does **not** hold when no model is
  configured — that is Q9.

### New blockers (see Q9, Q10 above)

- **Q9 — `vecIndexes` pass-through + Q8 graceful-degradation contradict each
  other and brick the DB.** Passing `vecIndexes:` from config *unconditionally*
  while `embeddingModel` is `null` makes `KmdbDatabase.open()` throw
  `ArgumentError` on *every* command, not just search. Q8's "catch and rewrap"
  turns that into a CLI error for all commands — contradicting the create-time
  warning that promises lexical-only operation continues. Must gate the
  `vecIndexes:` pass-through on model availability (recommended) or honestly
  hard-fail. This is the Q6/Q7/Q8 interaction the reviewer was asked to stress —
  it does not survive the trace.
- **Q10 — the `(hybrid)` label has no signal to read.** `SearchMetadata`
  exposes no resolved-mode field, so "let the real resolution drive the label"
  is unimplementable. Specify the config-derived label rule (now deterministic
  thanks to the Q7 vecIndexes surface).

### Non-blocking gaps to fold into the checklist before implementation

1. **`--mode` string → `SearchMode` enum mapping** is unstated. Trivial
   (`SearchMode.values.byName(modeFlag)`; names match auto/lexical/semantic),
   but name it so the implementer doesn't pass a `String` to an enum parameter.
2. **`--fts`/`--semantic` flag plumbing.** Flags are parsed generically in
   `cli_runner._dispatchTokens` (not via `configureArgParser`), so the new flags
   will parse without parser changes — but they arrive as `true` (bare) or a
   `String` (`--fts=true`). Mirror the existing `flags['stopwords'] == true ||
   flags['stopwords'] == 'true'` idiom, and add them to `configureArgParser` for
   help-text parity. Also: the generic parser treats `--flag <positional>` as
   `flag=<positional>`, so document that these flags must follow the positional
   args (same pre-existing footgun as `--stopwords`).
3. **`search delete`'s existing FTS-only guard is a landmine.** `_delete`
   currently hard-errors ("no FTS index … found") before removing anything, so a
   field with only a vec index (registered via `--semantic`) can't be deleted.
   The Q8 "remove both by default / narrow with flags" behavior requires
   reworking that guard, not just extending it — call this out as an explicit
   rewrite step (same class as the `_search` rewrite).
4. **`search list` vec status source.** `_list` shows FTS build-state via
   `ftsManager.stateFor`. Q8's "label which type(s) are active" for the vec side
   should read config-registration presence (`vecIndexesForCollection`), not a
   `vecManager` build-state lookup — the model (and thus `vecManager`) may not be
   loaded during a `list`. State this so the implementer doesn't reach for a
   `vecManager.stateFor` that may be absent.

### Recommendation

Answer Q9 and Q10 (both have a clear recommended resolution that needs no
core-search change), fold the four non-blocking gaps into the Phase B checklist,
and rewrite the two affected checklist items ("pass `vecIndexes:` unconditionally"
→ gate on model availability; "let the real resolution drive the label" →
config-derived label rule). With those done, the plan clears the bar. Everything
else in the rewrite is implementation-ready.

## Plan review (kmdb-plan-reviewer, 2026-07-10 — third pass, confirmation)

**Verdict: ready. Status set to `Investigated`.**

Confirmed the applied resolutions against the second-pass specification:

- **Q9 (blocker) resolved correctly.** The Phase B "pass the resolved model and
  `vecIndexes:`" checklist item now gates the `vecIndexes:` pass-through on a
  real model having been constructed, passing `vecIndexes: const []` otherwise —
  exactly option (a). The `KmdbDatabase.open()` `ArgumentError`-bricking
  rationale is retained, so the "lexical-only until a model is added" promise
  from Q8 holds.
- **Q10 (blocker) resolved correctly.** The `_search` rewrite item now specifies
  the deterministic three-way, config-derived label (both index types non-empty
  ⇒ hybrid; FTS-only ⇒ lexical; vec-only ⇒ semantic; explicit `--mode` shows
  that mode) and deletes the `isHybrid` heuristic. No `SearchMetadata` change —
  as recommended.
- **Four non-blocking gaps folded in accurately.** `--fts`/`--semantic` flag
  plumbing (with configureArgParser parity and the positional-flag footgun),
  the `_delete` guard rework, and the `_list` vec-status-from-config seam are all
  present and correctly scoped under the `_create`/`_list`/`_delete` item. The
  `--mode` → `SearchMode` enum mapping was relocated from that item to the
  `_search` rewrite item, where it belongs (it is a search-path concern, not a
  create/list/delete one), matching the stated intent.

No new gaps introduced by the edits. The plan clears the implementation-readiness
bar: the problem statement is factually corrected, every open question is DECIDED,
and the Phase A / Phase B checklists are discrete and unambiguous. Ready for
kmdb-plan-implement. Only genuinely novel decision left to the implementer is the
mechanical `VecIndexRecord`/`ftsIndexes`-mirroring code, which the Investigation
section pins down field-for-field.

## Summary

{Dot points highlighting the work undertaken}
