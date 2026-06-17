# Extract `betto_lexical` and `betto_inferencing` as standalone packages

**Status**: Investigated

**PR link**: _pending_

## Problem statement

`kmdb_lexical` and `kmdb_inferencing` carry the `kmdb_` prefix, but neither
package is KMDB-specific. `kmdb_lexical` provides general-purpose tokenisation,
stemming, and stop-word utilities with no dependency on KMDB. `kmdb_inferencing`
provides BERT tokenisation, ONNX-backed embedding inference, SQ8 quantisation
helpers, and a model catalog — all of which are reusable across any Bettongia
application or third-party Dart project that needs local inference.

The pattern of extracting reusable components into the `betto_*` namespace
on pub.dev is already established (`betto_icu`, `betto_onnxrt`, `betto_zstd`,
`betto_charset_detector`). Both packages belong in that family.

There is a second motivation: the vault search proposal
(`docs/proposals/vault_search.md`) plans to extend `kmdb_inferencing` with
multilingual embedding models (`multilingual-e5-small`, `bge-m3`) and
a SentencePiece/XLM-R tokenizer (§10.3). Hosting this work in a `kmdb_*`
package is architecturally wrong — these are generic NLP components. Renaming
now ensures the multilingual work lands in the right home.

## Open questions

- [x] **Q1 — Workspace member vs published package (blocker).** **RESOLVED
  (user, 2026-06-17): publish to pub.dev.** Both `betto_lexical` and
  `betto_inferencing` move out of this workspace into their own repositories and
  are consumed here as published pub.dev packages, mirroring `betto_icu` and
  `betto_onnxrt`. End-state wiring (matching the current `betto_*` family as of
  HEAD `a1b4d9e`, where all `betto_*` packages are published):
  - The packages are **removed from the `workspace:` list** in the root
    `pubspec.yaml` — they are no longer workspace members.
  - Each is pinned in the root `dependency_overrides` at `^0.1.0-dev.1`
    (e.g. `betto_lexical: ^0.1.0-dev.1`, `betto_inferencing: ^0.1.0-dev.1`),
    alongside the existing `betto_onnxrt: ^0.1.0-dev.1` etc.
  - Consumers declare them **bare** in their own `dependencies:`
    (`betto_lexical:` / `betto_inferencing:` with no version constraint); the
    root override supplies the version.
  - This requires the Stage A / Stage gate / Stage B structure used by the
    `betto_icu` and `betto_onnxrt` extractions: create + publish the standalone
    repos first (manual gate), then wire them into KMDB. The implementation plan
    below has been restructured accordingly.
- [x] **Q2 — Scope of historical-doc rewrites.** **RESOLVED (user, 2026-06-17):
  freeze — leave as-is.** `docs/proposals/implemented/` and `docs/reviews/` are
  frozen historical records. This plan does **not** update
  `docs/proposals/implemented/betto_icu.md`,
  `docs/proposals/implemented/betto_onnxrt.md`, or
  `docs/reviews/roadmap-review-2026-06-05.md`. The `betto_icu.md` checklist item
  has been removed from the plan; `betto_onnxrt.md` and the review are likewise
  left untouched. (`docs/proposals/vault_search.md` is an *active* proposal, not
  an implemented/frozen one, so it is still updated — see Phase 3.)

## Review (2026-06-17, kmdb-plan-reviewer)

Overall: the problem statement is sound and the approach is correct. Extraction
into the `betto_*` namespace is the right call, and flipping the `EmbeddingModel`
dependency arrow so `kmdb` consumes `betto_inferencing` (rather than the reverse)
is the architecturally correct resolution — it matches the interface's own
stated intent. The plan is admirably thorough on doc/spec touchpoints. However,
**it is not yet mechanically executable**: it contains several factual errors
against the current code and two unresolved decisions. These would force a
Sonnet implementer to either guess or produce broken output. Details below.

### R1 — Dependency wiring is wrong / inconsistent (blocker)

The plan repeatedly instructs "add `betto_lexical:` / `betto_inferencing:` to
`dependency_overrides:` (pointing to the local workspace member)" (Investigation
consumer map; §1.2; §2.6). This is **not** how in-workspace members are wired.

Verified against `pubspec.yaml` and `packages/kmdb/pubspec.yaml`:
- In-workspace members (`kmdb`, `kmdb_lexical`, `kmdb_inferencing`, ...) use
  `resolution: workspace` and are listed under the root `workspace:` block.
  Consumers declare them **bare** (`kmdb_lexical:` with no version). They are
  **not** in `dependency_overrides`.
- `dependency_overrides` in this repo pins **published pub.dev** `betto_*`
  packages at `^0.1.0-dev.x` (Pattern B): `betto_common`, `betto_zstd`,
  `betto_onnxrt`, etc.

So the correct mechanical change for an in-workspace rename is: update the
`workspace:` list entry (`- packages/kmdb_lexical` → `- packages/betto_lexical`)
and keep the bare consumer dep. Adding a `dependency_overrides` entry is only
correct if the package is actually published. The plan must resolve **Q1** and
then make every wiring step consistent with the chosen end state. As written,
following the plan literally would add bogus override entries.

Note also: the existing `betto_lexical`-to-be already depends on
`betto_icu: ^0.1.0-dev.1` — i.e. it consumes a *published* betto package while
itself being a workspace member. That is fine and shows the two mechanisms
coexist; it is not a contradiction to fix, just context for Q1.

