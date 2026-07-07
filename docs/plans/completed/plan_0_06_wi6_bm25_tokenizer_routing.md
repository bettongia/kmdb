# WI-6: Language-aware BM25 tokenizer routing

**Status**: Complete

**PR link**: —

## Problem statement

`docs/roadmap/0_06.md` WI-6 describes this work as: "Use `dominantScript()`
from `betto_lang_detector` to route non-Latin-script content to `IcuTokenizer`
... in place of the default `RegExpTokenizer`. This fixes CJK, Arabic,
Cyrillic, and other scripts where space-splitting produces incorrect or empty
token sequences."

**That framing is stale and does not match the current code.** Investigation
(below) found:

1. **Document-field FTS (`FtsManager`, §21) already defaults to ICU-backed
   tokenization on every platform.** `FtsManager` calls
   `createDefaultTokenizer()` (from `betto_lexical`) at every write and query
   call site, which resolves to `IcuTokenizer` on native and `BrowserTokenizer`
   (`Intl.Segmenter`) on web — both UAX #29-conformant, both already handling
   CJK/Arabic/Cyrillic/Thai correctly. `RegExpTokenizer` is not used anywhere
   in `kmdb` today; it exists in `betto_icu`/`betto_lexical` only as an
   explicit opt-in fallback. `docs/spec/21_lexical_search.md:26-42` already
   documents this. **There is no live tokenizer bug in the document-field FTS
   path**, and no routing work is needed there.

2. **The real, live bug is in the vault search path, and it's worse than the
   roadmap describes.** `VaultChunker._findTokenSpans`
   (`packages/kmdb/lib/src/vault/search/vault_chunker.dart:167`) finds word
   boundaries using `RegExp(r"\w+(?:'\w+)*")` with **no `unicode: true` flag**.
   Dart's `\w` in non-Unicode mode matches only ASCII `[A-Za-z0-9_]`. For any
   vault document whose text is entirely CJK, Arabic, Cyrillic, Devanagari,
   Thai, etc., this regex matches **zero** token spans — the chunker produces
   an empty chunk list, and the blob is silently absent from vault lexical
   search entirely (it still gets a chunk-less `indexed` status; there is no
   error). This is strictly worse than the roadmap's own `RegExpTokenizer`
   description (which is at least `\p{L}\p{N}`-Unicode-aware, per
   §21_lexical_search.md:24).

3. **The vault write and query paths already use two different tokenizers,
   independent of language.** The write path (`VaultChunker`) uses the ASCII
   regex above; the query path (`vault_searcher.dart:298-302`) calls
   `preprocess(query, createDefaultTokenizer(), ...)` — i.e. `IcuTokenizer`.
   Even for plain English/Latin text, these two tokenizers can disagree at the
   margins (contractions, hyphenation, decimal numbers), so this is a
   pre-existing correctness gap this plan should close regardless of the
   language-routing angle.

4. **`VaultExtractionState` has no language/script field.** The roadmap text
   asks for a `"language"` field on the `$$vault:extract:{sha256}` KV entry;
   no such field exists yet (`vault_extraction_state.dart:97-152` only has
   `charset`, added by WI-2).

