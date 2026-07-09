# WI-11: XLM-R SentencePiece tokenizer (lands in `betto_inferencing`)

**Status**: Complete (Phase 0 complete + certified; Phase 1 implemented
2026-07-09 in `betto_inferencing`, merged via
[PR #1](https://github.com/bettongia/inferencing/pull/1) — see the Phase 1
checklist below for what's done. `make pre_commit` (format_check, analyze,
license_check, test) verified fully green as of the second commit on this
PR — an initial run couldn't reach `addlicense`'s installer from the
implementing session's sandbox, resolved once `addlicense` became available.
A real cross-platform bug was also found post-review and fixed on the same
PR: the integration test's fixture loading worked on `make macos_test` but
not `make ios_test`/`make android_test` (see the "Post-review fix" note
under the Tests checklist item below) — now verified passing on all three.
Published to pub.dev as `betto_inferencing 0.1.0-dev.2` and tagged
2026-07-09. `kmdb`'s own `pubspec.yaml` `dependency_overrides` bumped to
match, and WI-4's plan/`docs/roadmap/0_06.md` updated to reflect the Q6 hard
gate clearing — WI-4 Phase 2 is now unblocked.)

**PR link**: https://github.com/bettongia/inferencing/pull/1

**Package boundary decision (2026-07-08).** This work lands as new files
directly inside `betto_inferencing`, **not** as a new standalone published
package — reconsidered from this plan's original framing after weighing the
precedent that `BertTokenizer` (an equally model-family-specific subword
tokenizer, for BERT/WordPiece) already lives in
`betto_inferencing/lib/src/bert_tokenizer.dart`, not its own package, while only
the genuinely model-independent primitive it depends on (word-segmentation,
`Tokenizer`/`RegExpTokenizer`/`IcuTokenizer`) is factored into a separate
package (`betto_lexical`/`betto_icu`). `XlmRobertaTokenizer` is the same kind of
thing as `BertTokenizer`, with exactly one known consumer (`OnnxEmbeddingModel`)
— the precedent, and CLAUDE.md's guidance against designing for hypothetical
future reuse, both favour landing it alongside `BertTokenizer` rather than
spinning out a new package for a single consumer. **This plan document itself
remains standalone** (this file, WI-11's own roadmap entry) — only the
deliverable's location changed, not this plan's tracking as its own work item.
See "Package boundary" in Investigation below for the fuller reasoning,
including the counter-arguments considered and rejected.

## Problem statement

WI-4 (`plan_0_06_wi4_multilingual_embedding_model.md`) targets
`multilingual-e5-small`, an XLM-RoBERTa-family model requiring
SentencePiece/Unigram subword tokenization — a different scheme from the BERT
WordPiece tokenization `betto_inferencing` already implements for
`bge-small-en-v1.5`. WI-4's Phase 0 investigation spike evaluated adopting the
pub.dev package `dart_sentencepiece_tokenizer` rather than hand-porting a
tokenizer from `transformers.js` (the option WI-4's own text originally assumed,
without having checked pub.dev first).

**Result: 0 of 11 smoke-corpus entries matched byte-exact** against reference
token ids from `multilingual-e5-small`'s real `tokenizer.json`. Every entry —
not just deliberately-adversarial edge cases — diverged from the first content
token, with output 1.3–3.5× longer than expected and full of `<unk>` fallback
tokens (the signature of Unigram tokenization running on unnormalized text).

**Root cause, confirmed at the source level:** `dart_sentencepiece_tokenizer`
parses HuggingFace's `Precompiled` normalizer type (the NFKC-like charsmap trie
baked into the model — not plain NFKC; see WI-4's Q1) but never applies it.
Specifically:

- `tokenizer.json`'s `normalizer` field is a `Sequence` whose first entry has
  `"type": "Precompiled"` and a `precompiled_charsmap` key holding the actual
  trie bytes, base64-encoded — confirmed directly by parsing
  `multilingual-e5-small`'s real `tokenizer.json` (retained from WI-4's spike at
  `~/development/bettongia/inferencing/tool/spike_assets/tokenizer.json`).
- `huggingface_json.dart`'s `_buildNormalizerSpec` (source:
  `~/.pub-cache/hosted/pub.dev/dart_sentencepiece_tokenizer-1.3.2/lib/src/sentencepiece/serialization/huggingface_json.dart:293-299`)
  reads `addDummyPrefix`/`removeExtraWhitespaces`/`escapeWhitespaces` flags
  correctly out of the parsed metadata, but never passes through a
  `precompiledCharsmap:` value — it defaults to `null`. The charsmap bytes are
  parsed elsewhere (`model_proto.dart`'s `NormalizerSpec.precompiledCharsmap`
  field exists and is populated by the **native `.model` protobuf** loading
  path) but are silently dropped on the **JSON** loading path this project
  needs, and `sp_normalizer.dart`'s `SpNormalizer` class has no field or logic
  for a charsmap at all — the data has nowhere to go even when present.

Per WI-4's Q6 resolution, this triggered a **hard gate**: no tokenizer-port code
was written in `betto_inferencing`, and a dedicated design pass — this plan — is
required before any further WI-4 implementation work resumes.

## Investigation

### The gap is narrower than "build a tokenizer from scratch"

Everything _except_ the charsmap normalizer already works correctly via
`dart_sentencepiece_tokenizer`'s existing **public** API, confirmed by reading
source directly (not assumed):

- **Vocabulary loading, Metaspace-equivalent whitespace/prefix/escape handling**
  (`SpNormalizer`'s `addDummyPrefix`/`removeExtraWhitespaces`/
  `escapeWhitespaces` — everything except the missing charsmap step), **Unigram
  Viterbi decoding**, and **BOS/EOS post-processing**
  (`SentencePieceConfig.addBosToken`/`addEosToken` — a real, public,
  already-used option; its own `SentencePieceConfig.llama`/`.gemma` presets set
  both to `true`/mixed) all appear correct and reachable through the published
  API.
- WI-4's spike independently corroborated this for the vocabulary specifically:
  it decoded all 11 reference token-id arrays back to source text using only
  `tokenizer.json`'s own vocab table (no HF/`transformers` needed) and every
  entry round-tripped exactly, including charsmap-driven effects (fullwidth →
  ASCII, curly-quote/ellipsis normalization) — strong evidence the vocab data
  itself, and the _decoding_ direction, are sound.
- The special tokens the spike **did** get right (`<s>=0`, `<pad>=1`, `</s>=2`,
  `<unk>=3`) are exactly the fairseq-remapped positions XLM-R uses (not raw
  SentencePiece piece-0-indexed ids) — suggestive evidence that HuggingFace's
  `tokenizer.json` vocab table already bakes in fairseq's id remapping, meaning
  the **separate "fairseq id remapping" step the original roadmap called out may
  not be needed at all** when loading from `tokenizer.json` (as opposed to the
  raw `.model` protobuf, where it likely would be). This is only 4 data points,
  though — needs confirming across ordinary vocabulary once a charsmap fix
  exists to retest with (see Open Questions).

**What doesn't exist anywhere in Dart today, and must be built:** the
charsmap-trie lookup algorithm itself — SentencePiece's "Darts" double-array
trie format, used to apply `precompiled_charsmap`'s byte-compiled substitution
rules to raw text. `dart_sentencepiece_tokenizer` parses these bytes into a
field (on the protobuf path only) but implements no lookup logic against them at
all — there is no existing Dart implementation to adopt, port, or extend.

### Composition is viable without forking

`SentencePieceTokenizer`'s real constructor is private
(`SentencePieceTokenizer._`, `sentencepiece_tokenizer.dart:92`) and every public
factory (`fromModelFile`, `fromBytes`, `fromModel`) routes through
`_createFromModel`, which builds `SpNormalizer.fromSpec(...)` internally with no
injection point. Its `normalizer` getter is read-only. **This rules out fixing
the gap by subclassing or swapping in a corrected `SpNormalizer`** — Dart's
library-level privacy means an external package cannot call a private
constructor even though the class itself isn't `final`.

It does **not** rule out composition, though: pre-applying a correct
`normalize(String) -> String` (our own charsmap-trie implementation) to raw
input text **before** calling the library's public `encode()` composes cleanly,
because charsmap-substitution-then-whitespace-collapse is the same pass ordering
real SentencePiece uses internally — a charsmap substitution that introduces a
plain space needs to happen _before_ the "collapse multiple spaces" step for
correctness, and doing our substitution first, then handing already-substituted
text to the library's own (already-correct) `SpNormalizer.normalize()`,
preserves that ordering rather than fighting it.

**Working hypothesis (to be validated by Phase 0 below, not assumed):** the core
job here is one focused, previously-unimplemented algorithm — a Darts
double-array trie parser/lookup for `precompiled_charsmap` bytes sourced
directly from `tokenizer.json` (no separate `.model` file needed) — composed
with `dart_sentencepiece_tokenizer`'s existing public API for everything else,
via a thin `XlmRobertaTokenizer` wrapper living inside `betto_inferencing` (see
"Package boundary" below). This is a **normal pub.dev dependency** on
`dart_sentencepiece_tokenizer`, not a fork: nothing found so far requires
modifying its own source.

### Package boundary: lands in `betto_inferencing`, not a new package

Originally planned as a new standalone `betto_*` package (reusability argument:
SentencePiece/charsmap normalization is generically useful beyond XLM-R — mT5,
ALBERT, Llama, Gemma all use variants of it — mirroring how
`betto_lang_detector`, WI-5, was spun out with exactly one known consumer at the
time). Reconsidered after directly comparing against `betto_inferencing`'s own
existing precedent: `BertTokenizer` (`lib/src/bert_tokenizer.dart`) is
architecturally the same kind of thing — a model-family-specific subword
tokenizer wrapper — and it lives directly in `betto_inferencing`, not a separate
package. Only the genuinely model-independent word-segmentation primitive it
depends on (`Tokenizer`/`RegExpTokenizer`/`IcuTokenizer`) is factored into
`betto_lexical`/`betto_icu`.