### R2 — `math_utils_test.dart` import claim is wrong (would break the build)

§2.5 says `packages/.../test/math_utils_test.dart` "imports private `src/` path
— no package name substitution needed here, just confirm." That is **false**.
The actual import is:

```dart
import 'package:kmdb_inferencing/src/math_utils.dart';
```

The **package name** is part of that URI and must become
`package:betto_inferencing/src/math_utils.dart`. Left unchanged, the package
won't resolve and the test won't compile. Fix the checklist item to perform the
substitution.

### R3 — `kmdb_lexical`'s own test files are missing from the plan

The Investigation consumer map and §1.3 enumerate only `kmdb` and
`kmdb_inferencing` consumers. They omit the package's **own** three test files,
all of which import `package:kmdb_lexical/lexical.dart` and break under both the
package rename and the barrel rename:

- `packages/kmdb_lexical/test/stemmer_test.dart`
- `packages/kmdb_lexical/test/default_tokenizer_test.dart`
- `packages/kmdb_lexical/test/stopwords_test.dart`

Add explicit checklist items: `package:kmdb_lexical/lexical.dart` →
`package:betto_lexical/betto_lexical.dart` in each. (There is no
`kmdb_lexical/example/` directory, confirmed.)

### R4 — `EmbeddingModel` interface description is stale; member count wrong

The interface at `packages/kmdb/lib/src/search/embedding_model.dart` now has
**four** members: `modelId`, `dimensions`, `embed`, `dispose`. §2.2 says "Keep
all three members (`modelId`, `dimensions`, `embed`, `dispose`)" — the prose says
three but lists four; the matching memory note ([[reference_embedding_model_seams]]
pre-dated the modelId/dimensions addition). Trivial to fix, but symptomatic of
the plan being written against a stale mental model.

More substantively, §2.2's copy instructions are imprecise:
- It says "Remove the `import 'dart:typed_data'` (keep it — it is still
  needed)." This is self-contradictory. State plainly: **keep** `dart:typed_data`
  (it backs `Float32List`).
- The interface doc comment references `VecManager`, `KmdbDatabase.open`, and
  `KmdbDatabase.close` (the latter in the `dispose` doc). §2.2 mentions
  `VecManager` and `KmdbDatabase.open` but not the `KmdbDatabase.close` reference
  in the `dispose` doc, and the embedded code example uses `OnnxEmbeddingModel`,
  `KmdbDatabase.open`, `VecIndexDefinition`. Decide whether to keep the example
  (now valid since `betto_inferencing` won't import `kmdb`, the doc reference to
  `KmdbDatabase` would be a dangling doc ref) or generalise it. Spell out the
  exact replacement wording so the implementer doesn't author prose ad hoc.

### R5 — Doc-update set is incomplete (and Q2)

Files with references the plan does **not** list:
- `docs/proposals/implemented/betto_onnxrt.md` — ~12 refs to `kmdb_inferencing`.
- `docs/reviews/roadmap-review-2026-06-05.md` — 5 refs.

The plan does list `docs/proposals/implemented/betto_icu.md` "for accuracy,"
which is inconsistent: either implemented-proposal/review snapshots are frozen
historical records (and `betto_icu.md` should be left alone too), or they get
rewritten (and `betto_onnxrt.md` + the review must be included). Resolve via Q2
and make the list match the rule chosen.

Also, the `vault_search.md` scope is undercounted. The plan claims only "§10.5
table" and "§10.2 package name," but verified refs are broader:
- `kmdb_inferencing`: line 93 (**§2.3**, extractor-naming analogy — outside §10),
  line 760 (§10.4), line 770 (§10.5).
- `kmdb_lang_id`: lines 643/646/648 (§10.2 code block), 750 (§10.3/10.4), 769
  (§10.5 table).
- `kmdb_lexical`: lines 747, 760, 771.
Either rewrite all of these or scope the edit explicitly; "§10.2 / §10.5" as
written misses the §2.3 and `kmdb_lexical` occurrences.

### R6 — Minor / confirmations

- The `kmdb` internal consumer `packages/kmdb/lib/src/query/kmdb_database.dart`
  imports `../search/embedding_model.dart` directly (line 20). §2.4's "search
  `lib/` for remaining direct imports" step covers it, but add it to the consumer
  map for completeness so nothing relies on a grep that the implementer might
  skip. Its doc comments also reference `OnnxEmbeddingModel.load` /
  `ModelCatalog.lookup` in examples — these become valid doc refs once `kmdb`
  depends on `betto_inferencing`, so no change needed there, but note it.
- `OnnxEmbeddingModel`'s doc comment (in the impl file) contains "for KMDB
  semantic search" and references `$meta` / `$vec:`. The plan's "ModelCatalog doc
  cleanup" section covers `model_catalog.dart` but not the impl file's class doc.
  Add an item to generalise the `OnnxEmbeddingModel` class doc too, or
  consciously decide to leave KMDB-flavoured examples (they still compile).
- `kmdb_cli` / `kmdb_harness` confirmed clean: only two comment-only mentions of
  `kmdb_inferencing` in `search_command.dart` (lines 168, 274), no imports or
  pubspec deps. The plan's claim here is accurate.