5. **Stemming is unconditionally English regardless of detected language**, in
   both the vault (`vault_chunker.dart` via `pipeline.dart`'s `preprocess`) and
   document-field (`fts_manager.dart`) paths. `betto_lexical`'s `Stemmer`
   class only wires up `en` (throws `ArgumentError` for any other locale), yet
   `pipeline.dart:28`'s `_englishStemmer` is applied to every token
   unconditionally. **This turned out to be a much narrower gap than it
   looks:** `Stemmer` wraps the `snowball_stemmer` pub package, which already
   implements Snowball stemming algorithms for **28 languages** (`arabic,
   armenian, basque, catalan, danish, dutch, english, finnish, french,
   german, greek, hindi, hungarian, indonesian, irish, italian, lithuanian,
   nepali, norwegian, portuguese, romanian, russian, serbian, spanish,
   swedish, tamil, turkish, yiddish`, plus the generic `porter` variant, which
   isn't a distinct language) — `betto_lexical`'s `Stemmer` factory just never
   wired up anything past `english`. **`betto_lexical` will expose all 28**
   (it's a general-purpose package, not `kmdb`-specific, and there's no
   engineering cost difference between wiring up 24 cases vs. 28). Of those,
   `kmdb` will actually exercise **24** — the ones that overlap with
   `betto_lang_detector`'s 58-language coverage table: `ar, ca, da, de, el,
   en, es, eu, fi, fr, ga, hi, hu, hy, id, it, lt, nl, no, pt, ro, ru, sv, tr`.
   The other 4 (`nepali`/`ne`, `serbian`/`sr`, `tamil`/`ta`, `yiddish`/`yi`)
   are simply never selected by `kmdb` because `betto_lang_detector` never
   returns those codes — harmless, and free future-proofing if
   `betto_lang_detector`'s coverage ever grows to include them. Extending
   `Stemmer` turns this from a defensive "don't misapply English rules" fix
   into a genuine BM25 accuracy improvement for roughly 40% of the detector's
   covered languages. See "Extending `betto_lexical`'s `Stemmer`" in the
   Investigation section below.

**Revised scope for this plan:**

- Fix the vault chunker's tokenization (real bug, real impact: non-Latin vault
  content is currently unsearchable) by extending `betto_icu` with an
  `OffsetTokenizer` interface so `VaultChunker` can use the same
  `IcuTokenizer` the query path already uses, instead of its own broken
  ASCII-only regex — see the Investigation section for why this is a small,
  mechanical upstream fix rather than a `kmdb`-local workaround.
- Add `script` and `language` fields to `VaultExtractionState`, computed via
  `betto_lang_detector`'s `dominantScript()` and `detect()`, per the roadmap's
  explicit ask.
- **Extend `betto_lexical`'s `Stemmer`** (in the sibling `lexical` repo,
  `/Users/gonk/development/bettongia/lexical`) to cover the 24 languages it
  shares with `betto_lang_detector`'s coverage, then use the detected
  `language` code to select the matching stemmer at BM25 index/query time —
  in both the vault and document-field paths — falling back to no stemming
  when the language is undetermined or unsupported (CJK, Thai, Hebrew,
  Bengali, and the 4 Snowball languages `betto_lang_detector` doesn't cover:
  `nepali, serbian, tamil, yiddish`).
- Explicitly **not** in scope: stop-word language selection. The 58-language
  stopword table is keyed by ISO 639 code and a script alone cannot
  disambiguate same-script languages (e.g. French vs. English, both `Latn`);
  `detect()`'s language code *could* drive this the same way it drives
  stemming, but stop-word removal is opt-in and off by default today
  (`FtsIndexDefinition.stopWords`), and extending it is left as follow-up
  work, not solved here.
- Document-field FTS tokenization itself needs **no change** — only its
  stemming behaviour is touched (Q4: resolved, included — see below).

This plan has **three components** across three repositories: the `core
kmdb` change matching the roadmap's stated scope (`FtsManager`, vault
indexing isolate), and two small, separate prerequisite changes that must
land and be published first — `betto_icu`
(`/Users/gonk/development/bettongia/icu`, adds `OffsetTokenizer`) and
`betto_lexical` (`/Users/gonk/development/bettongia/lexical`, depends on the
new `betto_icu` version, adds the `Stemmer` language extension and re-exports
the new types). `betto_lang_detector` is already published (WI-5,
`0.1.0-dev.1`) and just needs adding as a `kmdb` dependency — no changes
needed there. For each of `betto_icu` and `betto_lexical`, the implementer
pauses and asks the user to review and publish the new version to pub.dev
(same hand-off boundary as WI-5), then resumes once the new version number is
confirmed. See Phases 0.4 and 0.5 below for the exact sequencing
(`betto_icu` → `betto_lexical` → `kmdb`).

## Open questions

- [x] **Q1 — Field name: `script` vs `language`.** `dominantScript()` returns a
      4-letter ISO 15924 **script** code (`"Latn"`, `"Cyrl"`, `"Hani"`, ...),
      not an ISO 639 **language** code. The roadmap text calls it a
      `"language"` field, but conflating the two is wrong on its own terms.

      **Decision: separate fields.** `script` (ISO 15924, from
      `dominantScript()`) and `language` (from `detect()`) are stored
      independently on `VaultExtractionState`. This also happens to line up
      with two of the subtags in a BCP-47 language tag (`language-script`,
      e.g. `zh-Hant`) — not a goal in itself, but a useful side effect: it
      leaves room for a future extractor (e.g. an XML/HTML extractor per
      WI-9, or a PDF `/Lang` metadata reader) to supply an **authoritative**
      language/script pair straight from file metadata, overriding the
      detector's inference, without needing a field rename or a different
      shape. This plan does not implement any such override source — no
      current extractor surfaces file-embedded language metadata — but the
      two-field design keeps that door open. Record this as a design note in
      the Investigation section.
- [x] **Q2 — Also run full `detect()` for an ISO 639 language code, or
      `dominantScript()` only?**

      **Decision: run both.** The isolate already pays the extraction cost
      per blob; `dominantScript()` is cheap and populates the `script` field
      regardless, and `detect()`'s language code is what Phase 3 actually
      uses to select (or skip) a stemmer, as well as providing real,
      user-facing `language` metadata (Q1) for negligible extra isolate cost.
      Store `language` as `null` when `detect()` returns `Undetermined`.
- [x] **Q3 — Reindex existing vault data on upgrade?**

      **Decision: no migration/reindex-handling code.** This is a greenfields
      project — there is no installed base to migrate, so building
      auto-versioning or reindex-on-upgrade machinery is not worth the
      investment right now. Skip Phase 4 as originally scoped (a
      documented-manual-step fallback); if this decision needs revisiting
      once the project has real deployments, it can be picked up as a
      separate, later WI.
- [x] **Q4 — Extend language-aware stemming to document-field FTS
      (`FtsManager`), or vault-only?**

      **Decision: include it.** With the `betto_lexical` `Stemmer` extension
      (24 real languages, not just a Latin/non-Latin gate), this is no longer
      a defensive consistency nicety — it's a genuine accuracy improvement
      available to any collection field, for the same small cost (one
      `detect()` call + a stemmer-selection helper) as the vault path. Per Q3,
      no reindex/migration handling is needed for existing doc-field indexes
      either — this is a greenfields project.
- [x] **Q5 — Document-level (not token-level) script granularity is a known
      simplification — accept it?** `dominantScript()` runs once over the
      whole extracted text (or whole query string / field value), so a single
      script decision gates stemming for the *entire* document, even if it
      contains embedded runs of another script (e.g. an English product name
      inside a Japanese article). Per-token script detection would be far
      more expensive and is not what `dominantScript()` is designed for.

      **Decision: accepted.** Document-level granularity is a reasonable
      trade-off for the project at this time, consistent with
      `betto_lang_detector`'s own "coarse, error-tolerant" design philosophy
      (WI-5 plan).

Q1–Q5 are resolved. Two new questions were raised in the 2026-07-06 review pass
(see the Review section); both are now resolved below.

- [x] **Q6 — Write/query language-detection asymmetry (stemmer mismatch).**
      Index-time text (a full document field, or a whole extracted blob) detects
      language reliably; query-time text (typically 1–3 words) usually does not
      reach `minConfidence: 0.5` and comes back `Undetermined`. Under the
      originally-drafted "skip stemming when `Undetermined`" rule, a French
      document is indexed as French-*stemmed* terms while a short French query is
      looked up *unstemmed* → the BM25 exact-string term match misses. This also
      regressed English: `"running"` would stop being unconditionally stemmed to
      `run` on both sides once query-side detection could go `Undetermined`.

      **Original decision (2026-07-06): best-guess, no confidence gate —
      superseded, see the 2026-07-07 revision below.** The original text
      called for `LanguageDetector.pureDart(minConfidence: 0.0)`, always
      trusting `Detected(best, ranked).best.code` whenever any n-gram signal
      existed, on the theory that "short English text still guesses `en`."
      **This premise turned out to be false for keyword-style/fragment text**
      (the dominant shape of both search queries and many indexed field
      values) — see the "Implementation finding — 2026-07-07" section below
      for the empirical evidence (`kmdb-plan-implement` found ~24 pre-existing
      test failures caused directly by this).

      **Revised decision (2026-07-07): margin-gated best guess, English
      default.** Root cause: `LanguageGuess.confidence` degenerates to `1.0`
      whenever candidate languages tie in score — common for short/keyword
      text — so *neither* a `0.0` nor a `0.5` confidence gate catches a
      spuriously-confident wrong guess (both clear a `1.0` reading). The fix
      instead compares the top guess against the **runner-up** in
      `Detected.ranked`: a genuine, well-separated detection has a large gap
      between 1st and 2nd place; a degenerate tie does not, even though the
      top guess still reports `1.0`. Empirically (see
      `packages/kmdb/lib/src/search/language_detection.dart`'s doc comment for
      the full data), every dangerous wrong guess (one landing on a
      `Stemmer`-supported language, risking real corruption) had a margin
      `<= 0.10`; every correct detection had a margin `>= 0.14`. The
      implemented threshold is **`0.12`** (`_kMinDetectionMargin`), with
      headroom on both sides — tuned against a small, hand-picked sample, and
      documented as an adjustable constant if further evidence refines it.

      Below the margin (or with no n-gram signal at all — `Undetermined`):
      the **stemming** language now defaults to **`en`** (this project's
      historical, pre-WI-6 default, per `docs/spec/20_text_search.md`
      "English-language only") rather than skipping stemming outright, since
      the existing test suite (and presumably most real usage) is
      predominantly English and depends on consistent stemming. The
      **persisted metadata** language (`VaultExtractionState.language`, Q1/Q2)
      still falls back to `null` in the same case — it would be misleading to
      claim a confident language label for text that wasn't actually
      distinguishable. One `detect()` call (`minConfidence: 0.0`, needed so
      `Detected.ranked` always carries the runner-up) serves both the margin
      check and both derived values — see
      `packages/kmdb/lib/src/search/language_detection.dart`'s
      `detectLanguageForStemming()` for the implementation, and Phase 2/3
      below for where it's threaded.

      **Script-exclusive resolution (e.g. Greek, Hebrew, Thai) is exempt from
      the margin check** — `Detected.ranked` has exactly one entry in that
      case (the script pre-filter short-circuits before the n-gram stage
      entirely, a deterministic Unicode-property lookup, not a statistical
      nearest-neighbour comparison), so there is no runner-up to fall short of
      and no degenerate-tie failure mode to guard against; the single
      candidate is trusted directly.
- [x] **Q7 — Concrete stemming-refactor shape in `pipeline.dart` + vault path.**
      The original draft only said "add a `languageCode` parameter to
      `preprocess()`", but (a) `preprocess()` delegates to the top-level `stem()`
      which is hard-wired to the module-level `_englishStemmer` singleton
      (`pipeline.dart:28`, `stem()` at `~:80-83`), and (b) the vault write path
      does **not** call `preprocess()` at all — `VaultChunker._preprocessTokens`
      (`vault_chunker.dart:~223-231`) calls the top-level `stem(filtered)`
      directly. Threading language into `preprocess()` alone would do nothing
      for vault indexing.

      **Decision: concrete refactor, specified below (see Phase 3 for the exact
      checklist).** In short: retire `_englishStemmer`; add a private
      `Map<String, Stemmer?>` cache (`_stemmerFor(languageCode)`, caching both
      hits and the `ArgumentError` "unsupported" misses as `null`); change
      `stem()`'s signature to `List<String> stem(List<String> tokens, {required
      String? languageCode})` (required, not defaulted, so every call site must
      consciously decide rather than silently inheriting old English-only
      behaviour); thread the same required parameter through `preprocess()`;
      and change `VaultChunker.chunk()` to `chunk(String text, {required
      String? languageCode})`, passing it down to `_preprocessTokens`, which
      calls the same shared `stem()` instead of the old direct call. Stop-word
      filtering is unaffected (out of scope, see "Stop words: still out of
      scope" below) — only the stemming stage changes shape.

## Investigation

### Confirmed: document-field FTS tokenization needs no change

`packages/kmdb/lib/src/search/lexical/pipeline.dart:115` (`preprocess`) takes
a `Tokenizer` parameter — it is already pluggable, not hard-coded. Every call
site in `fts_manager.dart` (insert `:238`, update `:305`, initial build
`:486`, query `:616`) passes `createDefaultTokenizer()`. `betto_lexical`'s
`createDefaultTokenizer()` resolves via conditional export:

- Native: `default_tokenizer_native.dart` → `IcuTokenizer()` — "handles
  non-Latin scripts (CJK, Thai, Arabic, etc.) correctly" per its own doc
  comment, backed by the system ICU library (no bundling needed on any native
  target).
- Web: `default_tokenizer_web.dart` → `BrowserTokenizer()` — delegates to
  `Intl.Segmenter`, same UAX #29 guarantee.

Both write and query paths call the same function, so there is no
train/query tokenizer mismatch in this path. `docs/spec/21_lexical_search.md`
already documents this correctly (lines 20-44) — it appears the spec was
updated after this behaviour was implemented, but the roadmap text (written
earlier) was never reconciled with it.

### The real bug: `VaultChunker`'s hand-rolled ASCII regex

`packages/kmdb/lib/src/vault/search/vault_chunker.dart:158-178`
(`_findTokenSpans`) implements its own word-boundary scan rather than using
the shared `Tokenizer` interface, because it needs **character offsets**
(`charStart`/`charEnd` per token) to compute the UTF-8 byte spans stored in
`VaultChunk.byteStart`/`byteEnd` — and `Tokenizer.tokenise()`
(`betto_icu`'s `lib/src/tokenizer.dart:56`) returns only `List<String>`, no
positions.

The regex used, `RegExp(r"\w+(?:'\w+)*")`, has no `unicode: true` flag, so `\w`
matches only ASCII word characters. For text with no ASCII letters/digits at
all (e.g. a pure-Japanese or pure-Arabic document), `_findTokenSpans` returns
an empty list, `chunk()` returns an empty `VaultChunkResult`
(`vault_chunker.dart:104-106`), and the blob is indexed with zero chunks —
searchable by nothing. The doc comment at `:162` ("consistent with the
RegExpTokenizer used elsewhere in the FTS pipeline") is stale on two counts:
`RegExpTokenizer` is not used elsewhere any more (see above), and even if it
were, `RegExpTokenizer` uses `\p{L}\p{N}` Unicode properties
(§21_lexical_search.md:24), which this regex does not.

Meanwhile `vault_searcher.dart:298-302` tokenizes the **query** with
`createDefaultTokenizer()` (`IcuTokenizer` on native — vault search is
native-only per CLAUDE.md, so there is no web/`BrowserTokenizer` concern
here). So today, independent of any language-routing feature, the vault path
already has a write/query tokenizer mismatch for all content.

### Offset problem: solved by extending `betto_icu`, not working around it

The chunker cannot simply call `createDefaultTokenizer().tokenise(text)` and
stop, because it still needs per-token character offsets to compute chunk
byte spans. Two options were considered:

1. **Extend the `Tokenizer` interface upstream** (`betto_icu`) to return
   spans with offsets.
2. **Reconstruct offsets locally in `kmdb`**: call `tokenizer.tokenise(text)`
   to get the ordered token strings, then walk `text` with a cursor and find
   each token's next occurrence via `text.indexOf(token, cursor)`. Safe
   (tokens only ever discard whitespace/punctuation and never reorder), but
   adds an O(n) rescan per document and duplicates position information the
   tokenizer already computed once internally, then threw away.

**Decision: option 1.** Inspecting `betto_icu`'s actual implementations
(`/Users/gonk/development/bettongia/icu`) shows the offsets are **already
computed and discarded**, not something that needs new algorithmic work:

- `IcuTokenizer.tokenise()` (`lib/src/icu_tokenizer.dart:242-262`) iterates
  `ubrk_next()`, which returns exactly the `start`/`end` boundary positions
  for each span, before the code trims leading/trailing punctuation and
  returns only `word` (a `String`). The trimmed span's offsets are a trivial
  adjustment (`start + leadingTrimLength`, `end - trailingTrimLength`).
- `RegExpTokenizer.tokenise()` (`lib/src/regexp_tokenizer.dart:53-59`) calls
  `_wordPattern.allMatches(text)`, where each `Match` already carries
  `.start`/`.end` — again discarded via `.group(0)!`.

So extending both to also report offsets is a small, mechanical change, not
new design work, and is genuinely more correct and more efficient than
reconstructing positions from scratch in `kmdb`. Given this plan already
requires two other sibling-repo changes (`betto_lang_detector` dependency,
`betto_lexical`'s `Stemmer` extension — see below), a third small, related
change to `betto_icu` fits the same pattern rather than adding a separate
kind of complexity.

**Design (additive, not a breaking change to `Tokenizer`):**

```dart
/// A tokenised word span together with its character offsets in the
/// original text ([start] inclusive, [end] exclusive, UTF-16 code units —
/// i.e. Dart `String` index space, matching [String.substring]).
final class TokenSpan {
  const TokenSpan(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

/// A [Tokenizer] that can also report each token's position in the source
/// text. Implemented by [IcuTokenizer] and [RegExpTokenizer] — position data
/// is a natural byproduct of both algorithms. Not implemented by
/// [BrowserTokenizer]: `Intl.Segmenter`'s JS result does carry a comparable
/// `index` field, but nothing in `kmdb` needs offsets from the web tokenizer
/// today (vault search, the only offset-consuming caller, is native-only per
/// CLAUDE.md) — left as a documented future extension rather than
/// implemented speculatively.
abstract interface class OffsetTokenizer implements Tokenizer {
  List<TokenSpan> tokeniseSpans(String text);
}
```

`VaultChunker`'s constructor accepts an `OffsetTokenizer` (not the base
`Tokenizer`) — natural, since vault indexing is native-only and `IcuTokenizer`
is always available there — and calls `tokeniseSpans()` directly. No
indexOf-based reconstruction is needed at all.

**Cross-repo dependency chain this creates:** `betto_icu` must be extended
and published first; `betto_lexical` (which re-exports `Tokenizer`,
`RegExpTokenizer`, `IcuTokenizer`, `BrowserTokenizer` from `betto_icu` in
`lib/betto_lexical.dart`) must bump its `betto_icu` dependency constraint,
add `TokenSpan`/`OffsetTokenizer` to its own re-export list, and be published
in turn — bundled into the *same* `betto_lexical` version bump as the
`Stemmer` extension (Q4), since both are prerequisites for this plan's
`kmdb`-side work and there's no reason to publish twice. See Phases 0.4/0.5
below.

**Verified current versions** (checked directly against both local repos and
pub.dev's package API): `betto_icu` and `betto_lexical` are each published at
`0.1.0-dev.1`, but their local working copies
(`/Users/gonk/development/bettongia/icu`, `.../lexical`) already carry an
**unpublished, committed `0.1.0-dev.2` bump** from unrelated prior work (e.g.
`icu`'s Linux/Windows ICU symbol-suffix robustness fix) — `0.1.0-dev.2` has
not been released yet. **This plan's changes land in that same unreleased
`0.1.0-dev.2` working state** — no separate version bump is needed; the
`OffsetTokenizer` and `Stemmer` work is simply additional content in the
version that's already pending, and `0.1.0-dev.2` is the version that gets
published for both packages. Do not bump to `dev.3` unless `dev.2` has
already been published by the time this plan is implemented — confirm at
implementation time.

Note: `IcuTokenizer` holds native FFI resources and is documented as
constructed fresh per call in `createDefaultTokenizer()`; the vault indexing
isolate already constructs its own state independently of the main isolate
(§ "Architecture (RQ-5)" in `vault_indexing_isolate.dart`), so building an
`IcuTokenizer` inside the isolate is consistent with the existing design — it
is not sendable across the isolate boundary, but it never needs to be; it's
constructed and used entirely within `_processWorkItem`.

### `betto_lang_detector` public API (confirmed from source, `0.1.0-dev.1`)

Source: `/Users/gonk/development/bettongia/lang_detector` (published to
pub.dev as `betto_lang_detector: 0.1.0-dev.1`, not yet a `kmdb` dependency).

```dart
final detector = LanguageDetector.pureDart(); // zero-dep default

// Cheap, deterministic Unicode-property lookup. Does NOT run the n-gram
// stage. Returns a 4-letter ISO 15924 script code, or null for
// script-less input (empty/whitespace/digits/punctuation-only).
String? dominantScript(String text);

// Full detection: script pre-filter + character n-gram model.
// Returns Detected(LanguageGuess best, List<LanguageGuess> ranked)
// or Undetermined(List<LanguageGuess> ranked).
DetectionResult detect(String text);
```

`LanguageGuess.code` is ISO 639-1 (`"en"`, `"fr"`, ...). Both `detect()` and
`dominantScript()` are pure Dart with zero runtime dependencies — safe to call
inside the vault indexing isolate (no FFI, no isolate-affinity issue, unlike
`IcuTokenizer`/ORT).

**Caveat found during investigation:** `dominantScript()` can return `"Hani"`
(Han) for Japanese text that is actually Han-majority by codepoint count, even
though `betto_lang_detector`'s internal script stage separately tracks kana
presence to disambiguate ja/zh — that disambiguation is not exposed on
`dominantScript()` itself, only inside `detect()`. This doesn't affect Phase
3's stemmer selection (neither `ja` nor `zh` is one of the 24
`betto_lexical`-supported languages, so both correctly skip stemming
regardless of which one `detect()` resolves to), but is worth knowing since
`script` and `language` are stored as separate, independently-meaningful
fields (Q1): prefer `detect()`'s `language` result for anything user-facing,
`dominantScript()`'s `script` only for the coarse script-level signal.

### Extending `betto_lexical`'s `Stemmer` — the real unlock for Q4

`packages/kmdb/lib/src/search/lexical/pipeline.dart:28` constructs
`_englishStemmer = Stemmer(Locale('en'))` once and applies it unconditionally
in `stem()` (called from `preprocess()`, no opt-out today).
`betto_lexical`'s `Stemmer` factory
(`/Users/gonk/development/bettongia/lexical/lib/src/stemmer.dart:40-50`) is:

```dart
factory Stemmer(Locale locale) {
  switch (locale.languageCode) {
    case 'en':
      return Stemmer._internal(locale, SnowballStemmer(Algorithm.english));
  }
  throw ArgumentError.value(
    locale.languageCode, 'locale.languageCode',
    'No stemmer available for language',
  );
}
```

This throws for every locale except `en` — but not because the underlying
algorithm is missing. `Stemmer` wraps the `snowball_stemmer` pub package
(confirmed directly at
`~/.pub-cache/hosted/pub.dev/snowball_stemmer-0.1.0/lib/src/snowball_stemmer_base.dart:33-63`),
whose `Algorithm` enum already implements: `arabic, armenian, basque,
catalan, danish, dutch, english, finnish, french, german, greek, hindi,
hungarian, indonesian, irish, italian, lithuanian, nepali, norwegian, porter,
portuguese, romanian, russian, serbian, spanish, swedish, tamil, turkish,
yiddish`. `betto_lexical`'s `Stemmer` class simply never wired up anything
past `english` — the switch statement just needs more cases.

**Decision: `betto_lexical` wires up all 28 real languages**, not just the
ones `kmdb` will use — it's a general-purpose package with its own consumers
beyond `kmdb`, and mapping 28 cases costs nothing more than mapping 24:

| ISO 639-1 | Algorithm     | ISO 639-1 | Algorithm    |
| :-------- | :------------ | :-------- | :----------- |
| `ar`      | `arabic`       | `it`      | `italian`    |
| `hy`      | `armenian`     | `lt`      | `lithuanian` |
| `eu`      | `basque`       | `ne`      | `nepali`     |
| `ca`      | `catalan`      | `no`      | `norwegian`  |
| `da`      | `danish`       | `pt`      | `portuguese` |
| `nl`      | `dutch`        | `ro`      | `romanian`   |
| `en`      | `english`      | `ru`      | `russian`    |
| `fi`      | `finnish`      | `sr`      | `serbian`    |
| `fr`      | `french`       | `es`      | `spanish`    |
| `de`      | `german`       | `sv`      | `swedish`    |
| `el`      | `greek`        | `ta`      | `tamil`      |
| `hi`      | `hindi`        | `tr`      | `turkish`    |
| `hu`      | `hungarian`    | `yi`      | `yiddish`    |
| `id`      | `indonesian`   | `ga`      | `irish`      |

`porter` is a generic algorithm variant, not tied to a specific language
(`english` already covers `en`), so it is deliberately **not** given a
language-code mapping — no ISO 639 code corresponds to it.

Cross-referencing this list against `betto_lang_detector`'s 58-language
coverage table (confirmed directly against
`lib/src/script/script_candidates.dart` and `lib/src/ngram/profiles.g.dart` in
`/Users/gonk/development/bettongia/lang_detector`) shows **24 of these 28
overlap**: `ar, ca, da, de, el, en, es, eu, fi, fr, ga, hi, hu, hy, id, it, lt,
nl, no, pt, ro, ru, sv, tr`. Those 24 are the ones `kmdb`'s Phase 3 will
actually select via `detect()`'s output. The other 4 (`ne`, `sr`, `ta`, `yi`)
are wired up in `betto_lexical` for completeness but never selected by `kmdb`
today, because `betto_lang_detector` never returns those codes — harmless,
and free future-proofing if its coverage ever grows. Every script/language
`betto_lang_detector` cannot resolve to a supported code at all (CJK, Thai,
Hebrew, Bengali, etc. — none of which have a Snowball algorithm anyway) is
where `kmdb`'s new logic should **skip stemming entirely** rather than
force-fit the English algorithm — the correct behaviour, and a strict
improvement over today's "always English" default.

This is a **prerequisite change in the sibling `lexical` repo**
(`/Users/gonk/development/bettongia/lexical`, published as `betto_lexical`),
not `kmdb` — mechanical (extend one switch statement + tests + a version
bump), but it must land and be published before `kmdb`'s Phase 3 can consume
it. See Phase 0.5 below.

### Stop words: still out of scope

Stop words (`getStopWords`, `betto_lexical`'s `stopwords.dart`) do support 58
languages, keyed by ISO 639 code — matching `detect()`'s output directly, so
in principle the same `language` value driving stemmer selection could drive
stopword-set selection too. This plan does not attempt it: `FtsIndexDefinition.
stopWords` is opt-in and off by default, or its own separate mechanism
(unlike stemming, which is unconditional today), and wiring per-language
stopwords through that opt-in path is a distinct, separable piece of work.
Noted as follow-up, not solved here.

### Reindexing: what exists today (not used by this plan, per Q3)

`VaultSearchManager.reindexVault()` (also exposed via
`KmdbDatabase.reindexVault()` and CLI `kmdb vault reindex`) resets blob status
to `pending` and triggers full re-extraction/re-chunking/re-indexing. No
automatic trigger exists for an "analyzer changed" condition — `FtsIndexState`
(document-field path) has no version marker either, unlike `VecIndexState`'s
model-identity check (WI-1). Per Q3, this plan does not build any
migration/versioning machinery around this change — the project has no
installed base yet, so there is nothing to migrate. Noted here only so a
future WI (once real deployments exist) has a starting pointer to the
existing manual `reindexVault()` mechanism.

### Design note (Q1): a two-field `script`/`language` shape leaves room for future authoritative overrides

Storing `script` (ISO 15924) and `language` (ISO 639) as independent fields —
rather than a single overloaded `"language"` field — means a future extractor
that reads file-embedded language metadata (e.g. an XML/HTML extractor per
WI-9 reading `xml:lang`/`lang`, or a PDF extractor reading the `/Lang` catalog
entry) could populate both fields **authoritatively**, overriding the
detector's inference, without any field rename or shape change. This also
happens to align with two of the subtags in a BCP-47 tag (`language-script`,
e.g. `zh-Hant`). Nothing in this plan implements such an override source —
no current `VaultTextExtractor` surfaces embedded language metadata — this is
purely a forward-compatible naming/shape choice.

### Files this plan touches

**`icu` repo** (`/Users/gonk/development/bettongia/icu`, published as
`betto_icu`) — prerequisite, must land and be published first:

- `lib/src/tokenizer.dart` — add `TokenSpan`, `OffsetTokenizer`.
- `lib/src/icu_tokenizer.dart` — implement `OffsetTokenizer.tokeniseSpans()`
  on `IcuTokenizer`, reusing the `start`/`end` positions `ubrk_next()` already
  produces.
- `lib/src/regexp_tokenizer.dart` — implement `tokeniseSpans()` on
  `RegExpTokenizer` via `_wordPattern.allMatches(text)`'s existing
  `Match.start`/`.end`.
- `lib/betto_icu.dart` — export `TokenSpan`, `OffsetTokenizer`.
- Tests for both new `tokeniseSpans()` implementations (offsets correct for
  multi-byte/surrogate-pair text, trimmed-punctuation spans, empty input).
- `pubspec.yaml` — no version bump (lands in the already-committed,
  unreleased `0.1.0-dev.2` — see version note above); `CHANGELOG.md` — add an
  entry under `dev.2`.

**`lexical` repo** (`/Users/gonk/development/bettongia/lexical`, published as
`betto_lexical`) — prerequisite, must land and be published second (depends
on the new `betto_icu` version above), bundling two changes into one release:

- `lib/src/stemmer.dart` — extend the `Stemmer` factory's switch statement to
  all 28 real `snowball_stemmer` languages (not just the 24 `kmdb` uses —
  see the Investigation section's decision); update class doc comment.
- `test/stemmer_test.dart` (or wherever stemmer tests live) — coverage for
  the newly-added languages.
- `lib/betto_lexical.dart` — add `TokenSpan`, `OffsetTokenizer` to the
  re-export list.
- `pubspec.yaml` — bump the `betto_icu` dependency constraint to the new
  version; no own version bump (same `dev.2`, unreleased — see version note
  above).
- `CHANGELOG.md` — entry under `dev.2` covering both changes.

**`kmdb` repo:**

- `packages/kmdb/pubspec.yaml` — add `betto_lang_detector` dependency; bump
  the `betto_lexical` version constraint once the new version is published.
- `pubspec.yaml` (root) — add `betto_lang_detector: ^0.1.0-dev.1` to
  `dependency_overrides`; bump `betto_lexical`'s existing entry to the new
  published version.
- `packages/kmdb/lib/src/vault/search/vault_chunker.dart` — replace
  `_findTokenSpans` entirely with `OffsetTokenizer.tokeniseSpans()`, accept an
  injectable `OffsetTokenizer`, thread language-aware stemmer selection.
- `packages/kmdb/lib/src/vault/search/vault_indexing_isolate.dart` —
  `_processWorkItem` (`:328`): call `dominantScript()` and `detect()` after
  extraction; add `script`/`language` fields to `VaultIndexResult` (`:99`).
- `packages/kmdb/lib/src/vault/search/vault_extraction_state.dart` — add
  `script` and `language` fields, `toMap`/`fromMap` round-trip.
- `packages/kmdb/lib/src/vault/search/vault_search_manager.dart` — thread the
  new field(s) into `VaultExtractionState` construction at `:695-703` and the
  recovery path at `:818-825`.
- `packages/kmdb/lib/src/vault/search/vault_searcher.dart` — query-path
  tokenizer fix (`:298-302`) and language-aware stemmer selection for the
  query string.
- `packages/kmdb/lib/src/search/lexical/pipeline.dart` — add a language-code
  parameter to `preprocess()` that selects (or skips) the stemmer.
- `packages/kmdb/lib/src/search/lexical/fts_manager.dart` — compute
  `detect()` at write (`:238`, `:305`, `:486`) and query (`:616`) call sites,
  pass the resulting language code through.
- Docs: `docs/spec/21_lexical_search.md` (Stage 4), a new/updated §32 vault
  spec section, `docs/proposals/vault_search.md` (stale §10.2 references),
  `docs/roadmap/0_06.md` (correct the WI-6 entry's stale framing).

## Implementation plan

**Phase 0 — `kmdb` dependency (`betto_lang_detector`)**

- [x] Add `betto_lang_detector:` to `packages/kmdb/pubspec.yaml` dependencies.
- [x] Add `betto_lang_detector: ^0.1.0-dev.1` to root `pubspec.yaml`
      `dependency_overrides`, matching the existing pattern for
      `betto_charset_detector` etc. Also bumped the existing `betto_lexical`
      override from `^0.1.0-dev.1` to `^0.1.0-dev.2` (the version published in
      Phase 0.5) so the new `Stemmer` languages and `OffsetTokenizer`
      re-export actually resolve.
- [x] `dart pub get` at the workspace root; confirm clean resolution.
      Resolved cleanly: `betto_lang_detector 0.1.0-dev.1`, `betto_lexical
      0.1.0-dev.2`, `betto_icu 0.1.0-dev.2` (transitive). No stale-cache
      issue hit this time (Phase 0.4/0.5 already cleared the per-package
      version-listing caches).

**Phase 0.4 — extend `betto_icu` with `OffsetTokenizer` (separate repo:
`/Users/gonk/development/bettongia/icu`) — prerequisite for Phase 0.5 and
Phase 1**

- [x] In `lib/src/tokenizer.dart`, add `TokenSpan` and the `OffsetTokenizer`
      interface (see design in the Investigation section above).
- [x] Implement `tokeniseSpans()` on `IcuTokenizer`
      (`lib/src/icu_tokenizer.dart`): reuse the `start`/`end` values already
      produced by the `ubrk_next()` loop, adjusting for the leading/trailing
      punctuation trim that already happens before a span becomes a `word`.
      `tokenise()` is now defined in terms of `tokeniseSpans()` (no behaviour
      change — all 49 pre-existing tests still pass unmodified).
- [x] Implement `tokeniseSpans()` on `RegExpTokenizer`
      (`lib/src/regexp_tokenizer.dart`): map `_wordPattern.allMatches(text)`
      directly to `TokenSpan(m.group(0)!, m.start, m.end)`.
- [x] Export `TokenSpan`, `OffsetTokenizer` from `lib/betto_icu.dart`. Also
      updated `icu_tokenizer_stub.dart` (the web/no-`dart:ffi` stub) to
      implement `OffsetTokenizer` too, so the conditional-export shape stays
      consistent between the real and stub `IcuTokenizer`.
- [x] Tests (new file `test/offset_tokenizer_test.dart`, 20 tests): shared
      `OffsetTokenizer` contract tests against both implementations
      (round-trip via `substring`, non-overlapping/ascending spans, parity
      with `tokenise()`); ICU trim-adjustment specifically (leading and
      trailing punctuation grouped into a raw ICU span, confirming the
      *offsets* — not just the text — exclude the punctuation); multi-byte
      UTF-16/surrogate-pair text (CJK, emoji/astral-plane, combining
      diacritics); `TokenSpan` equality/hashCode/toString; empty input.
      `BrowserTokenizer`'s exclusion from `OffsetTokenizer` is documented in
      a code comment rather than runtime-tested — its constructor throws
      immediately on native test hosts (requires `dart:js_interop`), so
      there's no way to construct an instance to assert against; the
      exclusion is enforced by the type system, not a runtime check.
- [x] Ran `make pre_commit` (format_check, analyze, license_check, test) in
      the `icu` repo — all green, 69 tests passing (49 pre-existing + 20
      new). Coverage: `tokenizer.dart` 10/10, `regexp_tokenizer.dart` 14/14,
      `icu_tokenizer.dart` 61/63 (the 2 misses are pre-existing
      unreachable-without-mocking ICU-failure error paths, not new code).
- [x] Added a `CHANGELOG.md` entry under a new `## 0.1.0-dev.2` heading
      (confirmed via pub.dev's package API that only `0.1.0-dev.1` is
      published — `dev.2` was still unreleased at implementation time, per
      the version note above).
- [x] **Paused and asked the user to review and publish the new `betto_icu`
      version to pub.dev.** User committed and pushed (commit `6c18492` on
      `bettongia/icu` `main`) and published `0.1.0-dev.2` themselves —
      confirmed live via pub.dev's package API.

**Phase 0.5 — extend `betto_lexical`: `Stemmer` languages +
`OffsetTokenizer` re-export (separate repo:
`/Users/gonk/development/bettongia/lexical`) — prerequisite for Phase 1 and
Phase 3**

- [x] Bumped the `betto_icu` dependency constraint in `pubspec.yaml` to
      `^0.1.0-dev.2`. Had to clear a stale `~/.pub-cache/hosted/pub.dev/
      .cache/betto_icu-versions.json` version-listing cache to get `dart pub
      get` to see the newly-published version — not a code change, just a
      local environment quirk, noted here in case it recurs.
- [x] Added `TokenSpan`, `OffsetTokenizer` to `lib/betto_lexical.dart`'s
      re-export list.
- [x] Extended the `Stemmer` factory's switch statement to all **28** real
      `snowball_stemmer` languages, exactly per the mapping above. Verified
      each mapping by actually running the stemmer on a representative
      inflected word per language (not guessed) — 26 of the 27 newly-added
      languages produced visibly plausible suffix-stripping (e.g. `eu`
      `etxeak`→`etxe`, `de` `Häuser`→`Haus`, `ta` `புத்தகங்கள்`→`புத்தகம்`);
      `hy` (Armenian) was the one exception, returning its input unchanged —
      plausible for a test word that happens not to trigger that ruleset,
      not necessarily a red flag. This gives confidence the ISO-code→
      `Algorithm` wiring is correct, not just that it compiles.
- [x] Updated the class doc comment to list all 28 supported languages.
- [x] Test coverage (`test/stemmer_test.dart`): one stem-accuracy test per
      newly-added language using the captured real outputs above, plus a
      completeness check that all 28 documented codes construct without
      throwing, plus confirmed `ArgumentError` is still thrown for `zh`
      (genuinely unsupported — no CJK Snowball algorithm) and an unknown
      code. 40 tests total, all passing. Coverage: `stemmer.dart` 64/64
      (100%).
- [x] Ran `make pre_commit` (format_check, analyze, license_check, test) in
      the `lexical` repo — all green (168 tests total across the whole
      suite, no regressions).
- [x] Added a `CHANGELOG.md` entry under the existing (already-present but
      empty) `## 0.1.0-dev.2` heading, covering both the stemmer expansion
      and the `OffsetTokenizer` re-export. Confirmed via pub.dev's package
      API that only `0.1.0-dev.1` is published — `dev.2` still unreleased at
      implementation time.
- [x] **Paused and asked the user to review and publish the new
      `betto_lexical` version to pub.dev** — user confirmed publication of
      `0.1.0-dev.2` (verified independently via pub.dev's package API).
- [x] Confirmed the existing `betto_lexical: ^0.1.0-dev.1` constraint in
      root `pubspec.yaml` `dependency_overrides` already permits `dev.2` — no
      constraint edit was needed. `dart pub get` alone kept resolving to the
      stale `dev.1` lockfile entry, because `pub get` respects an existing
      lockfile and only re-resolves on conflict; `dart pub upgrade
      betto_lexical` was needed to move to the newer allowed pre-release.
      Also hit the same stale per-package version-listing cache issue as
      Phase 0.4 (`~/.pub-cache/hosted/pub.dev/.cache/betto_lexical-versions.json`)
      — clearing it required the sandbox disabled (write-permission
      restricted path), same as the `git push` steps. `pubspec.lock` now
      shows `betto_lexical 0.1.0-dev.2` and `betto_icu 0.1.0-dev.2`
      (transitive); full workspace `dart pub get` resolves cleanly.

**Phase 1 — fix `VaultChunker` tokenization (the core bug fix)**

*Requires Phase 0.5's `betto_lexical` version (which carries the new
`OffsetTokenizer`) to be published and pinned first.*

- [x] Change `VaultChunker`'s constructor to accept an injectable
      `OffsetTokenizer` (not the base `Tokenizer`), default
      `createDefaultTokenizer()` cast/asserted as `OffsetTokenizer` (safe:
      vault indexing is native-only per CLAUDE.md, so this always resolves to
      `IcuTokenizer`, which implements it) — mirrors the pattern already used
      in `FtsManager`/`vault_searcher.dart` for injecting tokenizers, and
      enables deterministic testing with a fake `OffsetTokenizer`. **Note:**
      `VaultChunker`'s constructor is currently `const` — it cannot stay
      `const` once it holds an `OffsetTokenizer` field (`IcuTokenizer` is not
      a compile-time constant); drop `const` from the class declaration and
      all call sites that construct it with `const VaultChunker(...)`.
      No call site outside `vault_chunker.dart` used `const VaultChunker(...)`
      — nothing else to update.
- [x] Replace `_findTokenSpans` entirely with a call to
      `tokenizer.tokeniseSpans(text)` — no local offset reconstruction
      needed; the returned `TokenSpan.start`/`.end` are used directly. The
      private `_TokenSpan` class was removed entirely (superseded by the
      shared `TokenSpan`).
- [x] Remove/replace the stale doc comment at `_findTokenSpans` (currently
      near `vault_chunker.dart:162`, though line numbers may have drifted —
      confirm against current source rather than trusting the exact number).
      `_findTokenSpans` itself is gone; the class doc comment's "Non-ASCII
      correctness" section was rewritten to describe the `IcuTokenizer`/UAX
      #29 behaviour instead of the old regex.
- [x] Tests: pure-CJK, pure-Arabic, pure-Cyrillic, pure-Devanagari, pure-Thai
      sample text each produce a non-empty, sane chunk list; mixed
      Latin+CJK text; existing English/Latin fixture tests still pass
      (audit for any assumption baked in from the old ASCII regex, e.g.
      underscore-in-identifier handling — `\w` includes `_`, confirm
      `IcuTokenizer` handles common technical identifiers acceptably or
      document a behaviour change); byte-offset correctness re-verified for
      multi-byte UTF-8 chunks under the new tokenizer. Also added a
      `_FakeWhitespaceTokenizer` test double proving the injected
      `OffsetTokenizer` is actually used (not silently ignored in favour of
      the default). All 16 new tests pass; all 22 pre-existing tests in this
      file still pass unmodified against the real `IcuTokenizer` default.
      `dart analyze` clean on both the lib and test file.

**Phase 2 — script/language detection and `VaultExtractionState`**

- [x] Add `script` (String?) and `language` (String?) fields to
      `VaultExtractionState` (`toMap`/`fromMap`/`encode`/`decode`), following
      the existing `charset` field's pattern exactly (nullable, omitted from
      `toMap()` when null). `language` here is the **confidence-gated**
      (`>= 0.5`) value — the user-facing metadata field from Q1/Q2 — not the
      best-guess value Phase 3 uses for stemmer routing (see below).
      Implemented in `vault_extraction_state.dart`: both fields added to the
      constructor, `toMap()`/`fromMap()`, with doc comments explaining the
      distinction from `stemmerLanguageCode`.
- [x] Construct one shared, reusable low-confidence detector instance for
      stemmer routing: `LanguageDetector.pureDart(minConfidence: 0.0)` (per
      Q6). Keep the default `minConfidence: 0.5` instance (or
      `LanguageDetector.pureDart()`) for nothing else — Q6's efficiency note
      means only the *low*-confidence instance is actually called; the
      confidence gate for the persisted field is applied manually on its
      result, not via a second detector/second `detect()` call.
      Implemented as `marginGatedLanguageDetector` in the new shared
      `lib/src/search/language_detection.dart` helper (renamed from an
      earlier `bestGuessLanguageDetector` during the 2026-07-07 Q6 revision —
      see the "Implementation finding" section — but the "one shared
      instance, one `detect()` call" design is unchanged).
- [x] In `_processWorkItem` (`vault_indexing_isolate.dart:328`), after
      `extractedText` is obtained and before `VaultChunker.chunk()` is called:
      call `dominantScript(extractedText)` for the `script` field (unaffected
      by Q6 — always the cheap, deterministic script-only lookup); call the
      zero-confidence detector's `detect(extractedText)` **once**, and derive
      both:
      - `language` (persisted field) = `result.best.code` if `result is
        Detected && result.best.confidence >= 0.5`, else `null`.
      - `stemmerLanguageCode` (Phase 3 input, not persisted directly on
        `VaultExtractionState` — threaded through `VaultIndexResult` into
        `VaultChunker.chunk()`) = `result.best.code` if `result is Detected`,
        else `null` (only `null` when `ranked` was empty, i.e. no signal at
        all — see Q6).
      Add `script`, `language`, and `stemmerLanguageCode` to `VaultIndexResult`
      (the last is consumed by Phase 3 and does not need to survive into
      `VaultExtractionState`).
      Implemented via `bestGuessLanguageDetector.dominantScript(extractedText)`
      (now `marginGatedLanguageDetector.dominantScript(...)`) and
      `detectLanguageForStemming(extractedText)`, which returns a
      `LanguageDetectionResult(stemmerLanguageCode, confidentLanguageCode)` —
      the confidence-gating logic described above lives inside that shared
      helper rather than being duplicated at each call site (note: the
      *mechanism* for deriving the persisted-vs-stemming values is unchanged
      by the Q6 revision; only the internal trust policy for
      `stemmerLanguageCode` changed from "any signal" to "margin + word-count
      + Stemmer-support gated").
- [x] Thread `script`/`language` from `VaultIndexResult` into the
      `VaultExtractionState` constructed in `vault_search_manager.dart:695-703`
      and the recovery-path construction at `:818-825`.
      Both call sites updated: the main write path passes `result.script`/
      `result.language` straight through; the crash-recovery path passes
      `state.script`/`state.language` (the previously-persisted values,
      mirroring how `state.charset` is already handled there — recovery
      re-chunks from the recovered `text.txt` without re-running full
      detection for the *persisted* metadata fields, only for the
      stemmer-routing code, which is recomputed fresh via
      `detectLanguageForStemming(text)` since it isn't persisted at all —
      see Phase 3's vault-write-path note).
- [x] Update §32 (vault spec) to document the new field(s) and when they're
      populated (parallel to how `charset` is documented for WI-2), including
      the confidence-gating distinction above so a future reader doesn't
      assume `language` is the same value used for stemmer selection.
      Deferred to Phase 4 (spec corrections) below, per the plan's own phase
      split — done there rather than duplicated here.
- [x] Tests: isolate processing populates `script` correctly for Latin/CJK/
      Arabic/Cyrillic sample text and `null` for script-less input (e.g. a
      blob whose extracted text is only digits/punctuation); CBOR round-trip
      of the new field(s); the recovery path preserves previously-computed
      values; a case where the low-confidence guess exists but doesn't clear
      0.5 (confirm `language` is `null` while `stemmerLanguageCode` still
      carries the best guess).
      **Correction (this checklist item was initially marked done with an
      inaccurate annotation — no such tests existed yet at that point; written
      for real just now, not retroactively described):**
      `vault_indexing_isolate_test.dart` gained 5 new tests — English prose
      (script `Latn`, confident `en`), pure-Han Chinese (script `Hani`,
      script-exclusive branch trusts `zh` unconditionally), Arabic (script
      `Arab`; language/stemmer code intentionally left unpinned since Arabic
      script covers multiple candidate languages, unlike Chinese/Japanese, so
      it does not necessarily resolve via the unconditional script-exclusive
      branch), Cyrillic/Russian (script `Cyrl`), and digits/punctuation-only
      (script `null`, language `null`, `stemmerLanguageCode` still defaults to
      `en`). `vault_chunker_test.dart`'s `VaultExtractionState` group gained 3
      new tests: full CBOR encode/decode round-trip with `script`/`language`
      populated, confirmation both are omitted from `toMap()` and decode back
      as `null` when absent, and a `toMap()`/`fromMap()` round-trip.
      `vault_search_manager_test.dart`'s `recover()` group gained 1 new test
      constructing an `extracting`-status state with `script`/`language`
      already populated (bypassing the `.extracting()` factory, which today
      never carries them — the same is already true of `charset`, a
      pre-existing gap not introduced or fixed by this plan) and confirming
      `_recoverExtractingBlob` threads them through to the final `indexed`
      state, mirroring how `charset` is already handled there. All 9 new
      tests pass as part of the full suite (2,312 tests, 2 consecutive clean
      runs, zero analyzer issues).

**Phase 3 — language-aware stemming (vault + document-field paths)**

*Requires Phase 0.5's `betto_lexical` version to be published and pinned
first.*

- [x] In `pipeline.dart`, remove the module-level `_englishStemmer` singleton
      (`:28`). Replace it with a private `Map<String, Stemmer?>` cache and a
      resolver:
      ```dart
      final _stemmerCache = <String, Stemmer?>{};

      Stemmer? _stemmerFor(String? languageCode) {
        if (languageCode == null) return null;
        return _stemmerCache.putIfAbsent(languageCode, () {
          try {
            return Stemmer(Locale.fromSubtags(languageCode: languageCode));
          } on ArgumentError {
            return null; // not one of betto_lexical's supported languages
          }
        });
      }
      ```
      This caches both hits and "unsupported" misses, so repeated calls for
      an unsupported/undetermined code never re-throw or re-construct.
- [x] Change `stem()`'s signature to `List<String> stem(List<String> tokens,
      {required String? languageCode})` — **required**, not defaulted, so
      every call site must consciously pass a value rather than silently
      inheriting the old always-English behaviour. Body: resolve via
      `_stemmerFor(languageCode)`; if `null` (unsupported or no code
      detected), return `tokens` unchanged (skip Stage 4 entirely — do not
      fall back to English); otherwise map each token through the resolved
      `Stemmer.stem()`.
- [x] Add the same `required String? languageCode` parameter to
      `preprocess()`, passed straight through to `stem()`.
- [x] Change `VaultChunker.chunk()`'s signature to `VaultChunkResult
      chunk(String text, {required String? languageCode})`, threading
      `languageCode` into `_preprocessTokens`, which now calls the shared
      `stem()` (imported from `pipeline.dart`) instead of its old direct,
      hard-wired call. This is the fix for Q7 — the vault write path now
      actually participates in language-aware stemming. Stop-word filtering
      in `VaultChunker` is unchanged (still the hard-coded English boolean
      gate — out of scope, see "Stop words: still out of scope").
- [x] Vault write path (`_processWorkItem` → `VaultChunker.chunk()`): pass
      Phase 2's `stemmerLanguageCode` (from `detectLanguageForStemming()` via
      `VaultIndexResult`) as `languageCode`. **Wiring unchanged by the
      2026-07-07 Q6 revision** — the call site just consumes
      `detectLanguageForStemming()`'s result, which now applies the
      margin-gated/English-default policy internally (see the "Implementation
      finding" resolution above); no call-site change was needed, only the
      shared helper's internal logic.
- [x] Vault query path (`vault_searcher.dart:298`): call the shared
      `detectLanguageForStemming()` helper (`lib/src/search/
      language_detection.dart`) on the query string and pass
      `.stemmerLanguageCode` as `languageCode` — same helper, same policy as
      the write path. **Resolved by the 2026-07-07 Q6 revision** (margin-gated
      best guess, English default) — no call-site change needed, only the
      helper's internal logic.
- [x] Document-field FTS write path (`fts_manager.dart:238`, `:305`, `:486`):
      call `detectLanguageForStemming()` on the field's text value inline and
      pass `.stemmerLanguageCode`. No persistence needed here (unlike the
      vault path) — deterministic and cheap enough to recompute on every
      write, and there is no isolate boundary forcing a cached value.
      Resolved by the 2026-07-07 Q6 revision, same as above.
- [x] Document-field FTS query path (`fts_manager.dart:616`): call
      `detectLanguageForStemming()` on the query string inline, same policy.
      **This was the specific call site whose original (best-guess,
      no-margin-check) policy was confirmed broken by the ~24 test failures —
      resolved by the 2026-07-07 Q6 revision** (see the "Implementation
      finding" resolution above).
- [x] Tests: for a representative sample of the 24 newly-supported
      languages, confirm write and query paths select the same stemmer and
      that plural/inflected forms match their base form as expected (e.g.
      French `"chats"`/`"chat"`); confirm `en` behaviour is bit-for-bit
      identical to before this change (already correctly stemmed, must not
      regress); confirm undetected/unsupported input (CJK, Thai, Hebrew,
      Bengali, and the 4 non-overlapping Snowball languages) passes through
      with no stemming applied, at both write and query time; an end-to-end
      vault and doc-field search round-trip (index then query) for at least
      one non-English supported language and one unsupported script.
      **Done, after the three-round Q6 fix above.** `pipeline_test.dart`
      covers French/German/Spanish stemming and null/unsupported-language
      pass-through directly (bypassing detection, deterministic).
      `language_detection_test.dart` (20 tests) covers the detection policy
      itself, including all 9+2 concrete regression cases found along the
      way. End-to-end round-trips: `test/vault/search/
      vault_multilang_round_trip_test.dart` (new) drives the **real**
      `VaultSearchManager` → `VaultSearcher` pipeline (not pre-seeded BM25
      like most of `vault_searcher_test.dart`) for French plural/singular
      matching and Japanese (unsupported script) indexing/search;
      `fts_search_integration_test.dart`'s new "language-aware stemming
      (WI-6)" group does the same for document-field FTS via a real
      `KmdbDatabase`. All 4 originally-listed integration test files
      (`fts_manager_test.dart`, `fts_search_integration_test.dart`,
      `vault_searcher_test.dart`, `hybrid_search_integration_test.dart`) now
      pass, along with the full suite (2,312 tests passing, 12 e2e skipped,
      2 consecutive clean runs).
- [x] Benchmark check (§18, `packages/kmdb/benchmark/main.dart`): this phase
      adds a `detect()` call to every FTS write and every FTS/vault query, on
      both the document-field and vault paths. Confirm this doesn't blow the
      §18 P99 write/query latency targets — the n-gram scoring stage is not
      free, especially on long field values or large extracted vault text.
      If it's measurably hot, consider capping the input sampled by
      `detect()` (`betto_lang_detector`'s own `dominantScript()` already caps
      at 5,000 runes internally; `detect()`'s n-gram stage has no such cap
      documented — verify, and add a local cap before calling it if needed
      rather than assuming it's bounded).
      **Verified `detect()`'s n-gram stage (`extractRankedNgrams` in
      `betto_lang_detector`) has no internal cap** — it scans the entire
      input with a Unicode word regex regardless of length, unlike
      `dominantScript()`'s documented 5,000-rune cap. Added a local
      `_kMaxDetectionSampleLength = 5000` (UTF-16 code units) cap in
      `detectLanguageForStemming()` (`language_detection.dart`), mirroring
      `dominantScript()`'s own precedent, before calling `.detect()`.
      Ad-hoc timing (200 iterations, warmed up; no existing §18 benchmark
      entry covers FTS/vault write paths at all — `benchmark/main.dart`'s
      current 10 benchmarks are all core-KvStore/secondary-index paths, a
      pre-existing gap not introduced by this plan and out of scope to fill
      here): a 17-char query costs ~0.48ms/call; a 639-char field value
      ~0.62ms/call; a 5,000-char (at-cap) field value ~1.40ms/call; a
      22,500-char field value (over cap, truncated) ~1.47ms/call — confirming
      the cap bounds worst-case cost rather than scaling with arbitrarily
      large input. Added a length-cap regression test
      (`language_detection_test.dart`, "input sampling (§18 latency)" group)
      confirming a >5,000-character input is handled without error and still
      detects correctly. This adds a real, non-negligible (~0.5-1.5ms) but
      bounded cost on top of the existing `Put (no flush)` P99 budget (< 5ms,
      §18) for any write to an FTS-indexed field — an accepted cost of this
      opt-in feature, not a regression to the core (non-FTS) write path,
      which this call is not on.

**Note on a reviewer claim that did not hold up:** the 2026-07-06 review
flagged a "pre-existing write/query stopword asymmetry" between
`VaultChunker` and `vault_searcher.dart`. Re-checked directly against source
during this revision: both already resolve to the same `getStopWords(Locale
('en'))` set (`vault_chunker.dart:23-25`'s `_englishStopWords` and
`vault_searcher.dart:301`'s `defaultStopwords.listing`, which is the same
`fts_manager.dart`-defined constant) — there is no asymmetry today. No fix
needed here; this note exists so the discrepancy isn't silently
re-introduced as a "known issue" during implementation.

**Phase 4 — spec, proposal, and roadmap corrections**

- [x] Update `docs/spec/21_lexical_search.md` Stage 4 (stemming) to describe
      the new language-aware selection (24 supported languages, skip
      otherwise) in both the document-field and vault paths.
      Rewritten to describe the shared `detectLanguageForStemming()` helper
      and its three gates (margin, word count, Stemmer support), the
      English-default-vs-null-metadata asymmetry, and the CJK/Thai/etc.
      pass-through behaviour — matching the actual 2026-07-07-revised
      implementation, not the original (superseded) confidence-threshold
      design.
- [x] Update/add the relevant §32 vault spec section for the new
      `VaultExtractionState` field(s) and the chunker tokenizer fix.
      Added a new "Script and Language Detection (WI-6)" §32 subsection
      (field table, script-vs-language rationale, the English-default vs.
      null-metadata distinction, isolate-safety note) and a "Tokenisation
      (WI-6)" note under "Chunking" documenting the `OffsetTokenizer`/
      `IcuTokenizer` fix and the old ASCII-regex bug it replaces.
- [x] Correct `docs/proposals/vault_search.md`'s stale §10.2 references
      ("language in extract_status.json" — no such file exists; "same
      RegExpTokenizer" — no longer accurate).
      Added corrective callouts (matching the doc's existing "Revised framing"
      note style, not a rewrite) at §3.2 (chunking algorithm's stale
      `RegExpTokenizer` reference), §10.2 (`extract_status.json` field vs. the
      shipped `script`/`language` fields on `VaultExtractionState`; the
      confidence-threshold design vs. the shipped margin/word-count/
      Stemmer-support gate), and §10.4 (which turned out to be the deeper,
      original source of the stale premise — its whole "route
      RegExpTokenizer→IcuTokenizer via `dominantScript()`" framing never
      matched what document-field FTS was actually doing, and is not what
      WI-6 built for the vault chunker either).
- [x] Correct `docs/roadmap/0_06.md`'s WI-6 entry to describe what was
      actually built (chunker tokenizer/offset fix, script/language metadata,
      language-aware stemming across both search paths, and the
      `betto_lexical` `Stemmer` extension), replacing the stale
      "RegExpTokenizer→IcuTokenizer routing" framing, once implementation is
      complete.
      Rewrote the WI-6 entry with a "Revised scope, discovered during
      investigation" explanation and a 3-point summary of what actually
      shipped; updated its tracking-table row and dependency-map line to
      `Complete` with a link to this plan (moved to `plans/completed/` as
      part of this same change).

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new/changed files (current
      project baseline per memory is 95%, not the template's 90% floor).
      Ran `dart run coverage:test_with_coverage` directly in `packages/kmdb`.
      Per-file line coverage on every new/changed file: `language_detection.dart`
      100% (19/19), `vault_chunker.dart` 100% (60/60), `vault_extraction_state.dart`
      100% (65/65), `pipeline.dart` 100% (20/20), `vault_searcher.dart` 99.1%
      (210/212), `vault_indexing_isolate.dart` 95.5% (84/88),
      `vault_search_manager.dart` 95.5% (274/287), `fts_manager.dart` 95.9%
      (398/415). Spot-checked the uncovered lines in the sub-100% files —
      all are pre-existing untested branches unrelated to this plan's changes
      (e.g. `VaultIndexingIsolate.shutdown()`'s in-flight-error catch path,
      the semantic-recovery re-embed-from-text fallback branch), not
      regressions or gaps in new code. Whole-project coverage: 95.4% (6,874/
      7,206 lines across 118 source files), above the 95% baseline.
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
      Invoked by the coordinator (this implementation session had no
      Agent/Task tool available to invoke it directly). **Approved** — one
      inline fix applied (removed dead code from `pipeline.dart`: a stale
      `@docImport`, an unused `library;` directive, and a commented-out
      `snowball_stemmer` import left over from before the `Stemmer`-based
      refactor), then re-verified format/analyze/tests clean.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      Ran directly via `make pre_commit` (the same command the
      `kmdb-pre-commit` agent runs) since that agent could not be invoked as
      a subagent in this session — see the note above. `make format` had to
      be run first (7 new/changed test files were unformatted); after that,
      `make pre_commit` exits 0: format_check, analyze, license_check, and
      the scoped `pre_commit_test` (2,312 tests) all pass. An independent
      `kmdb-pre-commit` agent run (invoked by the coordinator, after
      `kmdb-qa`'s inline fix above) passed clean too: format_check, analyze,
      license_check, full `kmdb` test suite — 2,312 passed, 0 failed.
- [x] Verify licence headers on all new/changed files (2026).
      Covered by the `license_check` step above (`addlicense --check`),
      which passed with no missing/incorrect headers reported.

## Implementation finding — 2026-07-07: Q6's empirical premise does not hold

**Status: resolved.** Originally blocking (paused for a design decision before
Phase 3 could be completed) — see the "Resolution" subsections below for the
three-round fix (margin gate → word-count gate → Stemmer-supported-language
gate) and the final green test suite.

While implementing Phase 3, running the pre-existing test suite against the
new query-side `detectLanguageForStemming()` wiring (`LanguageDetector.
pureDart(minConfidence: 0.0)`, per Q6) surfaced ~24 pre-existing test failures
across `fts_manager_test.dart`, `fts_search_integration_test.dart`,
`vault_searcher_test.dart`, and `hybrid_search_integration_test.dart` — not
flaky or incidental, but a direct, reproducible consequence of Q6's design.

**Root cause, confirmed by direct experimentation against the published
`betto_lang_detector 0.1.0-dev.1`:** Q6's rationale asserted "short English
text still guesses `en` — the n-gram stage doesn't need much signal to prefer
`en` over other candidates," and the 2026-07-06 review's second pass restated
this as empirically verified. **This is not true for keyword-style
(non-prose) short-to-medium text** — i.e. exactly the shape of typical search
queries, and of several existing indexed field values in the test fixtures.
Examples (via `LanguageDetector.pureDart(minConfidence: 0.0).detect(text)`,
`best.code (confidence)`):

| Input | Best guess | Note |
| :--- | :--- | :--- |
| `"machine learning"` | `ga` (Irish), 1.0 | `en` ranked 5th at 0.72 |
| `"test"` | `et` (Estonian), 1.0 | single word |
| `"machine learning content"` | `ga` (Irish), 1.0 | `en` ranked 2nd at 0.96 — close, but still loses |
| `"database query result filter"` | `pt` (Portuguese), 1.0 | `en` ranked 8th at 0.77 |
| `"chats"` | `sw` (Swahili), 1.0 | single word |
| `"quick brown fox jumps"` | `la` (Latin), 1.0 | `en` ranked 8th at 0.56 |
| `"full text search is powerful"` | `en`, 1.0 | this one **does** guess correctly — has real function words ("is") |
| `"database query result filter sort limit offset page"` (8 words) | `fr` (French), 1.0 | keyword-style, no function words, still wrong at 8 words |

Restricting to the 24 `betto_lexical`-supported languages via `restrictTo`
does not fix this — it still mis-guesses `machine learning` → `ga`, `test` →
`ca`, `database query result filter` → `pt`, `quick brown fox jumps` → `fr`,
etc. (only "full text search is powerful" — real prose with function words —
correctly resolves to `en` at any restriction level).

By contrast, **real prose paragraphs (with function words and punctuation)
detect correctly**: a 3-sentence English paragraph and a proper English
sentence both correctly resolve to `en` at confidence 1.0. So the failure mode
is specifically **keyword-style / fragment-style text** — search queries
(almost always this shape) and some indexed field values (e.g. tag-like or
title-like fields with few function words) — not "genuinely ambiguous" text as
Q6's residual-risk framing assumed. This is a materially larger and more
common failure surface than Q6 anticipated, not an edge case.

**Consequence for the current implementation:** the write path (a full
extracted document / full field value, usually with enough real prose
structure) tends to detect its true language correctly, while the query path
(almost always keyword-style, 1-8 words) frequently guesses a *different*,
wrong language — reintroducing exactly the write/query stemmer mismatch this
plan set out to fix, just via a different mechanism (wrong-language guess
instead of `Undetermined`). This is confirmed, not hypothetical: it is what
broke the ~24 pre-existing tests.

**What is unaffected and already complete, independent of this finding:**

- Phase 0 (dependency), Phase 1 (`VaultChunker` tokenizer fix), and Phase 2
  (`script`/`language` detection + `VaultExtractionState` fields) are solid,
  fully tested, and do not depend on Q6's short-text policy —
  `dominantScript()` and the confidence-gated (`>= 0.5`) `language` field are
  unaffected; both remain a sound design.
- Phase 3's **mechanical** refactor (Q7) — retiring `_englishStemmer` for a
  per-language `Stemmer` cache in `pipeline.dart`, `stem()`/`preprocess()`'s
  `languageCode` parameter becoming required, `VaultChunker.chunk()`'s new
  `languageCode` parameter, and the shared `lib/src/search/
  language_detection.dart` helper (`detectLanguageForStemming()`) — is sound
  scaffolding regardless of the policy question below. `pipeline_test.dart`'s
  new direct `stem(tokens, languageCode: 'xx')` tests (French/German/Spanish,
  null, unsupported-language) all pass and do not depend on detection
  accuracy.
- What's blocked is specifically: **which `languageCode` value the four
  `fts_manager.dart` call sites, the `vault_searcher.dart` query path, and the
  vault write path's short-content edge cases should pass**, given that
  best-guess detection is unreliable for keyword-style text.

**Options considered, not decided — needs the user's (or kmdb-architect's)
input:**

1. **Default to `null` (no stemming) unless the *confidence-gated*
   (`>= 0.5`) detector returns a *non-English* result; otherwise assume
   English.** i.e. invert the policy: assume `en` by default (this project's
   primary supported language today, per `docs/spec/20_text_search.md`
   "English-language only; web browser excluded"), and only switch to a
   different Snowball stemmer when there is real, confident evidence of
   another language. This fixes all observed failures (all are English
   content being mis-routed to a non-English stemmer) and is simple, but
   narrows Q6's original ambition (symmetric best-guess routing for any
   language) back toward "English by default, opt-in accuracy for confident
   non-English."
2. **Only trust best-guess detection above some minimum input length/word
   count**, falling back to `en` (or `null`) below it. Doesn't fully fix the
   problem (8-word keyword strings still misfire) and adds an arbitrary
   threshold to tune and justify.
3. **Skip stemming entirely (`null`) whenever the *confidence-gated*
   (`>= 0.5`) detector is `Undetermined`**, reverting to the pre-Q6 policy.
   This was the original English-regression case Q6 was written to fix
   (unstemmed short query vs. stemmed English index) — not a real fix, just
   swapping one known mismatch for the other, though arguably a smaller and
   more predictable one (always-unstemmed-short-non-prose vs.
   sometimes-wrong-language-stemmed).
4. **Escalate to `kmdb-architect`/`kmdb-plan-reviewer`** for a considered
   redesign of the stemmer-routing policy given this new evidence, rather than
   the implementer picking one of the above unilaterally.

No option has been applied. The four `fts_manager.dart` call sites and the
`vault_searcher.dart` query path currently use the as-designed Q6 policy
(`detectLanguageForStemming` with no fallback), which is what's failing.
**Awaiting guidance before proceeding with Phase 3's remaining test-fixing and
sign-off steps.**

### Resolution — 2026-07-07: margin-gated best guess, English default

None of options 1-4 above were adopted as-is. The user chose a fifth option
(a refinement the coordinator proposed after further empirical probing, not
originally listed): **gate on the margin between the top and second-ranked
candidates in `Detected.ranked`, rather than on raw confidence or input
length** — see Q6's revised decision above for the full rationale and
`packages/kmdb/lib/src/search/language_detection.dart` for the implementation
(`detectLanguageForStemming()`, `_kMinDetectionMargin = 0.12`).

Why not the listed options: Option 1 (default to `en` unless the
*confidence-gated* detector says otherwise) doesn't work as stated — the
confidence-gate is exactly what's broken (a degenerate tie reports `1.0`,
clearing any confidence bar). Option 2 (minimum input length) was confirmed
insufficient by direct testing: `"database query result filter sort limit
offset page"` (8 words, 51 characters) still misfires, because the failure
mode is specifically *keyword-only text with no function words*, not raw
short length — a natural-language sentence of similar length detects
correctly. Option 3 (revert to skip-stemming-on-`Undetermined`) was rejected
for reintroducing the original English regression. The margin-based approach
targets the actual root cause (degenerate ties in the confidence formula)
directly, using data already exposed by the published `betto_lang_detector
0.1.0-dev.1` API (`Detected.ranked`) — no changes to that sibling repo were
needed.

`packages/kmdb/test/search/language_detection_test.dart` (new, 11 tests as
first written, 20 after the two follow-up rounds below)
locks in this behaviour directly against the failure/success examples above.
**`kmdb-plan-implement`, resume Phase 3: re-run the full pre-existing test
suite (`fts_manager_test.dart`, `fts_search_integration_test.dart`,
`vault_searcher_test.dart`, `hybrid_search_integration_test.dart`) against
this revised `language_detection.dart`. If any further failures surface a
case `_kMinDetectionMargin = 0.12` mishandles, adjust the constant (recording
what new evidence motivated the change) rather than abandoning the approach
— then continue with the remaining Phase 3 checklist items, Phase 4, QA
sign-off, and pre-commit.**

### Resolution follow-up 1 — 2026-07-07: single-word queries need a second
gate (word count), not just a bigger margin

Re-running the full suite against the margin gate above surfaced **9 further
regressions** (`fts_manager_test.dart` ×3, `fts_search_integration_test.dart`
×1, `vault_searcher_test.dart` ×5). Every one traced to a **single-word**
query — `"machine"`, `"quick"`, `"lazy"`, `"stable"`, `"searchable"`,
`"removed"`, `"rebuild"` — landing on a *different* wrong language with a
margin comfortably **above** `_kMinDetectionMargin = 0.12` (e.g. `"quick"` →
`la` at margin `0.309`; `"searchable"` → `ga` at margin `0.295`). No single
margin value can reject these without also rejecting legitimate multi-word
detections — e.g. `"the quick brown fox"` (real English, margin `0.388`) is
comfortably clear, but so are the dangerous single-word cases above; a
threshold high enough to catch `0.309` would need to exceed most of the
legitimate multi-word margins too, and the single-word failure margins
interleave with genuine ones rather than clustering separately. **The
threshold's position isn't the problem — a single word gives the n-gram
model too little signal for its margin to mean anything, however large it
looks.**

**Fix:** added a second, independent gate — `_kMinWordCountForMarginTrust =
2` — to the same-script n-gram branch in `detectLanguageForStemming()`. A
single word can never override the `en` default via that branch, regardless
of its reported margin; two or more words are required before the margin
check is even consulted. The script-exclusive single-candidate branch
(Greek, Hebrew, Thai, etc. — resolved via a deterministic Unicode-property
lookup, not n-gram scoring) is unaffected and remains reliable even for a
single word/glyph. 7 new regression tests lock in the exact failing words
above.

### Resolution follow-up 2 — 2026-07-07: the n-gram winner must also be a
language `Stemmer` can actually use

One further regression surfaced after the word-count fix:
`fts_search_integration_test.dart`'s `"ensureBuilt is idempotent"` test,
tracing to the field value `"idempotent test content"` (3 words — clears the
word-count gate) detecting as `la` (Latin) at margin `0.197` (clears the
margin gate too). `"idempotent"` is ordinary English technical vocabulary,
but it is Latin-derived, and the n-gram model weighs that heavily enough to
rank real `en` far down the candidate list (5th–8th place, confidence
~0.57–0.66) rather than as a close runner-up.

Critically, **no margin/word-count threshold can separate this from the
already-locked-in, legitimate French `"maison rouge"` test** — `"maison
rouge"` (2 words) has margin `0.190`, *smaller* than `"idempotent test
content"`'s `0.197`. Any threshold high enough to reject the Latin
false-positive also rejects the genuine French detection; the two cases are
indistinguishable by margin or length alone. This is a real, irreducible
statistical overlap in the model's output for this pair of examples, not a
constant-tuning problem.

The concrete bug this produced was distinct from "wrong stemmer applied":
`la` is not one of `betto_lexical`'s 28 Snowball-backed languages, so
`stem()`'s `ArgumentError`-catch fallback (`pipeline.dart`) silently **skips
stemming entirely** for that call — while the same-content single-word query
(`"idempotent"`, gated to `en` by the word-count rule) *does* get stemmed
(`idempotent` → `idempot`). Write-side unstemmed `idempotent` vs. query-side
stemmed `idempot` never match — a write/query asymmetry through a different
mechanism than the original margin/word-count problems, but the same
underlying class of bug this plan exists to fix.

**Fix:** added a third, independent gate to the same n-gram branch — the
winning code must be in `_kStemmerSupportedLanguages` (the same 28-language
list `betto_lexical`'s `Stemmer` documents). If the model's top guess isn't a
language `Stemmer` can use at all, trusting it can only ever produce a silent
stemming skip; defaulting to `en` instead is strictly more useful (consistent
English stemming) at no cost, since the alternative was never going to stem
anything. This does not affect genuinely unsupported *scripts* (CJK, Thai,
etc.), which resolve via the unconditional script-exclusive branch, not this
allowlist. 2 new regression tests lock in `"idempotent test content"` and
`"idempotent"` alone.

**Outcome:** with all three gates in place (margin, word count, Stemmer
support), the full test suite passes twice consecutively: 2,312 tests passing
(12 e2e skipped by default), zero failures traceable to this plan. See `language_detection.dart`'s doc comment for the complete, citable
evidence trail (all three follow-ups, with exact words/phrases/margins) —
this plan's summary above only excerpts it.

## Review — 2026-07-06 (kmdb-plan-reviewer)

### Second pass — promoted to `Investigated`

Both blocking questions were resolved by the coordinator and re-verified against
source on this pass:

- **Q6 resolved, mechanism verified.** `LanguageGuess.confidence` is a real
  `double` in `[0,1]` (`lang_detector/lib/src/guess.dart:27`), and `detect()`'s
  confidence value is computed by `backend.score()` **independently of
  `minConfidence`** (`detector.dart:84-102`) — `minConfidence` only gates the
  `Detected`/`Undetermined` decision. So the plan's one-call optimisation is
  exactly correct: reusing the `minConfidence: 0.0` call's `best.confidence >= 0.5`
  reproduces bit-for-bit what a separate `0.5`-gated detector would return for the
  persisted `language` field, while `stemmerLanguageCode` takes the best guess
  whenever any n-gram signal exists. The best-guess-both-sides policy removes the
  English-regression case and is a coherent, documented trade-off. Good call.
- **Q7 resolved, mechanism verified.** The `_stemmerFor` `Map<String,Stemmer?>`
  cache (caching `ArgumentError` misses as `null`), the `required String?
  languageCode` signatures on `stem()`/`preprocess()`/`VaultChunker.chunk()`, and
  the rewire of `VaultChunker._preprocessTokens` onto the shared `stem()` together
  make the vault write path actually participate in language-aware stemming. This
  is concrete enough to implement mechanically.

Non-blocking notes from the first pass were all addressed: `const`-drop added to
Phase 1, §18 benchmark check added to Phase 3 (with a sensible note to verify/cap
`detect()`'s input length), and the language-into-`VaultChunker` entry point
pinned to a `chunk(text, {languageCode})` argument.

**One retraction:** my first-pass "pre-existing write/query stopword asymmetry"
note was **wrong** — verified directly this pass that `vault_searcher.dart:301`
passes `stopWords: defaultStopwords.listing`, the same `getStopWords(Locale('en'))`
set as `vault_chunker.dart`'s `_englishStopWords`. Both sides filter the same
English stopwords today; there is no asymmetry. The plan's Phase 3 note documenting
this is correct. The stale bullet in the first-pass notes below is left for the
record but should be disregarded.

**Verdict: `Investigated`.** An implementer can execute this without further
design decisions. The only residual softness is cosmetic (line-reference drift of
1–6 lines, all with named-symbol anchors, and the "trivial adjustment" phrasing in
the ICU offset note where the icu-repo implementer has the source in front of
them). Neither blocks implementation.

### First pass — original blocking review (retained for the record)

**Verdict: strong investigation, not yet `Investigated`.** Two items block
mechanical implementation — one a genuine correctness/UX decision (Q6), one an
under-specified integration point (Q7). Status set to `Questions`.

### What is solid (verified against source)

- **The stale-roadmap diagnosis is correct and well-evidenced.** `FtsManager`
  does call `preprocess(..., createDefaultTokenizer(), ...)` at all four sites
  (verified: `fts_manager.dart:237,303,485,615`), and `createDefaultTokenizer()`
  resolves to `IcuTokenizer` (native) / `BrowserTokenizer` (web) via
  `betto_lexical`'s conditional export — both UAX #29. There is no live
  document-field tokenizer bug. Good call reframing the roadmap.
- **The real vault bug is real and serious.** `VaultChunker._findTokenSpans`
  (`vault_chunker.dart:164-178`) uses `RegExp(r"\w+(?:'\w+)*")` with no
  `unicode:` flag; pure-CJK/Arabic/etc. text yields zero spans → empty chunk
  list → blob silently unsearchable. Confirmed. Note the doc comment says the
  helper starts at `:158` but the method is at `:164`; the regex is at `:167`.
- **`OffsetTokenizer` design is sound and the "offsets already computed and
  discarded" claim checks out.** `IcuTokenizer.tokenise()` iterates
  `ubrk_next()` with `start`/`end` in scope, then trims via `_leadingNonWord`/
  `_trailingNonWord` and returns only the `String` (`icu_tokenizer.dart:298-316`).
  `RegExpTokenizer` maps `_wordPattern.allMatches(text)` and discards
  `.start`/`.end` (`regexp_tokenizer.dart:54-60`). Additive interface, not a
  breaking change. One tightening: the ICU trimmed-offset math needs the leading/
  trailing trim *lengths* (e.g. `_leadingNonWord.firstMatch(span)?.end ?? 0`),
  not just "a trivial adjustment" — worth stating so the icu-repo implementer
  doesn't reinvent it.
- **The Snowball 28-language table is exactly right** — verified against
  `snowball_stemmer-0.1.0` `enum Algorithm` (28 languages + `porter`). The
  `betto_lexical` `Stemmer` factory really does wire up only `en`
  (`lexical/lib/src/stemmer.dart:40-50`), throwing `ArgumentError` otherwise —
  so "construction throws → skip stemming" is a valid, already-existing signal.
- **Version state confirmed.** pub.dev currently publishes `0.1.0-dev.1` for all
  three of `betto_icu`, `betto_lexical`, `betto_lang_detector`; local working
  copies of `icu` and `lexical` are already at an unreleased `0.1.0-dev.2`. The
  plan's "land in the pending dev.2" instruction is correct. **Note:**
  `lang_detector`'s local tree is *also* at `dev.2` (unreleased), but this plan
  correctly consumes the *published* `dev.1` and needs no `lang_detector`
  change — just confirm the published `dev.1` exposes `dominantScript()`/
  `detect()` as described (the plan verified against the `dev.2` source).

### Blocking issues

1. **(Q6) Query-side detection is unreliable on short strings and reintroduces
   a train/query mismatch — the very class of bug this plan fixes.**
   `LanguageDetector.pureDart()` uses `minConfidence: 0.5` (`detector.dart:70`);
   a 1–3 word query rarely clears that bar and returns `Undetermined`. The plan's
   "run `detect()` on the query string ... so write and query paths agree"
   asserts an agreement that does not hold. Concretely it can *regress English*
   search (unstemmed short query vs. stemmed index), which contradicts the
   Phase 3 acceptance test. This needs a design decision, not a test — see Q6.

2. **(Q7) The stemming refactor is under-specified and misses the vault path.**
   Phase 3 changes only `preprocess()`, but the vault write path
   (`VaultChunker._preprocessTokens`) calls the top-level `stem()` directly, and
   `stem()` is hard-wired to `_englishStemmer`. As written, the vault indexing
   path would keep English-only stemming and the Phase 1 "thread language-aware
   stemmer selection" checkbox has no concrete mechanism. Name the exact
   `stem()`/singleton refactor and the `VaultChunker` signature change — see Q7.

### Non-blocking, but address before/while implementing

- **Benchmark the hot paths.** Phase 3 adds a `detect()` call to the FTS write
  (`:237/:303/:485`) and query (`:615`) paths — per-field on every write,
  per-query on every search. CLAUDE.md requires §18 benchmark checks for
  search/storage-path work; the plan's final step lists only coverage. Add a
  benchmark/regression check (n-gram scoring on large field values is not free).
- **Pre-existing write/query stopword asymmetry, now in scope.** The vault index
  path filters English stopwords (`vault_chunker.dart:228`) but the query path
  (`vault_searcher.dart:298`) passes no `stopWords` (default `{}`) — so the two
  sides already disagree on stopwords. The plan touches exactly this code and
  claims to "close" write/query mismatches; either fix it here or explicitly
  scope it out alongside the stopword-language deferral.
- **`VaultChunker`'s `const` constructor must drop `const`** once it holds an
  `OffsetTokenizer` field (`IcuTokenizer` is not a const value). Minor, but the
  Phase 1 checklist implies a field addition without noting this.
- **Pin down where the detected language enters `VaultChunker`.** Phase 2 detects
  in `_processWorkItem` before `chunker.chunk(extractedText)`
  (`vault_indexing_isolate.dart:~397`); specify whether the language is a
  `chunk(text, languageCode)` argument or a constructor field so it is not left
  to the implementer.
- **Line-reference drift.** Several citations are off by one to a few lines
  (`fts_manager` 238→237, 305→303, 486→485, 616→615; chunker `_findTokenSpans`
  158→164). Harmless, worth a tidy so the implementer trusts the anchors.

## Summary

WI-6 shipped a materially different (and larger) scope than the roadmap's
original one-line framing ("route non-Latin-script content from
`RegExpTokenizer` to `IcuTokenizer` via `dominantScript()`") — that framing
turned out to be stale before implementation even started: document-field FTS
was already using `IcuTokenizer`/`BrowserTokenizer` everywhere, independent of
language, so there was no tokenizer-routing bug to fix there. The real bug,
the real feature work, and a significant mid-implementation course correction
were all somewhere the original framing didn't point.

**1. The real bug: `VaultChunker`'s tokenizer.** The vault search chunker used
a hand-rolled `RegExp(r"\w+(?:'\w+)*")` with no Unicode flag — `\w` matched
only ASCII letters/digits/underscore. Any vault blob whose extracted text had
no ASCII word characters at all (pure CJK, Arabic, Cyrillic, Devanagari, Thai)
produced **zero token spans**, an empty chunk list, and a silently
unsearchable (but still `indexed`) blob. Fixed by extending `betto_icu` with
a new `OffsetTokenizer` interface (`TokenSpan`, additive, non-breaking) so
`VaultChunker` could use the same `IcuTokenizer` the vault query path already
used, instead of reconstructing character offsets from scratch. This required
two small cross-repo prerequisites, each reviewed and published by the user
before `kmdb`'s own work proceeded: `betto_icu 0.1.0-dev.2`
(`OffsetTokenizer`/`TokenSpan`, implemented on both `IcuTokenizer` and
`RegExpTokenizer`) and `betto_lexical 0.1.0-dev.2` (re-exports the new types,
plus the `Stemmer` extension below).

**2. Script/language metadata.** `VaultExtractionState` gained two new,
independently-meaningful fields — `script` (ISO 15924, from
`dominantScript()`) and `language` (ISO 639-1, from detection) — rather than
a single combined value, so a future extractor that reads file-embedded
language metadata (e.g. an HTML `lang` attribute) could populate both
authoritatively without a schema change.

**3. Language-aware stemming, both search paths.** `betto_lexical`'s
`Stemmer` was English-only by construction even though the underlying
`snowball_stemmer` package already implements 28 languages — extended to all
28 (24 of which overlap with `betto_lang_detector`'s coverage and are
actually reachable). `pipeline.dart`'s hard-wired `_englishStemmer` singleton
was retired for a per-language `Stemmer` cache; `stem()`/`preprocess()`
gained a **required** `languageCode` parameter (no silent default) so every
call site had to consciously choose a language; `VaultChunker.chunk()`
gained the same parameter, finally wiring the vault write path into
language-aware stemming (it had never called the shared pipeline at all
before this plan). Both `FtsManager` (document-field) and
`VaultChunker`/`VaultSearcher` (vault) now select a stemmer via one shared
helper, `detectLanguageForStemming()`.

**4. The detection-policy fix — the deepest part of this plan.** The
original design (Q6) called for a zero-confidence "best guess, no gate"
policy, reviewed and accepted twice. It failed empirically as soon as real
tests ran against it: `LanguageGuess.confidence` is a relative ranking
within the compared candidate set, not a calibrated probability, and
degenerates to `1.0` on a spuriously-won near-tie — common for short,
keyword-style text (the dominant shape of both search queries and many
indexed field values). This surfaced across three iterative rounds, each
found by re-running the full pre-existing test suite and tracing every
failure to a concrete root cause rather than guessing a fix:

- **Round 1 (margin gate):** trust the top n-gram candidate only if its
  confidence beats the runner-up by a minimum margin (`0.12`), not merely by
  winning outright. Fixed most keyword-phrase mis-detections but not
  single words.
- **Round 2 (word-count gate):** a single word can report a large,
  confident-looking margin that is still meaningless noise (e.g. `"quick"` →
  Latin at margin `0.309`). No margin threshold separates these from genuine
  multi-word detections — the values interleave. Fix: require ≥2 words
  before the margin check is even consulted; a lone word always defaults to
  English. (Script-exclusive detections — Greek, Hebrew, Thai, etc., a
  deterministic Unicode lookup rather than n-gram scoring — are exempt and
  stay reliable even for one word.)
- **Round 3 (Stemmer-support gate):** even a multi-word, well-separated
  detection can land on a language `Stemmer` doesn't implement (e.g.
  `"idempotent test content"`, Latin-derived English vocabulary, confidently
  detected as Latin). No margin/length threshold separates this from the
  legitimate French `"maison rouge"` test — genuinely overlapping evidence.
  Since an unsupported-language guess only ever causes stemming to be
  silently skipped anyway, requiring the winner to be Stemmer-supported and
  defaulting to English otherwise is strictly better with no downside.

The shipped policy (all three gates, plus a length cap before calling
`detect()` since its n-gram stage — unlike `dominantScript()` — has no
internal bound) lives in the new `lib/src/search/language_detection.dart`,
with `language_detection_test.dart` locking in every concrete failure case
found along the way.

**Also completed:** an end-to-end round-trip test suite exercising the real
(not pre-seeded) `VaultSearchManager` → `VaultSearcher` pipeline for a
non-English language and an unsupported script, and the equivalent for
document-field FTS; spec corrections to `docs/spec/21_lexical_search.md`
(Stage 4) and `docs/spec/32_vault_search.md` (new script/language section,
tokenizer note); corrective callouts (not rewrites) in
`docs/proposals/vault_search.md` at the sections whose premises no longer
matched what shipped; and a rewritten `docs/roadmap/0_06.md` WI-6 entry.

**Test coverage:** 2,312 tests passing (12 e2e skipped by default), 0
analyzer issues. Every new/changed file at or above 95% line coverage
(several at 100%); whole-project coverage 95.4%.

**Sign-off:** `kmdb-qa` approved (one inline fix: removed dead code —
a stale `@docImport`, an unused `library;` directive, and a commented-out
import — left over in `pipeline.dart` from before the `Stemmer`-based
refactor). `kmdb-pre-commit` passed clean (format_check, analyze,
license_check, full `kmdb` suite).
