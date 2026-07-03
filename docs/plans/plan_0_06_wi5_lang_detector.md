# WI-5: Language detection (`betto_lang_detector`)

**Status**: Open

**PR link**: — (implemented in a separate repository; see note below)

> **Portability note.** This plan targets a **new, standalone repository**
> (`bettongia/lang_detector`, pub.dev package `betto_lang_detector`), not the
> `kmdb` workspace. It is written to be self-contained: copy this file to
> `docs/plans/plan_lang_detector.md` in the new repo and implement it there.
> It does not assume access to any other file in the `kmdb` repository — all
> scaffold content the implementer needs is embedded below. The only
> `kmdb`-specific things are the roadmap/proposal cross-references in the
> Problem Statement, which exist purely for traceability back to `kmdb`'s
> planning docs and are not needed to execute the plan itself. Once the new
> repo exists and this plan reaches `Investigated` status, follow that repo's
> own `docs/plans/README.md` workflow (created in Phase 0 below) rather than
> `kmdb`'s — in particular there is no `kmdb-qa` / `kmdb-pre-commit` agent
> pairing in the new repo; the "Final step" checklist below is adapted
> accordingly.

## Problem statement

`kmdb`'s vault search roadmap (`docs/roadmap/0_06.md`, WI-5) needs a lightweight
language identification capability for three narrow purposes — **none of which
require full NLP-grade accuracy**:

1. **Lexical analyzer selection** — BM25 stemming/stop-word/tokenizer choice is
   language-specific but degrades gracefully; coarse accuracy is enough (WI-6).
2. **Document metadata** — a `"language"` field for faceting/filtering/display.
3. **Script guard rails** — a cheap signal to route CJK/Cyrillic/Arabic/etc.
   content to `IcuTokenizer` instead of the space-splitting `RegExpTokenizer`.

`kmdb` explicitly does **not** need language detection for the semantic
(embedding) search path — WI-4 adopts a multilingual embedding model that
shares one vector space across all languages, which removes the need for
query-side or index-side language routing there. See
`docs/proposals/vault_search.md` §10 for the full design rationale (the
"Revised framing" callout at the top of that section explains why language
detection was demoted from a central to a narrow concern).

Because the role is narrow and error-tolerant, a **pure-Dart, dependency-free**
detector is sufficient — no FFI, no ONNX runtime, no per-platform native
build. This plan designs and builds that detector as a new, independently
published Bettongia package, following the same pattern as
`betto_charset_detector` (WI-2) and `betto_icu`/`betto_lexical`.

**Naming note:** `docs/proposals/vault_search.md` §10.2 used the working name
`betto_lang_id`. The roadmap (`docs/roadmap/0_06.md`, WI-5) supersedes that
with `betto_lang_detector` — this plan uses `betto_lang_detector` throughout
as the authoritative name. Confirm this in Open Questions before publishing,
since a published pub.dev package name is effectively permanent.

**Consumer contract (for later `kmdb` WI-6 integration, out of scope here):**
`kmdb`'s BM25 tokenizer routing will call `LanguageDetector.dominantScript()`
to pick between `RegExpTokenizer` and `IcuTokenizer`, and will store
`detect()`'s result in the `$$vault:extract:{sha256}` KV entry's `"language"`
field. This plan builds the package only — no `kmdb` wiring.

## Open questions

- [ ] **Q1 — Package name.** Confirm `betto_lang_detector` (roadmap) over
      `betto_lang_id` (proposal). *Recommendation: `betto_lang_detector` — it's
      the name the roadmap work item already carries and what the user
      referenced when commissioning this plan.*
- [ ] **Q2 — N-gram training corpus source.** The n-gram profile generator
      (§"N-gram profile data" below) needs a per-language text corpus. Two
      candidates, both needing a live check before `tool/generate_ngram_profiles.dart`
      is written:
      - **UDHR (Universal Declaration of Human Rights) translations**, hosted at
        `unicode.org/udhr/` — same host as the UCD data already used for the
        script table (§"Script pre-filter" below), consistent licensing story
        (UN public document; Unicode's UDHR corpus is published specifically to
        support this kind of linguistic tooling). This is the exact corpus type
        Cavnar & Trenkle's original n-gram categorization technique was
        validated against (short, ~2,000-word documents).
      - **Leipzig Corpora Collection** (Leipzig University) — larger, sentence-level
        corpora per language, CC BY licence, more representative of prose than
        UDHR's formal/legal register.
      *Recommendation: start with UDHR — single host, simplest licence story,
      proven fit for this exact algorithm. Fall back to Leipzig only for
      languages UDHR doesn't cover from the target list in §"Language
      coverage".* The implementer must fetch and inspect the actual file
      layout before finalizing `tool/generate_ngram_profiles.dart` — this plan
      fixes the *algorithm* and *data shape*, not the exact download URL.
- [ ] **Q3 — Initial language coverage: 58 languages, matching `betto_lexical`.**
      §"Language coverage" below proposes detecting exactly the 58 language
      codes `betto_lexical`'s `Stopwords` enum already covers (stopwords-iso
      set), so `LanguageDetector.detect()` output composes directly with
      `getStopWords(Locale)` for WI-6's analyzer-selection use case with no
      code mismatch. *Recommendation: accept — confirm no objection before
      implementation, since each additional language means one more n-gram
      profile to generate and validate.*