- The `betto_inferencing` barrel currently exports `OnnxEmbeddingModel` from
  `src/embedding_model.dart`; after the file rename the export must move to
  `src/onnx_embedding_model.dart` — §2.3 covers this correctly. Good.
- `kmdb_inferencing/pubspec.yaml` description says "ONNX runtime and BGE
  embedding model for KMDB semantic search" — §2.1 covers the rewrite. Good.

### Testing strategy gap

The plan's verification steps (`dart test` per package + `make pre_commit`) are
the right gates, but there is **no testing-strategy section** describing what
could regress. This is a pure rename/move with no behaviour change, so the
existing suites are the safety net — state that explicitly, and add one
assertion the implementer must check: that `package:kmdb/kmdb.dart` still
exports `EmbeddingModel` (a `show EmbeddingModel` re-export from
`betto_inferencing`) so downstream consumers (notably `kmdb_ui`, out of repo)
see no API change. A 1-line test or a `dart analyze` confirmation that the
export resolves is enough. No release-checklist (§28) additions are needed —
nothing here introduces an un-automatable test.

### Verdict

Approach: approved. Readiness: **not yet** — set to `Questions`. Resolve Q1 and
Q2, then fold R2/R3/R4/R5/R6 corrections into the checklists. Once those are in,
this is a clean mechanical change ready for `Investigated`.

## Follow-up review (2026-06-17, kmdb-plan-reviewer) — promoted to `Investigated`

Both open questions are answered (see the Open questions section, now checked
off) and all six findings are folded into the plan body:

- **Q1 → publish to pub.dev.** The plan was restructured from an in-workspace
  rename into the Stage A / Stage gate / Stage B shape used by the `betto_icu`
  and `betto_onnxrt` extractions (`docs/plans/completed/`). This is not a
  cosmetic wiring tweak: an in-workspace rename and a cross-repo publish are
  structurally different operations. The standalone repos are created and
  published first (manual gate), then KMDB is wired to consume them as bare deps
  pinned via `dependency_overrides: ^0.1.0-dev.1` — matching the current
  `betto_*` family at HEAD `a1b4d9e`. **R1 is resolved by this restructure**:
  there is no longer any "workspace member" wiring; the override entries are
  correct because the packages are genuinely published.
- **Q2 → freeze historical docs.** `betto_icu.md` checklist item removed;
  `betto_onnxrt.md` and `roadmap-review-2026-06-05.md` are not touched. **R5's
  doc-set question is resolved**: the only proposal updated is the *active*
  `vault_search.md`.
- **R2** fixed: `math_utils_test.dart` import substitution is now an explicit
  step (verified: it imports `package:kmdb_inferencing/src/math_utils.dart`).
- **R3** fixed: the three `betto_lexical` own-test files are now enumerated
  (verified to exist: `stemmer_test.dart`, `default_tokenizer_test.dart`,
  `stopwords_test.dart`).
- **R4** fixed: `EmbeddingModel` is now described as four members; the
  contradictory `dart:typed_data` instruction is corrected to "keep".
- **R5** `vault_search.md` scope: trimmed to what was actually verified in the
  review (§2.3, §10.2/§10.4/§10.5, and the `kmdb_lexical`/`kmdb_lang_id`
  occurrences) rather than the under-counted "§10.2 / §10.5".
- **R6** confirmations folded in where they were concrete checklist items.

Readiness: an implementer can now execute this end-to-end. The cross-repo
Stage gate is a deliberate manual checkpoint, not an unresolved design decision.
Cleared for `kmdb-plan-implement`.

## Investigation

### `kmdb_lexical` coupling analysis

`kmdb_lexical` has **zero coupling to KMDB**. Its `pubspec.yaml` dependencies
are `betto_icu` and `intl` — both already in the `betto_*` / Dart-stdlib family.
The public surface (`Tokenizer`, `RegExpTokenizer`, `IcuTokenizer`,
`BrowserTokenizer`, `Stemmer`, `Stopwords`, `createDefaultTokenizer`) is entirely
generic.

The only mechanical changes needed:
- The package name itself (`kmdb_lexical` → `betto_lexical`).
- The barrel file (`lib/lexical.dart` → `lib/betto_lexical.dart`), following the
  `betto_icu` → `package:betto_icu/betto_icu.dart` convention.
- ~30 self-referencing imports inside
  `lib/src/third_party/snowball_stemmer/lib/src/snowball_stemmer_base.dart` that
  use `package:kmdb_lexical/src/...`; these become `package:betto_lexical/src/...`.
- Import paths in the four consumer files across `kmdb` and `kmdb_inferencing`.

Historical note: the `betto_icu` extraction proposal
(`docs/proposals/implemented/betto_icu.md`) stated that `Stemmer` and `Stopwords`
"are KMDB-domain specific" and should remain in `kmdb_lexical`. This was a
statement about what should stay in the `kmdb_*` namespace _relative to `betto_icu`_,
not a claim that the utilities are inherently database-specific. That rationale is
superseded by this extraction.

### `kmdb_inferencing` coupling analysis

`kmdb_inferencing` has exactly **one dependency on `kmdb`**: the `EmbeddingModel`
abstract interface (`packages/kmdb/lib/src/search/embedding_model.dart`). It is
imported in `packages/kmdb_inferencing/lib/src/embedding_model.dart` (which
contains `OnnxEmbeddingModel`) and re-exported in the barrel. Everything else —
`BertTokenizer`, `ModelCatalog`, `SQ8` quantisation helpers, `OnnxEmbeddingModel`
— depends only on `betto_onnxrt`, `betto_lexical` (post-rename), `path`, `crypto`,
and `dart:io`.

