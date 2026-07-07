// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Shared language-detection helper for WI-6's language-aware BM25 stemming.
///
/// Centralises the "margin-gated best guess, English default" policy (see the
/// WI-6 plan's Q6 and its 2026-07-07 revision) so the vault indexing isolate,
/// [FtsManager] write/query paths, and [VaultSearcher]'s query path all apply
/// the exact same rule rather than re-deriving it independently.
///
/// ## Why not raw confidence
///
/// `LanguageGuess.confidence` degenerates to `1.0` whenever candidate
/// languages tie in score — which happens routinely for short, keyword-style
/// text (the dominant shape of both search queries and many indexed field
/// values). Neither a `minConfidence: 0.0` "best guess, no gate" policy nor a
/// standard `minConfidence: 0.5` gate catches this: a spuriously-confident
/// wrong guess reports `1.0`, clearing any reasonable bar. Confirmed
/// empirically against the published `betto_lang_detector 0.1.0-dev.1`:
/// `"machine learning"` reports `ga` (Irish) at confidence `1.0`, with `en`
/// ranked 5th at `0.72`.
///
/// ## The fix: margin between the top two candidates
///
/// Instead of trusting the top guess's absolute confidence, this compares the
/// top guess against the *runner-up* in [Detected.ranked]. A genuine,
/// well-separated detection has a large gap between 1st and 2nd place; a
/// degenerate tie does not, even though the top guess still reports `1.0`.
/// Empirically, every dangerous wrong guess (one that lands on a language
/// `Stemmer` actually supports, risking real corruption rather than a
/// harmless `ArgumentError` skip) had a margin at or below `0.10`; every
/// correct detection in the same sample had a margin at or above `0.14`.
/// [_kMinDetectionMargin] sits between the two with headroom. This constant
/// was tuned against a small, hand-picked sample (see the plan's Q6
/// revision) — if further test failures surface a case this threshold
/// mishandles, prefer adjusting the constant (with a note on what new
/// evidence motivated it) over abandoning the approach.
///
/// Below the margin (or with no n-gram signal at all): default the
/// *stemming* language to `en` (this project's historical, pre-WI-6 default
/// — see `docs/spec/20_text_search.md`) rather than skip stemming outright,
/// since the existing test suite (and presumably most real usage) is
/// predominantly English and depends on it being stemmed consistently. The
/// *persisted metadata* language, by contrast, falls back to `null` — it
/// would be dishonest to claim a confident language label for text we
/// couldn't actually distinguish.
///
/// ## 2026-07-07 follow-up: single words need a second gate (word count)
///
/// Re-running the pre-existing test suite against the margin gate above
/// surfaced 9 further regressions (`fts_manager_test.dart`,
/// `fts_search_integration_test.dart`, `vault_searcher_test.dart`) — every one
/// traced to a **single-word** query (`"machine"`, `"quick"`, `"lazy"`,
/// `"stable"`, `"searchable"`, `"removed"`, `"rebuild"`) landing on a
/// *different* wrong language with a margin comfortably **above**
/// [_kMinDetectionMargin]:
///
/// | Single word | Best guess | Margin |
/// | :--- | :--- | :--- |
/// | `"quick"` | `la` (Latin) | `0.309` |
/// | `"searchable"` | `ga` (Irish) | `0.295` |
/// | `"machine"` | `ga` (Irish) | `0.290` |
/// | `"lazy"` | `hu` (Hungarian) | `0.179` |
/// | `"stable"` | `et` (Estonian) | `0.144` |
/// | `"removed"` | `da` (Danish) | `0.131` |
///
/// Meanwhile genuinely correct multi-word detections can have a *smaller*
/// margin than several of the above (e.g. `"the quick brown fox"` → `en` at
/// margin `0.388` is comfortably clear, but the shortest tested genuine
/// non-English phrase, French `"maison rouge"`, and several correctly-`en`-
/// defaulted 2-4 word phrases sit well under `0.30`). There is no single
/// [_kMinDetectionMargin] value that rejects every dangerous single-word case
/// above without also being high enough to reject legitimate multi-word
/// detections — the single-word margin values interleave with the genuine
/// ones. The problem isn't the threshold's exact position; it's that a
/// **single word** gives the n-gram model too little signal for its margin to
/// be meaningful at all, regardless of how large that margin looks.
///
/// **Fix:** gate the same-script n-gram branch on word count as well as
/// margin — [_kMinWordCountForMarginTrust]. A single word never overrides the
/// `en` default via the n-gram branch, no matter its reported margin; two or
/// more words are required before the margin check is even consulted. This
/// is conservative (some short genuine non-English field values/queries will
/// now default to `en` too), but every observed failure mode is single-word,
/// and false-negatives here (missing a real accuracy opportunity) are far
/// cheaper than false-positives (silently corrupting the dominant, tested
/// English case this project actually commits to supporting today — see
/// `docs/spec/20_text_search.md`'s "English-language text (`en`)" scope
/// note). The script-exclusive single-candidate branch (Greek, Hebrew, Thai,
/// etc.) is unaffected — it is a deterministic Unicode-property lookup, not
/// an n-gram comparison, and remains reliable even for a single word/glyph.
///
/// ## 2026-07-07 follow-up 2: a real English word can still lose to an
/// unsupported "language" with a large, multi-word-clearing margin
///
/// One further regression surfaced after the word-count fix above:
/// `"idempotent test content"` (3 words — clears [_kMinWordCountForMarginTrust])
/// detects as `la` (Latin) at margin `0.197`, comfortably above
/// [_kMinDetectionMargin]. `"idempotent"` is a real, common English technical
/// term, but it happens to be Latin-derived, and the n-gram model apparently
/// weighs that etymology heavily enough to rank actual `en` far down the list
/// (5th–8th, confidence ~0.57–0.66) rather than as a close runner-up. Crucially,
/// **no margin/word-count threshold can separate this from the legitimate
/// French `"maison rouge"` test case** — `"maison rouge"` (2 words) has margin
/// `0.190`, *smaller* than `"idempotent test content"`'s `0.197`, so any
/// threshold high enough to reject the Latin false-positive also rejects the
/// genuine French detection. The two cases are indistinguishable by margin or
/// length alone.
///
/// This produced a concrete, observable bug distinct from "wrong stemmer
/// applied": `la` isn't one of `betto_lexical`'s 28 Snowball-backed
/// [Stemmer]-supported languages, so `stem()` (`pipeline.dart`) silently
/// *skips stemming* for that call (its `ArgumentError`-catch fallback) — while
/// the 1-word query `"idempotent"` (gated to `en` by the word-count rule
/// above) *does* get stemmed (`idempotent` → `idempot`). Write-side
/// unstemmed `idempotent` vs. query-side stemmed `idempot` never match.
///
/// **Fix:** in the n-gram branch, additionally require the winning code to be
/// one `betto_lexical`'s [Stemmer] actually implements
/// ([_kStemmerSupportedLanguages]). If the model's top guess is a language
/// with no Snowball algorithm behind it, trusting it can only ever produce a
/// silent stemming skip — defaulting to `en` instead is strictly more useful
/// (English stemming is applied consistently) and costs nothing, since the
/// alternative was never going to stem anything anyway. This does not weaken
/// the fix for genuinely CJK/Thai/etc. content: that resolves via the
/// script-exclusive single-candidate branch, which stays unconditional (a
/// script-level Unicode lookup, not this n-gram allowlist).
library;

