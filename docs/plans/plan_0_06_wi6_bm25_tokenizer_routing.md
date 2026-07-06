# WI-6: Language-aware BM25 tokenizer routing

**Status**: Implementing

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

      **Decision: best-guess, no confidence gate, for stemmer routing.**
      `LanguageDetector.pureDart(minConfidence: 0.0)` (a *second*, low-confidence
      instance, constructed once and reused — distinct from the default
      `minConfidence: 0.5` instance used for the persisted/user-facing `language`
      field) always returns `Detected(best, ranked)` whenever `ranked` is
      non-empty — i.e. whenever there is *any* n-gram signal at all — rather than
      `Undetermined` for merely-not-confident-enough input. Both write and query
      paths use this zero-confidence result's `best.code` to select a stemmer.
      This resolves the English-regression case cleanly (short English text
      still guesses `en` — the n-gram stage doesn't need much signal to prefer
      `en` over other candidates) and generally improves match odds for other
      short queries too. Residual risk: a genuinely ambiguous short string can
      still get a *wrong* language guess on the query side vs. the indexed
      document's (correctly, confidently detected) language, causing a miss —
      but that failure mode is no worse than the original "skip stemming"
      behaviour, and is a smaller, rarer window than before. Accepted as a
      documented trade-off consistent with `betto_lang_detector`'s "coarse,
      error-tolerant" design philosophy (Q5).

      **Efficiency note:** rather than running `detect()` twice (once per
      confidence threshold) and paying the n-gram scoring cost twice, call the
      zero-confidence detector **once** and apply the `>= 0.5` gate manually on
      its result for the persisted `language` field:
      `final language = (result is Detected && result.best.confidence >= 0.5)
      ? result.best.code : null;` while `stemmerLanguageCode = (result is
      Detected) ? result.best.code : null` always takes the best guess
      regardless of confidence. One `detect()` call serves both purposes. See
      Phase 2/3 below for exactly where this is threaded.
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

- [ ] Add `betto_lang_detector:` to `packages/kmdb/pubspec.yaml` dependencies.
- [ ] Add `betto_lang_detector: ^0.1.0-dev.1` to root `pubspec.yaml`
      `dependency_overrides`, matching the existing pattern for
      `betto_charset_detector` etc.
- [ ] `dart pub get` at the workspace root; confirm clean resolution.

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

- [ ] Change `VaultChunker`'s constructor to accept an injectable
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
- [ ] Replace `_findTokenSpans` entirely with a call to
      `tokenizer.tokeniseSpans(text)` — no local offset reconstruction
      needed; the returned `TokenSpan.start`/`.end` are used directly.
- [ ] Remove/replace the stale doc comment at `_findTokenSpans` (currently
      near `vault_chunker.dart:162`, though line numbers may have drifted —
      confirm against current source rather than trusting the exact number).
- [ ] Tests: pure-CJK, pure-Arabic, pure-Cyrillic, pure-Devanagari, pure-Thai
      sample text each produce a non-empty, sane chunk list; mixed
      Latin+CJK text; existing English/Latin fixture tests still pass
      (audit for any assumption baked in from the old ASCII regex, e.g.
      underscore-in-identifier handling — `\w` includes `_`, confirm
      `IcuTokenizer` handles common technical identifiers acceptably or
      document a behaviour change); byte-offset correctness re-verified for
      multi-byte UTF-8 chunks under the new tokenizer.

**Phase 2 — script/language detection and `VaultExtractionState`**

- [ ] Add `script` (String?) and `language` (String?) fields to
      `VaultExtractionState` (`toMap`/`fromMap`/`encode`/`decode`), following
      the existing `charset` field's pattern exactly (nullable, omitted from
      `toMap()` when null). `language` here is the **confidence-gated**
      (`>= 0.5`) value — the user-facing metadata field from Q1/Q2 — not the
      best-guess value Phase 3 uses for stemmer routing (see below).
- [ ] Construct one shared, reusable low-confidence detector instance for
      stemmer routing: `LanguageDetector.pureDart(minConfidence: 0.0)` (per
      Q6). Keep the default `minConfidence: 0.5` instance (or
      `LanguageDetector.pureDart()`) for nothing else — Q6's efficiency note
      means only the *low*-confidence instance is actually called; the
      confidence gate for the persisted field is applied manually on its
      result, not via a second detector/second `detect()` call.
- [ ] In `_processWorkItem` (`vault_indexing_isolate.dart:328`), after
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
- [ ] Thread `script`/`language` from `VaultIndexResult` into the
      `VaultExtractionState` constructed in `vault_search_manager.dart:695-703`
      and the recovery-path construction at `:818-825`.
- [ ] Update §32 (vault spec) to document the new field(s) and when they're
      populated (parallel to how `charset` is documented for WI-2), including
      the confidence-gating distinction above so a future reader doesn't
      assume `language` is the same value used for stemmer selection.