The `EmbeddingModel` interface's own doc comment acknowledges the intent:
> "Allows `VecManager` in `kmdb` to accept an embedding model without taking a
> dependency on the FFI-heavy `kmdb_inferencing` package."

The natural resolution is to **move `EmbeddingModel` into `betto_inferencing`**
and have `kmdb` depend on `betto_inferencing` for the interface. This flips the
dependency arrow to the correct direction: the database consumes the embedder,
not the other way around.

After the move:
- `betto_inferencing` defines and implements `EmbeddingModel` (no `kmdb` dependency).
- `kmdb/lib/kmdb.dart` re-exports `EmbeddingModel` from `betto_inferencing` so
  all callers of `package:kmdb/kmdb.dart` continue to find it unchanged.
- `kmdb/lib/src/search/embedding_model.dart` (the old definition file) is deleted;
  its export in `kmdb.dart` is updated to `show EmbeddingModel` from `betto_inferencing`.

### File layout for `betto_inferencing/lib/src/`

The current `kmdb_inferencing/lib/src/embedding_model.dart` contains
`OnnxEmbeddingModel`. The incoming interface is also named `EmbeddingModel`. To
avoid a name collision, rename the implementation file first:

| Old path | New path |
| -------- | -------- |
| `kmdb_inferencing/lib/src/embedding_model.dart` | `betto_inferencing/lib/src/onnx_embedding_model.dart` |
| _(moved from kmdb)_ | `betto_inferencing/lib/src/embedding_model.dart` |

`betto_inferencing/lib/betto_inferencing.dart` (the barrel) exports:
- `EmbeddingModel` from `src/embedding_model.dart`
- `OnnxEmbeddingModel` from `src/onnx_embedding_model.dart`
- `BertTokenizer`, `TokenizerOutput` from `src/bert_tokenizer.dart`
- `ModelCatalog` from `src/model_catalog.dart`
- `quantise`, `dequantise` from `src/sq8.dart`
- Re-exports from `betto_onnxrt`: `DownloadProgress`, `ModelDownloader`,
  `ModelFile`, `ModelSpec`, `ResolvedModel`

### `ModelCatalog` doc comment cleanup

`ModelCatalog` contains wording like "for KMDB semantic search" in its doc
comments. Once in `betto_inferencing` these are updated to remove KMDB-specific
framing ("production-validated embedding models for dense retrieval").
The behavior is unchanged; only the wording is generalised.

### Vault search proposal impact

`docs/proposals/vault_search.md` is an **active** proposal (not a frozen
implemented/historical doc), so it is updated. The verified occurrences to
change (line numbers approximate — grep to confirm before editing) are:

- `kmdb_inferencing` → `betto_inferencing`: line ~93 (§2.3, extractor-naming
  analogy — note this is *outside* §10), line ~760 (§10.4), line ~770 (§10.5).
- `kmdb_lexical` → `betto_lexical`: lines ~747, ~760, ~771.
- `kmdb_lang_id` → `betto_lang_id`: lines ~643/646/648 (§10.2 code block), ~750
  (§10.3/10.4), ~769 (§10.5 table).

The implementer should grep the whole file for `kmdb_inferencing`,
`kmdb_lexical`, and `kmdb_lang_id` and replace every occurrence, not just the
§10.2/§10.5 table — earlier review under-counted these.

§10.5 refers to "extend `kmdb_inferencing`"
for multilingual models. After extraction this becomes `betto_inferencing`.
§10.2 proposes a `kmdb_lang_id` package for language detection — this plan
updates that reference to `betto_lang_id`, consistent with the `betto_*`
convention for reusable Bettongia utilities.

### Consumer map

Because the packages are **published** (Q1), the wiring follows the current
`betto_*` family pattern (verified against `pubspec.yaml` and
`packages/kmdb/pubspec.yaml` at HEAD `a1b4d9e`):

- Root `pubspec.yaml`: **remove** `packages/kmdb_lexical` and
  `packages/kmdb_inferencing` from the `workspace:` list; **add**
  `betto_lexical: ^0.1.0-dev.1` and `betto_inferencing: ^0.1.0-dev.1` to
  `dependency_overrides:`.
- Consumers declare the deps **bare** (e.g. `betto_lexical:` with no version) in
  their own `dependencies:`, exactly as `betto_zstd:` / `betto_common:` are
  declared bare in `packages/kmdb/pubspec.yaml` today.

The KMDB-side consumer changes (the only files edited in this repo — the moved
source itself lives in the new standalone repos):

| File | Change |
| ---- | ------ |
| `packages/kmdb/pubspec.yaml` | `kmdb_lexical:` (bare) → `betto_lexical:` (bare); add `betto_inferencing:` (bare) |
| `packages/kmdb/lib/src/search/lexical/fts_manager.dart` | `package:kmdb_lexical/lexical.dart` → `package:betto_lexical/betto_lexical.dart` |
| `packages/kmdb/lib/src/search/lexical/pipeline.dart` | same |
| `packages/kmdb/test/search/lexical/pipeline_test.dart` | same |
| `packages/kmdb/lib/kmdb.dart` | re-export `EmbeddingModel` from `betto_inferencing` (was `src/search/embedding_model.dart`) |
| `packages/kmdb/lib/src/query/kmdb_database.dart` | line 20 imports `../search/embedding_model.dart` → `package:betto_inferencing/betto_inferencing.dart` (R6) |
| `packages/kmdb/lib/src/search/embedding_model.dart` | **deleted** (definition moved to `betto_inferencing` repo) |
| `pubspec.yaml` (workspace root) | remove the two `packages/kmdb_lexical` / `packages/kmdb_inferencing` `workspace:` entries; add the two `^0.1.0-dev.1` `dependency_overrides:` entries |

