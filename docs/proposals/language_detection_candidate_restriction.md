# Proposal: Restricting the Language-Detection Candidate Set

**Status:** Deferred — see [Decision](#decision-and-rationale)

**Related spec:** §21 Lexical Search, Stage 4 — Stemming
(`docs/spec/21_lexical_search.md`)

**Related plan:** [`plan_0_06_wi6_bm25_tokenizer_routing.md`](../plans/completed/plan_0_06_wi6_bm25_tokenizer_routing.md)
(WI-6, PR [#56](https://github.com/bettongia/kmdb/pull/56))

**Related roadmap:** WI-6, `docs/roadmap/0_06.md`

---

## Problem

WI-6 needed `detectLanguageForStemming()` (`packages/kmdb/lib/src/search/language_detection.dart`)
to decide which Snowball stemmer to apply to a piece of text. The obvious
approach — trust `betto_lang_detector`'s top guess whenever its `confidence`
clears a threshold — doesn't work: `LanguageGuess.confidence` degenerates to
`1.0` whenever candidate languages tie in score, which happens routinely for
short, keyword-style text (the dominant shape of both search queries and many
indexed field values). A spuriously-confident wrong guess reports `1.0`,
clearing any reasonable absolute-confidence bar.

The shipped fix is a three-gate policy: a margin check between the top two
ranked candidates, a minimum word-count before that margin is trusted at all,
and an allowlist restricting the winner to one of `betto_lexical`'s 28
Snowball-supported languages. Each gate was added in response to a concrete
empirical failure found by tracing real test regressions (see the plan's Q6
revision history and the library doc comment's two 2026-07-07 follow-ups).

Before this design was settled, `lingua-rs` (via its `lingua-cli` wrapper,
https://github.com/pemistahl/lingua-rs) was considered and rejected as the
detector, because it is a Rust library requiring FFI — `betto_lang_detector`
was built as a pure-Dart alternative specifically to avoid that dependency
class. This proposal revisits that comparison empirically, now that WI-6's
gate design and its exact failure modes are known, and captures a concrete
follow-on idea for `betto_lang_detector` itself.

---

## Investigation

### Method

`lingua-cli --all` was run against every string used in WI-6's test suite
(`language_detection_test.dart`, plus the single-word evidence table from the
library doc comment, plus representative strings from
`fts_manager_test.dart`, `fts_search_integration_test.dart`,
`vault_searcher_test.dart`, and `vault_multilang_round_trip_test.dart`),
comparing lingua's full confidence distribution against the corresponding
`betto_lang_detector` result already documented in
`language_detection.dart`.

### Result 1 — unrestricted candidate set (lingua's full ~75 languages)

| Input | `betto_lang_detector` | `lingua` (top / runner-up) | Verdict |
|---|---|---|---|
| "machine learning" | `ga` @ 1.0 (`en` 5th, 0.72) — wrong, degenerate tie | `en` 0.342 / `mi` 0.075 (margin 0.267) | lingua correct |
| "quick" | `la` @ 0.309 — wrong | `en` 0.172 / `sv` 0.075 (margin 0.097) | lingua correct |
| "searchable" | `ga` @ 0.295 — wrong | `en` 0.182 / `fr` 0.107 (margin 0.075) | lingua correct |
| "removed" | `da` @ 0.131 — wrong | `en` 0.283 / `nb` 0.227 (margin 0.057, weak) | lingua correct, barely |
| "lazy" | `hu` @ 0.179 — wrong | `pl` 0.325 / `sk` 0.103 (margin 0.222) | **lingua also wrong, more confidently** |
| "machine" (alone) | `ga` @ 0.290 — wrong | `sn` 0.117 / `en` 0.074 (margin 0.043) | lingua also wrong, weak margin |
| "idempotent test content" | `la` @ margin 0.197 — wrong | `la` 0.394 / `en` 0.071 (margin 0.323) | **lingua also wrong, more confidently** |
| "idempotent" (alone) | (word-count gated) | `la` 0.331 / `en` 0.048 (margin 0.283) | **lingua also wrong** |
| "test" (alone) | `1.0` degenerate tie | `et` 0.083 / `eo` 0.069 (margin 0.014, genuinely flat) | lingua correctly signals low confidence |
| "maison rouge" | `fr` margin 0.190 | `fr` 0.296 / `de` 0.065 (margin 0.230) | both correct |
| French/Japanese/Greek prose | correct | correct, decisively (0.887–1.0) | tie |

Two findings from the unrestricted run:

1. **The flagship failure case is fixed.** "machine learning" — the exact
   example in the library doc comment proving raw confidence is
   untrustworthy — resolves cleanly under lingua with a wide, genuine margin.
2. **The pathology is relocated, not eliminated.** `"idempotent"`
   (etymologically Latin) and `"lazy"` (which happens to resemble Polish)
   still confidently misdetect under lingua — *more* confidently than under
   `betto_lang_detector` in the idempotent case (margin 0.32 vs 0.20). Any
   detector choice would still need the word-count and stemmer-allowlist
   gates, not just margin.
3. **The structural win is calibration, not raw accuracy.** lingua's
   confidence is a genuine probability distribution over its full language
   set — ambiguous input (`"test"`) produces a low, flat top score (0.08)
   instead of a false `1.0`. This is the specific property
   `betto_lang_detector` lacks and that forced the margin-based redesign in
   the first place.

### Result 2 — candidate set restricted to the 25 Stemmer-overlapping languages

`lingua-cli --languages=ar,ca,da,de,el,en,es,eu,fi,fr,ga,hi,hu,hy,id,it,lt,nl,pt,ro,ru,sr,sv,ta,tr`
re-run against the same failing cases:

| Input | Unrestricted (wrong) | Restricted to 25 | Verdict |
|---|---|---|---|
| "lazy" | `pl` 0.325 / `sk` 0.103 (margin 0.222) | `en` 0.312 / `tr` 0.181 (margin 0.131) | **Fixed** — `pl` is no longer a candidate |
| "idempotent test content" | `la` 0.394 (margin 0.323) | `en` 0.170 / `it` 0.144 (margin 0.026) | Fixed, but barely clears zero |
| "idempotent" (alone) | `la` 0.331 | `en` 0.131 / `fi` 0.102 (margin 0.029) | Fixed, but barely |
| "machine learning" | `en` 0.342 (margin 0.267) | `en` 0.630 / `nl` 0.056 (margin 0.573) | Already correct, now overwhelming |
| "quick" | `en` 0.172 (margin 0.097) | `en` 0.356 (margin 0.201) | Correct either way, much stronger |
| "removed" | `en` 0.283 (margin 0.057, weak) | `en` 0.621 (margin 0.412) | Correct either way, much stronger |
| "machine" (alone) | `sn` 0.117 — wrong | `en` 0.170 / `fr` 0.150 (margin 0.021) | Fixed, but a coin flip |
| "test" (alone) | flat, `et` top | flat, `ro` top (0.107 vs `it` 0.093) | Still genuinely ambiguous |
| "stable" (alone) | 4-way near-tie, `fr` edges `en` | 4-way near-tie, `fr` edges `en` again | Still genuinely ambiguous |

Restricting the candidate pool to only languages the stemmer can act on
eliminates the entire class of "confidently wrong *and unstemmable*" errors —
`lazy`→`pl` and `idempotent`→`la` both resolve correctly once those languages
simply aren't candidates. It does **not** eliminate the need for a margin
gate: genuinely ambiguous single words (`"test"`, `"stable"`, and `"machine"`
at a wafer-thin 0.021 margin even restricted) still produce weak or flat top
scores among legitimate candidates and still need a "not confident enough,
default to `en`" fallback.

### Language-set intersection

25 of the Stemmer's 28 supported ISO 639-1 codes exist in lingua's ~75:

| Code | Language | Gap |
|---|---|---|
| `no` | Norwegian | lingua has no generic `no` — only `nb` (Bokmål) / `nn` (Nynorsk); would need a remap to feed the Stemmer |
| `ne` | Nepali | not supported by lingua |
| `yi` | Yiddish | not supported by lingua |

This gap is specific to adopting lingua itself. It would not apply to the
alternative below, which restricts `betto_lang_detector`'s own candidate set
rather than switching detectors.

---

## Alternatives considered

**Adopt `lingua-rs` as the detector.** Rejected (again). It fixes the
flagship "machine learning" case and calibrates confidence properly, but (a)
still requires the FFI dependency this project explicitly chose
`betto_lang_detector` to avoid — nothing in this data changes that
architectural cost — and (b) still needs the same word-count and
stemmer-allowlist gates for genuinely ambiguous short text (`"test"`,
`"stable"`, `"machine"`), so it would not simplify `language_detection.dart`
as much as it might first appear.

**Add a candidate-restriction parameter to `betto_lang_detector`.** The
interesting option. Restricting the *candidate set* — not switching
detectors — did the real work in Result 2 above (eliminating the
unstemmable-language misfires). `betto_lang_detector`'s current public API
(`LanguageDetector.pureDart(minConfidence: ...)`) has no equivalent knob. If
it exposed one, the same "restrict to the 28 Stemmer-supported codes"
hypothesis could be tested directly against our own pure-Dart detector,
independent of lingua entirely — potentially fixing the same class of error
(a confident guess landing on a language `Stemmer` can't act on) without any
FFI cost. This has not been prototyped; it is a hypothesis, not a validated
result, since `betto_lang_detector`'s own n-gram model may not respond to
candidate restriction the same way lingua's does.

**Do nothing — keep the current three-gate design.** The pragmatic default.
WI-6 ships with all 2,312 kmdb tests passing under the margin + word-count +
stemmer-allowlist policy; this investigation was not triggered by an observed
production problem, only by revisiting an earlier architectural decision
with the benefit of WI-6's now-concrete failure-mode catalogue.

---

## Decision and rationale

**Deferred.** No change to `language_detection.dart` or
`betto_lang_detector` is being made as a result of this investigation.

1. **WI-6 is not broken.** The shipped three-gate design resolves every known
   failure case correctly (defaulting to `en` rather than mis-stemming), just
   more conservatively than a restricted-candidate approach would. Real-world
   usage may show this conservatism is fine in practice — most search
   traffic against this project's collections is expected to be English
   prose, not the adversarial short-keyword cases this investigation
   targeted.
2. **The FFI objection to lingua is unchanged.** Nothing in this data
   resolves the original reason lingua was rejected; readopting it would
   need its own justification independent of detection accuracy.
3. **The candidate-restriction idea is unvalidated for `betto_lang_detector`
   specifically.** It's a promising, low-cost hypothesis (pure Dart, no new
   dependency) but would need its own small spike against
   `betto_lang_detector`'s actual n-gram model before it could be scoped as
   a plan.

---

## Future path

Resume this work if either trigger is met:

- **Real-world trigger:** short/keyword-style non-English queries or field
  values are observed (via user reports or search-quality review) to
  mis-stem often enough to matter. WI-6's current design silently defaults
  ambiguous text to English stemming, which is conservative but not free —
  it means short non-English content gets no stemming benefit at all.
- **Upstream trigger:** `betto_lang_detector` gains (or is extended to gain)
  a candidate-restriction parameter, making the Result 2 hypothesis directly
  testable without adopting lingua.

**Recommended sequence when triggered:**

1. Prototype a `candidateLanguages: Set<String>` (or similar) parameter on
   `betto_lang_detector`'s `LanguageDetector` — restricting `detect()`'s
   n-gram ranking to a caller-supplied set, mirroring lingua's `--languages`
   flag.
2. Re-run this proposal's exact test-string set (both tables above) against
   the prototype to check whether `betto_lang_detector`'s own model responds
   to candidate restriction the same way lingua's did (Result 2 is not
   guaranteed to transfer — the two libraries use different underlying
   models).
3. If it does, `language_detection.dart` could drop the standalone
   stemmer-allowlist gate (restriction makes it structurally redundant) and
   revisit whether the word-count gate's threshold can be relaxed, since the
   remaining failure surface (ambiguous single words) would be narrower.
4. The `no`/`ne`/`yi` gap only matters if lingua itself were adopted instead
   of extending `betto_lang_detector` — note it in that plan if this path is
   ever taken instead of the recommended one.