**Decision: follow the `BertTokenizer` precedent.** `XlmRobertaTokenizer` lands
in `betto_inferencing` alongside `BertTokenizer`, both implementing the
`ModelTokenizer` interface WI-4's Q2 defines. Reasoning: exactly one known
consumer today (`OnnxEmbeddingModel`); CLAUDE.md's explicit guidance against
designing for hypothetical future reuse ("don't design for hypothetical future
requirements... a premature abstraction" over "three similar lines"); and
avoiding the real overhead of a new repo/CI/pubspec/publish-cycle for what's
currently scoped as one missing normalizer. If a second real consumer for
SentencePiece/charsmap tokenization ever appears, extracting a shared package at
that point is cheap — premature generalisation now is not free. This plan's own
document stays a standalone tracked artifact regardless (its investigation and
Phase 0 spike have value independent of where the code lands).

### Third-party risk (raised by the user during planning)

`dart_sentencepiece_tokenizer` is MIT-licensed (compatible with this project's
Apache-2.0 convention) — a normal dependency of `betto_inferencing`, no
`NOTICE`/attribution file needed for using it as-is. Two acknowledged,
low-probability risks with an accepted mitigation: if the package is abandoned
or its public API changes incompatibly, its MIT licence permits vendoring a
pinned copy and continuing from there. Given this plan's actual reliance on it
is narrow (three public factory methods + `SentencePieceConfig`

- `encode()`), the vendoring fallback — if ever needed — would be small in
  scope, not "fork and maintain an entire tokenizer engine." Not designed
  against pre-emptively; noted as an accepted risk with a real,
  licence-compatible exit if it ever materializes.

The Darts-trie algorithm implementation itself will likely need to reference
third-party source for correctness (the original WI-4 roadmap text already
identified `spm_precompiled` (Rust, Apache-2.0) and the `tokenizers` crate
(Rust, Apache-2.0) as byte-exact references, and `transformers.js` (TypeScript,
Apache-2.0) as a porting-style source). If implementation ends up porting logic
(not just cross-checking behaviour) from any of these, `betto_inferencing`'s own
repo root needs a `NOTICE` file recording the source and what was ported (it
doesn't have one today — only a top-level Apache-2.0 `LICENSE`) — same
convention WI-4's plan documents for its own (gated, not yet triggered) Branch
B.

## Open questions

- [x] **Q1 — Exact charsmap trie binary format.** **Resolved by Phase 0.**
      `precompiled_charsmap` is
      `[4-byte LE trie length][darts-clone     double-array trie units][NUL-delimited replacement-string table]`.
      Each 32-bit trie unit packs `has_leaf`/`value`/`label`/`offset` exactly
      per `darts-clone`'s `include/darts.h`. See the Phase 0 results subsection
      below for the full write-up, including a confirmed deviation from a
      literal reading of `spm_precompiled`'s traversal (longest-, not shortest-,
      matching leaf must be used).
- [x] **Q2 — Confirm fairseq id remapping is genuinely unnecessary beyond
      special tokens.** **Resolved: not needed.** All 11 smoke-corpus entries
      (full multilingual sentences, not just special tokens) achieved byte-exact
      parity with no separate fairseq remapping step — confirming
      `tokenizer.json`'s vocab table already bakes fairseq's id offsets in when
      loaded via `HuggingFaceTokenizerLoader`. See Phase 0 results below.
- [x] **Q3 — Package name.** **Resolved: N/A.** Per the "Package boundary"
      decision above, this lands as new files inside `betto_inferencing`
      (`lib/src/xlmr_tokenizer.dart`, plus a charsmap-normalizer module) — there
      is no new package, so no package name is needed.
- [x] **Q4 — Compose (depend on `dart_sentencepiece_tokenizer` normally) vs.
      self-contained (reimplement vocab/Metaspace/Viterbi ourselves too), as a
      final decision, not just a working hypothesis.** **Resolved: compose.**
      Phase 0's prototype achieved byte-exact parity on all 11 smoke-corpus
      entries composing a charsmap-trie `normalize()` with
      `dart_sentencepiece_tokenizer`'s public API — with one correction to the
      original hypothesis: the library's HuggingFace-JSON metadata parser also
      fails to derive `addDummyPrefix`/`escapeWhitespaces` correctly for this
      tokenizer.json's shape (a second, independent defect — see Phase 0 results
      below), so Phase 1's compose wrapper must also replicate the
      whitespace-collapse + Metaspace steps itself, not just the charsmap
      substitution. Still "compose", not a fork: no
      `dart_sentencepiece_tokenizer` source was modified.
- [x] **Q5 — `NOTICE`/attribution scope.** Not needed for the
      `dart_sentencepiece_tokenizer` dependency itself (normal MIT dependency
      usage, added to `betto_inferencing`'s own `pubspec.yaml`). **Now confirmed
      needed** in `betto_inferencing`'s own repo root: Phase 0's prototype
      ported the traversal algorithm's structure directly from
      `spm_precompiled`'s Rust source (`DoubleArray::common_prefix_search`,
      `Precompiled::transform`, `Precompiled::normalize_string`'s
      grapheme-then-char fallback strategy) — this is porting logic, not just
      cross-checking behaviour against public documentation, so Phase 1 must add
      a `NOTICE` entry crediting `spm_precompiled` (Rust, Apache-2.0,
      `huggingface/spm_precompiled`) when the prototype is turned into
      production code.

      **Done (2026-07-09).** `~/development/bettongia/inferencing/NOTICE`
      added (new file — the repo previously had only a top-level `LICENSE`),
      crediting `spm_precompiled` (Apache-2.0, `huggingface/spm_precompiled`)
      and naming the exact three symbols this plan called out:
      `DoubleArray::common_prefix_search`, `Precompiled::transform`,
      `Precompiled::normalize_string`.

## Implementation plan

**Phase 0 — investigation spike: nail down the trie format, prove the compose
approach**

_Resolves Q1, Q2, Q4. This phase's own output determines what Phase 1+ looks
like — do not pre-commit to a package structure before this lands._

- [x] **Work location (RQ2):** do this work on a **new, throwaway branch** cut
      from `main` in `~/development/bettongia/inferencing` (e.g.
      `wi11-tokenizer-normalizer-spike`) — not on `wi4-tokenizer-spike`, which
      Phase 1's tidy-up step is going to discard. Before writing any prototype
      code, copy the load-bearing fixtures off the doomed `wi4-tokenizer-spike`
      branch into the new one: `tool/spike_assets/tokenizer.json`,
      `smoke_corpus.json`, and `reference_ids.json` (the `.model`/protobuf file
      is not needed — the compose step below loads the `.json` via the HF
      loader, never the `.model` via `fromBytes`; the old `spike_compare.dart`
      is disposed of in Phase 1's tidy-up, not carried here). These copies are
      the durable working set for this phase; nothing in this plan depends on
      `wi4-tokenizer-spike` continuing to exist after this step.
- [x] **Reference-oracle provenance:** before trusting `reference_ids.json` as
      ground truth, confirm (in one line, recorded in this plan) how it was
      produced. If it came from a real HuggingFace `AutoTokenizer` run (per
      WI-4's Q4 pattern), the gate is sound. If it was generated by any Dart
      code from this project (including the original WI-4 spike), the gate is
      circular and an independent HF-derived reference is needed before Phase
      0's pass/fail result means anything.
- [x] Study the Darts double-array trie format as used by SentencePiece's
      `precompiled_charsmap` — primary references: SentencePiece's own C++
      source (`normalizer.cc`/`normalizer.h` in `google/sentencepiece`),
      cross-checked against `spm_precompiled` (Rust, Apache-2.0, specifically
      built around this exact format) and the `tokenizers` crate (Rust,
      Apache-2.0) for byte-exact behaviour on ambiguous points. Note: this
      package already exports a `Trie`/`TrieNode`/`TrieMatch` type
      (`src/trie.dart`) — that is a general-purpose trie for added-token
      matching, **not** the Darts double-array charsmap trie this step needs;
      don't mistake it for a head start.
- [x] Prototype a Dart `normalize(String) -> String` function implementing the
      trie lookup against `multilingual-e5-small`'s real `precompiled_charsmap`
      bytes (from the copied `tokenizer.json` — its `normalizer.normalizers[0]`
      entry, `type: "Precompiled"`, base64 `precompiled_charsmap` field).
- [x] Compose: call the prototype's `normalize()` on each of the copied 11
      smoke-corpus entries, then feed the result into
      **`HuggingFaceTokenizerLoader.fromJsonString`** (or `.fromMap`/
      `.fromJsonFileSync` — the package's actual public entry point for
      HuggingFace `tokenizer.json`, exported from its top level) loaded from the
      same `tokenizer.json`, then `.encode()`, and compare against the copied
      `reference_ids.json` for byte-exact equality. **Do not use
      `SentencePieceTokenizer.fromBytes`/`fromModelFile`** — those parse the
      protobuf `.model` format (which _does_ populate the charsmap on a
      different code path with a different bug profile) and would either throw
      or silently exercise the wrong loader entirely if pointed at
      `tokenizer.json` bytes or the copied `.model` file. This plan is
      specifically about the JSON loading path's defect (`_buildNormalizerSpec`,
      see Investigation) — keep the two paths distinct and don't conflate them.
- [x] **Decision point:** byte-exact match on all 11 entries → compose
      hypothesis (Q4) confirmed; proceed to Phase 1 as a compose-based package.
      Any remaining mismatch → diagnose whether it's a trie-format bug (fix and
      retest) or evidence the compose boundary doesn't hold (re-open Q4 — do not
      proceed to Phase 1 until this is resolved, and update this plan's
      Investigation section with what was found). **Result: PASS, 11/11
      byte-exact, after two fixes found and applied during the spike** (longest-
      not shortest-match leaf selection; and composing the whitespace-collapse +
      Metaspace steps ourselves, not just the charsmap). See Phase 0 results
      below.