- [ ] Tests: isolate processing populates `script` correctly for Latin/CJK/
      Arabic/Cyrillic sample text and `null` for script-less input (e.g. a
      blob whose extracted text is only digits/punctuation); CBOR round-trip
      of the new field(s); the recovery path preserves previously-computed
      values; a case where the low-confidence guess exists but doesn't clear
      0.5 (confirm `language` is `null` while `stemmerLanguageCode` still
      carries the best guess).

**Phase 3 — language-aware stemming (vault + document-field paths)**

*Requires Phase 0.5's `betto_lexical` version to be published and pinned
first.*

- [ ] In `pipeline.dart`, remove the module-level `_englishStemmer` singleton
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
- [ ] Change `stem()`'s signature to `List<String> stem(List<String> tokens,
      {required String? languageCode})` — **required**, not defaulted, so
      every call site must consciously pass a value rather than silently
      inheriting the old always-English behaviour. Body: resolve via
      `_stemmerFor(languageCode)`; if `null` (unsupported or no code
      detected), return `tokens` unchanged (skip Stage 4 entirely — do not
      fall back to English); otherwise map each token through the resolved
      `Stemmer.stem()`.
- [ ] Add the same `required String? languageCode` parameter to
      `preprocess()`, passed straight through to `stem()`.
- [ ] Change `VaultChunker.chunk()`'s signature to `VaultChunkResult
      chunk(String text, {required String? languageCode})`, threading
      `languageCode` into `_preprocessTokens`, which now calls the shared
      `stem()` (imported from `pipeline.dart`) instead of its old direct,
      hard-wired call. This is the fix for Q7 — the vault write path now
      actually participates in language-aware stemming. Stop-word filtering
      in `VaultChunker` is unchanged (still the hard-coded English boolean
      gate — out of scope, see "Stop words: still out of scope").
- [ ] Vault write path (`_processWorkItem` → `VaultChunker.chunk()`): pass
      Phase 2's `stemmerLanguageCode` (the best-guess, non-confidence-gated
      value from `VaultIndexResult`) as `languageCode`.
- [ ] Vault query path (`vault_searcher.dart:298`): construct (or reuse) the
      same `LanguageDetector.pureDart(minConfidence: 0.0)` instance from
      Phase 2's design, call `.detect(query)`, and pass `result.best.code` (if
      `Detected`) or `null` (if `Undetermined`, i.e. no signal at all) as
      `languageCode` — the same best-guess policy as the write path, per Q6.
- [ ] Document-field FTS write path (`fts_manager.dart:238`, `:305`, `:486`):
      run the same zero-confidence `detect()` on the field's text value
      inline and pass the resulting best-guess code. No persistence needed
      here (unlike the vault path) — deterministic and cheap enough to
      recompute on every write, and there is no isolate boundary forcing a
      cached value.
- [ ] Document-field FTS query path (`fts_manager.dart:616`): run the same
      zero-confidence `detect()` on the query string inline, same best-guess
      policy.
- [ ] Tests: for a representative sample of the 24 newly-supported
      languages, confirm write and query paths select the same stemmer and
      that plural/inflected forms match their base form as expected (e.g.
      French `"chats"`/`"chat"`); confirm `en` behaviour is bit-for-bit
      identical to before this change (already correctly stemmed, must not
      regress); confirm undetected/unsupported input (CJK, Thai, Hebrew,
      Bengali, and the 4 non-overlapping Snowball languages) passes through
      with no stemming applied, at both write and query time; an end-to-end
      vault and doc-field search round-trip (index then query) for at least
      one non-English supported language and one unsupported script.
- [ ] Benchmark check (§18, `packages/kmdb/benchmark/main.dart`): this phase
      adds a `detect()` call to every FTS write and every FTS/vault query, on
      both the document-field and vault paths. Confirm this doesn't blow the
      §18 P99 write/query latency targets — the n-gram scoring stage is not
      free, especially on long field values or large extracted vault text.
      If it's measurably hot, consider capping the input sampled by
      `detect()` (`betto_lang_detector`'s own `dominantScript()` already caps
      at 5,000 runes internally; `detect()`'s n-gram stage has no such cap
      documented — verify, and add a local cap before calling it if needed
      rather than assuming it's bounded).

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

- [ ] Update `docs/spec/21_lexical_search.md` Stage 4 (stemming) to describe
      the new language-aware selection (24 supported languages, skip
      otherwise) in both the document-field and vault paths.
- [ ] Update/add the relevant §32 vault spec section for the new
      `VaultExtractionState` field(s) and the chunker tokenizer fix.
- [ ] Correct `docs/proposals/vault_search.md`'s stale §10.2 references
      ("language in extract_status.json" — no such file exists; "same
      RegExpTokenizer" — no longer accurate).
- [ ] Correct `docs/roadmap/0_06.md`'s WI-6 entry to describe what was
      actually built (chunker tokenizer/offset fix, script/language metadata,
      language-aware stemming across both search paths, and the
      `betto_lexical` `Stemmer` extension), replacing the stale
      "RegExpTokenizer→IcuTokenizer routing" framing, once implementation is
      complete.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new/changed files (current
      project baseline per memory is 95%, not the template's 90% floor).
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new/changed files (2026).

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

{To be filled in once implemented.}
