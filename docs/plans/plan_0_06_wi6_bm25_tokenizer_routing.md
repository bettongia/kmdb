# WI-6: Language-aware BM25 tokenizer routing

**Status**: Open

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

All open questions are resolved.

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

- [ ] In `lib/src/tokenizer.dart`, add `TokenSpan` and the `OffsetTokenizer`
      interface (see design in the Investigation section above).
- [ ] Implement `tokeniseSpans()` on `IcuTokenizer`
      (`lib/src/icu_tokenizer.dart`): reuse the `start`/`end` values already
      produced by the `ubrk_next()` loop, adjusting for the leading/trailing
      punctuation trim that already happens before a span becomes a `word`.
- [ ] Implement `tokeniseSpans()` on `RegExpTokenizer`
      (`lib/src/regexp_tokenizer.dart`): map `_wordPattern.allMatches(text)`
      directly to `TokenSpan(m.group(0)!, m.start, m.end)`.
- [ ] Export `TokenSpan`, `OffsetTokenizer` from `lib/betto_icu.dart`.
- [ ] Tests: offsets correct for ASCII, multi-byte UTF-16/surrogate-pair
      text (emoji, CJK, astral-plane characters), and text where ICU groups
      trailing punctuation into a span (confirm the trim adjustment is
      correct, not just the untrimmed span); empty input; confirm
      `BrowserTokenizer` is unaffected (does not implement `OffsetTokenizer`,
      by design).
- [ ] Run `make coverage` / `make pre_commit` in the `icu` repo — all green.
- [ ] Add a `CHANGELOG.md` entry for this change under the existing (already
      committed, unreleased) `0.1.0-dev.2` version — no new version bump is
      needed, this change lands in the pending `dev.2` release alongside its
      other unrelated content. Confirm `dev.2` is still unpublished at
      implementation time before assuming this; bump to the next version
      instead if it has already been released.
- [ ] **Pause here and ask the user to review and publish the new
      `betto_icu` version to pub.dev** — publishing is never the
      implementer's job (same hand-off boundary as WI-5). `betto_lexical`'s
      Phase 0.5 depends on this being published first.

**Phase 0.5 — extend `betto_lexical`: `Stemmer` languages +
`OffsetTokenizer` re-export (separate repo:
`/Users/gonk/development/bettongia/lexical`) — prerequisite for Phase 1 and
Phase 3**

- [ ] Bump the `betto_icu` dependency constraint in `pubspec.yaml` to the
      version published in Phase 0.4.
- [ ] Add `TokenSpan`, `OffsetTokenizer` to `lib/betto_lexical.dart`'s
      re-export list (alongside the existing `Tokenizer`, `RegExpTokenizer`,
      `IcuTokenizer`, `BrowserTokenizer`).
- [ ] In `lib/src/stemmer.dart`, extend the `Stemmer` factory's switch
      statement to map all **28** real `snowball_stemmer` languages to their
      `Algorithm` enum value (see the full table in the Investigation section
      above: `ar→arabic, hy→armenian, eu→basque, ca→catalan, da→danish,
      nl→dutch, en→english, fi→finnish, fr→french, de→german, el→greek,
      hi→hindi, hu→hungarian, id→indonesian, ga→irish, it→italian,
      lt→lithuanian, ne→nepali, no→norwegian, pt→portuguese, ro→romanian,
      ru→russian, sr→serbian, es→spanish, sv→swedish, ta→tamil, tr→turkish,
      yi→yiddish` — all 28 except `porter`, which has no language-code
      mapping). Keep the existing `ArgumentError` for every other code — this
      becomes the deliberate "not supported" signal `kmdb`'s Phase 3 catches
      to skip stemming (`kmdb` will only ever pass one of the 24 codes
      `betto_lang_detector` can produce, but the package itself supports all
      28).