- [x] **Q2 check:** the 11 smoke-corpus entries are full multilingual sentences
      (not just the 4 special tokens), so a byte-exact pass at the decision
      point above already exercises ordinary vocabulary, not only
      `<s>`/`<pad>`/`</s>`/`<unk>` — if it passes, Q2 (fairseq remapping
      genuinely unneeded on the JSON path) is already answered by that same
      result, not a separate probe. Only add extra non-smoke-corpus vocabulary
      checks if the decision point's pass is inconclusive about remapping
      specifically (e.g. passes overall but you have reason to suspect a
      narrower issue words the smoke corpus doesn't exercise). Record which case
      applied. **Result: the main gate's 11/11 pass already answers Q2 directly
      — no separate probe was needed or added.**
- [x] Record Q1/Q2/Q4's resolutions in this plan's Open Questions and
      Investigation sections with concrete evidence, per this project's usual
      plan-update discipline.

### Phase 0 results (2026-07-09) — PASS, 11/11 byte-exact; compose hypothesis confirmed

**Work location.** All Phase 0 work happened on a fresh
`wi11-tokenizer-normalizer-spike` branch, cut from `main`, in
`~/development/bettongia/inferencing`. No `wi11-*` branch existed before this
session (a clean start, not a resumption of a partial attempt).
`wi4-tokenizer-spike` was left untouched — its uncommitted state
(`M pubspec.yaml`, untracked `tool/`) was preserved exactly as found (verified
via `git stash`/`git stash pop` around the branch-creation step, and a final
`git diff`/`git status` check that it matches its pre-session state). The three
load-bearing fixtures (`tool/spike_assets/tokenizer.json`, `smoke_corpus.json`,
`reference_ids.json`) were copied onto the new branch and staged (`git add`);
they were **not committed** — the harness's own pre-commit hook intercepts any
`git commit` invocation and runs `make pre_commit` unconditionally (unrelated to
this plan's explicit "do not run `make pre_commit` for this spike" instruction),
so a formal commit was skipped deliberately rather than bypassing that hook. The
fixtures and prototype files exist in the branch's working tree, which is
sufficient for a throwaway spike; Phase 1 should commit properly when it starts.

**Reference-oracle provenance.** `tool/spike_compare.dart:19` (pre-existing,
copied from `wi4-tokenizer-spike`, not written by this session) documents
`reference_ids.json` as real HuggingFace `AutoTokenizer` output for
`intfloat/multilingual-e5-small`. Corroborated independently: the four
special-token ids match XLM-R's known fairseq-remapped positions (`<s>`=0,
`</s>`=2), and no Dart code anywhere in this project's history produced this
file — it is not a circular reference.

**Trie format (Q1).** `precompiled_charsmap` (base64 inside `tokenizer.json`'s
`normalizer.normalizers[0]`, `type: "Precompiled"`) is:

```
[0..4)   little-endian uint32: byte length of the trie blob
[4..4+n) trie blob: n/4 little-endian uint32 darts-clone double-array units
[4+n..)  NUL-delimited UTF-8 replacement-string table
```

confirmed against `google/sentencepiece`'s `normalizer.cc`
(`DecodePrecompiledCharsMap`/`EncodePrecompiledCharsMap`) and independently
against the Rust `spm_precompiled` crate's `parse()`. Each 32-bit trie unit
packs (per `darts-clone`'s `include/darts.h`, `Details::DoubleArrayUnit`):
`has_leaf()` = bit 8; `value()` = low 31 bits; `label()` = MSB + low byte;
`offset()` = `(unit >> 10) << ((unit & (1<<9)) >> 6)`.

**Traversal algorithm — the ambiguous point.** SentencePiece's own C++
(`Normalizer::NormalizePrefix`) does a flat byte-position scan picking the
_longest_ match. The real oracle (`reference_ids.json`, via HuggingFace
`AutoTokenizer` → `tokenizers` crate → `spm_precompiled`) uses a **different**
algorithm (`Precompiled::normalize_string`): split the input into Unicode
extended grapheme clusters; for each cluster under 6 UTF-8 bytes, try a
whole-cluster trie lookup first; on no match (or cluster ≥ 6 bytes), fall back
to looking up each individual character in the cluster, passing through
unmatched characters unchanged. The prototype (`tool/spike_charsmap_trie.dart`)
implements this grapheme-then-char algorithm, not naive SentencePiece-C++ byte
scanning — matching the actual oracle mattered, not the original C++
description.

**Two real defects found (beyond the already-known charsmap-drop bug):**

1. **Leaf-selection direction.** A literal reading of `spm_precompiled`'s
   `Precompiled::transform` (`let index = results[0]`) takes the _shortest_
   matched-prefix leaf found while walking a key's bytes (leaves are appended to
   the results vector in walk order, shortest-to-longest). Empirically wrong for
   at least one real smoke-corpus case: NFD `"Việt"` (`e` + combining dot-below
   U+0323 + combining circumflex U+0302, one extended grapheme cluster) has two
   leaves along its byte path — a shorter one (`e`+dot-below → `ẹ`) and a
   longer, complete one (all three codepoints → `ệ`). Taking the shortest
   (`results.first`) drops the circumflex and fails parity; taking the
   **longest** (`results.last`, matching SentencePiece C++'s own explicit
   longest-match rule) fixes it and produces byte-exact parity on the full
   corpus. Recorded directly in `CharsmapTrie.transform`'s doc comment for Phase
   1's benefit — this is a genuine gotcha for whoever ports the prototype, not a
   hypothetical.
2. **`dart_sentencepiece_tokenizer`'s HF-JSON loader also mis-derives
   whitespace/dummy-prefix flags for this tokenizer.json's shape** — a second,
   independent defect from the already-known charsmap-drop one.
   `_parseNormalizerFlags` only inspects the `normalizer` section (looking for
   literal `Prepend`/`Replace(content: "▁")` nodes); it never reads
   `pre_tokenizer`. `multilingual-e5-small`'s tokenizer.json puts its
   dummy-prefix/whitespace-escaping entirely in `pre_tokenizer`
   (`{"type": "Metaspace", "replacement": "▁", "add_prefix_space": true}`), and
   its `normalizer` section's second entry (`Replace` for `" {2,}"` → `" "`)
   doesn't match the heuristic's `content == "▁"` check either. Confirmed
   directly: `tokenizer.normalizer.toString()` prints
   `SpNormalizer(addDummyPrefix: false, removeExtraWhitespaces: false, escapeWhitespaces: false)`
   — all three flags false, which makes `SpNormalizer.normalize()` an
   unconditional identity pass-through for this file. This is actually
   convenient: it means Phase 0's compose script could replicate the
   whitespace-collapse (`_collapseSpaceRuns`) and Metaspace (`_metaspace`) steps
   itself, ahead of `encode()`, without fighting the library's own (silently
   disabled) logic. Confirmed empirically: feeding the library literal
   pre-escaped text (e.g. `"▁Hello"`) produces the correct single-token id,
   while plain `"Hello"` or `" Hello"` does not.

**Compose pipeline that achieved parity** (`tool/spike_wi11_compose.dart`):
`text` → `CharsmapTrie.normalize()` (charsmap substitution, grapheme-then-char,
longest-leaf) → `_collapseSpaceRuns()` (collapse runs of ≥2 spaces) →
`_metaspace()` (prepend a space if absent, replace every space with `▁`) →
`HuggingFaceTokenizerLoader.fromJsonString(tokenizerJsonRaw)` →
`tokenizer.encode(normalizedText, addSpecialTokens: true)` → compare `.ids`
against `reference_ids.json`.

**Result:**

```
[PASS] ar (47 tokens)
[PASS] edge_fullwidth (4 tokens)
[PASS] edge_nfd (6 tokens)
[PASS] edge_punct (15 tokens)
[PASS] en (39 tokens)
[PASS] hi (50 tokens)
[PASS] ko (49 tokens)
[PASS] ru (43 tokens)
[PASS] th (48 tokens)
[PASS] vi (85 tokens)
[PASS] zh (32 tokens)

=== Summary: 11 passed, 0 failed ===
```

**Decision: PASS.** Compose hypothesis (Q4) confirmed, with the correction that
Phase 1's compose wrapper must own three normalization steps — charsmap
substitution, whitespace-run collapse, and Metaspace escaping — not just the
charsmap alone, since the library's own metadata-derived flags cannot be trusted
for this tokenizer.json shape. Q2 (fairseq remapping) is answered by the same
11/11 result: no separate remapping step was needed. Q5 is now confirmed to
require a `NOTICE` entry in Phase 1 (see Open Questions above), since the
prototype ported `spm_precompiled`'s traversal structure, not just cross-checked
behaviour.

**No Phase 1+ work was started.** No new package or `lib/src/` files were
created inside `betto_inferencing`; no `README`/`NOTICE` changes were made;
`dart_sentencepiece_tokenizer` was added to `pubspec.yaml` only as a
dev-dependency for the spike script (Phase 1 will need to move it to a normal
`dependencies` entry). `make pre_commit`, `make coverage`, and `kmdb-qa` were
deliberately not run — this phase is an investigation spike, not a completed
implementation.

**Phase 0 prototype files (throwaway, on `wi11-tokenizer-normalizer-spike`
only):** `tool/spike_charsmap_trie.dart` (the `CharsmapTrie` Darts-trie
reader/normalizer), `tool/spike_wi11_compose.dart` (the compose/comparison
script), plus the three copied fixtures under `tool/spike_assets/`.

### Phase 1

**Phase 1 — land `CharsmapTrie` + `XlmRobertaTokenizer` in `betto_inferencing`**

_Fleshed out 2026-07-09 now that Phase 0 has landed (11/11 byte-exact, exact
trie format and compose pipeline known — see "Phase 0 results" above). This
phase is now concrete, not sketched — ready for `kmdb-plan-reviewer`._

- [x] **Consolidate the spike branches into a real feature branch.** Cut
      `wi11-xlmr-tokenizer` from `main` in
      `~/development/bettongia/inferencing`. Port (not copy verbatim — clean up
      per the steps below) the working logic from
      `wi11-tokenizer-normalizer-spike`'s `tool/spike_charsmap_trie.dart` and
      `tool/spike_wi11_compose.dart`. Once ported, both `wi4-tokenizer-spike`
      and `wi11-tokenizer-normalizer-spike` are superseded — confirm nothing
      load-bearing remains only on either, then discard both branches.

      **Done (2026-07-09).** `wi11-xlmr-tokenizer` cut fresh from `main` (not
      from either spike branch, so no spike history/commits carried over).
      `CharsmapTrie`'s logic was ported from
      `wi11-tokenizer-normalizer-spike`'s `tool/spike_charsmap_trie.dart` with
      production doc comments, an added defensive out-of-range guard in
      `_commonPrefixSearch` (malformed trie data degrades to "no match"
      rather than throwing `RangeError`), and the debug-only
      `debugAllPrefixMatches` helper dropped (unused outside the spike). The
      compose pipeline from `tool/spike_wi11_compose.dart` was ported into
      `XlmRobertaTokenizer`'s `encode()`/`normalizeForTokenization`. Neither
      spike branch (`wi4-tokenizer-spike`, `wi11-tokenizer-normalizer-spike`)
      was merged or deleted — deletion was left to the user per the plan's
      explicit "confirm before deleting" instruction; nothing load-bearing
      remains only on either now that porting is complete.

- [x] **`lib/src/charsmap_trie.dart` (new): `CharsmapTrie`.** Parses
      `precompiled_charsmap` bytes
      (`[4B LE trie length][darts-clone     double-array trie units][NUL-delimited replacement-string table]`
      — see Phase 0 results for the exact layout and unit-packing bit layout)
      and implements `String normalize(String text)` via the grapheme-cluster-
      then-char lookup algorithm the real oracle actually uses (not naive
      SentencePiece-C++ byte scanning — see Phase 0 results). **The doc comment
      on the traversal/leaf-selection logic must explicitly record the
      longest-vs-shortest-leaf finding** (a literal reading of
      `spm_precompiled`'s `Precompiled::transform` picks the _shortest_
      matched-prefix leaf; this is wrong — the NFD `"Việt"` case proves the
      **longest** leaf is required) so a future reader doesn't "fix" it back to
      shortest by re-deriving from `spm_precompiled` naively. Proper error
      handling for malformed/truncated trie bytes (throw a clear, typed error —
      not a crash or silent corruption).

      **Done (2026-07-09).** Implemented at
      `~/development/bettongia/inferencing/lib/src/charsmap_trie.dart`,
      100% line coverage per `make coverage`. `parse()` throws
      `FormatException` for a blob under 4 bytes or a trie-length header that
      isn't a multiple of 4 / overruns the blob. Also added a defensive
      out-of-range guard inside `_commonPrefixSearch` (not called out
      explicitly by the plan, but a natural extension of "not a crash": a
      corrupt/degenerate trie that passes `parse()`'s header checks but
      contains an out-of-range node offset now degrades to "no match" instead
      of throwing `RangeError` at lookup time). The longest-vs-shortest-leaf
      gotcha is recorded verbatim on `transform()`'s doc comment. Regression
      tests in `test/charsmap_trie_test.dart` (15 tests) cover the NFD
      `"Việt"` case, fullwidth→ASCII folding, ellipsis normalization,
      pass-through of unmatched characters (curly quotes), empty input, and
      all three malformed-input error paths plus the defensive guard.

