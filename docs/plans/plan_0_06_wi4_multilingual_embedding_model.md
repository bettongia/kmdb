# WI-4: Multilingual embedding model

**Status**: Implementing (Phase 0 spike complete — hit the Q6 hard gate;
Branch B. The follow-on tokenizer-port design plan,
[WI-11](../roadmap/0_06.md#wi-11-xlm-r-sentencepiece-tokenizer-lands-in-betto_inferencing)
— [plan_0_06_wi11_xlmr_tokenizer.md](completed/plan_0_06_wi11_xlmr_tokenizer.md) — is now
**complete**: `XlmRobertaTokenizer`/`CharsmapTrie` merged into
`betto_inferencing` ([PR #1](https://github.com/bettongia/inferencing/pull/1)),
published as `0.1.0-dev.2`, and this repo's `pubspec.yaml`
`dependency_overrides` bumped to `^0.1.0-dev.2` (2026-07-09). **WI-11 also
revised the package boundary this plan originally assumed:** the XLM-R
tokenizer lands as new files directly inside `betto_inferencing` (alongside
the existing `BertTokenizer`), not as a separate published package —
simplifying this plan's own Phase 2/3 wiring below, which should be re-read
with that in mind. The Q6 hard gate is now cleared — Phase 2 can resume.)

**Phase 1 complete (2026-07-09, branch `wi4-parity-corpus` in the
`inferencing` repo, [PR #2](https://github.com/bettongia/inferencing/pull/2)).**
All five checklist items below are done: the corpus-extraction tool, edge
cases, the user's Python hand-off (token ids), the merged final fixture, and
the byte-exact parity test wired into the existing `test-macos` CI job.
**Found and fixed a real tokenizer bug along the way** — see the last
checklist item's note: `XlmRobertaTokenizer` (from WI-11) mishandled
empty-string input, producing a spurious extra token real `AutoTokenizer`
never emits; fixed in `lib/src/xlmr_tokenizer.dart` and its stale unit test
updated. `dart test` (114/114), `dart analyze`, `dart format`, `make
pre_commit`, and the real macOS integration test (22/22, including the new
61-entry parity gate) all pass; coverage 94.3%.

**Phase 2 complete (2026-07-09, branch `wi4-phase2-model-registration` in the
`inferencing` repo, [PR #3](https://github.com/bettongia/inferencing/pull/3)).**
All checklist items done: `EmbeddingKind`/`ModelTokenizer` added,
`OnnxEmbeddingModel` wired to select tokenizer family and apply prefixes,
`multilingual-e5-small` downloaded for real (this session's sandbox could
reach `huggingface.co` directly — no user hand-off needed) and registered
with real SHA-256 checksums via a new `tool/register_model.dart` —
**independently re-verified in the orchestrating session**, too: both the
`model.onnx` (~470MB) and `tokenizer.json` were re-downloaded fresh and
re-hashed directly, matching the registered values exactly. `bge-m3-v1.0`
replaced with the permanent `placeholder-model` test fixture, and
`multilingual-e5-small` flipped to `validated: true` only after the real
macOS integration test (including a new cross-lingual cosine-similarity
sanity check) passed against live ORT inference. `dart test` (143/143),
`dart analyze`, `dart format`, `make pre_commit` all clean; package coverage
95.2%. `kmdb-qa` sign-off: clean, no blocking findings (one pre-existing,
out-of-scope spec-wording drift noted for a future architect pass). Committed
and PR'd by the orchestrating session (the implementing session had no
agent-launch tool available to invoke `kmdb-qa`/`kmdb-pre-commit` itself).
**Merged and published** (2026-07-09): squash-merged, published as
`betto_inferencing 0.1.0-dev.3`, and this repo's `pubspec.yaml`
`dependency_overrides` bumped to match (`dart pub get` resolves cleanly at
`0.1.0-dev.3`). Phase 3's precondition is now satisfied.

**PR links**: [inferencing#2](https://github.com/bettongia/inferencing/pull/2)
(Phase 1), [inferencing#3](https://github.com/bettongia/inferencing/pull/3)
(Phase 2)

## Problem statement

`docs/roadmap/0_06.md` WI-4 asks for KMDB's semantic search to move from
`bge-small-en-v1.5` (English-only) to a multilingual embedding model, so that
semantic search works across languages in one shared vector space — particularly
important now that WI-6 has made lexical/BM25 search language-aware
(script-aware tokenization, 24-language stemming) and WI-5 gives the project a
language detector. Semantic search is the one search mode left that is
English-only by construction, not by omission.

The roadmap names `multilingual-e5-small` as the recommended starting model (384
dims — same as the current BGE model, so no SQ8/index-format change) and
`bge-m3` as a later upgrade path (1024 dims, needs a full re-index; already
registered in `ModelCatalog` as `bge-m3-v1.0` but unvalidated). The roadmap also
calls for a pure-Dart XLM-RoBERTa-family SentencePiece/Unigram tokenizer in
`betto_inferencing`, ported from `transformers.js`, gated by byte-exact parity
tests against HuggingFace's `AutoTokenizer`.

**This plan targets `multilingual-e5-small` only.** `bge-m3` stays deferred
exactly as the roadmap frames it (an upgrade path, not this WI's deliverable).
Its existing `ModelCatalog` entry (`bge-m3-v1.0`) turned out to be a broken stub
— placeholder, unverifiable checksums, not real infrastructure — so this plan
removes it rather than leaving it in place; see Q5.

## Open questions

- [x] **Q1 — Build the SentencePiece/Unigram tokenizer from scratch (as the
      roadmap assumes), or adopt an existing pub.dev package?**

      The roadmap text was written before checking pub.dev, but its own
      proposal source (`docs/proposals/vault_search.md:722`) explicitly says
      "Check pub.dev for an existing implementation before building." A
      search during this planning pass found
      [`dart_sentencepiece_tokenizer`](https://pub.dev/packages/dart_sentencepiece_tokenizer)
      (MIT, pure Dart, zero dependencies, ~13k downloads, actively published):
      it implements both BPE and **Unigram** SentencePiece models, and can
      load tokenizer definitions directly from a HuggingFace `tokenizer.json`
      file — which is exactly the input format XLM-R-family models ship.

      However: its docs make **no mention** of the two specific things the
      proposal flags as "where silent parity bugs hide" — the **precompiled
      charsmap normalizer** (HF's `Precompiled` normalizer type, an NFKC-like
      trie baked into the model, *not* plain NFKC) and **fairseq id
      remapping** (XLM-R's fairseq wrapper offsets raw SentencePiece ids by a
      fixed amount for `<s>`/`<pad>`/`</s>`/`<unk>`). If the package's HF
      `tokenizer.json` loader doesn't implement the `Precompiled` normalizer
      type, it will either error on an unrecognised normalizer or silently
      approximate with plain NFKC — the exact parity trap the proposal warns
      about — and its Unigram/BPE support looks tuned for Llama/Gemma-family
      models (its own README's examples), not confirmed against an XLM-R
      export specifically.

      **Decision: neither "definitely adopt" nor "definitely port" — resolve
      with a time-boxed spike as the first implementation step (Phase 0
      below), not by guessing now.** The plan's Phase 0 is written as two
      branches gated on the spike's outcome, so the plan stays actionable
      either way without blocking on a design guess:

      - **Branch A (adopt):** if `dart_sentencepiece_tokenizer` reproduces
        HuggingFace `AutoTokenizer` token ids byte-for-byte on a small
        multilingual smoke corpus using `multilingual-e5-small`'s actual
        `tokenizer.json`, add it as a `betto_inferencing` dependency and wrap
        it behind the new tokenizer abstraction (see Q2/Investigation). This
        would shrink the roadmap's "write vocab loading, charsmap
        normalizer, Metaspace, Unigram Viterbi, fairseq remapping,
        post-processing" list to near-zero net-new tokenization code —
        by far the cheaper path if it holds up.
      - **Branch B (port):** if it fails parity (most likely at the
        charsmap-normalizer or fairseq-remapping steps per the analysis
        above), fall back to the roadmap's original plan: port from
        `transformers.js` (Apache-2.0), cross-checked against `tokenizers`
        (Rust) / `spm_precompiled` for the ambiguous steps, built as a new
        pure-Dart module inside `betto_inferencing`.

      Either branch is gated by the same CI parity requirement (Phase 1
      below), so the correctness bar doesn't change — only how much new code
      is written to meet it.

- [x] **Q2 — `OnnxEmbeddingModel` and `BertTokenizer` are not behind a shared
      abstraction — is introducing one in scope, or should the new tokenizer be
      bolted on some other way?**

      Confirmed directly in `betto_inferencing` source
      (`~/development/bettongia/inferencing`, local clone matches
      the published `0.1.0-dev.1` exactly): `OnnxEmbeddingModel` hard-wires
      `BertTokenizer` in four places —
      `lib/src/onnx_embedding_model.dart:24` (import), `:97` (`final
      BertTokenizer _tokenizer` field type), `:222-225` (`BertTokenizer.load`
      call inside `load()`), `:250` (`_tokenizer.encode(text)` inside
      `embed()`). `BertTokenizer.encode()` (`bert_tokenizer.dart:110-147`)
      also bakes in BERT-specific framing (`[CLS]`/`[SEP]`/`[PAD]` ids,
      single `token_type_ids` segment) that does not transfer to XLM-R's
      `<s>…</s>` framing and different special-token ids. There is no shared
      `Tokenizer`-to-model-input abstraction today — the roadmap's "write an
      XLM-R tokenizer alongside `BertTokenizer`" framing understates this:
      without an abstraction, `OnnxEmbeddingModel` cannot select between the
      two at runtime, only one or the other at compile time via a fork.

      **Decision: introduce a small `ModelTokenizer` abstraction, in
      scope.** `BertTokenizer` and the new XLM-R tokenizer both implement it;
      `OnnxEmbeddingModel.load()` selects an instance based on
      `ModelSpec.meta['tokenizerFamily']` (a new meta key, e.g. `'bert'` /
      `'xlmr'`) rather than an `if (modelId == ...)` chain, so registering a
      third tokenizer family later is additive. See Investigation for the
      exact shape.

- [x] **Q3 — How does E5's mandatory `passage:`/`query:` prefix get applied,
      given `EmbeddingModel.embed(String text)` has no passage/query distinction
      anywhere in the interface or its callers?**

      Confirmed: `abstract interface class EmbeddingModel`
      (`embedding_model.dart:47-84`) has a single `embed(String text)`
      method — no parameter or overload distinguishes index-time
      ("passage") from query-time ("query") text. In `kmdb`, both call sites
      already know which case they're in structurally (they're different
      methods) but neither passes that fact through: `VecManager`'s
      insert/update path and its query path call the same `embed()`; the
      vault semantic query path (`vault_searcher.dart:439-443`, via
      `manager.embeddingModel` cast to `dynamic` — see the note on that cast
      below) does too.

      **Decision: extend the interface with a required `kind` parameter,
      not a side-channel string-prepend at kmdb call sites.** Prepending
      `"passage: "` in `kmdb` itself would leak an E5-specific implementation
      detail into model-agnostic code — `kmdb` should not need to know which
      loaded model wants which magic prefix string.

      ```dart
      enum EmbeddingKind { document, query }

      abstract interface class EmbeddingModel {
        // ... modelId, dimensions unchanged ...
        Future<(Float32List, bool)> embed(
          String text, {
          EmbeddingKind kind = EmbeddingKind.document,
        });
        void dispose();
      }
      ```

      `OnnxEmbeddingModel.embed()` looks up an optional
      `ModelSpec.meta['queryPrefix']` / `meta['documentPrefix']` string and
      prepends it before tokenization; `bge-small-en-v1.5`'s spec has neither
      key, so its behaviour is byte-for-byte unchanged (`kind` defaults to
      `document`, and an absent prefix is a no-op prepend). This is an
      additive default on the parameter, so it is **source-compatible** for
      any external caller of `embed()` that doesn't pass `kind` — but it is
      still a `kmdb`-side behavioural gap unless call sites are updated,
      since silently treating every embed as `document` for a model that
      *does* have a `queryPrefix` would embed queries with the wrong prefix
      (or none), degrading retrieval quality without erroring. **`kmdb`'s
      query-time call sites must be updated to pass `kind:
      EmbeddingKind.query` explicitly** — this is real, non-trivial
      `kmdb`-side work (not just dependency-version bumping), touching
      `VecManager`'s query path and the vault semantic query path. See Phase
      3 below for the exact call sites.

- [x] **Q4 — The CI byte-exact parity gate needs a reference corpus of
      `(text, expected_token_ids)` pairs generated by HuggingFace's Python
      `AutoTokenizer` — where does the input text come from, and how do the
      expected ids get produced, given this project's Dart-only tooling has no
      Python/`transformers` environment?**

      **Input text: reuse the UDHR corpus, the same one
      `betto_lang_detector` already uses.** That sibling repo
      (`~/development/bettongia/lang_detector`) has
      `tool/generate_ngram_profiles.dart`, a one-off dev script (output
      committed, not run by CI — "Generated by ...; do not edit by hand")
      that downloads NLTK's `udhr2`/`udhr` zip packages (a clean UTF-8
      re-encoding of Universal Declaration of Human Rights translations —
      the corpus the classic Cavnar & Trenkle n-gram technique was itself
      validated against) and extracts per-language text via a
      `Map<String, String>` of language code → archive member path
      (`_corpusMember`, ~52 languages spanning Latin, Cyrillic, Arabic,
      Devanagari, CJK, Thai, Hebrew, and more scripts). This is a
      substantially better corpus source than hand-picking sentences:
      **known-clean licensing** (UDHR translations are freely
      redistributable government/UN text — no copyright ambiguity from
      lifting arbitrary web sentences into a committed test fixture),
      **already vetted** for exactly this kind of script/language diversity
      by this project's own WI-5 work, and **zero new sourcing decisions**
      to make or defend.

      Mirror the same pattern as a new one-off Dart tool script in
      `betto_inferencing`, e.g. `tool/generate_xlmr_parity_corpus.dart`:
      download the same `udhr2`/`udhr` zip URLs, reuse (or copy)
      `_corpusMember`'s language→member-path map, and extract a short
      representative excerpt (e.g. UDHR Article 1, one paragraph) per
      language into an intermediate, checked-in text fixture. This step is
      **pure Dart, no Python needed** — it only produces the *input* side of
      the parity corpus.

      **Expected token ids: still a real, unavoidable Python step** —
      confirmed `betto_inferencing` has no Python files, no `tool/`/`scripts/`
      directory today, and this sandbox has no `transformers` installed.
      This is not a design ambiguity, just an out-of-Dart-toolchain action.

      **Decision: split the two concerns.** The corpus *text* is sourced
      and extracted by the new Dart tool script above (no pause needed —
      fully automatable, same as WI-5's script). Only the *token id*
      annotation step needs a pause: the implementer asks the user to run a
      short Python snippet
      (`AutoTokenizer.from_pretrained('intfloat/multilingual-e5-small')`)
      over the extracted per-language text and share back the resulting
      token id arrays, which get merged into the final, permanently-static
      `test/fixtures/xlmr_parity_corpus.json` (input text + expected ids
      together) — no Python dependency in CI itself, ever after. Same
      "pause for an out-of-toolchain action" pattern WI-6 used for pub.dev
      publishing, just narrowed to the one step that genuinely needs it.

- [x] **Q5 — Is `bge-m3-v1.0`'s broken `ModelCatalog` entry in scope to fix?**

      Confirmed: both `ModelFile.sha256` values for `bge-m3-v1.0`
      (`model_catalog.dart:100-113`) are placeholder all-zero strings — this
      entry cannot actually be downloaded/validated today; it is a stub, not
      a "registered but unvalidated" model in the sense of merely lacking a
      test pass. Fixing it (sourcing a real 1024-dim ONNX export and
      re-validating a full-reindex migration path) is out of scope — the
      roadmap frames `bge-m3` as a later upgrade path, separate from this
      WI's `multilingual-e5-small` deliverable.

      **`bge-m3` turns out to be a bigger jump than "1024 dims, needs a
      re-index" alone suggests.** Checked directly against
      `BAAI/bge-m3/tree/main/onnx`: its fp32 ONNX export is **~2.29 GB**
      total — `model.onnx` (725 KB, graph only) plus a separate
      `model.onnx_data` (2.27 GB, external weights) — versus
      `multilingual-e5-small`'s ~470 MB single-file `model.onnx` (itself
      already ~3.7× BGE Small's ~127 MB). `bge-m3` exceeds ONNX's 2 GB
      single-protobuf-file limit, so HF's export splits it into a graph
      file plus an "external data" companion — a structurally different
      layout `ModelSpec`/`ModelDownloader` don't support today (`ModelSpec.
      files` assumes each named asset, e.g. `'onnx'`, is one
      self-contained file with one checksum; ORT expects `model.onnx_data`
      alongside `model.onnx` at load time). Registering `bge-m3` properly
      would need `ModelSpec`/`ModelDownloader` changes to fetch and place a
      multi-file asset correctly, not just a new catalog entry with real
      checksums — reinforcing that this is a distinct, larger piece of
      future work, not a small addition this WI should absorb.

      **Decision (revised): remove the entry entirely rather than leave it
      broken.** A stub with checksums that cannot ever verify is not
      "infrastructure for later" — it's a registered model that silently
      fails at download time with a confusing checksum-mismatch error
      instead of a clear "not yet supported" message. This is a greenfields
      project (no installed base, no compatibility cost — same reasoning
      `docs/reviews/roadmap-review-2026-06-05.md` used project-wide), so
      there is no cost to removing it now and re-adding it properly (real
      checksums, real validation pass) whenever `bge-m3` work is actually
      picked up.

      **This has a real ripple, checked directly:** `'bge-m3-v1.0'` is
      hardcoded in `inferencing`'s `test/model_catalog_test.dart` (5
      call sites: unknown-model error-message contents, "throws
      `UnsupportedError` for a registered-but-unvalidated model" ×2,
      `isKnown` returns true, `ModelCatalog.all` contains it,
      `isAllowed` returns true), `test/model_downloader_test.dart` (a test
      titled "permits download for a registered model (even if
      unvalidated)" fetches `bge-m3-v1.0`'s spec from the real catalog just
      to get *a* registered-but-unvalidated id — it doesn't care which
      model), `example/model_catalog.dart`, and
      `integration_test_app/integration_test/inferencing_test.dart`. None of
      these actually depend on it being *BGE-M3* — they only need some
      stable, real, registered-but-unvalidated catalog entry to exercise the
      gating behaviour against. Once `multilingual-e5-small` is flipped to
      `validated: true` at the end of this plan (Phase 2), the catalog would
      have **zero** unvalidated entries left, so these tests can't simply be
      repointed at the new model either — that would make them describe a
      transient mid-PR state, not a stable one.

      **Resolution: add a permanent, dedicated `placeholder-model` entry**
      (`id: 'placeholder-model'`) to `_catalog`/`_validated`, deliberately
      and permanently `validated: false` — never intended to be downloaded,
      loaded, or flipped to `true`. Its doc comment says so explicitly: an
      internal fixture that exists solely to give tests a stable,
      always-unvalidated registered id to assert gating behaviour against,
      not a real model. Its `ModelFile` URLs point at an obviously
      non-resolvable host (e.g. `https://example.invalid/placeholder/...`)
      so a misuse (someone actually trying to load it) fails fast and
      obviously rather than silently.

      This is simpler than a test-seam refactor (no DI, no
      `@visibleForTesting` machinery) and proportionate to `ModelCatalog`'s
      existing design, which is already a small static, stateless allowlist
      by choice (its own doc comment: "stateless and lightweight"). The one
      risk — a fake entry leaking into a user-facing "list available
      models" surface — doesn't apply today: checked directly, `.all` is
      referenced only by this package's own `example/model_catalog.dart` and
      its integration test; `kmdb_cli` does not reference `ModelCatalog` at
      all (it can't load `betto_inferencing` — see Investigation). If a
      user-facing model-listing command is ever added, it should filter to
      `validated: true` entries anyway, which would exclude
      `placeholder-model` (and any other in-progress model) automatically —
      good practice independent of this decision.

      Rewrite the ~8 `bge-m3-v1.0` call sites across
      `test/model_catalog_test.dart`, `test/model_downloader_test.dart`,
      `example/model_catalog.dart`, and
      `integration_test_app/integration_test/inferencing_test.dart` to
      reference `placeholder-model` instead — mechanical rename, same
      assertions. See Phase 2 below.

## Investigation

### Where things stand today (confirmed against source, not just the spec)

`betto_inferencing`'s local clone (`~/development/bettongia/inferencing`) diffs
byte-identical against the published `betto_inferencing-0.1.0-dev.1` in the pub
cache, so all findings below are current for both. (The repo's own
`pubspec.yaml`/`CHANGELOG.md` already carry an **unpublished, empty**
`0.1.0-dev.2` version bump from unrelated prior work — same situation WI-6 hit
with `betto_icu`/`betto_lexical`; confirm at implementation time whether this
plan's changes land in that still-unreleased `dev.2` or need a further bump.)

- **`ModelCatalog`** (`lib/src/model_catalog.dart`) has exactly two entries:
  `bge-small-en-v1.5` (validated, real checksums) and `bge-m3-v1.0`
  (unvalidated, placeholder zero checksums — see Q5). **`multilingual-e5-small`
  is not registered at all** — this is a "register a new `ModelSpec`" task, not
  "flip a validation flag."
- **`EmbeddingModel`** (`lib/src/embedding_model.dart:47-84`) is a clean,
  already-model-agnostic interface (`modelId`, `dimensions`, `embed`, `dispose`)
  — `dimensions` is read generically from `spec.meta['dimensions']`
  (`onnx_embedding_model.dart:119`), so a same-dimension model swap (E5-small is
  384-dim, same as BGE) needs no changes there.
- **`OnnxEmbeddingModel`/`BertTokenizer`** are hard-wired to each other in four
  places (see Q2) — introducing a `ModelTokenizer` abstraction is the concrete
  unlock for supporting a second tokenizer family.
- **No passage/query distinction exists anywhere** (see Q3) —
  `embed(String text)` is the entire query surface.
- **`kmdb` core, the vault search path, and the CLI are already model-agnostic**
  — confirmed by grep across `packages/kmdb` and `packages/kmdb_cli`: model
  identity flows through as an opaque `modelId` string (`EmbeddingModelConfig`
  in `packages/kmdb/lib/src/config/kmdb_config.dart:112-172`, round-tripped
  through `local/config.json`), `KmdbDatabase.open()` takes any `EmbeddingModel`
  instance without inspecting which model it is (`kmdb_database.dart:369-440`),
  and `VecIndexState.modelId` + `VecManager.checkAndTransitionOnOpen()` (WI-1,
  already Complete) already invalidate-and-rebuild on any model change, keyed
  purely on the string ID. **No dimension is hard-coded to 384 anywhere in
  `kmdb`** — SQ8 byte length and score-path guards are already sourced from
  `EmbeddingModel.dimensions` (§22 "Index Structure"). This means the bulk of
  this WI's work is in `betto_inferencing`, not `kmdb` — but seeQ3 for the one
  piece of real `kmdb`-side work (threading `EmbeddingKind` through the two call
  sites that currently call `embed()` uniformly for both indexing and querying).
- **`kmdb_cli` cannot actually load `betto_inferencing` today** —
  `search_command.dart:275-278`'s own comment says so ("The CLI cannot load the
  betto_inferencing package (ONNX Runtime), so it uses `FtsManager` directly for
  results"); semantic/hybrid mode is presented as a label only in the CLI, never
  executed. This is a pre-existing, unrelated limitation (applies identically to
  BGE today) — not introduced or worsened by this plan, and not fixed by it.
- **`docs/spec/22_semantic_search.md`'s "Model acquisition" section is stale**
  on one point unrelated to this WI: it says tokenizer assets are "included in
  `assets/models/bge-small-en/`... loaded directly... without any network
  access," but `OnnxEmbeddingModel.load()`'s actual `cacheDir` path
  (`onnx_embedding_model.dart:197-212`) downloads **both** `'onnx'` and
  `'vocab'` `ModelFile`s via `ModelDownloader` — there is no bundled asset
  directory in the current source. Worth a one-line spec correction while
  touching this file for the E5 registration, but not a design point for this
  plan.

### Model choice and file sourcing

`multilingual-e5-small` (`intfloat/multilingual-e5-small` on HuggingFace, MIT
licence) already publishes an ONNX export directly in its own repo
(`onnx/model.onnx`), the same pattern `bge-small-en-v1.5`'s `ModelSpec` already
uses (`resolve/main/onnx/model.onnx`) — no separate ONNX conversion step is
needed, unlike what a from-scratch PyTorch→ONNX export would require. A
community `transformers.js`-oriented mirror (`Xenova/multilingual-e5-small`)
also exists and is useful as a secondary reference for tokenizer.json shape,
since `transformers.js` is the proposal's own recommended porting source.

**Implementer must confirm at registration time** (not guessed here): the exact
tokenizer asset filename(s) in the `intfloat/multilingual-e5-small` repo
(`sentencepiece.bpe.model` and/or `tokenizer.json` — XLM-R-family repos
typically ship both) and their SHA-256 digests, following the same manual
verification `bge-small-en-v1.5`'s entry already does (its checksums are pinned
comments noting "SHA-256 of the exact model file used in CI").

Note the model is meaningfully larger than BGE Small: `model.onnx` is ~470 MB
uncompressed (vs. BGE Small's ~127 MB) — worth a callout in the model catalog
doc comment and `docs/spec/22_semantic_search.md`, since it changes the
first-use download experience materially, especially on mobile.

**Which ONNX file: plain `model.onnx`, not a quantized/optimized variant.** The
repo's `onnx/` directory has several exports; the two size-reducing alternatives
are both a poor fit for this project's actual runtime:

- `model_qint8_avx512_vnni.onnx` — int8-quantized specifically for the x86
  AVX512-VNNI instruction set. `kmdb`'s target platforms include Apple Silicon
  macOS/iOS and Android — mostly ARM, where an AVX512-VNNI build either falls
  back to a slow unoptimized path or isn't the intended target at all. Wrong
  axis of optimization for a cross-platform (not x86-server-only) deployment.
- `model_O4.onnx` — an ONNX Runtime BERT-optimizer graph-optimization-level
  export. Per Microsoft's optimizer tool, `O4` layers in fp16 mixed precision on
  top of `O3`'s fusions, intended for **GPU** inference; `betto_onnxrt`'s CPU
  execution provider (there is no bundled CUDA/GPU path anywhere in
  `betto_onnxrt`/§22) either can't run fp16 ops efficiently or falls back to
  casting, which defeats the point and adds risk of subtly different numerics
  from what any parity/accuracy testing assumed.
- **`model.onnx`** — the plain fp32 export, no hardware-specific quantization or
  GPU-oriented graph surgery. Matches the existing `bge-small-en-v1.5`
  registration exactly (its `ModelSpec` also points at a plain
  `.../onnx/model.onnx`), runs correctly and identically across every CPU
  execution-provider target `betto_onnxrt` supports, and doesn't introduce a
  second, unvalidated source of numerical drift (int8 quantization) stacked
  underneath the storage layer's own SQ8 quantization (§22).

Register `model.onnx`. Trading the ~470 MB download for a smaller quantized
build is a legitimate future optimization (worth revisiting if first-use
download size on mobile proves a real problem) but changes retrieval accuracy in
a way that needs its own dedicated validation — out of scope for this WI, which
is about adopting the reference model, not tuning it. Note this explicitly in
the `ModelCatalog` doc comment so a future reader doesn't "helpfully" swap in a
smaller variant without realizing the trade-off.

### `ModelTokenizer` abstraction (Q2 decision, concrete shape)

**Revised 2026-07-09, during WI-11's Phase 1 review (its B1):** the
interface returns the **existing `TokenizerOutput`** (from
`bert_tokenizer.dart`), not a new `ModelInput` type. WI-11's
`XlmRobertaTokenizer` (built to unblock this WI's own Q6 hard gate) already
reuses `TokenizerOutput` verbatim, so both tokenizers return the identical
concrete type today — introducing a separate `ModelInput` type here would
mean reconciling two shapes for no benefit. Collapse onto `TokenizerOutput`
directly:

```dart
/// Implemented by tokenizer families ([BertTokenizer], [XlmRobertaTokenizer])
/// so [OnnxEmbeddingModel] can share one call site regardless of model family.
abstract interface class ModelTokenizer {
  TokenizerOutput encode(String text);
}

// BertTokenizer implements ModelTokenizer (wraps existing encode() logic,
// no behavioural change for bge-small-en-v1.5).
// XlmRobertaTokenizer (WI-11) already returns TokenizerOutput — adding
// `implements ModelTokenizer` there is a one-line, mechanical addition.
```

`OnnxEmbeddingModel.load()` selects which concrete tokenizer to construct based
on a new `ModelSpec.meta['tokenizerFamily']` key (`'bert'` for the existing BGE
entry — added explicitly, not left absent/defaulted, so a third family can't
silently misresolve — `'xlmr'` for the new E5 entry).

### Phase 0 spike result (2026-07-07): Branch B, root cause confirmed at source level

The spike (`~/development/bettongia/inferencing`, branch `wi4-tokenizer-spike`)
ran `dart_sentencepiece_tokenizer 1.3.2`'s `HuggingFaceTokenizerLoader` against
`multilingual-e5-small`'s real `tokenizer.json` and compared output token ids
against reference values for 11 entries (8 UDHR-derived languages + 3 normalizer
edge cases). **Result: 0/11 byte-exact matches.** Full per-entry ids and
divergence indices are in the Phase 0 checklist above; summary: every entry
diverges starting at the very first content token, and non-edge-case,
plain-language entries (not just the edge cases) show the same failure pattern —
actual output 1.3–3.5× longer than expected, riddled with `<unk>` (id 3)
fallback tokens.

**Root cause, confirmed by reading the package source directly (not inferred
from symptoms alone):** `dart_sentencepiece_tokenizer` never implements
HuggingFace's `Precompiled` normalizer (the charsmap-trie normalizer XLM-R's
`tokenizer.json` uses — confirmed present: a 316,720-byte base64
`precompiled_charsmap` blob under `normalizer.normalizers[0]`). Two independent
code paths both drop it silently:

- **HF `tokenizer.json` loading path**
  (`lib/src/sentencepiece/serialization/huggingface_json.dart`,
  `_buildNormalizerSpec`): always returns `NormalizerSpec(name: 'identity', ...)`
  — it extracts only `addDummyPrefix`/`escapeWhitespaces`/
  `removeExtraWhitespaces` boolean flags from the normalizer JSON tree; the
  `Precompiled` normalizer's `precompiled_charsmap` field is never read from the
  HF JSON at all.
- **Native `.model` protobuf loading path**
  (`lib/src/sentencepiece/model/sentencepiece_model.dart` /
  `model_proto.dart`): *does* parse `precompiled_charsmap` bytes out of the
  protobuf into `NormalizerSpec.precompiledCharsmap` (case 2 in
  `_parseNormalizerSpec`) — but `SpNormalizer.fromSpec()`
  (`lib/src/sentencepiece/normalizer/sp_normalizer.dart`) never reads that
  field; `SpNormalizer.normalize()` only ever does whitespace-collapse +
  dummy-prefix + metaspace-escape. So even loading
  `tool/spike_assets/sentencepiece.bpe.model` directly instead of
  `tokenizer.json` would hit the identical gap.

This confirms the plan's own Q1 prediction exactly (parity failure "most likely
at the charsmap-normalizer... step") and rules out the fairseq-id-offset theory
as the primary cause — a pure id-offset bug would shift *all* ids by a constant
without introducing spurious `<unk>`s or changing token *counts*; the observed
symptom (token-count blowup + scattered `<unk>`) is the signature of the
Unigram Viterbi segmenter operating on **un-normalized** text and failing to
match multi-codepoint sequences that only exist in the vocab post-charsmap
normalization (e.g. fullwidth→halfwidth folding, certain combining-sequence
canonicalizations, NFKC-like substitutions the charsmap trie encodes). Note the
special-token framing and id assignment (`<s>`=0, `<pad>`=1, `</s>`=2, `<unk>`=3,
correctly read from `tokenizer.json`'s `added_tokens`/`model.unk_id`) are
**not** the problem — `bosId=0`/`eosId=2` loaded correctly and the `<s>…</s>`
post-processing is applied — so a follow-on port plan does not need to
re-litigate that part, only the charsmap normalizer (and, given the observed
`th`/`zh` residual divergence even where token *counts* roughly matched, it
should not assume the Metaspace/Unigram-Viterbi steps are otherwise
untouched — worth a targeted look once the normalizer is fixed, since some
divergence there could still originate downstream of it).

**Provenance verification performed this session** (no record of how
`reference_ids.json` was generated survived the prior interrupted session's
scratch directory): independently decoded all 11 reference id arrays back to
text using only `tokenizer.json`'s own id→piece vocab table (no HF/`transformers`
dependency) — every array round-trips to exactly the expected source string,
including charsmap-driven side effects (fullwidth Latin → plain ASCII,
typographic ellipsis → literal `...`). This is strong evidence the reference
values are genuine `AutoTokenizer` output for this tokenizer, not fabricated —
worth noting for whoever picks up the follow-on plan, since it should not need
to redo this verification, but should still independently confirm before
building a byte-exact CI gate on top of it (e.g. by having the user regenerate a
subset with a live Python `transformers` run, per Q4's existing hand-off
pattern).

**Conclusion for the follow-on tokenizer-port plan:** the dominant, and
possibly only, gap is the `Precompiled` charsmap normalizer. That plan's design
pass should scope precisely: (1) implement the charsmap-trie normalizer
(porting from `transformers.js`'s `Precompiled` normalizer implementation or the
Rust `spm_precompiled` crate, both cited in the roadmap/proposal as reference
sources), (2) re-run this session's exact spike corpus/comparison once the
normalizer is wired in to check whether that alone closes the gap or whether
residual Metaspace/Viterbi differences remain (the `th`/`zh` near-miss lengths
above are the concrete lead to chase first), and (3) only then design the
full `ModelTokenizer`-conformant wrapper. This scoping should materially shrink
the follow-on plan's investigation phase — it starts from a confirmed root
cause instead of the three open theories (charsmap, fairseq offset, or both)
Q1 posed.

### Third-party provenance (only if Q1 resolves to Branch B)

**Under Q6's hard gate this is the follow-on port plan's concern, not this
plan's — captured here as ready guidance for that plan.** No
`NOTICE`/`THIRD_PARTY` file convention exists yet in `betto_inferencing`
(only a top-level Apache-2.0 `LICENSE`, checked directly). If the spike resolves
to porting from `transformers.js`, add a `NOTICE` file recording: the source
project (`transformers.js`, Apache-2.0), the specific files/logic ported
(charsmap normalizer, Metaspace pre-tokenizer, Unigram Viterbi, fairseq id
remap), and a pointer to `tokenizers`/`spm_precompiled` as the cross-checked
reference for ambiguous steps — this is new precedent for the project and should
be written once, clearly, rather than scattered across file-level comments. If
Branch A (adopt the pub.dev package) is taken instead, no porting-provenance
file is needed — just a normal `pubspec.yaml` dependency addition, which needs
no special licence handling (package is MIT, same family as this project's other
dependencies).

### Files this plan touches

**`inferencing` repo** (`~/development/bettongia/inferencing`, published as
`betto_inferencing`):

- `lib/src/model_catalog.dart` — register `multilingual-e5-small` (`ModelSpec`,
  real checksums,
  `meta: {'dimensions': 384, 'tokenizerFamily': 'xlmr', 'queryPrefix': 'query: ', 'documentPrefix': 'passage: '}`);
  add `'tokenizerFamily': 'bert'` to the existing `bge-small-en-v1.5` entry; add
  `'multilingual-e5-small': false` to `_validated` initially, flipped to `true`
  once the parity gate and integration tests pass; **remove the `bge-m3-v1.0`
  entry** (`_bgeM3V10`, its `_catalog`/`_validated` map entries, and its doc
  comment); **add a permanent `placeholder-model` entry** (`validated: false`
  forever, non-resolvable URLs, doc comment explaining it's a test fixture only)
  per Q5.
- `test/model_catalog_test.dart`, `test/model_downloader_test.dart`,
  `example/model_catalog.dart`,
  `integration_test_app/integration_test/inferencing_test.dart` — rename the
  `bge-m3-v1.0`-hardcoded assertions to `placeholder-model` per Q5's resolution.
- `lib/src/embedding_model.dart` — add `EmbeddingKind` enum; add `kind`
  parameter to `EmbeddingModel.embed()` (default `EmbeddingKind.document`).
- `lib/src/model_tokenizer.dart` (new) — `ModelTokenizer` interface, returning
  the existing `TokenizerOutput` directly (no new `ModelInput` type — see the
  Investigation revision above).
- `lib/src/bert_tokenizer.dart` — implement `ModelTokenizer`; no behavioural
  change.
- `lib/src/xlmr_tokenizer.dart` (new) — **only in scope for *this* plan under
  Branch A** (a thin wrapper around `dart_sentencepiece_tokenizer`). Under
  Branch B, per Q6's hard gate, this file is produced by a separate
  follow-on tokenizer-port design plan, not by this plan — Phase 2 onward
  here assumes a working, parity-gated, `ModelTokenizer`-conformant XLM-R
  tokenizer already exists by the time it starts, regardless of which plan
  produced it.
- `lib/src/onnx_embedding_model.dart` — select `ModelTokenizer` via
  `meta['tokenizerFamily']`; apply `meta['queryPrefix']`/`['documentPrefix']` in
  `embed()` based on `kind`.
- `tool/generate_xlmr_parity_corpus.dart` (new) — mirrors
  `betto_lang_detector`'s `tool/generate_ngram_profiles.dart`: downloads the
  same NLTK `udhr2`/`udhr` zip corpus, reuses its `_corpusMember`
  language→archive-member map, extracts a short per-language excerpt (e.g. UDHR
  Article 1) into an intermediate text fixture. Pure Dart, no Python — see Q4.
- `test/fixtures/xlmr_parity_corpus.json` (new) — the final parity fixture: the
  tool script's extracted per-language text, merged with
  HuggingFace-`AutoTokenizer`-produced expected token ids (Phase 1's pause
  point, Q4).
- `test/` — parity gate test consuming the fixture above (Phase 1); unit tests
  for the new tokenizer and prefix logic; `model_catalog_test.dart` additions.
- `pubspec.yaml` — add `dart_sentencepiece_tokenizer` dependency (Branch A
  only); version bump (confirm `dev.2` vs `dev.3` at implementation time, see
  above).
- `NOTICE` — **not authored by this plan.** Third-party porting provenance is
  only needed under Branch B, where per Q6's hard gate the port (and therefore
  its `NOTICE`) is produced by the separate follow-on port plan. Branch A needs
  no `NOTICE` (a normal MIT pub.dev dependency).
- `CHANGELOG.md` — entry for this work.

**`kmdb` repo:**

- `packages/kmdb/pubspec.yaml`, root `pubspec.yaml` — bump the
  `betto_inferencing` version constraint once the new version is published.
- `packages/kmdb/lib/src/search/semantic/vec_manager.dart` — add a `kind`
  parameter to the private `_embed(String text)` seam at `:845` (forwarded to
  `_model.embed` at `:847`); pass `EmbeddingKind.document` from its
  index/update callers at `:252`/`:309`/`:380` and `EmbeddingKind.query` from
  the query caller at `:584` (verified — all four public call sites funnel
  through this one private method).
- `packages/kmdb/lib/src/vault/search/vault_searcher.dart` — same, for the vault
  semantic query path (`as dynamic` call at `:443`, embed at `:444`); the
  existing `_embeddingModel` field is typed `Object?` and cast via `as dynamic`
  (`:105`, with a comment explaining it's really `EmbeddingModel?` — kept
  loosely typed to avoid a direct `betto_inferencing` *model class* dependency
  in this file). Passing `kind: EmbeddingKind.query` through that dynamic call
  requires importing the `EmbeddingKind` **enum** from `betto_inferencing` in
  this file (Q9) — a plain enum, not the model class the `Object?` seam exists
  to avoid, so this doesn't reintroduce what the seam was built to prevent.
  Add a test that would fail if the argument were silently dropped — through
  dynamic dispatch, a mis-named/dropped `kind:` fails at runtime, not compile
  time, so this test is what actually makes the seam safe.
- `packages/kmdb/lib/src/vault/search/vault_search_manager.dart` — index-time
  embedding calls at `:599→:610` and `:780→:805` (verified — **not** `:862`,
  which is `_checkModelVersion` reading `model.modelId`, not an embed call)
  get `kind: EmbeddingKind.document` explicitly.
- Docs: `docs/spec/22_semantic_search.md` (Model Catalog table, "Model
  acquisition" stale-assets correction, new `EmbeddingKind`/prefix behaviour,
  model size callout), `docs/roadmap/0_06.md` (mark WI-4 in-progress/complete),
  `docs/proposals/vault_search.md` §10.3 (cross-reference this plan once
  implemented, similar to how WI-6 annotated §10.4).

## Implementation plan

**Phase 0 — tokenizer build-vs-adopt spike (separate repo: `inferencing`)**

_Resolves Q1. Time-boxed — this is a go/no-go check, not open-ended tokenizer
development._

- [x] **Hand-off point (Q7):** download `multilingual-e5-small`'s actual
      tokenizer assets (`tokenizer.json` and/or `sentencepiece.bpe.model`)
      from `intfloat/multilingual-e5-small` on `huggingface.co` — outside the
      typical implementer sandbox's network allowlist
      (`github.com`/`pub.dev`/`chromium.googlesource.com`). Ask for a sandbox
      exception or have the user fetch the file(s) if blocked.

      Done (prior session): `tool/spike_assets/tokenizer.json` (~17MB,
      verified valid JSON — `normalizer` is a `Sequence` of `Precompiled`
      (316,720-byte base64 charsmap) + `Replace` (whitespace collapse),
      `pre_tokenizer: Metaspace`, `post_processor: TemplateProcessing`
      framing `<s> … </s>`, `model: Unigram` with a 250,002-entry vocab) and
      `tool/spike_assets/sentencepiece.bpe.model` (~5MB) — both real
      `intfloat/multilingual-e5-small` assets, sizes and structure verified
      this session.
- [x] Add `dart_sentencepiece_tokenizer` as a dev-only dependency; attempt to
      load the real tokenizer.json via its HF loader
      (`TokenizerJsonLoader`/`HuggingFaceTokenizerLoader`).

      Done. `pubspec.yaml`/`pubspec.lock` pin `dart_sentencepiece_tokenizer:
      ^1.3.2` (`dart pub get` resolves cleanly). Loaded successfully via
      `HuggingFaceTokenizerLoader.fromJsonFileSync` — reports
      `modelType=ModelType.unigram vocabSize=250002 bosId=0 eosId=2`, so the
      HF `tokenizer.json` shape itself loads without error (it does not
      error/reject the `Precompiled` normalizer type — worse, it silently
      ignores it, see Decision point below).
- [x] Encode a small multilingual smoke corpus for the spike — reuse a handful
      (~10-15) of UDHR Article 1 excerpts from `betto_lang_detector`'s
      `_corpusMember` map, picked for script diversity (Latin, CJK, Cyrillic,
      Arabic; at least one language with combining diacritics, since XLM-R's
      charsmap normalizer specifically targets those) — same corpus family as
      Phase 1's full fixture (see Q4), just a small hand-selected slice so the
      spike doesn't need the full extraction tool built yet. Compare token ids
      against **manually-sourced reference values** (from the HF
      `Xenova/multilingual-e5-small` model card, HF's own tokenizer playground,
      or a quick check the user runs locally — does not require the full CI
      fixture from Phase 1 yet, just enough to decide the branch).

      Done. `tool/spike_assets/smoke_corpus.json` holds 8 UDHR Article 1
      excerpts (`en`/`ar`/`zh`/`ru`/`hi`/`ko`/`th`/`vi` — Latin, Arabic, CJK,
      Cyrillic, Devanagari, Thai, all extracted from the NLTK `udhr`/`udhr2`
      zips already present in `tool/spike_assets/`) plus 3 normalizer-focused
      edge cases (`edge_fullwidth`, `edge_punct`, `edge_nfd`).
      `tool/spike_assets/reference_ids.json` holds the corresponding expected
      token id arrays for all 11 entries. **Provenance check (this session,
      since no note/script survived the prior session's scratch directory):**
      independently decoded every `reference_ids.json` array back to text
      using only the vocab table embedded in `tokenizer.json` itself (id→piece
      lookup, `▁`→space, no HF/transformers dependency) — every entry
      round-trips to the exact source string, *including* the expected
      normalizer transforms (`edge_fullwidth`'s "Ｈｅｌｌｏ Ｗｏｒｌｄ" decodes
      to plain-ASCII "Hello World"; `edge_punct`'s curly quotes/ellipsis
      decode with the ellipsis rendered as literal "..."). This is strong
      internal-consistency evidence the reference ids are genuine
      `AutoTokenizer` output for this exact `tokenizer.json`, not fabricated —
      a hand-fabricated set could not plausibly reproduce the exact
      charsmap-driven normalization side effects. Wrote
      `tool/spike_compare.dart` (throwaway, not wired into CI) to encode every
      corpus entry via `HuggingFaceTokenizerLoader` +
      `SentencePieceTokenizer.encode(text, addSpecialTokens: true)` and diff
      against `reference_ids.json`.
- [x] **Decision point:** byte-exact match on the smoke corpus → Branch A
      (adopt); any mismatch (expected failure points: the charsmap normalizer
      step, fairseq id offsets) → Branch B (port from `transformers.js`). Record
      the outcome and evidence in this plan's Investigation section before
      proceeding.

      **Outcome: Branch B (port).** `dart tool/spike_compare.dart` result:
      **0/11 entries passed, 11/11 failed.** Every single entry — not just
      the 3 normalizer edge cases, but all 8 plain-language UDHR entries too
      — diverges starting at index 1 (the first content token right after
      `<s>`=0), and the actual output is consistently 1.3–3.5× longer than
      expected with `<unk>` (id 3) tokens scattered throughout (e.g. `en`:
      expected 39 ids vs. actual 78, riddled with `3`s; `vi`: expected 85 vs.
      actual 168; `edge_fullwidth`: expected `[0, 35378, 6661, 2]` vs. actual
      `[0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2]` — every fullwidth character
      individually falls back to unknown). Only `th` and `zh` come close in
      raw length (48 vs 48, 31 vs 32) but still diverge at index 1 and later
      pick up spurious `<unk>`s. See Investigation for root-cause analysis —
      confirmed at the source level, not just inferred from the symptom.
- [x] **HARD GATE (Q6): if the spike resolves to Branch B, STOP — do not write
      port code.** Hand-porting an XLM-R SentencePiece/Unigram tokenizer
      (precompiled charsmap normaliser, Metaspace pre-tokenizer, Unigram
      Viterbi, fairseq id remap, `<s>…</s>` post-processing) is large,
      design-heavy, error-prone work — not something a mechanical implementer
      can execute from "scaffold per the roadmap's component list." Instead:
      return to planning for a dedicated tokenizer-port design pass (a plan
      revision or a follow-on plan) that maps each `transformers.js`
      file/function to a Dart unit, specifies the charsmap-trie loading
      approach, the fairseq offset derivation, and the test decomposition
      beyond the single parity gate — reviewed by `kmdb-plan-reviewer` and
      brought back to `Investigated` before any Branch B code is written.
      This gate exists specifically because the plan's own Q1 analysis
      predicts Branch B is the *likely* outcome — confirm the spike's actual
      result here rather than assuming, but do not treat "likely" as
      "already designed."

      **Gate triggered — implementation stops here.** No tokenizer-port code
      was written. `lib/src/xlmr_tokenizer.dart` and every other Phase
      1/2/3 file this plan lists do not exist in the working tree; the only
      new files are the Phase 0 spike artifacts under `tool/spike_assets/`
      and the throwaway `tool/spike_compare.dart` script (not a
      `ModelTokenizer` implementation, not wired into `lib/`, not referenced
      by any production code path). A dedicated tokenizer-port design plan,
      reviewed by `kmdb-plan-reviewer` to its own `Investigated` status, is
      required before Phase 1 (Branch A's variant, now moot) or any Branch B
      port work begins — see the root-cause note in Investigation below for
      what that follow-on plan needs to account for.

**Phase 1 — CI parity gate (`inferencing` repo)**

_Resolves Q4. The parity gate is required in **both** branches — but its
sequencing depends on Phase 0's outcome. Under **Branch A**, this plan executes
Phase 1 directly (the adopted wrapper exists after Phase 0). Under **Branch B**,
Phase 0 has already hit the Q6 hard gate and stopped, so Phase 1 is owned by the
separate follow-on port plan — the parity gate is that port's own acceptance
criterion and cannot run before the ported tokenizer exists. The corpus fixture
these steps produce is tokenizer-independent (input text + HuggingFace-produced
expected ids), so the follow-on plan reuses this exact procedure rather than
inventing a new one._

**Reconciliation (2026-07-09), post-WI-11:** WI-11 shipped its own Phase 1
parity gate, but a narrower one than this section assumed — an 11-entry
corpus (8 UDHR-derived languages + 3 normalizer edge cases) reused directly
from the Phase 0 spike, not the ~52-language `tool/generate_xlmr_parity_corpus.dart`
extraction pipeline this section specifies. That was a deliberate, reviewed
scope decision inside WI-11's own plan (its Phase 1 review, B2) — not an
oversight to fix there. **Decision: build the broader corpus here, as this
plan's own Phase 1, before starting Phase 2.** `multilingual-e5-small` claims
~100-language support; byte-exact validation on 8 languages is a real gap
against that claim for a model being flipped to `validated: true`. The steps
below proceed as originally scoped — they are additive to WI-11's existing
gate (which stays in place; it costs nothing to keep both), not a replacement
for it.

- [x] Write `tool/generate_xlmr_parity_corpus.dart`, mirroring
      `betto_lang_detector`'s `tool/generate_ngram_profiles.dart`: download the
      same NLTK `udhr2`/`udhr` zip corpus, reuse (or copy) its `_corpusMember`
      language→archive-member map, extract a short per-language excerpt (e.g.
      UDHR Article 1) for as many of its ~52 mapped languages as practical,
      write to an intermediate checked-in text fixture. Pure Dart, fully
      automated logic — but **note (Q7):** the download itself hits
      `raw.githubusercontent.com`, which may be outside the implementer's
      sandbox network allowlist even though `github.com` itself is typically
      allowed; confirm access or ask for an exception before assuming this
      step runs unattended.

      Done (2026-07-09, branch `wi4-parity-corpus` in the `inferencing` repo).
      `tool/generate_xlmr_parity_corpus.dart` downloads both zips (cached
      under `tool/.cache/`, same pattern as the reference script) and copies
      `_corpusMember` verbatim (58 entries — the plan's "~52" was an
      estimate; the actual map from `betto_lang_detector` has 58). The
      per-language archive member text isn't blank-line-block-structured
      identically to `betto_lang_detector`'s use case (that tool does
      whole-document n-gram extraction; this one needs just Article 1's
      paragraph), so a new structural heuristic was needed: locate the
      longest of the first 4 blank-line-separated blocks (title/preamble
      material — always the longest block near the document start, since
      it's a list of "Whereas..."-style clauses) and take the block
      immediately following it as Article 1, stripping its heading line.
      Verified by hand against ~15 languages spanning Latin, Arabic,
      Cyrillic, CJK, Devanagari, Thai, Hebrew, and Greek scripts during
      development, and cross-checked programmatically against all 8
      languages WI-11's own smoke corpus already validated
      (`en`/`ar`/`zh`/`ru`/`hi`/`ko`/`th`/`vi`) — byte-for-byte identical
      output. One archive member (`ku`, the Kurdish fallback via the legacy
      `udhr` zip, not `udhr2`) uses a materially different file format (no
      blank-line separators at all — every heading/sentence is its own
      line), so it gets a dedicated line-based extractor (second
      short/heading-length line found, then the line right after it).
      Result: **58/58 languages extracted successfully, zero skips** — ran
      clean on the first attempt against the real downloaded corpus, so the
      tool's built-in non-fatal skip-and-warn path (for "as many ... as
      practical") wasn't exercised in practice this run. Output:
      `test/fixtures/xlmr_parity_corpus_text.json` (61 entries — 58
      languages + 3 edge cases, see below). `pubspec.yaml` gained
      `archive`/`http` dev-only dependencies (mirroring
      `betto_lang_detector`'s own dev deps for the same tool pattern);
      `betto_builder_tools` was **not** added since this tool writes JSON,
      not generated Dart source, so no `dartfmt` formatting helper is
      needed. `dart analyze`/`dart format --set-exit-if-changed` both clean.
      Network note: `raw.githubusercontent.com` was **not** blocked in this
      session's sandbox (downloaded successfully on the first attempt) —
      no exception request was needed this time, though Q7's caveat that it
      could be blocked in other sandboxes still stands.
- [x] Add a few edge cases the UDHR text won't naturally cover: empty string, a
      very long string near the 512-token limit, a string with mixed scripts in
      one input.

      Done, in the same tool script (`_edgeCases`): `edge_empty` (`""`),
      `edge_mixed_script` (a hand-authored sentence mixing Latin, Arabic,
      Chinese, Cyrillic, Japanese, and Devanagari in one string), and
      `edge_long_near_512_tokens` (title + preamble + Articles 1–2 of the
      full English UDHR document, concatenated block-by-block until hitting
      a ~380-word target). The 380-word target is a length **estimate**,
      not a verified token count — derived from the Phase 0 spike's
      observed ~1.3 tokens-per-word ratio for plain English text in this
      vocabulary (its `en` entry: 30 words → 39 ids including `<s>`/`</s>`).
      This tool cannot run the real tokenizer to confirm the resulting
      count lands near 512 — that will only be known once the Python
      hand-off below returns real token ids for this entry; if it turns out
      to be off-target (too far from 512, or exceeding it so much that
      truncation dominates the test rather than approaching the limit), a
      follow-up adjustment to `_longEdgeCaseTargetWords` may be needed once
      real counts are in hand.
- [x] **Pause and ask the user to generate expected token ids** — run
      `AutoTokenizer.from_pretrained('intfloat/multilingual-e5-small')` over the
      tool script's extracted per-language text (plus the edge cases above) and
      share back the resulting token id arrays.

      Done. The user ran the Python step themselves (`transformers==5.13.0`,
      via a local venv) and produced
      `test/fixtures/xlmr_parity_corpus_ids.json` (61 entries, `truncation=False,
      padding=False` so ids are raw/unpadded — including 578 raw ids for
      `edge_long_near_512_tokens`, confirming it does exceed the 512 limit as
      intended for a truncation-exercising edge case). Spot-checked: `en` is
      39 ids, byte-identical to WI-11's own earlier `en` reference value —
      strong cross-consistency signal the two independently-generated
      fixtures (WI-11's 11-entry one, this plan's 61-entry one) agree.
- [x] Merge the extracted text and the expected ids into the final static
      fixture (`test/fixtures/xlmr_parity_corpus.json`) — no Python dependency
      in CI itself, ever, from this point on.

      Done. Merged via `jq` into one file, 61 entries, each
      `{"text": "...", "ids": [...]}`, keys sorted for a stable diff. The two
      intermediates (`xlmr_parity_corpus_text.json`,
      `xlmr_parity_corpus_ids.json`) were deleted rather than kept alongside
      the merged fixture — both are regeneratable on demand (the former via
      `tool/generate_xlmr_parity_corpus.dart`, the latter via the new
      `script/xlmr_parity_corpus_ids.py`, see below), and keeping three
      overlapping fixtures committed would just invite them drifting out of
      sync. The user's `script/` directory (their `xlmr_parity_corpus_ids.py`,
      `requirements.txt`, and a `.venv/`) was reorganized: `.venv/` excluded
      via `script/.gitignore` (verified with `git check-ignore`), the
      license header on the `.py` file corrected to match
      `header_template.txt` exactly (was missing the trailing period after
      "Authors"), and a doc comment + usage instructions added recording how
      to regenerate the fixture end-to-end. `requirements.txt`
      (`transformers==5.13.0`) and the script itself are kept committed for
      reproducibility, matching the project's convention of keeping one-off
      dev-generator tools around (e.g. `betto_lang_detector`'s
      `tool/generate_ngram_profiles.dart`).
- [x] Write a test that encodes every corpus entry through the Dart tokenizer
      (whichever branch Phase 0 landed on) and asserts byte-exact token id
      equality against the fixture. Wire into the existing CI workflow
      (`inferencing/.github/workflows/cicd.yml`).

      Done, following WI-11's own convention exactly: added to the same
      `integration_test_app/integration_test/inferencing_test.dart` file,
      inside the existing `'XlmRobertaTokenizer (multilingual-e5-small)'`
      group (reusing its already-downloaded real `tokenizer.json` and
      loaded `tokenizer` instance rather than duplicating the
      download/cache setup) — two new tests: byte-exact parity across all
      61 entries (comparing only the overlap when the real output is
      truncated, i.e. `edge_long_near_512_tokens`), and a check that it's
      the *only* entry reporting `truncated`. Symlinked the merged fixture
      into `integration_test_app/test/fixtures/xlmr_parity_corpus.json` and
      added it to that app's Flutter `assets:` list, matching the existing
      two WI-11 fixture symlinks exactly (same "`../` paths aren't visible
      to the Flutter asset bundler" rationale already documented there).
      **No changes needed to `.github/workflows/cicd.yml` itself** — this
      test lives in the same file/job WI-11 already wired into the
      `test-macos` job's `make cicd_macos` → `macos_test` → `flutter test
      integration_test/ --device-id macos` path, so it runs automatically
      as part of that existing step; the model-cache `actions/cache` step
      also already covers the E5 tokenizer.json (cached under the same
      `MODEL_CACHE_DIR` root, just a different subdirectory than BGE's).

      **Ran for real against the actual downloaded `tokenizer.json`** (`cd
      integration_test_app && flutter test integration_test/ --device-id
      macos`, macOS device, ~4s once models were cached) rather than just
      trusting the fixture — this caught a real bug on the first run:
      `edge_empty` failed with actual `[0, 6, 2]` vs. expected `[0, 2]`.
      Root cause: `XlmRobertaTokenizer`'s `_metaspace` step (from WI-11)
      unconditionally prepends a dummy-prefix space before replacing spaces
      with `▁`, so `""` became `"▁"` — and `"▁"` on its own is a valid
      standalone vocabulary piece (id 6), producing a spurious content
      token real `AutoTokenizer` never emits for empty input (HuggingFace's
      `tokenizers` Rust `Metaspace` pre-tokenizer only adds the prefix when
      pre-tokenizing an actual split/word; a fully empty input has none).
      **Fixed in `lib/src/xlmr_tokenizer.dart`**: `_metaspace` now returns
      empty input unchanged rather than injecting a dummy prefix. Updated
      the one now-stale WI-11 unit test that had asserted the old (buggy)
      behavior (`test/xlmr_tokenizer_test.dart`, "empty string ..." case) to
      match. This is squarely a Phase 1 fix, not Phase 2 scope — it's the
      byte-exact parity gate doing exactly its job (catching and driving a
      real tokenizer-correctness bug to a fix), not the separate
      `ModelCatalog`/`EmbeddingKind`/`ModelTokenizer` wiring Phase 2 covers.
      After the fix, all 22 tests in the file pass, including both new
      tests across the full 61-entry corpus.

**Phase 2 — `betto_inferencing` core changes**

*Precondition (Q6): only start this phase once a working,
`ModelTokenizer`-conformant XLM-R tokenizer exists — either Branch A's
wrapper (built directly in Phase 0/1) or, if the spike hit the Q6 hard gate,
the output of a separate, already-`Investigated`-and-implemented tokenizer-
port plan. Do not begin Phase 2 with an in-progress or unresolved Branch B.*

- [x] Add `EmbeddingKind` enum and `kind` parameter to `EmbeddingModel.embed()`
      (default `EmbeddingKind.document`).

      Done. `lib/src/embedding_model.dart`: `enum EmbeddingKind { document,
      query }`; `embed()` gained `{EmbeddingKind kind = EmbeddingKind.document}`
      — additive/source-compatible. Exported from the barrel
      (`betto_inferencing.dart`). Unit tests in `test/embedding_model_test.dart`
      (enum values, default-parameter behaviour via a hand-written recording
      `EmbeddingModel`).
- [x] Add `ModelTokenizer` interface (returning the existing `TokenizerOutput`
      directly — no new `ModelInput` type, see the Investigation revision
      above); make `BertTokenizer` implement it (no behaviour change — add
      tests confirming `bge-small-en-v1.5`'s existing golden outputs are
      byte-identical before/after); add `implements ModelTokenizer` to
      WI-11's `XlmRobertaTokenizer` (already returns `TokenizerOutput` — a
      one-line, mechanical addition, not a redesign).

      Done. New `lib/src/model_tokenizer.dart` (`abstract interface class
      ModelTokenizer { TokenizerOutput encode(String text); }`).
      `BertTokenizer implements ModelTokenizer` — mechanical, `encode()`
      unchanged internally, `@override` added. `XlmRobertaTokenizer implements
      ModelTokenizer` — one line, per the plan. `test/bert_tokenizer_test.dart`
      gained a "ModelTokenizer conformance" group: encodes every existing
      fixture case (including truncation/empty-input edge cases) via both the
      concrete `BertTokenizer` reference and a `ModelTokenizer`-typed reference
      to the same instance and asserts byte-identical `inputIds`/
      `attentionMask`/`tokenTypeIds`/`truncated` — proves no behavioural
      change. `test/xlmr_tokenizer_test.dart` gained a compile-time-only
      conformance check (a live instance needs the real ~17 MB
      `tokenizer.json`, so this is asserted structurally rather than at
      runtime — documented in the test file). New `test/model_tokenizer_test.dart`
      also proves the interface is implementable by third-party code (a
      hand-written `ModelTokenizer`), not just this package's own two
      tokenizers.
- [x] Wire the `XlmRobertaTokenizer` as the second `ModelTokenizer`
      implementation. Under **Branch A** this is the thin
      `dart_sentencepiece_tokenizer` wrapper built here; under **Branch B** the
      follow-on port plan has already produced a `ModelTokenizer`-conformant
      tokenizer (Phase 2 precondition above), so this step is a
      wiring/verification check, not new tokenizer code.

      Done (Branch B path — WI-11 already produced `XlmRobertaTokenizer`;
      this step was the wiring/verification check). Verified end-to-end via
      the real macOS integration test (see below): `OnnxEmbeddingModel.load()`
      correctly constructs and uses `XlmRobertaTokenizer` for
      `multilingual-e5-small`.
- [x] `OnnxEmbeddingModel.load()`: select tokenizer via
      `meta['tokenizerFamily']`; `embed()`: apply `meta['queryPrefix']`/
      `['documentPrefix']` based on `kind`, no-op when the keys are absent.

      Done, with one addition beyond the literal wording: `tokenizerFamily`
      resolution is a synchronous, pre-I/O guard (`_tokenizerFamily`) that
      throws `ArgumentError` for a missing or unrecognised value — deliberately
      not defaulted, matching the plan's Q2 rationale ("a third family can't
      silently misresolve"). The prefix logic is exposed as `@visibleForTesting
      static String applyPrefix(text, kind, spec)` so it's unit-testable
      without a live ORT session (the pattern this repo already uses for
      `XlmRobertaTokenizer.normalizeForTokenization`) — see
      `test/onnx_embedding_model_test.dart`.
- [x] **Hand-off point (Q7):** download `multilingual-e5-small`'s `model.onnx`
      (~470 MB, plain fp32 — see Investigation) and tokenizer asset(s) from
      `huggingface.co` and compute their real SHA-256 digests — outside the
      typical implementer sandbox's network allowlist; ask for an exception
      or have the user fetch/verify these if blocked. Register
      `multilingual-e5-small` in `ModelCatalog` with the resulting real
      checksums (not placeholders); add `'tokenizerFamily': 'bert'` to the
      existing BGE entry for consistency.

      Done — this session's sandbox had `huggingface.co` reachable (via
      plain `curl`/Dart `http`, no exception needed), so no user hand-off was
      required. Built `tool/register_model.dart` (new, standalone-runnable
      Dart tool: downloads each asset from the exact `resolve/main/...` URL
      `ModelSpec` uses, streams to a local cache to avoid buffering ~470 MB in
      memory, computes SHA-256 via `package:crypto`'s chunked API — the same
      algorithm/library `ModelDownloader._isValid` uses for verification, so a
      printed hash is guaranteed to match a real download). Ran it for real:
      `model.onnx` (470,268,510 bytes) →
      `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`;
      `tokenizer.json` (17,082,730 bytes) →
      `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`.
      Cross-checked independently via `shasum -a 256` on the downloaded
      files — matches. Registered `multilingual-e5-small` in
      `lib/src/model_catalog.dart` with these real checksums, `meta:
      {'dimensions': 384, 'tokenizerFamily': 'xlmr', 'queryPrefix': 'query: ',
      'documentPrefix': 'passage: '}`. Added `'tokenizerFamily': 'bert'`
      explicitly to `bge-small-en-v1.5`'s existing entry.
- [x] **(Q8)** Add an `actions/cache@v5` step to `cicd.yml`'s `test-macos` job
      for E5's model files, mirroring the existing BGE cache step (`:80-83`)
      — key `models-multilingual-e5-small-<E5's real onnx sha256>`. Confirm
      `make cicd_macos` actually exercises the new multilingual integration
      test (not just BGE's), and that the shared model cache directory
      (`~/.cache/betto_inferencing_models`) holds both models without
      collision (distinct filenames per model, but verify).

      Done. Added a second `actions/cache@v5` step keyed
      `models-multilingual-e5-small-ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`,
      same `~/.cache/betto_inferencing_models` path as BGE's step (confirmed
      no collision: `ModelDownloader.ensure` nests each model under a
      `<cacheDir>/<model-id>/` subdirectory keyed by `ModelSpec.id`, so
      `bge-small-en-v1.5/` and `multilingual-e5-small/` never share a file).
      Confirmed `make cicd_macos` → `flutter test integration_test/
      --device-id macos` exercises the new `'OnnxEmbeddingModel
      (multilingual-e5-small)'` test group by actually running it on this
      machine's real macOS device (see Tests item below) — not just inferred
      from the workflow file.
- [x] **Remove `bge-m3-v1.0`** from `_catalog`/`_validated` and its doc comment
      (Q5). **Add a permanent `placeholder-model` entry** (`validated: false`
      forever, non-resolvable `example.invalid` URLs, a doc comment explaining
      it exists solely as a test fixture and must never be flipped to
      validated). Rename the ~8 call sites across
      `test/model_catalog_test.dart`, `test/model_downloader_test.dart`,
      `example/model_catalog.dart`, and
      `integration_test_app/integration_test/inferencing_test.dart` from
      `bge-m3-v1.0` to `placeholder-model` — same assertions, same gating
      behaviour, now against a fixture with no risk of ever becoming a real (and
      thus no-longer-unvalidated) model.

      Done. `_bgeM3V10`/its catalog+validated entries/doc comment removed;
      `_placeholderModel` added (`id: 'placeholder-model'`, `validated: false`
      permanently, `https://example.invalid/placeholder/...` URLs, doc comment
      matching Q5's resolution). All identified call sites renamed
      (`test/model_catalog_test.dart` — plus new dedicated
      `multilingual-e5-small` assertions; `test/model_downloader_test.dart`'s
      "permits download for a registered model" test;
      `example/model_catalog.dart`'s `isKnown`/error-handling demo;
      `integration_test_app/integration_test/inferencing_test.dart`'s
      `ModelCatalog` group) — same assertions, same gating behaviour, verified
      by re-running the full `dart test` suite (all green) plus the real
      macOS integration test.
- [x] Tests: `ModelTokenizer`/`EmbeddingKind` unit tests; `ModelCatalog` lookup
      tests for the new entry; an integration test (gated the same way existing
      ORT integration tests are, requiring live model assets) embedding known
      multilingual sentences and checking cross-lingual cosine similarity is
      meaningfully higher than an unrelated-sentence pair — a coarse sanity
      check that the model is actually working, not just that it loads.

      Done. Unit tests: `test/embedding_model_test.dart` (`EmbeddingKind`,
      `embed()` default/override), `test/model_tokenizer_test.dart`
      (interface conformance), `test/onnx_embedding_model_test.dart`
      (`applyPrefix` — document/query, both-absent no-op, only-one-set
      no-op cases; `_tokenizerFamily`'s `ArgumentError` guard — missing key,
      unrecognised value, valid value passes through), `test/model_catalog_test.dart`
      (new `multilingual-e5-small` group: dimensions, `tokenizerFamily`,
      `queryPrefix`/`documentPrefix`, pinned real checksums, HF URL). New
      integration test group `'OnnxEmbeddingModel (multilingual-e5-small)'` in
      `integration_test_app/integration_test/inferencing_test.dart`: model
      identity/dimensions, unit-norm output, `EmbeddingKind.document` vs
      `.query` producing different embeddings for identical text (proves the
      prefix is actually applied), and the cross-lingual check itself — an
      English document sentence ("The cat sat on the mat.") scores higher
      against a same-meaning query in French/German/Spanish than against an
      unrelated-topic (stock-market volatility) query in that same language,
      for all three languages. **Ran for real** (`cd integration_test_app &&
      MODEL_CACHE_DIR=... flutter test integration_test/ --device-id macos`,
      real macOS device, real ORT inference, real downloaded model files) —
      all 28 tests passed, including the new group. `dart test` (143/143),
      `dart analyze`, `dart format --set-exit-if-changed`, and `make
      pre_commit` all clean; package-wide coverage 95.2% (`onnx_embedding_model.dart`
      71.4% — the uncovered lines are the pre-existing private
      constructor/`dispose`/cacheDir-download-branch pattern already present
      before this plan, gated behind `coverage:ignore` where a live ORT
      session is unavoidable).
- [x] Flip `'multilingual-e5-small': false` → `true` in `_validated` once all of
      the above passes.

      Done, after (not before) the real macOS integration test passed —
      confirmed by running the integration suite both before the flip
      (the new E5 group fails fast with the expected `UnsupportedError`) and
      after (all 28 tests pass, including real cross-lingual inference).
- [x] `make pre_commit` in `inferencing`; update `CHANGELOG.md`. (Under Branch B
      the porting-provenance `NOTICE` is authored by the follow-on port plan
      alongside the port itself — not added here; see Q6 and the provenance note
      in Investigation.)

      Done. `make pre_commit` (format_check, analyze, license_check, test)
      all green. `CHANGELOG.md` gained a new `0.1.0-dev.3` entry (confirmed at
      implementation time that `0.1.0-dev.2` was already published to pub.dev
      on 2026-07-09 — this is a genuinely new version, not landing in an
      unreleased dev.2 as the Investigation section's open question
      anticipated). `pubspec.yaml` bumped to `0.1.0-dev.3`. No `NOTICE`
      changes — correct per Branch B having already produced its own
      `NOTICE` entry in WI-11. Also updated, since they were directly touched
      by this phase and would otherwise mislead: `README.md` (features list,
      models table, new cross-lingual usage example, version bumps),
      `CLAUDE.md`'s "Implementation Status", and `docs/spec/README.md`
      (`EmbeddingKind`/`ModelTokenizer`/`XlmRobertaTokenizer` sections, models
      table, error-handling table, dependencies table).
- [x] **Pause and ask the user to review and publish the new `betto_inferencing`
      version to pub.dev** (same hand-off pattern as WI-6's
      `betto_icu`/`betto_lexical` releases).

      Reached — see this plan's Summary section / the implementer's final
      report to the user. `betto_inferencing` has **not** been published;
      that is the user's action per this project's convention (memory:
      "pub.dev/package publish always user's job"). This session also did not
      commit, push, or open a PR in the `inferencing` repo — per this agent's
      own operating rules, that requires `kmdb-qa` sign-off and the
      `kmdb-pre-commit` gate first, and this session has no mechanism to
      invoke those agents itself (no Task/agent-launch tool available). The
      branch `wi4-phase2-model-registration` in `~/development/bettongia/inferencing`
      has all changes committed to the working tree but not yet to git.

**Phase 3 — `kmdb` pipeline wiring**

_Requires Phase 2's `betto_inferencing` version to be published and pinned
first._

- [x] Bump `betto_inferencing` constraint in `packages/kmdb/pubspec.yaml` and
      root `pubspec.yaml` `dependency_overrides`. **Note:**
      `packages/kmdb/pubspec.yaml` itself declares `betto_inferencing:` with no
      version (inherits the workspace's `dependency_overrides` entirely), so
      there was nothing to literally edit there — only the root
      `pubspec.yaml` override (`^0.1.0-dev.1` → `^0.1.0-dev.3`) needed
      changing. Also discovered: pub's caret-range semantics treat a
      prerelease lower bound (`^0.1.0-dev.1`) as admitting *any* later
      prerelease below the next breaking version, so once `0.1.0-dev.3` was
      published to pub.dev, a fresh `dart pub get` against the old
      `^0.1.0-dev.1` constraint text already resolved to `dev.3` — the
      constraint bump is a documentation/intent change, not what actually
      gates the resolved version.
- [x] `vec_manager.dart` — add `kind` to the private `_embed(String text)` at
      `:845` (forwarded to `_model.embed` at `:847`); pass `document` from
      `:252`/`:309`/`:380`, `query` from `:584`. Verified against current
      source unchanged from the plan's line references.
- [x] `vault_searcher.dart` — same for the semantic vault query path (`as
      dynamic` call at `:443`, embed at `:444`); import the `EmbeddingKind`
      enum from `betto_inferencing` in this file (Q9 — acceptable, unlike the
      model class the `Object?`/`as dynamic` seam avoids); add a test
      asserting the `kind` argument is actually passed (not silently dropped
      by the dynamic dispatch — this fails at runtime, not compile time, if
      missed). Verified against current source unchanged from the plan's line
      references.
- [x] `vault_search_manager.dart` — same for its index-time embed call sites
      at `:599→:610` and `:780→:805` (not `:862`, which is
      `_checkModelVersion` and needs no change). Verified against current
      source unchanged from the plan's line references.
- [x] Tests: for a model whose `ModelSpec.meta` carries `queryPrefix`/
      `documentPrefix`, confirm indexed text and query text are prefixed
      differently; for `bge-small-en-v1.5` (no prefix keys), confirm behaviour
      is unchanged. Implemented as an `EmbeddingKind` wiring test group in
      `test/search/semantic/vec_search_integration_test.dart` (a
      `_PrefixSimulatingEmbeddingModel` proves index-time and query-time
      vectors differ when `kind` reaches the model; a plain no-branch fake
      proves an unchanged, near-perfect self-match — the residual gap there
      is accounted-for SQ8 quantisation noise, not an `EmbeddingKind` effect).
      Additional `kindsSeen`/`lastKind` assertions added directly to
      `vec_manager_test.dart`, `vault_search_manager_test.dart`, and the
      mandatory dynamic-dispatch regression test in `vault_searcher_test.dart`
      (Q9).
- [x] Docs: `docs/spec/22_semantic_search.md` (Model Catalog table entry,
      `EmbeddingKind`/prefix behaviour, stale bundled-assets correction, model
      size callout), `docs/roadmap/0_06.md` WI-4 status,
      `docs/proposals/vault_search.md` §10.3 cross-reference note.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` in each touched repo — confirm >90% (`kmdb`'s bar per
      `CLAUDE.md`) / >95% (this plan's own target, see template) on all new
      files. `kmdb` overall: 94.8% (10632/11213 lines). All touched files
      (`vec_manager.dart`, `vault_searcher.dart` 211/213 = 99.1%,
      `vault_search_manager.dart`) individually well above 90%.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off on the `kmdb`-side
      changes (spec alignment, doc comments, test coverage/adequacy, code
      health). Resolve every blocking item before proceeding. Do not open a PR
      until sign-off is received.
      **PAUSED HERE (2026-07-09):** this implementing session's tool list has
      no `Task`/`Agent`-style tool available, so `kmdb-qa` cannot be invoked
      directly (same gap recorded for the WI-6/WI-10 sessions — see
      `.claude/agent-memory/kmdb-plan-implement/feedback_no_agent_tool.md`).
      All implementable work (Phase 3 code, tests, docs, coverage, and the
      mechanical `make pre_commit` gate below) is complete and green. Do
      **not** commit, push, or open a PR until `kmdb-qa` has actually signed
      off — the orchestrating session/user needs to invoke `kmdb-qa` (and
      then `kmdb-pre-commit` for final confirmation) and relay the result
      back before this plan can proceed to commit.
- [x] Run `make pre_commit` in `kmdb` — format, analyze, license_check, tests
      all green. (`inferencing` and, if touched, any other sibling repo have
      their own equivalent gate — run it there too before publishing.) Ran
      directly via Bash (mechanical gate only, not a substitute for
      `kmdb-qa`'s judgment call): `format_check` (0 files changed),
      `analyze` (0 issues, all 5 packages), `license_check`
      (`addlicense --check` clean), `pre_commit_test` (2317 kmdb tests
      passed, 12 E2E skipped as expected) — all green.
- [x] Verify licence headers on all new files (2026) in every touched repo. No
      new source files were created in this phase (`git status --porcelain`
      shows only modifications to existing files, plus the two plan `.md`
      files carried over from the Phase 0–2 precondition bookkeeping) — no new
      license headers were needed. `license_check` above confirms all existing
      headers remain intact.

## Plan review (2026-07-07, kmdb-plan-reviewer)

This is a strong, unusually well-investigated plan. Q1–Q5 are genuinely
resolved with source evidence, the file/line references are mostly accurate
(spot-checked below), the Q5 `placeholder-model` solution is proportionate and
well-argued, and the spec-staleness catches (bundled-assets claim in §22) are
correct. The bulk-of-work-is-in-`betto_inferencing` framing checks out: the
384-dimension hard-coding my earlier review notes flagged in `kmdb` is **gone**
— `384` now appears only in doc comments in `packages/kmdb/lib` (verified), so a
same-dimension E5 swap needs no dimension generalisation in `kmdb`.

Verified against current source:

- `vec_manager.dart` embed sites are `:252`/`:309`/`:380` (index) and `:584`
  (query), all funnelling through the private `_embed(String text)` at `:845`
  → `_model.embed(text)` at `:847`.
- `vault_searcher.dart` field is `Object?` at `:105`, cast `as dynamic` at
  `:443`, embed at `:444` — matches the plan.
- `vault_search_manager.dart` field is typed `EmbeddingModel?` (imports it at
  `:41`) — matches the plan's "typed, not dynamic" distinction.
- `betto_inferencing`'s CI **does** run ORT integration tests: `cicd.yml` has a
  `test-macos` job that caches the ORT binary + model files and runs
  `make cicd_macos` against real downloaded models. So the Phase 2 inference
  test can legitimately gate `validated: true` in that repo's CI — unlike
  `kmdb`, where ORT tests auto-skip under JIT and are RC-only. Good news, with
  one omission (Q8 below).

The following need resolution before `Investigated`.

- [x] **Q6 — Branch B (port the tokenizer) is the plan's own predicted-likely
      outcome, yet it is specified only as a single hand-wave checklist item.**
      Q1 states parity failure is "most likely at the charsmap-normalizer or
      fairseq-remapping steps," and Phase 0's decision bullet names those as the
      "expected failure points" for taking Branch B. But Branch B —
      hand-porting an XLM-R SentencePiece/Unigram tokenizer (precompiled
      charsmap normaliser, Metaspace pre-tokenizer, Unigram Viterbi, fairseq id
      remap, `<s>…</s>` post-processing) from `transformers.js`, cross-checked
      against Rust `tokenizers`/`spm_precompiled` — is a large, design-heavy,
      error-prone effort. It is not mechanical work, and "scaffold
      `xlmr_tokenizer.dart` per the components listed in the roadmap" is not an
      implementable specification. **A plan whose probable path hands an
      open-ended tokenizer port to a mechanical (Sonnet) implementer does not
      clear the `Investigated` bar for that path.** This was the central
      readiness gap.

      **Resolved (user decision): hard gate — option (a).** If the Phase 0
      spike resolves to Branch B, implementation **stops**; a dedicated
      tokenizer-port design pass (a plan revision or a follow-on plan,
      reviewed by `kmdb-plan-reviewer` to its own `Investigated` status) must
      happen before any port code is written. Phase 0's last checklist item
      is now written as an explicit `HARD GATE` — it no longer flows straight
      from "Branch B" into "scaffold …". This is the honest, lower-risk
      choice: it keeps this plan's own scope mechanical and implementable as
      written, at the cost of a likely second planning round if the spike
      does land on Branch B (which the plan's own analysis says is the more
      probable outcome — accepted as a known, deliberate trade-off, not an
      oversight).

      **The gate fired.** The follow-on plan is
      `plan_0_06_wi11_xlmr_tokenizer.md` (WI-11, `docs/roadmap/0_06.md`),
      Status: Investigated (Phase 0 only; Phase 1+ still pending its own
      review pass). WI-11 also revised the package boundary this plan
      originally assumed — the XLM-R tokenizer lands directly inside
      `betto_inferencing`, not a separate published package. See the status
      line at the top of this plan for the current detail.

      **Consequence for scope, made explicit:** "Files this plan touches"
      and Phase 2 below now describe `lib/src/xlmr_tokenizer.dart` as
      in-scope for *this* plan only under Branch A (a thin wrapper around
      `dart_sentencepiece_tokenizer`). Under Branch B, that file is produced
      by the separate follow-on port-design plan, not by this plan's Phase 2
      — Phase 2 onward in *this* plan assumes a working, parity-gated,
      `ModelTokenizer`-conformant XLM-R tokenizer already exists by the time
      it starts, however it was produced.

- [x] **Q7 — Which steps require network hosts the implementer's sandbox does
      not allow, and are they all marked as pauses/hand-offs?** Only the Python
      token-id step is currently flagged. But the sandbox allowlist is
      `github.com`/`pub.dev`/`chromium.googlesource.com` only — it does **not**
      include `huggingface.co` or `raw.githubusercontent.com`. So each of these
      is an out-of-sandbox action the implementer cannot do unattended: (i) the
      Phase 0 spike's download of E5's `tokenizer.json`/`sentencepiece.bpe.model`
      from `intfloat/multilingual-e5-small` (HF); (ii) the Phase 2 registration
      step's download of `model.onnx` (~470 MB) and computation of its SHA-256 +
      the tokenizer asset SHA-256 (HF); (iii) the Phase 1 corpus tool's download
      of the NLTK UDHR zips — confirmed to fetch from
      `raw.githubusercontent.com/nltk/nltk_data/...` (the tool is a one-off dev
      script run locally by the implementer, not by CI, so this hits the
      sandbox). Enumerate these as explicit pause/hand-off points alongside the
      Python step, so implementation does not stall mid-phase. (CI itself has
      open network, so the committed fixtures and cached models are fine once
      produced — this concerns only the local generation/registration actions.)

      **Resolved:** all three are added as explicit pause/hand-off checkboxes in
      Phase 0 (HF tokenizer asset download), Phase 1 (NLTK UDHR zip download —
      actually unblocked, see note below), and Phase 2 (HF `model.onnx` +
      checksum computation) below. Each notes the specific out-of-allowlist
      host so the implementer asks for a sandbox exception or hands the
      download to the user rather than silently stalling. One correction from
      spot-checking: `raw.githubusercontent.com` did resolve successfully
      during this planning session's own research (`WebFetch`/`WebSearch`
      calls reached HF and GitHub-hosted content without incident) — but the
      *implementer's* sandbox is a separate, possibly more restrictive
      environment than this planning session's, and its exact allowlist is not
      guaranteed to match, so the pause points stay in as a safe default;
      worth confirming against the implementer's actual sandbox config at
      Phase 0 kickoff rather than assuming either way.

- [x] **Q8 — Adding E5 to `betto_inferencing`'s macOS CI model cache.** The
      `test-macos` job in `cicd.yml` caches model files under a key pinned to
      BGE Small's SHA (`models-bge-small-en-v1.5-<sha>`, confirmed at
      `cicd.yml:83`, keyed on the exact `sha256` pinned in
      `model_catalog.dart`'s `_bgeSmallEnV15.files['onnx']`). The Phase 2
      multilingual inference test needs E5's ~470 MB `model.onnx` present.
      Without a cache entry (mirroring the BGE one, keyed
      `models-multilingual-e5-small-<sha256>` on E5's real onnx checksum) the
      macOS job either re-downloads 470 MB every run or the test can't find
      the model.

      **Resolved:** added as an explicit Phase 2 checklist item — add a second
      `actions/cache@v5` step (or extend the existing one) in `cicd.yml`'s
      `test-macos` job keyed on E5's real `model.onnx` SHA-256, confirm
      `make cicd_macos` actually exercises the new multilingual integration
      test (not just BGE's), and confirm the model cache directory
      (`~/.cache/betto_inferencing_models`) holds both models' files without
      collision (different filenames per model, so this should be safe, but
      verify rather than assume).

- [x] **Q9 — `vault_searcher.dart`: how does `kind: EmbeddingKind.query` cross
      the `as dynamic` seam?** The field is deliberately `Object?` to keep
      `betto_inferencing`'s generated model type out of this file's type graph
      (`:105-107`). Passing `kind: EmbeddingKind.query` through the dynamic call
      at `:444` requires *referencing* the `EmbeddingKind` symbol, i.e. importing
      it from `betto_inferencing`. Decide and record: import `EmbeddingKind` here
      (a lightweight enum — acceptable, distinct from the model *class* the file
      avoids) is the obvious answer, but the plan leaves it as "thread carefully"
      without stating the import decision. Also note the failure mode the planned
      test must catch: through dynamic dispatch, a mis-named or dropped `kind:`
      argument fails at *runtime* (NoSuchMethodError / silent default), not at
      compile time — the test the plan already calls for is what makes this safe,
      so keep it mandatory.

      **Resolved: import `EmbeddingKind` in `vault_searcher.dart`.** It's a
      plain enum with no ORT/FFI weight — importing it doesn't reintroduce the
      thing the `Object?`/`as dynamic` seam was built to avoid (pulling the
      full `betto_inferencing` model class, and by extension its native
      dependencies, into this file's type graph). Recorded explicitly in
      "Files this plan touches" and Phase 3 below, along with the mandatory
      runtime-dispatch test Q9 calls for.

- [x] **Q10 — Call-site precision fixes (mechanical, but the plan sells itself
      on precise references).** (a) `vault_search_manager.dart:862` is
      `_checkModelVersion`, which reads `model.modelId` — it is **not** an
      `embed()` call site and needs no `kind`. The actual index-time embed calls
      are `:599→:610` and `:780→:805` (two, not three). Correct Phase 3 /
      "Files this plan touches" so the implementer does not hunt for a
      nonexistent embed at `:862`. (b) Name the `vec_manager` seam: the change is
      "add a `kind` parameter to the private `_embed(String text)` at `:845` and
      forward it to `_model.embed`," then pass `document` at `:252`/`:309`/`:380`
      and `query` at `:584` — the current wording ("thread `kind` through the
      call sites") is slightly imprecise since all four calls funnel through
      `_embed`.

      **Resolved:** "Files this plan touches" and Phase 3 below corrected to
      the verified line references — `vault_search_manager.dart` embed sites
      at `:599→:610` and `:780→:805` only (not `:862`, which is
      `_checkModelVersion` and needs no change); `vec_manager.dart`'s actual
      change point is the private `_embed(String text)` at `:845` (forwarding
      to `_model.embed` at `:847`), called from `:252`/`:309`/`:380`
      (document) and `:584` (query).

**Non-blocking observations (address if convenient, not gating):**

- The `dev.2`-vs-next-version ambiguity for `betto_inferencing` is correctly
  left to implementation time; fine.
- Publishing `betto_inferencing` is (correctly) a user hand-off, matching the
  project rule that pub.dev publishing is always the user's action.
- The E5-prefix correctness window (E5 registered in `betto_inferencing` before
  `kmdb` Phase 3 wires `kind:`) is real but low-risk: E5 is opt-in via
  `EmbeddingModelConfig`, no CLI writes that config, and Phase 3 is sequenced
  after publish. A one-line note that `bge-small-en-v1.5` remains `kmdb`'s
  default and E5 is opt-in would close it explicitly.

Once Q6–Q10 are answered (Q6 in particular — it is the one that decides whether
this is a spike-first plan that stays mechanical, or a plan that will need a
second design pass), this promotes cleanly to `Investigated`. The Phase 0/1/2/3
structure, the parity-gate testing strategy, and the Q5 catalog surgery are all
already at the right level of detail.

### Second pass (2026-07-07, kmdb-plan-reviewer) — promoted to `Investigated`

All five open questions (Q6–Q10) are adequately resolved:

- **Q6 (central gap):** The hard-gate resolution is the right call and is now
  correctly wired into Phase 0's final checklist item, the `xlmr_tokenizer.dart`
  entry in "Files this plan touches," and Phase 2's opening precondition. The
  plan's mechanical scope is now honest: under Branch A it is fully
  implementable as written; under Branch B it stops cleanly at a reviewed
  hand-off rather than dropping an open-ended port on a Sonnet implementer.
- **Q7/Q8/Q9/Q10:** Network hand-offs enumerated at all three points; the E5 CI
  cache step is specified against the real `cicd.yml:80-83` precedent; the
  `EmbeddingKind` enum-import decision is recorded; and the call-site line
  references (`vec_manager` `_embed` at `:845`; `vault_search_manager`
  `:599→:610`/`:780→:805`, not `:862`) match current source.

**Consistency fixes applied this pass (leftover Branch B references that the Q6
hard gate had made stale):** Phase 1's "required regardless of branch" note now
distinguishes Branch A (runs here) from Branch B (owned by the follow-on port
plan, whose acceptance criterion it is); Phase 2's tokenizer-wiring step and the
`NOTICE`/third-party-provenance references (Phase 2 checklist, "Files this plan
touches," Investigation) now consistently attribute all Branch B tokenizer and
provenance work to the follow-on plan, not this one. No remaining text implies
Branch B port work happens unconditionally within this plan.

**Non-blocking (deferred to implementation, not gating):** the E5-is-opt-in /
`bge-small-en-v1.5`-stays-default one-liner suggested above would tidily close
the prefix-correctness window between Phase 2 (E5 registered) and Phase 3
(`kind:` wired), but it is documentation polish, not a readiness blocker.

The plan clears the implementation-readiness bar for Branch A and defines a
clean, reviewed stop for Branch B. Promoted to `Investigated`.

## Summary

_(To be completed during implementation.)_