- [ ] **Q4 — Confidence formula acceptable as a heuristic, not a probability.**
      §"Confidence scoring" below defines `confidence` as a linear rescaling of
      the Cavnar-Trenkle out-of-place distance across the *candidate set being
      compared* (not a calibrated probability). This means the same input text
      can report different confidence values depending on `restrictTo`. This is
      intentional (documented as a feature, not a bug — narrower `restrictTo`
      should produce sharper confidence) but is a real design choice worth a
      second pair of eyes. *Recommendation: accept.*

## Investigation

### Package identity

```yaml
name: betto_lang_detector
description: >-
  A pure-Dart language detection library for Dart and Flutter applications.
version: 0.1.0-dev.1
repository: https://github.com/bettongia/lang_detector
issue_tracker: https://github.com/bettongia/lang_detector/issues
homepage: https://bettongia.github.io/lang_detector/

topics:
  - internationalization

platforms:
  android:
  ios:
  linux:
  macos:
  web:
  windows:

environment:
  sdk: ^3.12.0

# Zero runtime dependencies — pure Dart, no FFI, no model runtime.
dependencies:

dev_dependencies:
  betto_builder_tools: ^0.1.0-dev.1
  code_builder: ^4.11.1
  lints: ^6.0.0
  test: ^1.25.6
```

Zero runtime dependencies is a deliberate, checkable property: this package
must work identically on web (no `dart:io`), mobile, and desktop with no
platform-conditional exports, unlike `betto_icu` (which needs an FFI/`Intl.Segmenter`
split) or `betto_charset_detector` (which depends on the `charset` package).
Confirm this stays true at the end of implementation — it is the core value
proposition versus the MediaPipe/FastText/Lingua-rs alternatives the proposal
already rejected (§10.2 of `vault_search.md`).

### Public API

Adopted directly from `docs/proposals/vault_search.md` §10.2, with the
`restrictTo` propagation rule resolved (see below — the proposal specifies the
constructor shape but not how `restrictTo` reaches the n-gram scoring stage).

```dart
/// A detected language with its confidence in [0.0, 1.0].
final class LanguageGuess {
  /// ISO 639-1 language code (e.g. `"en"`, `"hu"`). Matches the code set
  /// used by `betto_lexical`'s `Stopwords` enum.
  final String code;

  /// Confidence in [0.0, 1.0]. See [LanguageDetector] for how this is
  /// computed — it is a relative score within the candidate set compared,
  /// not a calibrated probability.
  final double confidence;

  const LanguageGuess(this.code, this.confidence);
}

/// The result of [LanguageDetector.detect].
sealed class DetectionResult {}

/// A language was identified with confidence at or above the detector's
/// `minConfidence` threshold.
final class Detected extends DetectionResult {
  final LanguageGuess best;
  final List<LanguageGuess> ranked;
  Detected(this.best, this.ranked);
}

/// No language met the `minConfidence` threshold. [ranked] holds whatever
/// candidates were scored (may be empty, e.g. for empty/whitespace-only or
/// script-less input).
final class Undetermined extends DetectionResult {
  final List<LanguageGuess> ranked;
  Undetermined(this.ranked);
}

/// A pluggable scoring strategy. [LanguageDetector.pureDart] supplies the
/// built-in script + n-gram implementation; custom backends (e.g. test
/// doubles, or a future model-backed detector) can implement this directly.
abstract interface class LanguageDetectorBackend {
  /// The language codes this backend can ever return from [score].
  Set<String> get supportedLanguages;

  /// Scores [text] against every language in [supportedLanguages]. Order is
  /// not significant — [LanguageDetector] sorts by confidence.
  List<LanguageGuess> score(String text);
}

final class LanguageDetector {
  /// [restrictTo], when non-null, is applied as a post-hoc filter over
  /// [backend]'s results: guesses whose code is not in [restrictTo] are
  /// dropped before ranking. This works for *any* backend but does not
  /// improve a custom backend's internal accuracy — only [pureDart] threads
  /// [restrictTo] into the scoring stage itself (see below).
  LanguageDetector({
    required LanguageDetectorBackend backend,
    this.minConfidence = 0.5,
    this.restrictTo,
  });

  final double minConfidence;
  final Set<String>? restrictTo;

  /// The zero-dependency default: Unicode script pre-filter + character
  /// n-gram model, covering the 58 languages in §"Language coverage".
  ///
  /// [restrictTo], when supplied, is threaded into the n-gram stage so only
  /// the given languages' profiles are compared — this is the accuracy lever
  /// called out in the proposal ("the biggest practical accuracy lever").
  factory LanguageDetector.pureDart({
    double minConfidence = 0.5,
    Set<String>? restrictTo,
  });

  /// Full detection: script pre-filter, then (if the script alone does not
  /// resolve to a single language) character n-gram scoring.
  DetectionResult detect(String text);

  /// Cheap script-only classification — does not run the n-gram stage.
  ///
  /// Returns a 4-letter ISO 15924 script code (e.g. `"Latn"`, `"Cyrl"`,
  /// `"Han"`) for the most common script among the input's letter
  /// codepoints, or `null` if the input has no scripted letters (empty,
  /// whitespace-only, digits/punctuation/emoji-only).
  ///
  /// This always uses the built-in script table — it is not affected by a
  /// custom [backend] passed to the primary constructor, since script
  /// classification is a fixed, deterministic Unicode property lookup, not a
  /// pluggable strategy.
  String? dominantScript(String text);
}
```