`kmdb_cli` and `kmdb_harness` have no direct dependency on either package (the
CLI comment at `search_command.dart:274` explicitly notes it cannot load
`kmdb_inferencing`; only the two comment-only mentions at `search_command.dart`
lines 168 and 274 exist, no imports or pubspec deps), so no `pubspec.yaml` or
import changes are needed there.

The source-internal import substitutions (`betto_lexical` self-references in the
Snowball stemmer; `betto_inferencing` internal imports, tests, and example) are
performed **in the new standalone repos** during Stage A — see the Stage A
phases. They are not edits to this monorepo.

### Spec and doc files requiring update

| File | What changes |
| ---- | ------------ |
| `CLAUDE.md` | Repository Layout table (`kmdb_lexical`, `kmdb_inferencing` rows), Architecture §Text Search, External Bettongia packages list |
| `docs/spec/19_platform.md` | Package layout listing, platform matrix rows for lexical/semantic search, `betto_icu` row ("consumed by `kmdb_lexical`" → `betto_lexical`) |
| `docs/spec/21_lexical_search.md` | `createDefaultTokenizer()` export ref |
| `docs/spec/22_semantic_search.md` | Multiple refs to `kmdb_inferencing`, pubspec snippet |
| `docs/spec/28_release_checklist.md` | Lines referencing `kmdb_inferencing` (embedding model download, model downloader paths) |
| `docs/roadmap/0_00.md` | Add `betto_lexical` and `betto_inferencing` to "Bettongia packages" checklist |
| `docs/roadmap/0_05.md` | Minor refs to `kmdb_inferencing` |
| `docs/roadmap/0_06.md` | Refs to `kmdb_inferencing` in vault search context |
| `docs/api.md` | API link entries for both packages |
| `docs/proposals/vault_search.md` | **active** proposal — replace all `kmdb_inferencing` → `betto_inferencing`, `kmdb_lexical` → `betto_lexical`, `kmdb_lang_id` → `betto_lang_id` (full-file grep; see "Vault search proposal impact" above) |

**Not updated (frozen historical records — Q2):**
`docs/proposals/implemented/betto_icu.md`,
`docs/proposals/implemented/betto_onnxrt.md`, and
`docs/reviews/roadmap-review-2026-06-05.md` are left as-is. Implemented
proposals and reviews are point-in-time snapshots and are not rewritten.

### Pre-commit scope note

`melos pre_commit_test` is scoped to `kmdb`. Because `betto_lexical` and
`betto_inferencing` are **published, out-of-workspace** packages (Q1), their test
suites run in their own repos' CI during Stage A, not in this monorepo's
`make test`. The monorepo gate that matters for Stage B is `make pre_commit`
(format_check, analyze, license_check, scoped `kmdb` tests) — which exercises the
`fts_manager`/`pipeline`/`EmbeddingModel` consumers against the published deps.

## Testing strategy

This is a pure package-rename / file-move / dependency-rewire change with **no
behaviour change**. The safety net is the existing test suites, which move with
the code into the new repos (`betto_lexical`, `betto_inferencing`) plus the
unchanged `kmdb` suite. There is no new untested surface, so the 90% coverage
bar is preserved by construction; once moved, `betto_lexical`/`betto_inferencing`
coverage is each new repo's concern, not KMDB's.

Gates and assertions the implementer must check:

- Each standalone repo's own `dart test` passes during Stage A.
- After Stage B wiring: `cd packages/kmdb && dart test` passes (exercises
  `fts_manager`, `pipeline`, and the `EmbeddingModel` consumers via the
  published deps).
- **API-stability assertion:** confirm `package:kmdb/kmdb.dart` still exports
  `EmbeddingModel` (now a `show EmbeddingModel` re-export from
  `betto_inferencing`) so out-of-repo consumers (notably `kmdb_ui`) see no API
  change. A `dart analyze` pass that resolves the re-export, or a one-line test
  importing `EmbeddingModel` from `package:kmdb/kmdb.dart`, is sufficient.
- `make pre_commit` (format_check, analyze, license_check, scoped `kmdb` tests)
  passes.

No release-checklist (`docs/spec/28_release_checklist.md`) additions are needed —
nothing here introduces an un-automatable test. (The existing
`kmdb_inferencing`-path references in §28 are doc updates only, covered in
Phase 3.)

## Implementation plan

> **Structure (per Q1 — publish to pub.dev).** Following the `betto_icu` and
> `betto_onnxrt` extractions (`docs/plans/completed/`), this is a cross-repo
> operation: **Stage A** creates and verifies each standalone package in its own
> repo; the **Stage gate** is a manual checkpoint that creates the GitHub repos
> and publishes to pub.dev; **Stage B** wires the published packages into the
> KMDB monorepo. The file moves and source-internal import rewrites happen in the
> new repos during Stage A — they are **not** edits to `packages/` in this repo.