- [ ] Update the class doc comment (currently "Currently supports English
      (`en`)") to list all 28 supported languages.
- [ ] Add test coverage: one representative word → expected-stem pair per
      newly-added language (a small, hand-picked case per language is enough
      — this is a thin wrapper over an already-tested third-party algorithm,
      not a reimplementation), plus confirm `ArgumentError` is still thrown
      for an unsupported code (e.g. `'zh'`, `'ja'`).
- [ ] Run `make coverage` / `make pre_commit` in the `lexical` repo — all
      green.
- [ ] Add a `CHANGELOG.md` entry describing both changes (expanded stemmer
      coverage + `OffsetTokenizer` re-export) under the existing (already
      committed, unreleased) `0.1.0-dev.2` version — no new version bump is
      needed, same as `betto_icu`'s Phase 0.4. Confirm `dev.2` is still
      unpublished at implementation time; bump to the next version instead
      if it has already been released.
- [ ] **Pause here and ask the user to review and publish the new
      `betto_lexical` version to pub.dev** — same hand-off boundary as
      Phase 0.4. Do not proceed to `kmdb` Phase 1 or Phase 3 until the new
      version is published and its exact version number is confirmed.
- [ ] Once published: since the release is still `0.1.0-dev.2` (not a new
      version number), `kmdb`'s existing `betto_lexical: ^0.1.0-dev.1`
      constraint in root `pubspec.yaml` `dependency_overrides` likely already
      permits it (a caret constraint with a pre-release lower bound allows
      later pre-releases of the same version, e.g. `dev.2`). Run `dart pub
      get` at the workspace root and confirm it resolves to the new `dev.2`
      content (check `pubspec.lock` / re-fetch if the cache is stale) rather
      than assuming a constraint edit is needed — only bump the constraint
      if resolution doesn't pick it up or if `dev.2` turns out to already be
      published (i.e. this plan's changes land in `dev.3` instead, per the
      version note above).

**Phase 1 — fix `VaultChunker` tokenization (the core bug fix)**

*Requires Phase 0.5's `betto_lexical` version (which carries the new
`OffsetTokenizer`) to be published and pinned first.*

- [ ] Change `VaultChunker`'s constructor to accept an injectable
      `OffsetTokenizer` (not the base `Tokenizer`), default
      `createDefaultTokenizer()` cast/asserted as `OffsetTokenizer` (safe:
      vault indexing is native-only per CLAUDE.md, so this always resolves to
      `IcuTokenizer`, which implements it) — mirrors the pattern already used
      in `FtsManager`/`vault_searcher.dart` for injecting tokenizers, and
      enables deterministic testing with a fake `OffsetTokenizer`.
- [ ] Replace `_findTokenSpans` entirely with a call to
      `tokenizer.tokeniseSpans(text)` — no local offset reconstruction
      needed; the returned `TokenSpan.start`/`.end` are used directly.
- [ ] Remove/replace the stale `:162` doc comment.
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
      `toMap()` when null).
- [ ] In `_processWorkItem` (`vault_indexing_isolate.dart:328`), after
      `extractedText` is obtained and before `VaultChunker.chunk()` is called,
      run `LanguageDetector.pureDart().dominantScript(extractedText)` and
      `.detect()`. Add both results to `VaultIndexResult` (`language` is
      `null` when `detect()` returns `Undetermined`).
- [ ] Thread the new field(s) from `VaultIndexResult` into the
      `VaultExtractionState` constructed in `vault_search_manager.dart:695-703`
      and the recovery-path construction at `:818-825`.
- [ ] Update §32 (vault spec) to document the new field(s) and when they're
      populated (parallel to how `charset` is documented for WI-2).
- [ ] Tests: isolate processing populates `script` correctly for Latin/CJK/
      Arabic/Cyrillic sample text and `null` for script-less input (e.g. a
      blob whose extracted text is only digits/punctuation); CBOR round-trip
      of the new field(s); the recovery path preserves previously-computed
      values.

**Phase 3 — language-aware stemming (vault + document-field paths)**

*Requires Phase 0.5's `betto_lexical` version to be published and pinned
first.*

- [ ] Add a `languageCode` (`String?`) parameter to `preprocess()` in
      `pipeline.dart`. When non-null, attempt `Stemmer(Locale(languageCode))`
      for Stage 4; when construction throws `ArgumentError` (language not
      one of the 24 `betto_lexical` now supports) or `languageCode` is
      `null`, **skip Stage 4 entirely** — do not fall back to the English
      stemmer. This is the key behaviour change from today's unconditional
      English default.
- [ ] Consider caching constructed `Stemmer` instances per language code
      (a small `Map<String, Stemmer>` — avoids rebuilding on every call).
      Not required for correctness, worth doing for the hot query path.
- [ ] Vault write path: pass the blob's already-detected `language` (from
      Phase 2, threaded from `VaultIndexResult` into `VaultChunker`) as
      `languageCode`.
- [ ] Vault query path (`vault_searcher.dart:298`): run `detect()` on the
      query string inline and pass its language code (or `null` if
      `Undetermined`), so write and query paths agree.
- [ ] Document-field FTS write path (`fts_manager.dart:238`, `:305`,
      `:486`): run `detect()` on the field's text value inline and pass the
      result. No persistence needed here (unlike the vault path) — this is
      deterministic and cheap enough to recompute on every write, and there
      is no isolate boundary forcing a cached value.
- [ ] Document-field FTS query path (`fts_manager.dart:616`): run `detect()`
      on the query string inline.
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

## Summary

{To be filled in once implemented.}