### Repository layout

```
betto_lang_detector/
  lib/
    betto_lang_detector.dart          # public API export (mirrors betto_charset_detector.dart)
    src/
      guess.dart                      # LanguageGuess, DetectionResult, Detected, Undetermined
      backend.dart                    # LanguageDetectorBackend interface
      detector.dart                   # LanguageDetector (primary ctor + pureDart factory)
      composite_backend.dart          # CompositeBackend: script shortcut + n-gram fallback
      script/
        script_filter.dart            # dominantScript(text), scriptOfRune(int), _hasKana(text)
        script_ranges.g.dart          # generated: sorted (start, end, scriptCode) table
        script_candidates.dart        # hand-maintained: script code -> Set<String> of our 58 langs
      ngram/
        ngram_extractor.dart          # extractRankedNgrams(text, {int limit}) — shared by tool/ and runtime
        ngram_backend.dart            # NgramBackend implements LanguageDetectorBackend
        profiles.g.dart               # generated: Map<String, List<String>> lang -> top-300 ranked n-grams
  tool/
    generate_scripts.dart             # UCD Scripts.txt + PropertyValueAliases.txt -> script_ranges.g.dart
    generate_ngram_profiles.dart      # corpus -> profiles.g.dart (imports ngram_extractor.dart directly)
  test/
    detector_test.dart
    composite_backend_test.dart
    script_filter_test.dart
    ngram_extractor_test.dart
    ngram_backend_test.dart
  example/
    example.dart
  docs/
    plans/
      README.md                      # copy verbatim from betto_lexical or betto_charset_detector
      plan_lang_detector.md           # this plan, copied in
    roadmap/
      README.md                      # copy verbatim from betto_lexical
    spec/
      README.md                      # short technical spec — script table + n-gram algorithm summary
    reviews/
      README.md                      # copy verbatim from betto_lexical
    template/                        # copy verbatim from betto_lexical (site build assets)
  header_template.txt                # see below
  addlicense_config.txt              # see below
  Makefile                           # see below
  site.mk                            # copy verbatim from betto_lexical (unchanged — generic)
  analysis_options.yaml              # see below
  pubspec.yaml                       # see §"Package identity"
  CLAUDE.md                          # see below
  AUTHORS                            # copy from any sibling betto_* package, update name/email
  CONTRIBUTING.md                    # copy verbatim from betto_charset_detector
  LICENSE                            # copy verbatim (Apache 2.0) from any sibling betto_* package
  CHANGELOG.md                       # start with `## 0.1.0-dev.1` + feature bullets, see betto_charset_detector's for style
  README.md                          # package overview + usage example, see betto_charset_detector's for style
  .gitignore                         # copy verbatim from betto_charset_detector
```

This mirrors `betto_charset_detector` (simple pure-Dart detector, single
public entry point) crossed with `betto_lexical`'s codegen pattern
(`tool/loader.dart` using `betto_builder_tools` + `code_builder` to produce
`.g.dart` data files) — both already-published sibling packages, inspected
directly as part of this investigation (see below).

**Critical invariant:** `tool/generate_ngram_profiles.dart` must **import and
call** `lib/src/ngram/ngram_extractor.dart`'s `extractRankedNgrams`, not
reimplement n-gram extraction. If the generator and the runtime scorer
tokenize text differently (e.g. different padding, different case-folding,
different n-gram order range), the generated profiles will not match what the
runtime backend produces at query time, silently degrading accuracy with no
test able to catch it short of an end-to-end accuracy benchmark. Sharing the
exact function is the only way to guarantee this by construction. This mirrors
how `betto_lexical`'s `tool/loader.dart` and runtime `stopwords.dart` both
consume the same generated `Stopwords` enum rather than the tool re-deriving
word lists independently.

### Scaffold file contents

#### `header_template.txt`

```
Copyright {{.Year}} The Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

Use `{{.Year}}` → `2026` (or the current year at implementation time) on every
hand-written `.dart` file. Generated `.g.dart` files are exempt (see
`addlicense_config.txt` below), matching `betto_lexical`'s convention.

#### `addlicense_config.txt`

```
-l=apache
-c="The Authors"
--ignore="**/*.yml"
--ignore="**/*.yaml"
--ignore="**/*.xml"
--ignore="**/*.g.dart"
--ignore="**/*.txt"
--ignore="**/.dart_tool/**"
--ignore="**/generated/**"
--ignore="**/coverage/**"
--ignore="site/**"
--ignore="vendor/**"
--ignore=".claude/**"
--ignore="docs/template/**"
.
```

(Trimmed from `betto_lexical`'s version — dropped the JS/Ruby/ObjC ignores
that don't apply to a pure-Dart-only package; add them back if `tool/` ever
needs a non-Dart helper script.)