import 'package:betto_lang_detector/betto_lang_detector.dart'
    show Detected, LanguageDetector, Undetermined;

/// Minimum gap between the top and second-ranked [Detected.ranked] guesses
/// required to trust the top guess. See the library doc comment for the
/// empirical justification. Only consulted when [_kMinWordCountForMarginTrust]
/// is also met.
const double _kMinDetectionMargin = 0.12;

/// Minimum whitespace-delimited word count required before the n-gram
/// margin check ([_kMinDetectionMargin]) is trusted at all. See the library
/// doc comment's 2026-07-07 follow-up for the empirical justification — a
/// single word's margin is not a meaningful signal, however large it looks.
const int _kMinWordCountForMarginTrust = 2;

/// ISO 639-1 codes `betto_lexical`'s [Stemmer] implements a Snowball
/// algorithm for (mirrors `Stemmer`'s own documented 28-language list — see
/// `pipeline.dart` and `Stemmer`'s doc comment in `betto_lexical`). Used to
/// reject an n-gram winner that would only ever result in a silent stemming
/// skip — see the library doc comment's second 2026-07-07 follow-up.
///
/// Kept in sync manually with `betto_lexical`'s `Stemmer` factory; if that
/// package's supported-language set changes, update this list to match.
const Set<String> _kStemmerSupportedLanguages = {
  'ar', 'hy', 'eu', 'ca', 'da', 'nl', 'en', 'fi', 'fr', 'de', 'el', 'hi', 'hu',
  'id', 'ga', 'it', 'lt', 'ne', 'no', 'pt', 'ro', 'ru', 'sr', 'es', 'sv', 'ta',
  'tr', 'yi', //
};

/// ISO 639-1 code this project defaults stemming to when detection isn't
/// trustworthy enough to override it — see the library doc comment.
const String _kDefaultStemmingLanguage = 'en';