### Stage A — Create and verify the standalone packages

_This stage produces two self-contained, tested packages in their own repos.
Stop at the Stage gate before touching the KMDB monorepo._

#### Phase A1 — `betto_lexical` standalone repo

- [ ] Create the repo directory (e.g. `/Users/gonk/development/bettongia/lexical/`),
  `git init`, add Apache 2.0 `LICENSE` and `analysis_options.yaml`
  (`include: package:lints/recommended.yaml`).
- [ ] Copy the contents of `packages/kmdb_lexical/` (lib, test) into the new repo.
- [ ] Write `pubspec.yaml`:
  - `name: betto_lexical`, `version: 0.1.0-dev.1`,
    `homepage: https://github.com/bettongia/lexical`, `sdk: ^3.12.0`.
  - Description: "Lexical text utilities (tokenizer, stemmer, stopwords) for Dart
    and Flutter."
  - Dependencies: `betto_icu: ^0.1.0-dev.1`, `intl: ^0.20.2` (carry over the
    existing deps).
  - **Do not** set `publish_to: none` — this package is published.
- [ ] Rename the barrel `lib/lexical.dart` → `lib/betto_lexical.dart`
  (no content change required).
- [ ] In `lib/src/third_party/snowball_stemmer/lib/src/snowball_stemmer_base.dart`,
  replace all `package:kmdb_lexical/src/` → `package:betto_lexical/src/`
  (~30 self-referencing import lines at the top of the file).
- [ ] In the three own-test files, replace `package:kmdb_lexical/lexical.dart` →
  `package:betto_lexical/betto_lexical.dart` (R3):
  - `test/stemmer_test.dart`
  - `test/default_tokenizer_test.dart`
  - `test/stopwords_test.dart` (this one is `... show getStopWords`)
  (There is no `kmdb_lexical/example/` directory — confirmed.)
- [ ] Ensure every file carries the `header_template.txt` license header with the
  current year.
- [ ] Run `dart pub get` then `dart test` in the new repo — all tests pass.
- [ ] Commit on a branch (do **not** open the PR yet; the GitHub repo is created
  in the Stage gate).

#### Phase A2 — `betto_inferencing` standalone repo

- [ ] Create the repo directory (e.g. `/Users/gonk/development/bettongia/inferencing/`),
  `git init`, add Apache 2.0 `LICENSE` and `analysis_options.yaml`.
- [ ] Copy the contents of `packages/kmdb_inferencing/` (lib, test, example) into
  the new repo.
- [ ] Write `pubspec.yaml`:
  - `name: betto_inferencing`, `version: 0.1.0-dev.1`,
    `homepage: https://github.com/bettongia/inferencing`, `sdk: ^3.12.0`.
  - Description: "ONNX Runtime inference and embedding models for dense text
    retrieval."
  - Dependencies: `betto_onnxrt: ^0.1.0-dev.1`, `betto_lexical: ^0.1.0-dev.1`
    (the just-published lexical package), `path`, `crypto`.
  - **Remove** the `kmdb:` dependency entirely. **Do not** set
    `publish_to: none`.
- [ ] Rename the barrel `lib/kmdb_inferencing.dart` → `lib/betto_inferencing.dart`.
- [ ] **Move the `EmbeddingModel` interface in** (file-layout step — resolves the
  name collision with `OnnxEmbeddingModel`):
  - Rename the existing `lib/src/embedding_model.dart` (which contains
    `OnnxEmbeddingModel`) → `lib/src/onnx_embedding_model.dart`.
  - Create a new `lib/src/embedding_model.dart` containing the `EmbeddingModel`
    abstract interface, copied from
    `packages/kmdb/lib/src/search/embedding_model.dart` with these changes:
    - Use the `header_template.txt` license header with the current year.
    - **Keep** the `import 'dart:typed_data';` — it backs `Float32List` and is
      still needed. (Earlier draft said "remove (keep it)" — contradictory; the
      instruction is: keep it.)
    - Generalise the doc comment: the class doc references `VecManager` and
      `KmdbDatabase.open`; the `dispose` doc references `KmdbDatabase.close`; the
      embedded `## Usage` example uses `OnnxEmbeddingModel`, `KmdbDatabase.open`,
      and `VecIndexDefinition`. Since `betto_inferencing` must not depend on
      `kmdb`, rewrite these to the consuming-application framing. Exact
      replacement: replace the first paragraph with "Allows a consuming database
      or application to accept an embedding model without taking a dependency on
      the FFI-heavy `betto_inferencing` package. The concrete implementation
      (`OnnxEmbeddingModel`) lives in this package and implements this
      interface."; replace the `## Usage` block's `KmdbDatabase.open(...)` call
      with a comment-only sketch that constructs `OnnxEmbeddingModel.load(...)`
      and passes it to "your database's open call" (no `KmdbDatabase` symbol);
      in the `dispose` doc replace "Called by `KmdbDatabase.close`" with "Called
      by the consuming database after all other cleanup."
    - **Keep all four members unchanged**: `modelId`, `dimensions`, `embed`,
      `dispose` (R4 — the interface currently has four members, not three).