#### `Makefile`

```make
.DEFAULT_GOAL := default

include site.mk

default: clean prepare license_check format analyze test coverage doc_site
.PHONY: default

pre_commit: format_check analyze license_check test
.PHONY: pre_commit

cicd: default
.PHONY: cicd

format:
	dart format lib/ test/ tool/ example/
.PHONY: format

format_check:
	dart format --output=none --set-exit-if-changed lib/ test/ tool/
.PHONY: format_check

analyze:
	dart analyze
.PHONY: analyze

test: test.log
.PHONY: test

test.log: lib/** test/**
	dart test | tee test.log

license_check:
	cat addlicense_config.txt | xargs addlicense --check

license_add:
	cat addlicense_config.txt | xargs addlicense

coverage: coverage.log
.PHONY: coverage

coverage.log: lib/** test/**
	dart test --coverage-path=coverage/lcov.info
	rm -rf site/coverage
	mkdir -p site/coverage
	genhtml coverage/lcov.info -o site/coverage

prepare:
	dart pub global activate coverage
	dart pub get
.PHONY: prepare

clean:
	rm -rf site dist coverage .dart_tool
	rm -f *.log
	dart pub get
.PHONY: clean

generate_scripts:
	dart run tool/generate_scripts.dart
.PHONY: generate_scripts

generate_ngram_profiles:
	dart run tool/generate_ngram_profiles.dart
.PHONY: generate_ngram_profiles

web_test:
	dart pub get
	dart test -p chrome
.PHONY: web_test

cicd_windows:
	dart pub get
	dart test
.PHONY: cicd_windows

cicd_macos:
	dart pub get
	dart test
.PHONY: cicd_macos
```

(Adapted from `betto_lexical`'s `Makefile` — `generate_stopwords` replaced with
the two generator targets this package needs.)

#### `analysis_options.yaml`

```yaml
include: package:lints/recommended.yaml
```

(Same as `betto_charset_detector` — no package-specific lint overrides needed.)

#### `CLAUDE.md`

Copy `betto_lexical`'s `CLAUDE.md` structure (General / Repository Layout /
Commands / Implementation Status / Architecture / Documentation sections — see
that package for the exact prose pattern) and adapt the Repository Layout and
Architecture sections to this package's structure above. Keep the "plans in
`docs/plans/`, roadmap in `docs/roadmap/`, 90% coverage minimum, license header
on every file" paragraphs verbatim — they are the same house rules across every
Bettongia pure-Dart package.

### Script pre-filter

**Data source:** Unicode Character Database (UCD), same authority already
implicitly trusted via `betto_icu`'s dependency chain. Two files, both under
`https://www.unicode.org/Public/UCD/latest/ucd/`:

- `Scripts.txt` — codepoint ranges to long script name (e.g.
  `0041..005A    ; Latin # ...`).
- `PropertyValueAliases.txt` — long name to 4-letter ISO 15924 alias (e.g. the
  `sc` property section maps `Latin` → `Latn`, `Cyrillic` → `Cyrl`, `Han` →
  `Hani`... **note:** Unicode's own alias for Han is `Hani`, not `Han`; use
  whatever `PropertyValueAliases.txt` actually says rather than assuming the
  short forms used loosely in prose above and in the roadmap doc — the codegen
  tool derives the alias from source data, not from a hand-typed guess).

**Codegen tool (`tool/generate_scripts.dart`):**

1. Use `betto_builder_tools`'s `loadData` (same helper `betto_lexical`'s
   `tool/loader.dart` uses) to fetch and cache both files locally.
2. Parse `PropertyValueAliases.txt`'s `sc` (Script) section into
   `Map<String longName, String isoCode>`.
3. Parse `Scripts.txt` into `List<(int start, int end, String longName)>`,
   map each `longName` through the alias table, merge adjacent/overlapping
   ranges that resolve to the same ISO code, and sort by `start`.
4. Emit `lib/src/script/script_ranges.g.dart` as three parallel typed arrays
   (`Int32List _starts`, `Int32List _ends`, `List<String> _codes`) plus a
   binary-search lookup function `String? scriptOfRune(int rune)` — mirrors
   the sorted-range-table pattern already used in `betto_mediatype_detector`'s
   generated registries and is the standard efficient approach for a table
   with on the order of a few thousand ranges. `Common` and `Inherited` are
   kept in the table (needed so `scriptOfRune` can positively identify and
   then discard them) but never returned by `dominantScript`.

**`dominantScript(String text)` algorithm** (`lib/src/script/script_filter.dart`):