- [x] **`lib/src/xlmr_tokenizer.dart` (new): `XlmRobertaTokenizer`.** Loads a
      `tokenizer.json` (extracting
      `normalizer.normalizers[0].precompiled_charsmap` for `CharsmapTrie`, and
      passing the full JSON to
      `HuggingFaceTokenizerLoader.fromJsonString`/`.fromMap` for the underlying
      `SentencePieceTokenizer`). Its `encode(String text)` method composes, in
      order: (1) `CharsmapTrie.normalize()`, (2) whitespace-run collapse, (3)
      Metaspace escaping (prepend a leading space if absent; replace spaces with
      `▁`), (4) `tokenizer.encode(normalizedText,     addSpecialTokens: true)`.
      **Doc comment must explain _why_ steps 2–3 are done manually here rather
      than trusted to the library's own `SpNormalizer`**:
      `dart_sentencepiece_tokenizer`'s HF-JSON metadata parser derives
      `addDummyPrefix`/`removeExtraWhitespaces`/ `escapeWhitespaces` by
      pattern-matching the `normalizer` section, but `multilingual-e5-small`'s
      `tokenizer.json` puts that configuration in `pre_tokenizer.Metaspace`
      instead — so all three flags come back `false` and the library's own
      whitespace handling silently no-ops for this file (confirmed empirically
      in Phase 0 — this is a second, independent defect from the already-known
      charsmap-drop one). **Sequencing note — do not write
      `implements ModelTokenizer` here.** `ModelTokenizer` (WI-4's Q2) doesn't
      exist yet — it's created by WI-4's own Phase 2, which in turn is gated on
      this plan completing. Writing `XlmRobertaTokenizer` against a nonexistent
      interface would be circular.

      **Output contract (B1 — resolved):** `encode()` returns the **existing
      `TokenizerOutput`** class from `bert_tokenizer.dart`, reused verbatim —
      not a new type. This makes both tokenizers return the identical
      concrete type today, and makes "add `implements ModelTokenizer` to
      `XlmRobertaTokenizer`" in WI-4's Phase 2 a trivial one-line addition
      rather than a type-reconciliation exercise (see the corresponding fix
      now recorded in WI-4's own plan: its planned `ModelInput` type should
      collapse onto `TokenizerOutput`, not introduce a second parallel
      shape). Concretely:
      - **Do the actual tokenization via `dart_sentencepiece_tokenizer`'s own
        `SentencePieceTokenizer.encode()`**, which returns its own `Encoding`
        type (`Int32List ids`, `Uint8List typeIds`/`attentionMask` — checked
        directly in `sentencepiece_tokenizer.dart`/`encoding.dart`). Convert
        `Encoding` → `TokenizerOutput` (`Int64List` fields, per
        `OnnxTensor.fromInt64`'s requirement) inside `XlmRobertaTokenizer`.
      - **`tokenTypeIds`:** RoBERTa/XLM-R doesn't use segment ids, but
        `TokenizerOutput` requires the field — populate it as an all-zeros
        `Int64List` of the same length (this is also what the library's own
        `Encoding.typeIds` already is for single-segment input, so the
        conversion is a direct widen, not invented data).
      - **Padding/truncation: use the library's own `padding`/`truncation`
        config, do not hand-roll `BertTokenizer`-style logic.** Checked
        directly: `SentencePieceTokenizer.encode()` already sources the pad
        token id from the loaded vocab (`vocab.padId >= 0 ? vocab.padId : 0`,
        `sentencepiece_tokenizer.dart:318` etc.) — for `multilingual-e5-small`
        that's **`1`**, correctly, automatically, with no risk of the
        BERT-specific `padId = 0` bug the reviewer flagged. Configure via the
        library's **methods** (not property assignment — `padding`/`truncation`
        are read-only getters, verified in `sentencepiece/sentencepiece_tokenizer.dart:177,180`):
        `tokenizer.enablePadding(direction: SpPaddingDirection.right, length:
        maxLength)` and `tokenizer.enableTruncation(maxLength: maxLength,
        direction: SpTruncationDirection.right)` (the real public config points,
        `sentencepiece/sentencepiece_tokenizer.dart:183,204`; both return
        `this` for chaining). **Confirm the actual `maxLength` value against
        `multilingual-e5-small`'s own `tokenizer_config.json`/`config.json`
        at implementation time** — default to 512 (matching `BertTokenizer`'s
        own default and typical XLM-R/E5 config) only if the real config
        doesn't specify something else; do not assume without checking.
      - **`truncated` (B1b — resolved): two-pass, with an explicit per-call
        reset.** Verified against source: `Encoding` exposes no
        overflow/truncated field, and `_applyPostProcessing` truncates *before*
        padding to the same `maxLength`
        (`sentencepiece/sentencepiece_tokenizer.dart:250-334`), so a padded
        output is always exactly `maxLength` long and its length can't
        distinguish "truncated" from "padded." **Decision:** two-pass. But note
        (verified at source) that `enablePadding`/`enableTruncation` mutate
        **persistent instance state** on the shared `SentencePieceTokenizer`
        (`_paddingConfig`/`_truncationConfig`, `:90-91`) — they are *not*
        per-call arguments and stick across `encode()` calls. So the two passes
        must be, on **every** `XlmRobertaTokenizer.encode()` invocation, in this
        exact order:
        1. `tokenizer.noPadding(); tokenizer.noTruncation();` — reset to the
           unbounded state (`noPadding()` `:197`, `noTruncation()` `:215`; both
           return `this`). This reset is **mandatory each call**, not a
           one-time setup: without it, the "unbounded" pass would still be
           bounded by the *previous* call's config and `truncated` would
           silently stick `false` after the first call.
        2. First pass — `final rawLength = tokenizer.encode(normalizedText,
           addSpecialTokens: true).ids.length;` (now genuinely unbounded).
        3. `final truncated = rawLength > maxLength;`
        4. `tokenizer.enablePadding(direction: SpPaddingDirection.right,
           length: maxLength); tokenizer.enableTruncation(maxLength: maxLength,
           direction: SpTruncationDirection.right);`
        5. Second pass — re-`encode()` the *same* `normalizedText` with the
           *same* `addSpecialTokens: true` for the real, padded/truncated
           result that populates `TokenizerOutput`.

        Both passes must use identical `addSpecialTokens: true` so `rawLength`
        (which includes BOS/EOS) is compared against the same `maxLength` the
        bounded pass truncates to. This doubles tokenization cost per
        `encode()` call, accepted as negligible relative to the ONNX model
        inference that follows it, and avoids re-implementing the library's own
        (already-correct) truncation/padding logic by hand — exactly what B1's
        main resolution moved away from. Manual slice+pad was considered and
        rejected for the same reason. (The library's own
        `encodeBatch`/`encodePair`, `:432-441`/`:555-590`, use the equivalent
        save→null→work→restore idiom internally, confirming this reset pattern
        is the intended way to take an unbounded pass on a configured
        instance.)

      **Done (2026-07-09).** Implemented at
      `~/development/bettongia/inferencing/lib/src/xlmr_tokenizer.dart`
      exactly per the resolved design above: `encode()` returns
      `TokenizerOutput` (reused verbatim from `bert_tokenizer.dart`),
      `tokenTypeIds` is the direct `Int64List` widen of `Encoding.typeIds`,
      padding/truncation are configured via `enablePadding`/`enableTruncation`
      (not hand-rolled), and `truncated` uses the exact 5-step two-pass
      sequence with a mandatory `noPadding()`/`noTruncation()` reset at the
      start of every `encode()` call. `maxLength` defaults to 512 — confirmed
      against `multilingual-e5-small`'s own `tokenizer.json`, which declares
      no `truncation`/`padding` section of its own (no stronger signal to
      defer to), and matches the model's published `max_seq_length`. Per B3,
      `load()` and `encode()`'s vocab-dependent tail are wrapped in
      `// coverage:ignore-start`/`-end`; steps 1–3 of the compose pipeline are
      exposed as `@visibleForTesting static normalizeForTokenization` so they
      remain plain, offline-testable methods (not vocab-dependent) — covered
      by `test/xlmr_tokenizer_test.dart`. Two mechanical additions beyond the
      plan's literal text, needed to make the ported code compile/run rather
      than reflecting any design change: `package:characters` (used by
      `CharsmapTrie`) also had to move from `dev_dependencies` to
      `dependencies` alongside `dart_sentencepiece_tokenizer`, and
      `package:meta` (`^1.16.0`) was added as a normal dependency for the
      `@visibleForTesting` annotation.

- [x] Add `dart_sentencepiece_tokenizer: ^1.3.2` as a **normal** dependency in
      `betto_inferencing`'s own `pubspec.yaml` (Phase 0 only added it as a
      dev-dependency for the spike script). **Vehicle for this change:**
      `betto_inferencing`'s `pubspec.yaml`/`CHANGELOG.md` already carry an
      unpublished, empty `0.1.0-dev.2` bump (per WI-4's own Investigation) —
      land this dependency change, plus WI-4 Phase 2's own additions, in that
      same still-unreleased version rather than bumping again, consistent with
      the "single release with WI-4 Phase 2" instruction below.

      **Done (2026-07-09).** Moved to `dependencies` in the still-unreleased
      `0.1.0-dev.2` (`CHANGELOG.md` updated with a Features entry for this
      release). `characters` also moved dev→normal alongside it (needed by
      `CharsmapTrie`, not called out explicitly by this bullet's literal text
      — see the `XlmRobertaTokenizer` item above for why).

- [x] **Tests — fixture strategy matches this project's existing precedent**
      (`BertTokenizer`'s own tests use a small synthetic
      `test/fixtures/vocab.txt`, not the real downloaded BGE vocab — do the
      analogous thing here, not the full 17 MB `tokenizer.json`): -
      `test/fixtures/xlmr_precompiled_charsmap.b64` (new) — **just** the
      extracted `precompiled_charsmap` base64 string from
      `multilingual-e5-small`'s real `tokenizer.json` (~317 KB base64 / ~237 KB
      raw — small enough to commit directly, unlike the full 17 MB file, which
      is 98%+ the 250k-entry vocab table this fixture doesn't need).
      `CharsmapTrie` unit tests run against this in isolation: no network, no
      vocab, no full tokenizer required. - `CharsmapTrie` unit tests against
      that fixture: **the NFD `"Việt"` case is the single most important
      regression test** — it's the one case that actually distinguishes correct
      (longest-leaf) from plausible-but-wrong (shortest-leaf) behaviour; also
      cover fullwidth→ASCII, curly-quote/ellipsis normalization, an
      unmatched/pass-through character, and empty string. - **Parity gate (B2 —
      resolved): use the 11-entry smoke corpus, not WI-4's UDHR fixture.**
      `test/fixtures/xlmr_smoke_corpus.json` (the 11 texts) and
      `test/fixtures/xlmr_reference_ids.json` (their real
      `AutoTokenizer`-produced expected ids, provenance already confirmed in
      Phase 0) — commit both; they exist today only as untracked working-tree
      files on the (soon-discarded) `wi4-tokenizer-spike` branch, so carrying
      them over into this plan's real feature branch is load-bearing, not
      optional, same class of gap RQ2 caught for Phase 0. **Do not** reuse or
      build WI-4's `xlmr_parity_corpus.json` — it doesn't exist, and per WI-4's
      own Q4 that fixture is a different, broader UDHR-derived corpus requiring
      its own Python `AutoTokenizer` hand-off pause that this plan doesn't set
      up. Building the full parity gate is this plan's job, not something to
      reuse. - **This test genuinely needs the real 17 MB `tokenizer.json` to
      run** (it's exercising the actual library `encode()` against the actual
      250k-entry vocab) — **do not commit it**; download-and-cache it the same
      way `betto_inferencing`'s existing ORT integration tests already do for
      real model assets (`cicd.yml`'s `test-macos` job). **State this trade-off
      explicitly, don't leave it implicit:** WI-4's own Q4 deliberately designed
      its (never-built) parity fixture to need _no network and no Python in CI,
      ever_, by committing the whole text+ids corpus. This plan's gate
      reintroduces a `huggingface.co` dependency at test time because the
      alternative — committing a 17 MB file that's 98% an unused-for-testing
      vocab table — is worse. This is an accepted, stated divergence from WI-4
      Q4's design point, not an oversight. - **CI job placement (non-blocking
      item, resolved):** default to piggybacking this test onto the existing
      `test-macos` job (simpler, lower implementation risk) rather than building
      a new lighter job, even though this test only needs `tokenizer.json` (17
      MB) and not the ~470 MB `model.onnx`. Revisit only if this job's runtime
      actually becomes a measured CI problem — do not treat CI topology as an
      open design decision at implementation time. - **Offline coverage (B3 —
      resolved): apply this project's existing `// coverage:ignore-start`/`-end`
      convention**, the same one `onnx_embedding_model.dart` already uses for
      its own ORT-session- dependent methods ("Requires a live ORT session —
      covered by integration tests with model assets"). Wrap
      `XlmRobertaTokenizer`'s `load()` and the vocab-dependent tail of
      `encode()` (the `SentencePieceTokenizer.encode()` call and
      `Encoding`→`TokenizerOutput` conversion) the same way — covered by the
      gated integration test above, not `make coverage`. Keep steps 1–3 of the
      compose pipeline (`CharsmapTrie.normalize()`, whitespace-run collapse,
      Metaspace escaping) as plain, uncovered-annotation-free methods: they need
      only the small committed charsmap fixture, run fully offline, and are
      exactly what the `CharsmapTrie`/`"Việt"` regression tests already exercise
      — this is what lets the file clear the coverage bar without a synthetic
      full `tokenizer.json` (hand-authoring a valid darts-clone charsmap blob
      was considered and rejected as disproportionate effort for this purpose).

      **Done (2026-07-09).** All fixtures committed exactly as specified:
      `test/fixtures/xlmr_precompiled_charsmap.b64` (316,720 bytes, extracted
      from the real `tokenizer.json`), `test/fixtures/xlmr_smoke_corpus.json`,
      `test/fixtures/xlmr_reference_ids.json` (both carried over from
      `wi4-tokenizer-spike`'s untracked working-tree files). `CharsmapTrie`
      tests (15) cover the NFD `"Việt"` regression plus fullwidth, ellipsis,
      pass-through, empty-string, and malformed-input cases —
      `test/charsmap_trie_test.dart`. Offline `XlmRobertaTokenizer` tests (7)
      cover `normalizeForTokenization`'s three-step pipeline (charsmap +
      whitespace-collapse + Metaspace) and `_extractCharsmapTrie`'s
      success/failure paths — `test/xlmr_tokenizer_test.dart`. The
      network-gated 11-entry byte-exact parity test (plus padding/
      attention-mask/truncation checks against the real vocabulary) was added
      to the existing Flutter integration suite,
      `integration_test_app/integration_test/inferencing_test.dart`
      (piggybacked on the existing `test-macos` job per the CI-placement
      resolution, downloading `multilingual-e5-small`'s real `tokenizer.json`
      directly from `huggingface.co` — not via `ModelDownloader`/
      `ModelCatalog`, since that model isn't a registered catalog entry yet;
      that's WI-4's job). `make coverage` on the resulting `test/` suite:
      94.3% overall (up from the pre-change baseline), `charsmap_trie.dart`
      100%, `xlmr_tokenizer.dart` 87.5% (the only uncovered lines are the
      private constructor and `encode()`'s declaration line, both only
      reachable from a real loaded instance — i.e. exactly the
      `// coverage:ignore`-designated, integration-test-only surface B3
      anticipated).

      **Post-review fix (2026-07-09): cross-platform fixture-loading bug.**
      The integration test's first cut loaded the two fixture JSON files via
      a `dart:io` `File` read relative to `Directory.current`
      (`'${Directory.current.path}/../test/fixtures'`) — this only resolves
      to something meaningful on desktop (`make macos_test`, the job CI
      actually runs), because the host source checkout is visible there.
      Running `make ios_test` against this branch surfaced the real bug:
      inside an iOS simulator's app-sandbox container the host tree isn't
      present at all, so `Directory.current` resolves to nothing useful and
      the read fails with `PathNotFoundException`. The same would have hit
      `make android_test` for the identical reason. Fixed by declaring the
      two fixtures as Flutter `assets` in `integration_test_app/pubspec.yaml`
      and loading them via `rootBundle.loadString` instead — verified this
      works uniformly by confirming asset-bundling behaviour directly (a
      `../`-escaping asset path builds without error but is **not** actually
      copied into `flutter_assets/`, so `rootBundle` can't see it there
      either; the fix instead symlinks the two files into
      `integration_test_app/test/fixtures/`, inside the app's own project
      root, and declares assets from that in-tree location — one source of
      truth, no duplicated fixture content). Re-verified `make macos_test`,
      `make ios_test`, and `make android_test` all pass (20/20 each). Second
      commit on the same PR/branch.

- [x] **`NOTICE` file in `betto_inferencing`'s repo root** (new precedent for
      that repo — it has none today, only a top-level `LICENSE`). Q5 confirmed
      this is needed: the traversal algorithm's _structure_ was ported from
      `spm_precompiled`'s Rust source, not just cross-checked — cite
      specifically `DoubleArray::common_prefix_search`,
      `Precompiled::transform`, and `Precompiled::normalize_string`'s
      grapheme-then-char fallback strategy (`huggingface/spm_precompiled`,
      Apache-2.0).

      **Done (2026-07-09).** See Q5 above — same `NOTICE` file.

- [x] **`betto_inferencing`'s own `README.md`** must state the
      `dart_sentencepiece_tokenizer` dependency, its licence (MIT — compatible
      with this project's Apache-2.0 convention, state it explicitly rather than
      leaving it implicit in `pubspec.yaml`), and **why it couldn't be used
      as-is — both defects found, not just the originally-known one**: (1) it
      parses `precompiled_charsmap` bytes but never applies them
      (`huggingface_json.dart`'s `_buildNormalizerSpec`), and (2) its HF-JSON
      metadata parser also fails to derive the correct whitespace/dummy-prefix
      configuration for tokenizer.json files that put it in
      `pre_tokenizer.Metaspace` rather than `normalizer` (found during this
      plan's Phase 0). Point to this plan's Investigation section for full
      evidence rather than duplicating it, but the summary itself must live in
      the README — a future maintainer shouldn't have to find this plan to
      understand the design.

      **Done (2026-07-09).** Added a "Why not `dart_sentencepiece_tokenizer`
      alone" section to `README.md` naming both defects, the MIT licence
      compatibility statement, and pointers to `NOTICE` and this plan.

- [x] Run `make pre_commit` in `betto_inferencing`. **No separate pub.dev
      publish step for this work specifically** — it ships as part of
      `betto_inferencing`'s next normal version bump. Coordinate with WI-4's
      Phase 2, which already needs a `betto_inferencing` version bump of its own
      (E5 model registration, `ModelTokenizer`/`EmbeddingKind` additions) —
      landing both in the same release avoids two separate publish/pin cycles.

      **Done (2026-07-09).** Initially only `format_check`/`analyze`/`test`
      could be verified directly (`addlicense` wasn't installed and `go
      install` couldn't reach `proxy.golang.org` from the implementing
      session's sandbox). Once `addlicense` became available, `make
      pre_commit` was re-run in full and passed clean (format_check, analyze,
      license_check, test all green) — see the Final step's identical bullet
      below for the confirmed run.

- [ ] Update WI-4's plan: unblock its Q6 hard gate (already noted at the top of
      WI-4's plan, cross-referencing this one). Update `docs/roadmap/0_06.md`'s
      WI-4/WI-11 entries to reflect completion.

      **Deliberately not done in this session (2026-07-09).** The user's
      explicit task instructions for this implementation session scoped it to
      "WI-11 Phase 1 only... plus plan-checklist updates in the kmdb repo's
      plan doc" (singular — this file), and separately said "Do not touch
      WI-4's plan or any kmdb-repo source code." Editing
      `plan_0_06_wi4_multilingual_embedding_model.md` or
      `docs/roadmap/0_06.md` would contradict that explicit, more specific
      instruction, so both are left as a follow-up for whoever resumes WI-4
      (or the main session) once this plan's PR is open/merged — at which
      point WI-4's Q6 hard gate can be unblocked for real, with the actual PR
      link and merge status in hand rather than an implementation-in-progress
      status.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` in `betto_inferencing` — confirm all new files meet
      this project's coverage bar.

      **Done (2026-07-09).** 94.3% overall (209 lines, 197 hit) — see the
      Tests bullet above for the per-file breakdown. Comfortably above the
      90% bar.

- [x] Run `make pre_commit` in `betto_inferencing` — format, analyze,
      license_check, tests all green. (No `kmdb-qa` hand-off here — this work is
      entirely within `betto_inferencing`, a separate repo from `kmdb`; the same
      as how WI-4's own `betto_inferencing`-side phases don't invoke `kmdb-qa`
      either. `kmdb-qa` applies once WI-4's Phase 3 wires this into `kmdb`
      itself.)

      **Done (2026-07-09).** `make pre_commit` (`format_check`, `analyze`,
      `license_check` via `addlicense`, `test`) ran clean end-to-end once
      `addlicense` was available in the implementing session's environment —
      exit code 0, no diffs, no analyzer issues, `license_check` silent-pass
      (addlicense's normal success signal), 114/114 tests passing.

- [x] Verify licence headers on all new files (2026).

      **Done (2026-07-09).** Confirmed both manually (all new `.dart` files
      carry `// Copyright 2026 The Authors.` matching `header_template.txt`
      and this repo's existing convention) and mechanically, via the clean
      `make license_check`/`addlicense --check` run noted above. `NOTICE`
      and `CHANGELOG.md`/`README.md` updates are not source files
      `addlicense` instruments (no header needed, consistent with the
      existing repo's untouched `.md` files).

## Reviewer feedback (kmdb-plan-reviewer, 2026-07-08)

Reviewed against `docs/plans/README.md`. Every source-level claim in this plan
was independently verified against `dart_sentencepiece_tokenizer-1.3.2` and the
retained spike assets — they all hold. This is an unusually well-investigated,
correctly-scoped plan, and the spike-first structure with a hard decision-point
gate is exactly the right shape for this problem. One concrete Phase-0 execution
defect and a small number of Phase-0 specification gaps must be resolved before
Phase 0 is safe to hand to an implementer.

### Problem statement — sound

The problem is real, well-motivated, and correctly gated: WI-4's Q6 hard gate
fired (0/11 byte-exact), and this is the mandated follow-on. Verified: the spike
assets (`smoke_corpus.json`, `reference_ids.json`, `tokenizer.json`,
`sentencepiece.bpe.model`) are present at
`~/development/bettongia/inferencing/tool/spike_assets/`, and the
`wi4-tokenizer-spike` branch has exactly the uncommitted state described
(`M pubspec.yaml`, untracked `tool/`).

### Solution approach — sound, and the root-cause diagnosis is correct

Verified against source:

- `huggingface_json.dart:_buildNormalizerSpec` (l.292–299) reads
  `addDummyPrefix`/`removeExtraWhitespaces`/`escapeWhitespaces` but never passes
  a `precompiledCharsmap` — the charsmap is silently dropped on the JSON path.
- `precompiledCharsmap` is only ever populated on the **protobuf** path
  (`model/sentencepiece_model.dart` field 2 → `model_proto.dart:108`).
- The private constructor `SentencePieceTokenizer._` (l.93) and the routing of
  every factory through `_createFromModel` (which builds `SpNormalizer.fromSpec`
  with no injection point) confirm the plan's claim that subclass/swap is
  impossible and compose-before-`encode()` is the viable seam.
- `SentencePieceConfig.addBosToken/addEosToken` exist and are auto-derived from
  metadata by the HF loader — corroborating the "BOS/EOS already work" claim.

The narrowing from "port a whole tokenizer" to "supply one missing charsmap-trie
normalizer and compose" is well-evidenced and, critically, the plan holds it as
an _unconfirmed hypothesis_ that Phase 0 must prove — not an assumption. Good.

### Blocking items for Phase 0 (must resolve before `Investigated`)

- [x] **RQ1 — Phase 0 names the wrong public API for loading `tokenizer.json`.**
      Phase 0 step 3 says feed the normalized text into
      `SentencePieceTokenizer.fromBytes`/`.encode()` "loaded from the same
      `tokenizer.json`." This is factually wrong and will not run: `fromBytes`
      (l.121) calls `SentencePieceModelLoader.fromBytes`, which parses the
      **protobuf `.model`** format — feeding it `tokenizer.json` bytes would
      throw/garble. The correct public entry-point for HuggingFace
      `tokenizer.json` is **`HuggingFaceTokenizerLoader.fromJsonString`** (or
      `.fromMap`/`.fromJsonFileSync`), exported from the package top-level. This
      matters beyond a typo: `fromJsonString` → `fromMap` → the _defective_
      `_buildNormalizerSpec`, i.e. it is precisely the charsmap-dropping JSON
      path this plan is built around, whereas `fromBytes`/protobuf actually
      _does_ populate the charsmap and would exercise a different code path with
      a different bug profile. Fix step 3 (and any other reference) to name
      `HuggingFaceTokenizerLoader.fromJsonString`. Note the spike dir also
      contains `sentencepiece.bpe.model` (the protobuf) — be explicit that Phase
      0 loads the **`.json`** file via the HF loader, not the `.model` file via
      `fromBytes`, so the two don't get conflated.

      **Resolved:** Phase 0's compose step now names
      `HuggingFaceTokenizerLoader.fromJsonString` (or `.fromMap`/
      `.fromJsonFileSync`) explicitly, with an inline note explaining exactly
      why `fromBytes`/`fromModelFile` must not be used here (protobuf path,
      different bug profile) — the two loading paths are called out by name
      so they can't be conflated.

- [x] **RQ2 — Phase 0 doesn't say where the prototype code and copied fixtures
      live.** Phase 1 explicitly forbids scaffolding the new package until Phase
      0 lands, so the Phase 0 prototype cannot live in the (not-yet-created)
      package. It also should not deepen the `wi4-tokenizer-spike` branch that
      Phase 1 wants to discard. Name the Phase 0 working location concretely
      (e.g. a fresh throwaway branch/worktree, or a scratch tool dir) and name
      where the load-bearing fixtures — `tokenizer.json`, `smoke_corpus.json`,
      `reference_ids.json` — are copied to, so an implementer isn't inventing
      this on the fly and the Phase-1 tidy-up's "confirm Phase 0 copied what it
      needs" precondition has a concrete target. (The fixtures currently exist
      only as untracked working-tree files on a branch slated for deletion —
      copying them somewhere durable is genuinely load-bearing, not optional.)

      **Resolved:** Phase 0's first checklist item now names a concrete
      working location — a fresh throwaway branch cut from `main`
      (`wi11-tokenizer-normalizer-spike`, not `wi4-tokenizer-spike`) — and an
      explicit first step to copy the three load-bearing fixtures
      (`tokenizer.json`, `smoke_corpus.json`, `reference_ids.json`) onto it
      before any prototype code is written. Phase 1's tidy-up step was
      updated to match: it now discards *both* the original `wi4-tokenizer-spike`
      branch and this new Phase 0 work branch once its prototype has been
      moved into the scaffolded package.

      **Non-blocking notes also addressed:** reference-oracle provenance is
      now an explicit Phase 0 checklist item (confirm `reference_ids.json`
      came from a real HF `AutoTokenizer` run, not circularly from this
      project's own code, before trusting the gate); the Q2-redundancy note
      is folded into a "Q2 check" step clarifying the 11-entry smoke corpus
      already covers ordinary vocabulary, so passing it answers Q2 directly
      rather than requiring a separate probe; the `Trie`/`TrieNode` heads-up
      is now an inline note on the trie-format-study step so it isn't
      mistaken for a head start on the Darts charsmap trie.

### Non-blocking, worth tightening

- **Reference-oracle provenance (Q2 gate integrity).** The byte-exact gate is
  only as trustworthy as `reference_ids.json`. State in one line how it was
  produced (presumably HF `AutoTokenizer` on `multilingual-e5-small`, per WI-4's
  Q4) so the implementer trusts the oracle rather than treating a spike-produced
  file as ground truth. If it was generated by the spike's own Dart code, the
  gate is partly circular and needs an independent HF-derived reference.

- **Q2 may already be answered by the main gate.** Phase 0 step 5 ("extend to a
  handful of ordinary vocabulary entries" for Q2) is likely redundant with step
  3: the 11 smoke entries are full multilingual sentences, so if they pass
  byte-exact, ordinary-word ids are _already_ proven correct with no separate
  remap step — which is exactly what Q2 asks. Clarify whether step 5 is a
  distinct probe or just the observation that step 3 already covers Q2; as
  written an implementer may look for extra work that isn't needed.

- **Heads-up (not an error):** the package already exports
  `Trie/TrieNode/ TrieMatch` from `src/trie.dart`. That is a general-purpose
  trie (added-token matching), **not** the Darts double-array charsmap trie this
  plan must build — worth a one-line note so an implementer doesn't mistake it
  for a ready-made charsmap implementation.

### Implementation-readiness verdict

Phase 0's deliverable and success criterion (a `normalize(String)->String` that
yields 11/11 byte-exact on the smoke corpus, with a crisp diagnose/re-open-Q4
decision point) are well-specified — an inherently exploratory spike, but with
an unambiguous pass/fail gate, which is the right bar for a spike per README.
The blockers above (RQ1 wrong API, RQ2 undefined work location/fixture target)
are the only things that would force an implementer to guess. Resolve RQ1 and
RQ2 and Phase 0 is ready to execute; Phase 1+ is correctly left as sketch-only
pending Phase 0's outcome and should **not** be fleshed out yet. Status set to
**Questions**.

### Second pass (kmdb-plan-reviewer, 2026-07-08) — resolutions verified, promoted to Investigated

Both blockers and all three non-blocking notes were addressed by the main
session and re-verified against `dart_sentencepiece_tokenizer-1.3.2` source and
the retained spike assets:

- **RQ1 confirmed accurate.** `HuggingFaceTokenizerLoader` is exported from the
  package top level (`dart_sentencepiece_tokenizer.dart`); `fromJsonString`
  (`huggingface_json.dart:73`), `fromMap` (:82), and `fromJsonFileSync` (:145)
  all exist, and `fromMap` routes through `_parseUnigramModel` →
  `_buildNormalizerSpec` (:293) — the exact charsmap-dropping JSON path this
  plan targets. The warned-against `fromBytes` (:121, →
  `SentencePieceModelLoader.fromBytes`) and `fromModelFile` (:103) both exist
  and route to the protobuf loader, so the "do not use these" note names real
  methods with the stated distinct bug profile.
- **RQ2 confirmed accurate.** `wi4-tokenizer-spike` is checked out with exactly
  `M pubspec.yaml` + untracked `tool/`; `main` exists and is branchable for the
  fresh `wi11-tokenizer-normalizer-spike` branch; all three load-bearing
  fixtures are present in `tool/spike_assets/`. Phase 0's copy-fixtures step is
  first and precedes every fixture reference (provenance check, prototype,
  compose).
- **Provenance note.** `spike_compare.dart:19` documents `reference_ids.json` as
  real HuggingFace `AutoTokenizer` output, and the ids are XLM-R-shaped (`<s>`=0
  … `</s>`=2) — consistent with the plan's assumption. Keeping explicit
  confirmation as a Phase 0 step is correct.
- Minor cross-reference tidy applied to the work-location bullet (the `.model`
  exclusion now points at the compose step where it's actually justified, not
  the immediately-following bullet).

**Scope of this Investigated status:** it certifies **Phase 0** (the
investigation spike) as ready to execute without design guesswork. Phase 1+ is
deliberately sketch-only and gated on Phase 0's decision point; once Phase 0
lands (trie format nailed, compose hypothesis proven or Q4 re-opened), the
fleshed-out Phase 1 package build-out must return here for a fresh review pass
before it, in turn, is implemented. Do not treat the current Phase 1 sketch as
an implementation spec.

### Post-review update (2026-07-08): package boundary decision

After this review pass, the user asked whether `betto_inferencing` might be a
better home than a new standalone package, given `BertTokenizer` (an
architecturally equivalent model-specific tokenizer) already lives there rather
than in its own package. Decision: yes — this work now lands as new files inside
`betto_inferencing` directly (see "Package boundary" in Investigation, and the
title/header changes above). **This does not affect Phase 0's certified
status**: Phase 0 was always a throwaway spike branch inside
`~/development/bettongia/inferencing` regardless of where the final code would
land, and none of its steps (work location, fixture copying, trie study,
prototype, compose, decision point) reference package structure at all. Phase 1+
— already flagged above as requiring a fresh review pass regardless — has been
updated to target `betto_inferencing`'s own `lib/src/` instead of a new package
(no scaffolding, no separate pub.dev publish, no package name). Q3 (package
name) is now resolved as N/A. This plan document itself remains a standalone
tracked artifact under its own WI-11 roadmap entry, per the user's explicit
request, independent of where the code lands.

## Phase 1 review (kmdb-plan-reviewer, 2026-07-09)

Reviewing **Phase 1 only** — Phase 0 remains certified per the second-pass and
post-review notes above (11/11 byte-exact, Q1/Q2/Q4 resolved with source-level
evidence, Q5 confirmed needed). Every structural claim the task asked me to
double-check was verified against actual source in
`~/development/bettongia/inferencing`, not taken on the plan's word:

**Verified accurate (genuine strengths — do not re-litigate):**

- **No file/class collisions.** `lib/src/charsmap_trie.dart`,
  `lib/src/xlmr_tokenizer.dart`, and `lib/src/model_tokenizer.dart` do **not**
  exist; nor does a repo-root `NOTICE` (only `LICENSE`). The sequencing claim
  holds: `ModelTokenizer` genuinely does not exist yet, so "do not write
  `implements ModelTokenizer`" is correct, not defensive.
- **Fixture precedent is accurately characterized.** `test/fixtures/vocab.txt`
  is a 1,142-byte _synthetic_ vocab (its test's own comment documents an
  ~111-entry hand-built map), not the real 30,522-entry BGE vocab. Extracting
  only the ~317 KB base64 charsmap rather than committing the 17 MB
  `tokenizer.json` (confirmed: `tool/spike_assets/tokenizer.json` is 17,082,730
  bytes) is the right analogue for `CharsmapTrie` unit tests.
- **NOTICE citations are specific enough to execute** — exact Rust symbols named
  (`DoubleArray::common_prefix_search`, `Precompiled::transform`,
  `Precompiled::normalize_string`; `huggingface/spm_precompiled`, Apache-2.0).
- **README requirements name both defects** (charsmap-drop in
  `_buildNormalizerSpec`; whitespace/dummy-prefix mis-derivation for
  `pre_tokenizer.Metaspace`-shaped configs) with a pointer back to
  Investigation. Mechanically actionable.
- **Doc-comment gotchas are precisely specified** — the longest-vs-shortest-leaf
  finding and the why-we-replicate-whitespace/Metaspace rationale are both
  called out as required doc comments with enough context to survive into code.

The `CharsmapTrie` half of Phase 1 is implementation-ready. The
`XlmRobertaTokenizer` half and the parity-gate/coverage story are **not** — they
force the implementer into design decisions with cross-plan (WI-4) consequences.
Status set to **Questions**.

### Blocking items (must resolve before Phase 1 is `Investigated`)

- [x] **B1 — `XlmRobertaTokenizer.encode()`'s output contract is
      under-specified, and "mirror `TokenizerOutput`" collides with WI-4's own
      design.** WI-4's plan (its Investigation, and its file list:
      `lib/src/model_tokenizer.dart (new) — ModelTokenizer interface, ModelInput     type (generalised TokenizerOutput)`)
      defines the future interface as `ModelInput encode(String text)` — a
      **new** `ModelInput` type, _not_ the existing `TokenizerOutput`. So "shape
      `encode()`'s return type to closely mirror `TokenizerOutput` … at minimum"
      does not make "add `implements     ModelTokenizer` later" trivial: if
      WI-11 invents a differently-named, differently-shaped type, WI-4 Phase 2
      must reconcile the return type — a change, not an additive line. Decide
      and write down concretely: - **Which exact type does `encode()` return?**
      Recommended: reuse the existing `TokenizerOutput` class from
      `bert_tokenizer.dart` verbatim so both tokenizers already return the
      identical concrete type, and flag to WI-4 that its planned `ModelInput`
      should collapse onto `TokenizerOutput` (or rename it) rather than
      introduce a parallel type. If instead a new type is intended, name it and
      its fields here. - **`tokenTypeIds`.** `TokenizerOutput` requires it.
      XLM-R/RoBERTa does not use token-type ids. State explicitly whether
      `encode()` populates an all-zeros `Int64List` (needed if reusing
      `TokenizerOutput`) or the return type omits the field. - **Padding /
      truncation / pad-id — the load-bearing gap.** `BertTokenizer.encode()`
      pads to `maxLength` (512) with `padId = 0` and reserves the final slot for
      `[SEP]`. **XLM-R's `<pad>` is id 1, not 0** (the plan itself lists
      `<pad>`=1), and its terminator is `</s>`=2. An implementer copying
      `BertTokenizer`'s padding would be silently wrong. Specify: does
      `encode()` pad at all, to what `maxLength`, with pad id 1, how is
      `attentionMask` built, is an `</s>` slot reserved, and what does
      `truncated` mean here? Or is padding/tensor-shaping deferred entirely to
      WI-4 Phase 2 (in which case `encode()` returns the _unpadded_ id sequence
      and the "mirror `TokenizerOutput` with `attentionMask`" instruction is
      wrong and should be removed)? Phase 0 only ever compared raw `.ids` — the
      padded/masked surface is genuinely undesigned.

      **Resolved:** `encode()` now returns `TokenizerOutput` reused verbatim
      (not a new type) — WI-4's own plan updated in parallel to collapse its
      planned `ModelInput` onto `TokenizerOutput` rather than introduce a
      second type. `tokenTypeIds` is an all-zeros `Int64List` (matching what
      the library's own `Encoding.typeIds` already is for single-segment
      input — a direct widen, not invented data). Padding/truncation/pad-id
      is **not** hand-rolled BERT-style: checked directly in
      `sentencepiece_tokenizer.dart` that `SentencePieceTokenizer.encode()`
      already sources the pad id from the loaded vocab
      (`vocab.padId >= 0 ? vocab.padId : 0` — `1` for this tokenizer,
      correctly, automatically), so the fix is to configure the library's own
      padding/truncation via its `enablePadding(...)`/`enableTruncation(...)`
      **methods** (see second-pass note below — `padding`/`truncation` are
      read-only getters, not settable properties, so the original "set
      `tokenizer.padding = ...`" spelling was corrected) rather than reimplement
      BERT's padding logic. `maxLength` must be confirmed against the real
      model config at implementation time (default 512 only as a fallback).
      `truncated` is explicitly flagged as unverified (Phase 0 never
      exercised truncation) — implementer must check the library's actual
      truncation-signal API rather than have one asserted here.

- [x] **B2 — The parity fixture is self-contradictory: two different corpora are
      named as "the" gate, and one of them does not exist.** The Tests bullet
      says the full parity test runs the **11-entry smoke corpus against
      `reference_ids.json`** (download-and-cache the real `tokenizer.json`), but
      the same bullet then says to **"Reuse or extend WI-4's own
      `test/fixtures/xlmr_parity_corpus.json`"** — which (a) does not exist
      (`find` confirms no such file anywhere), and (b) per WI-4's Q4 is a
      _different_, UDHR-derived ~52-language fixture whose expected ids require
      the **Python `AutoTokenizer` hand-off pause** that WI-11's Phase 1 does
      not include. These are incompatible. Note WI-4's Phase 1 explicitly says
      that under Branch B "Phase 1 is owned by the separate follow-on port plan"
      — i.e. building that parity gate is now _WI-11's_ job, not something to
      "reuse." Resolve by picking one and making the whole plan consistent: - If
      the gate is the **11-entry `reference_ids.json`** (provenance already
      confirmed as real `AutoTokenizer` output — the cheaper, already-done
      path): delete the "reuse WI-4's `xlmr_parity_corpus.json`" sentence, and
      state where `reference_ids.json` + `smoke_corpus.json` live durably
      (committed under `test/fixtures/`? they exist today only as untracked
      working-tree files on the throwaway spike branch — carrying them over is
      load-bearing, same class of gap RQ2 caught for Phase 0). - If the gate is
      meant to be the **broader UDHR `xlmr_parity_corpus.json`** (per WI-4 Q4's
      careful design of a _committed, network-free, Python-free-forever_
      fixture): then WI-11 must own the full Q4 procedure, including the
      `generate_xlmr_parity_corpus.dart` tool and the user Python-pause to mint
      expected ids — none of which is in Phase 1 today. - Either way,
      **acknowledge the network-dependency divergence**: WI-4 Q4 deliberately
      designed the parity gate to need _no network and no Python in CI ever_ by
      committing the whole fixture. WI-11's "download-and-cache
      `tokenizer.json`" reintroduces a `huggingface.co` dependency for the gate.
      That may be an acceptable trade (17 MB is a lot to commit), but it is a
      reversal of a WI-4 design decision and should be stated as such, not left
      implicit.

      **Resolved:** picked the 11-entry `reference_ids.json`/`smoke_corpus.json`
      path — cheaper, provenance already confirmed, no new Python hand-off
      needed. The "reuse WI-4's fixture" sentence is removed; both files are
      now named as fixtures to commit under `test/fixtures/` (carried over
      from the throwaway spike branch, per the same durability concern RQ2
      raised for Phase 0). The network-dependency divergence from WI-4 Q4's
      design is now stated explicitly as an accepted trade-off, not left
      implicit.

- [x] **B3 — Coverage strategy for `xlmr_tokenizer.dart` is unresolved, and the
      `BertTokenizer` analogy breaks exactly here.** Verified: `make coverage`
      runs only `test/` (unit tests); the real model/tokenizer assets are loaded
      **only** by `integration_test_app/integration_test/inferencing_test.dart`,
      run via a separate `make macos_test`/`ios_test` and **not** counted by
      `make coverage`. The default `test/` suite never loads a real
      `tokenizer.json` or `model.onnx`. `BertTokenizer` reaches its coverage bar
      _entirely offline_ because its synthetic `vocab.txt` fully exercises
      `encode()` — but `XlmRobertaTokenizer.load()` and the tail of `encode()`
      (`HuggingFaceTokenizerLoader.fromJsonString` + library `encode()`) need
      the full 250k-entry `tokenizer.json`, which the plan wants downloaded, not
      committed. So as written, the download-gated parity test lands outside
      `make coverage`, and `xlmr_tokenizer.dart`'s load/encode-tail would be
      **uncovered** — the plan's own final step ("run `make coverage`, confirm
      all new files meet the bar") cannot pass. Resolve one of: - Factor steps
      1–3 (charsmap normalize, whitespace collapse, Metaspace) into
      offline-unit-testable methods (they need only the committed charsmap
      fixture, not the vocab), and structure the file so the vocab-dependent
      remainder is thin enough that the file still clears 90% offline — and say
      so explicitly, with the untested lines identified; or - Commit a _minimal
      synthetic_ `tokenizer.json` (tiny Unigram vocab + a small hand-built
      charsmap) mirroring the `vocab.txt` precedent faithfully, so `encode()` is
      covered offline (note: hand-authoring a valid darts-clone charsmap blob is
      non-trivial — assess feasibility before committing to this); or -
      Explicitly accept that the full-tokenizer path is covered only by the
      gated integration test and record how the 90% bar is still met for the
      file (which concrete lines are exercised offline).

      **Resolved:** the third option — apply this project's existing
      `// coverage:ignore-start`/`-end` convention (already used by
      `onnx_embedding_model.dart` for its own ORT-session-dependent methods)
      to `XlmRobertaTokenizer.load()` and the vocab-dependent tail of
      `encode()`. Steps 1–3 of the compose pipeline stay plain,
      uncovered-annotation-free methods — they need only the small committed
      charsmap fixture and are exactly what the `CharsmapTrie` unit tests
      already exercise offline. The synthetic-full-`tokenizer.json` option was
      considered and rejected as disproportionate effort.

### Non-blocking, worth tightening

- **B2's CI-job question is punted to the implementer.** The Tests bullet says
  "consider whether it can run in a lighter, faster CI job … a real efficiency
  question for the implementer to resolve, not a foregone conclusion either
  way." Deciding CI topology is exactly the kind of on-the-fly design the
  `Investigated` bar is meant to eliminate. Make a call (piggyback the existing
  `test-macos` job vs. a new lighter job) or downgrade this to an explicit
  "optional optimization, default is to piggyback" so it is not a decision the
  implementer must originate.

  **Resolved:** default to piggybacking on the existing `test-macos` job;
  revisit only if its runtime becomes a measured CI problem, not treated as an
  open decision at implementation time.

- **State the `dart_sentencepiece_tokenizer` dev→normal dependency move
  concretely.** The plan says to move it from dev-dependency to a normal
  `dependencies` entry (`^1.3.2`) — good — but also confirm at implementation
  time whether the pending unreleased `betto_inferencing` version bump (WI-4's
  Investigation flags a still-unpublished `0.1.0-dev.2`) is the vehicle, to keep
  this consistent with the "single release with WI-4 Phase 2" instruction in the
  last Phase 1 bullet.

  **Resolved:** confirmed as the vehicle — the dependency bullet now states this
  lands in that same still-unreleased `0.1.0-dev.2`.

### Implementation-readiness verdict

`CharsmapTrie` (the novel, risky half) is ready: format, algorithm, gotcha
doc-comment, fixture, and the `"Việt"` regression test are all pinned down.
`XlmRobertaTokenizer` is not — B1 (output contract + WI-4 type coordination), B2
(which parity corpus, and where the fixtures live), and B3 (offline coverage)
each force the implementer to make a design decision the plan should be making
for them, and B1/B2 have consequences for WI-4's Phase 2 that shouldn't be
discovered mid-implementation. Resolve B1–B3 and this returns cleanly to
`Investigated`. Do not hand Phase 1 to `kmdb-plan-implement` until then.

### Phase 1 second pass (kmdb-plan-reviewer, 2026-07-09) — B2/B3 + non-blockers verified good; B1 partially reopened

Re-verified each resolution directly against source in
`~/development/bettongia/inferencing` and the pinned
`dart_sentencepiece_tokenizer-1.3.2` in pub-cache — not the plan's prose.

**Verified accurate, do not re-litigate:**

- **B2 — resolved correctly.** The "reuse WI-4's fixture" sentence is gone; the
  Tests bullet now says "Do not reuse or build WI-4's `xlmr_parity_corpus.json`"
  and names `test/fixtures/xlmr_smoke_corpus.json` + `xlmr_reference_ids.json`
  as committed fixtures carried over from the spike branch. The
  `huggingface.co`-at-test-time divergence from WI-4 Q4's zero-network design is
  now stated explicitly as an accepted trade-off. Consistent.
- **B3 — resolved correctly.** The `// coverage:ignore-start`/`-end` convention
  genuinely exists in `onnx_embedding_model.dart` (lines 217–227, 248–291,
  300–304, plus `// coverage:ignore-line` at 111/119) with the stated "requires
  a live ORT session" rationale. Applying it to `XlmRobertaTokenizer.load()` and
  the vocab-dependent tail of `encode()` while leaving steps 1–3 plain and
  offline-tested is a faithful use of the precedent.
- **Cross-plan (WI-4) — consistent.**
  `plan_0_06_wi4_multilingual_embedding_model.md` now defines `ModelTokenizer`
  as `TokenizerOutput encode(String text)` (its §"`ModelTokenizer` abstraction",
  lines ~434–452 and Phase 2 checklist ~814–822), returning the existing
  `TokenizerOutput` verbatim; every remaining `ModelInput` mention is a negation
  ("no new `ModelInput` type"). XLM-R adding `implements ModelTokenizer` is
  correctly framed as a one-line addition. No lingering contradiction.
- **Non-blocking #1 (CI placement)** and **#2 (dep vehicle `0.1.0-dev.2`)** —
  both resolved as described.
- **B1, partially:** `TokenizerOutput` reuse is sound (it exists with the stated
  fields; `tokenTypeIds` as an all-zeros `Int64List` is valid; the `Encoding`
  `Uint8List` → `Int64List` widen is direct). The pad-id claim is **verified
  accurate**: `SentencePieceTokenizer.encode()` sources the pad id from
  `vocab.padId >= 0 ? vocab.padId : 0`
  (`sentencepiece/sentencepiece_tokenizer.dart:318,327,356`) — `1` for
  `multilingual-e5-small`, no BERT `padId=0` bug.

**B1 reopened — two source-level defects the resolution introduced:**

- [x] **B1a — the padding/truncation API spelling is wrong (will not compile).**
      The resolution asserts, as verified, "Set
      `tokenizer.padding =     SpPaddingConfig(...)` and
      `tokenizer.truncation = SpTruncationConfig(...)` (both already public
      config points on the class)." Source shows `padding` and `truncation` are
      **read-only getters** (`sentencepiece_tokenizer.dart:177,180`) — there are
      no setters. The real public config points are the **methods**
      `enablePadding({direction, length, padToMultipleOf})` (:183) and
      `enableTruncation({required maxLength, direction})` (:204), both returning
      `this`. **Corrected inline** in both the checklist bullet and the B1
      resolution note during this pass (pure factual fix, no design choice) —
      recorded here for traceability, not left for the implementer.

- [x] **B1b — `truncated` derivation is genuinely undesigned, and the
      resolution's suggested mechanism does not exist.** The resolution defers
      `truncated` to "check what signal the library exposes … compare
      pre/post-truncation token counts, or any overflow indicator on
      `Encoding`/`encode()`." Verified: there is **no** such signal. `Encoding`
      has no overflow/truncated field, and `_applyPostProcessing` applies
      truncation _before_ padding to the same `maxLength`
      (`sentencepiece_tokenizer.dart:250-334`), so a padded output is always
      exactly `maxLength` long — its length cannot distinguish "truncated" from
      "padded." `truncated` is a **required** constructor arg on
      `TokenizerOutput`, so the implementer must produce a value, and the only
      ways to do so are real design choices the plan should make, e.g.: -
      **Two-pass:** `encode()` once with padding+truncation _disabled_ to get
      the raw length, set `truncated = rawLen > maxLength`, then re-encode with
      the configs enabled (correct, but doubles tokenization cost); or -
      **One-pass + manual detect:** enable truncation only (no padding), read
      the length, but this still can't see the pre-truncation length — rejected;
      or - **Enable neither config; slice + pad manually** using `vocab.padId` —
      but that reintroduces the hand-rolled padding B1 explicitly moved away
      from. Pick one (the two-pass approach is the most likely acceptable
      default given `maxLength`-length inputs are rare in this corpus, but the
      perf trade-off is a real call), or explicitly decide `truncated` is always
      `false`/best-effort and document why. Until this is written down, an
      implementer must design it on the fly — below the `Investigated` bar.

      **Resolved: two-pass**, per the recommendation above — `encode()` twice
      (once unbounded to detect overflow, once with padding/truncation
      enabled for the real result), accepting the doubled tokenization cost
      as negligible relative to the ONNX inference that follows. Written
      concretely into the main Phase 1 checklist's `truncated` bullet.
      **Third-pass correction (see "Phase 1 third pass" below):** the initial
      two-pass wording assumed padding/truncation-disabled was simply "the
      default." Source review found `enablePadding`/`enableTruncation` are
      *persistent instance state*, so the plan now mandates an explicit
      `noPadding()`/`noTruncation()` reset at the start of every `encode()`
      call before the unbounded pass — otherwise `truncated` sticks `false`
      after the first call. Corrected inline in the checklist bullet.

**Verdict:** B2, B3, and both non-blockers are fully resolved and verified. B1a
is corrected in place. **B1b is a genuine remaining design gap** — small in
surface area (one diagnostic bool) but load-bearing because the field is
required and the plan's stated derivation path is disproven by source. Status
stays **Questions** pending a one-line decision on B1b. Everything else in Phase
1 is implementation-ready; resolve B1b and this promotes cleanly to
`Investigated`.

### Phase 1 third pass (kmdb-plan-reviewer, 2026-07-09) — B1b closed with a source-level correction; promoted to Investigated

The main session resolved B1b with the two-pass approach flagged above as the
likely acceptable default. Verifying it against
`dart_sentencepiece_tokenizer-1.3.2` source (not the plan's prose) surfaced one
real defect in the _wording_ of the resolution, now corrected inline — after
which the item closes cleanly.

**What was checked and found (`sentencepiece/sentencepiece_tokenizer.dart`):**

- **The disabled state the first pass needs is real and reachable.**
  `_paddingConfig`/`_truncationConfig` default to `null` (`:90-91`) and
  `_applyPostProcessing` skips both when null (`:304,:312,:342,:354`), so a
  freshly loaded tokenizer _is_ unbounded. There are also explicit public resets
  — `noPadding()` (`:197`) and `noTruncation()` (`:215`), both returning `this`.
  So the task's question ("is there a `disablePadding`/`disableTruncation` or is
  'the default' assumed?") is answered: yes, `noPadding()`/`noTruncation()`
  exist and the plan should — and now does — name them rather than lean on
  default state.

- **Defect in the resolution as first written (now fixed).** The two-pass
  wording said "call `encode()` once with padding/truncation _left disabled_ …
  then a second time with `enablePadding`/`enableTruncation` applied." That is
  only correct on the **first** `XlmRobertaTokenizer.encode()` call.
  `enablePadding`/`enableTruncation` mutate **persistent instance state** on the
  shared `SentencePieceTokenizer` — they are not per-call arguments and stick
  across calls. On every call after the first, the "unbounded" first pass would
  still be bounded by the previous call's config, so `rawLength` would be
  clamped to `maxLength` and `truncated = rawLength > maxLength` would silently
  be `false` forever after. This is precisely the latent-bug class the
  `Investigated` bar exists to eliminate. Corrected inline: the checklist
  `truncated` bullet now mandates `noPadding(); noTruncation();` at the **start
  of every** `encode()` call before the unbounded pass, with the full 5-step
  ordering and the identical `addSpecialTokens: true` requirement on both
  passes. This mirrors the library's own `encodeBatch`/`encodePair`
  save→null→work→restore idiom (`:432-441`, `:555-590`) — evidence the reset
  pattern is the intended way to take an unbounded pass on a configured
  instance, not a workaround.

Calling `encode()` twice on the same instance with a reset in between is
therefore a valid, supported usage pattern, and the plan now specifies exactly
how the unbounded state is achieved each call rather than assuming it.

**Verdict: B1b closed.** This was the last open item across three review passes.
Every source-level claim in Phase 1 has been independently verified;
`CharsmapTrie`, `XlmRobertaTokenizer` (output contract, padding/truncation API,
`truncated` derivation), the parity-gate fixtures, coverage strategy, NOTICE,
README, and dependency-vehicle steps are all specific enough for mechanical
execution with no remaining design decisions. **Status promoted to
`Investigated`** — Phase 1 is ready for `kmdb-plan-implement`.

## Summary

_(To be completed during implementation.)_