- [ ] In `lib/src/onnx_embedding_model.dart`:
  - Remove `import 'package:kmdb/kmdb.dart';`.
  - Add `import 'embedding_model.dart' show EmbeddingModel;`.
  - Replace `import 'package:kmdb_lexical/lexical.dart' show Tokenizer;` →
    `import 'package:betto_lexical/betto_lexical.dart' show Tokenizer;`.
  - Generalise any "for KMDB semantic search" / `$meta` / `$vec:` framing in the
    `OnnxEmbeddingModel` class doc comment to package-neutral wording, or
    consciously leave the examples (they still compile). Decide and note in the
    commit; recommended: generalise to "dense text retrieval".
- [ ] In `lib/src/bert_tokenizer.dart`: replace
  `package:kmdb_lexical/lexical.dart show Tokenizer, RegExpTokenizer` →
  `package:betto_lexical/betto_lexical.dart show Tokenizer, RegExpTokenizer`.
- [ ] Update the barrel `lib/betto_inferencing.dart`:
  - `export 'src/embedding_model.dart' show EmbeddingModel;`
  - `export 'src/onnx_embedding_model.dart' show OnnxEmbeddingModel;`
  - Keep `BertTokenizer`/`TokenizerOutput`, `ModelCatalog`, `quantise`/`dequantise`
    exports, and the `betto_onnxrt` re-exports (`DownloadProgress`,
    `ModelDownloader`, `ModelFile`, `ModelSpec`, `ResolvedModel`).
  - Note: the current barrel exports `OnnxEmbeddingModel` from
    `src/embedding_model.dart` (line ~46) and does **not** re-export
    `EmbeddingModel` at all (today `EmbeddingModel` comes from `kmdb` via the impl
    file's `import 'package:kmdb/kmdb.dart';`). After the move, the barrel gains a
    new `export 'src/embedding_model.dart' show EmbeddingModel;` line and the
    `OnnxEmbeddingModel` export moves to `src/onnx_embedding_model.dart` as above.
    There is no `kmdb` re-export block in the barrel to remove — the `kmdb`
    dependency is dropped in the impl file (handled in the
    `onnx_embedding_model.dart` step).
  - Library doc: "ONNX Runtime inference and embedding models for dense text
    retrieval."
- [ ] `lib/src/model_catalog.dart`: replace "for KMDB semantic search" → "for
  dense text retrieval"; "KMDB release" → "a future release" in the
  `UnsupportedError` message. No behaviour change.
- [ ] Update tests and example imports
  (`package:kmdb_inferencing/kmdb_inferencing.dart` →
  `package:betto_inferencing/betto_inferencing.dart`):
  - `test/bert_tokenizer_test.dart`
  - `test/kmdb_inferencing_test.dart` → rename to `test/betto_inferencing_test.dart`,
    update import.
  - `test/model_catalog_test.dart`
  - `test/model_downloader_test.dart`
  - `test/sq8_test.dart`
  - `test/math_utils_test.dart` — **substitute the package name** (R2): this file
    imports `package:kmdb_inferencing/src/math_utils.dart`, which must become
    `package:betto_inferencing/src/math_utils.dart`. (The package name is part of
    the `src/` URI; leaving it unchanged breaks the build.)
  - `example/kmdb_inferencing_example.dart` → rename to
    `example/betto_inferencing_example.dart`, update import.
- [ ] Ensure every file carries the `header_template.txt` license header.
- [ ] Run `dart pub get` then `dart test` in the new repo — all tests pass.
  (Note: `betto_lexical` and `betto_onnxrt` must already resolve — either from
  pub.dev once published in the Stage gate, or via a local path/git override used
  only for Stage A verification, removed before publishing.)
- [ ] Commit on a branch (do **not** open the PR yet).

---

### ⛔ Stage gate — manual steps required before Stage B

Before wiring into the KMDB monorepo, complete these manually (mirrors the
`betto_icu` / `betto_onnxrt` gates):

1. **Create the GitHub repos** `github.com/bettongia/lexical` and
   `github.com/bettongia/inferencing`; push the Stage A branches; open and merge
   the Stage A PRs.
2. **Publish `betto_lexical 0.1.0-dev.1` to pub.dev** first (it is a dependency
   of `betto_inferencing`), then **publish `betto_inferencing 0.1.0-dev.1`**.
3. **Confirm both resolve from pub.dev** (e.g. a scratch `pub get`) before
   starting Stage B.

Once done, return here and continue with Stage B.

---

### Stage B — Wire the published packages into the KMDB monorepo

_Prerequisite: `betto_lexical 0.1.0-dev.1` and `betto_inferencing 0.1.0-dev.1`
are published and resolvable from pub.dev._

#### Phase B1 — Workspace + dependency_overrides

- [ ] In the workspace root `pubspec.yaml`:
  - **Remove** `- packages/kmdb_lexical` and `- packages/kmdb_inferencing` from
    the `workspace:` list (these packages have left the workspace).
  - **Add** to `dependency_overrides:`:
    `betto_lexical: ^0.1.0-dev.1` and `betto_inferencing: ^0.1.0-dev.1`
    (alongside the existing `betto_onnxrt: ^0.1.0-dev.1` etc.).
- [ ] Delete the now-unused `packages/kmdb_lexical/` and
  `packages/kmdb_inferencing/` directories from the monorepo.

#### Phase B2 — `kmdb` consumer rewiring

- [ ] `packages/kmdb/pubspec.yaml`:
  - Replace the bare `kmdb_lexical:` entry with a bare `betto_lexical:` entry.
  - Add a bare `betto_inferencing:` entry under `dependencies:`.
- [ ] `packages/kmdb/lib/src/search/lexical/fts_manager.dart`:
  `import 'package:kmdb_lexical/lexical.dart'` →
  `import 'package:betto_lexical/betto_lexical.dart'`.
- [ ] `packages/kmdb/lib/src/search/lexical/pipeline.dart`: same substitution.
- [ ] `packages/kmdb/test/search/lexical/pipeline_test.dart`: same substitution.
- [ ] Delete `packages/kmdb/lib/src/search/embedding_model.dart` (the interface
  now lives in `betto_inferencing`).
- [ ] `packages/kmdb/lib/kmdb.dart`: change the `EmbeddingModel` export:
  - Old: `export 'src/search/embedding_model.dart' show EmbeddingModel;`
  - New: `export 'package:betto_inferencing/betto_inferencing.dart' show EmbeddingModel;`
- [ ] `packages/kmdb/lib/src/query/kmdb_database.dart` (line ~20): change
  `import '../search/embedding_model.dart';` →
  `import 'package:betto_inferencing/betto_inferencing.dart';` (R6). (Its doc
  comments referencing `OnnxEmbeddingModel.load` / `ModelCatalog.lookup` become
  valid doc refs once `kmdb` depends on `betto_inferencing` — no change needed.)
- [ ] Grep `packages/kmdb/lib/` for any remaining direct imports of
  `src/search/embedding_model.dart` and repoint them to
  `package:betto_inferencing/betto_inferencing.dart`.

#### Phase B3 — Verify Stage B

- [ ] Run `dart pub get` from the workspace root.
- [ ] Run `cd packages/kmdb && dart test` — all tests pass.
- [ ] Confirm the API-stability assertion from the Testing strategy: `dart
  analyze` resolves the `EmbeddingModel` re-export from `package:kmdb/kmdb.dart`.

---

### Phase 3: Spec, docs, and roadmap updates

- [ ] **`CLAUDE.md`** — Repository Layout table:
  - `kmdb_lexical/` row → `betto_lexical/` (external Bettongia package, published)
  - `kmdb_inferencing/` row → `betto_inferencing/` (external Bettongia package, published)
  - External Bettongia packages list: add `betto_lexical` and `betto_inferencing`
  - Architecture §Text Search: update package name references
  - `betto_icu` row: "consumed by `kmdb_lexical`" → "consumed by `betto_lexical`"

- [ ] **`docs/spec/19_platform.md`**:
  - Package layout listing: `kmdb_lexical/` and `kmdb_inferencing/` rows
  - Platform matrix rows: lexical and semantic search (`kmdb_inferencing` ref)
  - Third-party dependency table: "consumed by `kmdb_lexical`" / "consumed by `kmdb_inferencing`"

- [ ] **`docs/spec/21_lexical_search.md`**: update `createDefaultTokenizer()` ref from `kmdb_lexical`.

- [ ] **`docs/spec/22_semantic_search.md`**: update all `kmdb_inferencing` refs, pubspec
  snippet, `ModelCatalog` description, path references.

- [ ] **`docs/spec/28_release_checklist.md`**: update the embedding model download entries
  (lines ~419, 453–454, 487) that reference `kmdb_inferencing` paths.

- [ ] **`docs/roadmap/0_00.md`**: add `[ ] betto_lexical` and `[ ] betto_inferencing` to
  the "Bettongia packages" checklist under "Bettongia packages (not in this repo)".

- [ ] **`docs/roadmap/0_05.md`**: update minor refs to `kmdb_inferencing`.

- [ ] **`docs/roadmap/0_06.md`**: update vault search context refs to `kmdb_inferencing`
  → `betto_inferencing`.

- [ ] **`docs/api.md`**: update the two API link entries (`kmdb_inferencing`, `kmdb_lexical`).

- [ ] **`docs/proposals/vault_search.md`** (active proposal): full-file grep and
  replace `kmdb_inferencing` → `betto_inferencing`, `kmdb_lexical` →
  `betto_lexical`, `kmdb_lang_id` → `betto_lang_id` (see "Vault search proposal
  impact" for the verified occurrences; do not stop at the §10.2/§10.5 table —
  there are refs at §2.3 and elsewhere). Add a one-line note that
  `betto_lang_id` follows the `betto_*` convention for reusable Bettongia
  utilities.

> **Frozen — not updated (Q2):** `docs/proposals/implemented/betto_icu.md`,
> `docs/proposals/implemented/betto_onnxrt.md`, and
> `docs/reviews/roadmap-review-2026-06-05.md` are point-in-time historical
> records and are left as-is.

---

### Phase 4: Pre-commit gate
- [ ] Run `make pre_commit` — format_check, analyze, license_check, and scoped
  `kmdb` tests must all pass.
- [ ] (The `betto_lexical` / `betto_inferencing` suites are exercised in their
  own repos' CI during Stage A — they are no longer in this workspace, so
  `make test` here covers only the monorepo packages.)

### Phase 5: PR
- [ ] Open a pull request for the **KMDB monorepo** Stage B + docs changes
  (the standalone-repo PRs were merged at the Stage gate). Update this plan's
  **PR link** field.
- [ ] Move this plan to `docs/plans/completed/` once the PR is merged.

## Summary

_To be filled in after implementation._