1. Iterate `text.runes`, capped at the first 5,000 runes (bounds cost on very
   large inputs; vault chunks per WI-3's chunking pipeline are already far
   smaller than this, so the cap is not expected to bind in practice — same
   defensive-cap pattern as `betto_charset_detector`'s `_sampleSize`).
2. For each rune, binary-search `scriptOfRune`. Skip runes that resolve to
   `null`, `Common`, or `Inherited` (whitespace, punctuation, digits, symbols
   contribute no signal).
3. Tally counts per remaining script code.
4. Return the code with the highest count, or `null` if the tally is empty.
5. Separately (not part of `dominantScript`, but computed alongside it inside
   `CompositeBackend` — see below), track whether *any* rune resolved to
   `Hiragana` or `Katakana` — this boolean is the ja/zh disambiguator and is
   deliberately **not** folded into the dominant-script count, because a
   Japanese document is very often Han-majority by raw codepoint count even
   though kana presence is the decisive signal.

### Language coverage

**Target set: the same 58 ISO 639-1 codes `betto_lexical`'s `Stopwords` enum
covers** (confirmed by inspecting the published package directly):
`af, ar, bg, bn, br, ca, cs, da, de, el, en, eo, es, et, eu, fa, fi, fr, ga,
gl, gu, ha, he, hi, hr, hu, hy, id, it, ja, ko, ku, la, lt, lv, mr, ms, nl, no,
pl, pt, ro, ru, sk, sl, so, st, sv, sw, th, tl, tr, uk, ur, vi, yo, zh, zu`.

This is a deliberate, justified scoping choice (Q3 above), not an arbitrary
subset: it makes `LanguageDetector.detect()`'s output directly usable as input
to `getStopWords(Locale)` for WI-6's analyzer-selection use case, with no code
translation layer and no risk of the detector naming a language
`betto_lexical` doesn't have stop words for.

**Script partition of the 58** (this is what actually determines how much work
the n-gram stage has to do, and is the concrete justification for scoping the
n-gram corpus effort):

| Script | Languages | Count | Resolution |
| ------ | --------- | ----- | ---------- |
| Latin | af, br, ca, cs, da, de, en, eo, es, et, eu, fi, fr, ga, gl, ha, hr, hu, id, it, ku, la, lt, lv, ms, nl, no, pl, pt, ro, sk, sl, so, st, sv, sw, tl, tr, vi, yo, zu | 41 | n-gram stage |
| Cyrillic | bg, ru, uk | 3 | n-gram stage |
| Arabic | ar, fa, ur | 3 | n-gram stage |
| Devanagari | hi, mr | 2 | n-gram stage |
| Bengali | bn | 1 | script-exclusive |
| Gujarati | gu | 1 | script-exclusive |
| Armenian | hy | 1 | script-exclusive |
| Greek | el | 1 | script-exclusive |
| Hebrew | he | 1 | script-exclusive |
| Thai | th | 1 | script-exclusive |
| Hangul | ko | 1 | script-exclusive |
| Han + kana | ja (kana present), zh (Han only, no kana) | 2 | script-exclusive (kana-presence rule) |

The n-gram model's real job is disambiguating the 49 languages across Latin /
Cyrillic / Arabic / Devanagari (41+3+3+2); the remaining 9 are fully resolved
by the script stage alone and never reach the n-gram scorer. This partition is
also what `script_candidates.dart` encodes directly (hand-maintained — small
and stable, not worth code-generating):

```dart
/// Script code -> candidate language codes, restricted to the 58 languages
/// this package detects. Hand-maintained: this mapping is small, stable
/// (ISO 15924 script assignments for these 58 languages do not change), and
/// encodes linguistic knowledge that isn't mechanically derivable from UCD
/// data alone (e.g. that Kurdish in this corpus is scored as Latin-script,
/// not the Arabic-script Sorani variant — see the known-limitation note
/// below).
const Map<String, Set<String>> scriptCandidates = {
  'Latn': {
    'af','br','ca','cs','da','de','en','eo','es','et','eu','fi','fr','ga',
    'gl','ha','hr','hu','id','it','ku','la','lt','lv','ms','nl','no','pl',
    'pt','ro','sk','sl','so','st','sv','sw','tl','tr','vi','yo','zu',
  },
  'Cyrl': {'bg', 'ru', 'uk'},
  'Arab': {'ar', 'fa', 'ur'},
  'Deva': {'hi', 'mr'},
};

/// Script code -> the single language it always resolves to among our 58,
/// short-circuiting the n-gram stage entirely. 'Hani' (Han) is handled
/// separately via the kana-presence rule, not through this table.
const Map<String, String> scriptExclusiveLanguage = {
  'Beng': 'bn',
  'Gujr': 'gu',
  'Armn': 'hy',
  'Grek': 'el',
  'Hebr': 'he',
  'Thai': 'th',
  'Hang': 'ko',
};
```

**Known limitation, to record in the README:** Kurdish (`ku`) is treated as
Latin-script only (Kurmanji orthography). Sorani Kurdish, written in a Perso-Arabic
script, will be misdetected as `ar`/`fa`/`ur` by the script stage and never
reach a Kurdish-aware profile, because this package does not carry a
Sorani-script n-gram profile. This is an accepted, documented trade-off, not a
bug to fix in this plan — expanding script-variant coverage per language is
future work if a real need surfaces.

### N-gram profile data

**Algorithm: Cavnar & Trenkle "N-Gram-Based Text Categorization" (1994),** the
standard technique this class of lightweight detector uses (the same family
TextCat and similar tools implement). Fully specified below so the implementer
makes no further algorithmic judgment calls.

**Extraction (`lib/src/ngram/ngram_extractor.dart`, shared by codegen and
runtime — see the "critical invariant" note above):**

```dart
/// Extracts character n-grams (orders 1-5) from [text], ranked by descending
/// frequency, returning at most [limit] entries (ties broken by ascending
/// alphabetical order on the n-gram string, for determinism).
///
/// Words are runs of Unicode letters/marks (`RegExp(r'\p{L}[\p{L}\p{M}]*',
/// unicode: true)`... concretely, split on everything that is *not*
/// `\p{L}` or `\p{M}`), lowercased, then padded with a single `_` boundary
/// marker on each side (`"the"` -> `"_the_"`). N-grams are all contiguous
/// substrings of the padded word of length 1 through 5 (or up to the padded
/// word's length if shorter). Words shorter than the padding alone (i.e.
/// zero-letter matches) cannot occur given the split regex.
List<String> extractRankedNgrams(String text, {int limit = 300});
```

**Profile generation (`tool/generate_ngram_profiles.dart`):**

1. For each of the 58 languages, obtain representative source text (see Q2 —
   corpus source to be confirmed by the implementer).
2. Call `extractRankedNgrams(corpusText, limit: 300)` — this *is* the
   language's profile: a ranked list, rank 0 = most frequent n-gram.
3. Emit `lib/src/ngram/profiles.g.dart` as `const Map<String, List<String>>`
   (language code -> its ranked list), generated via `code_builder` +
   `betto_builder_tools`'s `dartfmt`, following the exact same `Library` /
   `generatedByComment` / license-comment-wrapping pattern as
   `betto_lexical`'s `tool/loader.dart` (inspected directly — see the
   `buildStopwordRegistry` function there for the literal code shape to
   follow, substituting a flat `Map<String, List<String>>` literal for the
   per-language `part of` files stopwords uses — a single file is fine here
   since 58 lists of ≤300 short strings is small, unlike stopword sets which
   can run to thousands of words per language).

**Scoring (`lib/src/ngram/ngram_backend.dart`, `NgramBackend implements
LanguageDetectorBackend`):**

Given a candidate language set `S` (either all 58, or the script-narrowed
subset, or `restrictTo` — see `CompositeBackend` below) and input `text`:

1. `queryNgrams = extractRankedNgrams(text, limit: 300)`. If `queryNgrams` is
   empty (fewer than, say, 3 distinct letters in the input), return `[]`
   immediately — not enough signal (this is what produces `Undetermined([])`
   for empty/whitespace/digit/emoji-only input, alongside the script stage
   already returning `null` for the same inputs).
2. For each language `L` in `S` with profile `P_L` (a ranked list, index =
   rank):
   - For each `(rank_q, ngram)` in `queryNgrams`: if `ngram` is present in
     `P_L` at `rank_p`, add `|rank_q - rank_p|` to `distance(L)`; if absent,
     add the **maximum out-of-place penalty**, `300` (the profile size — the
     standard choice in this algorithm family), to `distance(L)`.
3. `minD = min(distance(L) for L in S)`, `maxD = max(distance(L) for L in S)`.
4. `confidence(L) = maxD == minD ? 1.0 : 1.0 - (distance(L) - minD) / (maxD - minD)`.
   (If `S` has exactly one candidate, `confidence = 1.0` — there is nothing to
   compare against, so the single candidate wins by definition; this only
   happens when the script stage has already narrowed to one language, which
   `CompositeBackend` short-circuits before ever calling `NgramBackend` — see
   below — so in practice `NgramBackend.score` is never called with `|S| < 2`,
   but the formula handles it safely regardless.)
5. Return `[LanguageGuess(L, confidence(L)) for L in S]`.

This confidence formula is a heuristic, not a calibrated probability (Q4) —
document this explicitly in the class doc comment so no downstream caller
(e.g. a future `kmdb` consumer) mistakes it for one.

### `CompositeBackend` — orchestrating script + n-gram

```dart
final class CompositeBackend implements LanguageDetectorBackend {
  CompositeBackend({Set<String>? restrictTo})
    : _candidates = restrictTo?.intersection(_allLanguages) ?? _allLanguages;

  @override
  Set<String> get supportedLanguages => _candidates;

  @override
  List<LanguageGuess> score(String text) {
    final scriptResult = _scriptStage(text);
    if (scriptResult != null) return [scriptResult];
    return _ngramStage(text);
  }

  // ... see algorithm below
}
```

`_scriptStage(text)`:

1. Compute `dominantScript(text)` and `hasKana(text)` in one pass over
   `text.runes` (share the iteration — no need to scan twice).
2. If `hasKana` and `'ja'` is in `_candidates` → return
   `LanguageGuess('ja', 1.0)`.
3. Else if `dominantScript == 'Hani'` (Han, no kana) and `'zh'` is in
   `_candidates` → return `LanguageGuess('zh', 1.0)`.
4. Else if `dominantScript` is a key in `scriptExclusiveLanguage` and the
   mapped language is in `_candidates` → return that
   `LanguageGuess(lang, 1.0)`.
5. Else → return `null` (fall through to the n-gram stage).

`_ngramStage(text)`:

1. If `dominantScript(text)` resolved to a key in `scriptCandidates`, narrow
   to `scriptCandidates[script]!.intersection(_candidates)` — this is the
   "cheap guard rail" reducing the n-gram comparison set from up to 58 down to
   at most 41 (Latin case), improving both speed and accuracy (fewer
   plausible confusions).
2. Else (script `null`, or a script with no entry in `scriptCandidates` —
   e.g. mixed-script or unrecognized-script input) → use `_candidates`
   unnarrowed.
3. If the narrowed candidate set has fewer than 2 languages, return `[]`
   (nothing meaningful to compare — e.g. `restrictTo` excluded every language
   the script suggests).
4. Delegate to `NgramBackend.score(text)` restricted to that set.

Step 5 above ("script stage returns `null`, fall through") together with step
3 here ("candidate set collapses to <2, return `[]`") are what make
`CompositeBackend.score` total over all inputs including pathological ones
(`restrictTo: {}}`, non-script text, single-character input) — every path is
covered, and `LanguageDetector.detect` turns an empty `score()` result into
`Undetermined([])` uniformly regardless of which path produced it.

### Test strategy

Coverage target: **>90%** (project-wide house rule, per every sibling `betto_*`
package's `CLAUDE.md`). Concretely:

| Area | Key cases |
| ---- | --------- |
| `script_filter_test.dart` | One representative codepoint per script in `scriptCandidates` + `scriptExclusiveLanguage` + `Hani`; `Common`/`Inherited`-only input → `null`; empty string → `null`; mixed-script input → majority wins; the 5,000-rune sample cap (construct input that would flip the answer if the cap didn't apply); kana-presence boolean independent of dominant-script tally (construct a Han-majority string with one Hiragana character and assert `hasKana == true` while `dominantScript == 'Hani'`). |
| `ngram_extractor_test.dart` | Known input -> known ranked output for a small hand-computed example; boundary padding verified explicitly (`"the"` produces `"_"`, `"_t"`, `"_th"`, ..., `"_the_"`); punctuation/digits act as word separators and contribute no n-grams; `limit` truncation; deterministic tie-break (construct two n-grams with equal frequency, assert alphabetical order). |
| `ngram_backend_test.dart` | Distance computation against a small synthetic 2-3-language profile fixture (not the real 58-language generated data — keep this test fast and its expected values hand-computable); absent-n-gram penalty applied correctly; confidence formula's `minD == maxD` branch; empty `queryNgrams` → `[]`. |
| `composite_backend_test.dart` | Each of the 7 script-exclusive branches short-circuits (mock/verify n-gram stage is never invoked — e.g. inject a `NgramBackend` double that throws if called, to prove the shortcut path); ja vs zh kana-presence disambiguation on real sample sentences; `restrictTo` narrowing at both the script-candidate and script-exclusive layers (e.g. `restrictTo: {'fr'}` on Japanese text — `hasKana` is true but `'ja'` isn't in candidates, so it must fall through, then the n-gram stage over `{'fr'}` alone returns confidence 1.0 for `fr` regardless of fit — assert this documented (if surprising) behaviour explicitly); candidate set collapsing to `[]`. |
| `detector_test.dart` | `pureDart` factory wiring; `minConfidence` threshold producing `Detected` vs `Undetermined`; `restrictTo` post-filter behaviour with a **custom** backend (prove it works generically, independent of `CompositeBackend`); `dominantScript` bypasses any injected custom backend (inject a backend double that would answer differently, assert `dominantScript` ignores it). |

Real-language accuracy (does the n-gram model, once fully generated,
correctly identify e.g. French vs. Spanish on real prose) is **not** a unit
test concern — those tests use small hand-computed fixtures, per the table
above, to keep them fast and deterministic. Validate real accuracy manually
once during implementation (e.g. run `detect()` over a handful of held-out
UDHR sentences per language, not from the training corpus) and record a
short summary in this plan's Summary section; do not commit an automated
"corpus accuracy" test suite, since maintaining a labelled held-out set is
disproportionate to this detector's stated "coarse, error-tolerant" role.

No fault-injection / durability testing applies here — this package has no
storage, sync, or filesystem write path at runtime (`tool/` scripts write
files but only at codegen time, never in the shipped library), so `kmdb`'s
`docs/reviews/code-review-2026-05-22.md` durability concerns are out of scope.

### Spec doc

Add a short `docs/spec/README.md` in the new repo (per the scaffold layout
above) covering: the two-stage algorithm at a paragraph each, the 58-language
coverage table, the confidence-formula caveat (Q4), and the Kurdish
known-limitation note. This is the package's only spec document — no numbered
spec sections needed (that convention is `kmdb`-specific, not a Bettongia-wide
one; compare `betto_lexical`'s and `betto_charset_detector`'s single-file
`docs/spec/README.md`).

## Implementation plan

**Phase 0 — repository bootstrap**

- [ ] Create the `bettongia/lang_detector` GitHub repository (confirmed empty
      as of this plan's writing — `git ls-remote` returned no refs).
- [ ] Scaffold the package: `dart create --template=package betto_lang_detector`
      or manual layout matching §"Repository layout" above.
- [ ] Add all scaffold files from §"Scaffold file contents" (`header_template.txt`,
      `addlicense_config.txt`, `Makefile`, `analysis_options.yaml`,
      `pubspec.yaml`). Copy `site.mk`, `LICENSE`, `CONTRIBUTING.md`,
      `.gitignore`, `docs/plans/README.md`, `docs/roadmap/README.md`,
      `docs/reviews/README.md`, `docs/template/*` verbatim from
      `betto_lexical` or `betto_charset_detector` (both public on GitHub).
- [ ] Copy this plan file into `docs/plans/plan_lang_detector.md` in the new
      repo.
- [ ] Write `CLAUDE.md` per §"Scaffold file contents" above.
- [ ] `dart pub get`; confirm a clean `dart analyze` on the empty scaffold.

**Phase 1 — script pre-filter**

- [ ] Resolve Q2's sibling concern for this phase: confirm the exact
      `Scripts.txt` / `PropertyValueAliases.txt` URLs and formats by fetching
      them directly (`https://www.unicode.org/Public/UCD/latest/ucd/`).
- [ ] Implement `tool/generate_scripts.dart` (§"Script pre-filter" codegen
      steps 1-4). Run `make generate_scripts`; commit the generated
      `lib/src/script/script_ranges.g.dart`.
- [ ] Implement `lib/src/script/script_filter.dart` (`scriptOfRune`,
      `dominantScript`, the shared kana-presence helper used by
      `CompositeBackend`).
- [ ] Hand-write `lib/src/script/script_candidates.dart` per §"Language
      coverage" above.
- [ ] Write `test/script_filter_test.dart` per §"Test strategy". Confirm
      coverage.

**Phase 2 — n-gram model**

- [ ] Resolve Q2 (corpus source) concretely — fetch and inspect the chosen
      corpus, confirm it covers all 58 target languages (or identify gaps and
      decide a fallback source per-language).
- [ ] Implement `lib/src/ngram/ngram_extractor.dart` per §"N-gram profile
      data" — extraction algorithm.
- [ ] Write `test/ngram_extractor_test.dart` first (small hand-computed
      fixtures) — this locks the extraction algorithm's exact behaviour
      before the codegen tool depends on it.
- [ ] Implement `tool/generate_ngram_profiles.dart`, importing
      `ngram_extractor.dart` directly (critical invariant, see above). Run
      `make generate_ngram_profiles`; commit the generated
      `lib/src/ngram/profiles.g.dart`.
- [ ] Implement `lib/src/ngram/ngram_backend.dart` (`NgramBackend`) per the
      scoring algorithm above.
- [ ] Write `test/ngram_backend_test.dart` per §"Test strategy" (synthetic
      fixture profiles, not the generated 58-language data).

**Phase 3 — composite backend and public API**

- [ ] Implement `lib/src/guess.dart` (`LanguageGuess`, `DetectionResult`,
      `Detected`, `Undetermined`).
- [ ] Implement `lib/src/backend.dart` (`LanguageDetectorBackend`).
- [ ] Implement `lib/src/composite_backend.dart` (`CompositeBackend`) per
      §"CompositeBackend" above.
- [ ] Implement `lib/src/detector.dart` (`LanguageDetector`, `.pureDart`
      factory).
- [ ] Implement `lib/betto_lang_detector.dart` public export (mirror
      `betto_charset_detector.dart`'s doc-comment-with-example style).
- [ ] Write `test/composite_backend_test.dart` and `test/detector_test.dart`
      per §"Test strategy".
- [ ] Manual real-language accuracy spot-check (see §"Test strategy" —
      not an automated test); record results in this plan's Summary.

**Phase 4 — package finish**

- [ ] Write `example/example.dart` (mirrors `betto_charset_detector`'s
      `example/main.dart` structure: a `detect()` call and a `dominantScript()`
      call on sample strings).
- [ ] Write `README.md` (Features / Getting started / Usage sections, per
      `betto_charset_detector`'s style) and `CHANGELOG.md`
      (`## 0.1.0-dev.1` + feature bullets).
- [ ] Write `docs/spec/README.md` per §"Spec doc" above.
- [ ] Run `make coverage` — confirm >90% on all `lib/src/*.dart` files
      (excluding `.g.dart` generated files, which need no coverage — they are
      pure data).
- [ ] Run `make pre_commit` (format, analyze, license_check, test) — all
      green.
- [ ] Verify licence headers (year 2026) on every hand-written `.dart` file.

**Final step — sign-off (adapted for the standalone repo; no `kmdb-qa` /
`kmdb-pre-commit` agents exist there):**

- [ ] Self-review the diff against this plan's API surface and algorithm
      sections — confirm no undocumented deviation.
- [ ] `make pre_commit` green (format, analyze, license_check, tests).
- [ ] `make coverage` >90%.
- [ ] Update this plan's Status to `Complete`, move it to
      `docs/plans/completed/`, and fill in the Summary section.
- [ ] Publish to pub.dev as `0.1.0-dev.1` (`dart pub publish --dry-run` first).
- [ ] Once published, return to the `kmdb` repo and update
      `docs/roadmap/0_06.md` WI-5's status to `Complete` with a link to this
      plan and the published package, so WI-6 (which depends on this package)
      can proceed.

## Summary

{To be completed once implemented.}