/// Counts whitespace-delimited words in [text]. Used to gate the n-gram
/// margin check — see [_kMinWordCountForMarginTrust].
int _wordCount(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\s+')).length;
}

/// Shared, reusable zero-confidence-threshold [LanguageDetector] instance.
///
/// `minConfidence: 0.0` is required so [Detected.ranked] always carries the
/// full candidate ranking (needed to compute the margin below) rather than
/// collapsing to `Undetermined` before this helper gets a chance to look at
/// the runner-up. The *trust* decision is made by this file's margin check,
/// not by the detector's own confidence gate.
///
/// Constructed once and reused by every call site in this isolate/process
/// (each Dart isolate — including the vault indexing isolate — gets its own
/// instance; `LanguageDetector` is pure Dart with no FFI/native state, so this
/// is cheap and safe to construct per-isolate).
final LanguageDetector marginGatedLanguageDetector = LanguageDetector.pureDart(
  minConfidence: 0.0,
);

/// The result of [detectLanguageForStemming]: a margin-gated language code
/// for BM25 stemmer routing, alongside the same gate applied to persisted/
/// user-facing language metadata.
final class LanguageDetectionResult {
  /// Creates a [LanguageDetectionResult].
  const LanguageDetectionResult({
    required this.stemmerLanguageCode,
    required this.confidentLanguageCode,
  });

  /// ISO 639-1 language code for BM25 stemmer selection.
  ///
  /// Never `null` — falls back to [_kDefaultStemmingLanguage] when detection
  /// isn't trustworthy enough (see the library doc comment), so write and
  /// query paths always have *some* consistent stemming language to agree
  /// on. `Stemmer`'s own `ArgumentError` fallback in `pipeline.dart` is the
  /// separate mechanism that skips stemming entirely for scripts no Snowball
  /// algorithm covers (CJK, Thai, etc.) — this field is unrelated to that.
  final String stemmerLanguageCode;

  /// Confidence-gated ISO 639-1 language code, suitable for persisted/
  /// user-facing metadata (e.g. [VaultExtractionState.language]).
  ///
  /// `null` when detection wasn't trustworthy enough — unlike
  /// [stemmerLanguageCode], this has no default: it would be misleading to
  /// report a specific language we aren't actually confident about.
  final String? confidentLanguageCode;
}

/// Maximum number of UTF-16 code units of input sampled before calling
/// `detect()`. `LanguageDetector.dominantScript()` caps its own scan at 5,000
/// runes internally, but `detect()`'s n-gram stage
/// (`extractRankedNgrams` in `betto_lang_detector`) has no such cap — it
/// scans the entire input with a Unicode-aware word regex and ranks every
/// distinct n-gram found. For a large extracted vault document or a long
/// field value, this is an uncapped, unbounded-length scan on every FTS
/// write (§18 P99 write-latency risk). A representative sample is enough
/// for language identification — detection accuracy does not meaningfully
/// improve past a few thousand characters of real prose — so this local cap
/// mirrors `dominantScript()`'s own precedent rather than assuming
/// `detect()`'s cost is bounded.
const int _kMaxDetectionSampleLength = 5000;

/// Runs [marginGatedLanguageDetector] once over a bounded sample of [text]
/// (see [_kMaxDetectionSampleLength]) and derives both the margin-gated
/// stemmer-routing code and the same-gated metadata code from the single
/// result.
///
/// A single `detect()` call serves both purposes — no need to run detection
/// twice for one input.
LanguageDetectionResult detectLanguageForStemming(String text) {
  final sample = text.length > _kMaxDetectionSampleLength
      ? text.substring(0, _kMaxDetectionSampleLength)
      : text;
  final result = marginGatedLanguageDetector.detect(sample);
  final trusted = switch (result) {
    Detected(:final best, :final ranked) when ranked.length < 2 =>
      // Script-exclusive resolution (e.g. Greek, Hebrew, Thai) short-circuits
      // before the n-gram stage and returns exactly one candidate — this is a
      // deterministic Unicode-property lookup, not a statistical nearest-
      // neighbour comparison, so there is no "runner-up" to fall short of and
      // no degenerate-tie failure mode to guard against.
      best.code,
    Detected(:final best, :final ranked) =>
      (_kStemmerSupportedLanguages.contains(best.code) &&
              _wordCount(sample) >= _kMinWordCountForMarginTrust &&
              (best.confidence - ranked[1].confidence) >= _kMinDetectionMargin)
          ? best.code
          : null,
    Undetermined() => null,
  };
  return LanguageDetectionResult(
    stemmerLanguageCode: trusted ?? _kDefaultStemmingLanguage,
    confidentLanguageCode: trusted,
  );
}
