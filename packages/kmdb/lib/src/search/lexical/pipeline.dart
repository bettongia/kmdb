// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:intl/locale.dart';
import 'package:betto_lexical/betto_lexical.dart' show Stemmer, Tokenizer;

/// Per-language [Stemmer] cache used by [stem].
///
/// Keyed by ISO 639-1 language code. A `null` cached value means the code was
/// tried and [Stemmer]'s factory threw [ArgumentError] — i.e. `betto_lexical`
/// has no Snowball algorithm for that language (e.g. `ja`, `zh`, `th`, `he`,
/// `bn`) — so repeated lookups for an unsupported/undetermined code never
/// re-throw or reconstruct a [Stemmer]. Populated lazily; not thread-safe, but
/// KMDB is single-isolate (per call site) so this is safe.
final _stemmerCache = <String, Stemmer?>{};

/// Resolves (and caches) a [Stemmer] for [languageCode], or `null` if
/// [languageCode] is `null` or unsupported by `betto_lexical`.
///
/// See [_stemmerCache] for the caching rationale.
Stemmer? _stemmerFor(String? languageCode) {
  if (languageCode == null) return null;
  return _stemmerCache.putIfAbsent(languageCode, () {
    try {
      return Stemmer(Locale.fromSubtags(languageCode: languageCode));
    } on ArgumentError {
      return null; // Not one of betto_lexical's supported languages.
    }
  });
}

/// Stage 1 + 2: tokenise [text] with [tokenizer] and lowercase each token.
///
/// Returns an empty list for empty or whitespace-only input without error.
/// Lowercasing is applied after tokenisation, so the tokenizer sees the
/// original casing and boundary detection is not affected.
///
/// ## Example
///
/// ```dart
/// final t = RegExpTokenizer();
/// tokeniseAndNormalise('Dr. Jekyll and Mr. Hyde', t);
/// // → ['dr', 'jekyll', 'and', 'mr', 'hyde']
/// ```
List<String> tokeniseAndNormalise(String text, Tokenizer tokenizer) {
  if (text.isEmpty) return const [];
  // Tokenise first, then lowercase. Unicode-safe: toLowerCase() uses platform
  // locale for case folding, adequate for English.
  return tokenizer.tokenise(text).map((t) => t.toLowerCase()).toList();
}

/// Stage 3 (optional): remove tokens that appear in [stopWords].
///
/// Returns [tokens] unchanged when [stopWords] is empty (the common case when
/// stop-word filtering is disabled). When [stopWords] is provided, any token
/// whose lowercase form is in the set is dropped.
///
/// ## Example
///
/// ```dart
/// filterStopWords(['the', 'quick', 'brown', 'fox'], kEnglishStopWords);
/// // → ['quick', 'brown', 'fox']
/// ```
List<String> filterStopWords(List<String> tokens, Set<String> stopWords) {
  if (stopWords.isEmpty || tokens.isEmpty) return tokens;
  // Tokens are already lowercased by stage 1+2, so a direct set lookup works.
  return tokens.where((t) => !stopWords.contains(t)).toList();
}

/// Stage 4: apply a language-specific Snowball stemmer to each token.
///
/// Returns an empty list for empty input. Each token is stemmed independently;
/// the result list has the same length as [tokens]. Stemming is idempotent
/// for already-stemmed strings, so calling it multiple times is safe.
///
/// [languageCode] is an ISO 639-1 code (e.g. `"en"`, `"fr"`) selecting which
/// Snowball algorithm to apply, via `betto_lexical`'s [Stemmer]. It is
/// **required** (not defaulted) so every call site must consciously choose a
/// language rather than silently inheriting the old always-English behaviour
/// this pipeline used before WI-6. Pass `null` when no language could be
/// determined. When [languageCode] is `null`, or is a code `betto_lexical` has
/// no Snowball algorithm for (e.g. `ja`, `zh`, `th`, `he`, `bn`), [tokens] are
/// returned unchanged — stemming is **skipped entirely**, not silently
/// downgraded to English.
///
/// ## Example
///
/// ```dart
/// stem(['investigates', 'occurring', 'disturbing'], languageCode: 'en');
/// // → ['investig', 'occur', 'disturb']
///
/// stem(['chats', 'chiens'], languageCode: 'fr');
/// // → ['chat', 'chien']
///
/// stem(['tokens'], languageCode: null); // no stemming applied
/// // → ['tokens']
/// ```
List<String> stem(List<String> tokens, {required String? languageCode}) {
  if (tokens.isEmpty) return const [];
  final stemmer = _stemmerFor(languageCode);
  if (stemmer == null) return tokens;
  return tokens.map((t) => stemmer.stem(t)).toList();
}

/// Full preprocessing pipeline: tokenise → normalise → [filterStopWords] → stem.
///
/// This is the entry point called by both the indexing path (when a document
/// is written) and the query path (when a search query is submitted). Applying
/// the identical pipeline to both ensures that query terms and indexed terms
/// are always comparable.
///
/// ## Parameters
///
/// - [text] — the raw input string (document field value or query string).
/// - [tokenizer] — the [Tokenizer] implementation to use for segmentation.
/// - [stopWords] — the stop-word set to apply. Pass `kEnglishStopWords` to
///   enable English stop-word removal; pass an empty set (the default) to
///   disable filtering. Custom sets may also be supplied.
/// - [languageCode] — see [stem]. Required; pass `null` when no language could
///   be determined (stemming is skipped for that call).
///
/// ## Returns
///
/// A list of normalised, optionally filtered, and stemmed tokens. An empty
/// input string returns an empty list without error.
///
/// ## Example
///
/// ```dart
/// final tokens = preprocess(
///   'The quick brown fox jumps over the lazy dog',
///   RegExpTokenizer(),
///   stopWords: kEnglishStopWords,
///   languageCode: 'en',
/// );
/// // → ['quick', 'brown', 'fox', 'jump', 'lazi', 'dog']
/// ```
List<String> preprocess(
  String text,
  Tokenizer tokenizer, {
  Set<String> stopWords = const {},
  required String? languageCode,
}) {
  if (text.isEmpty) return const [];
  final tokens = tokeniseAndNormalise(text, tokenizer);
  final filtered = filterStopWords(tokens, stopWords);
  return stem(filtered, languageCode: languageCode);
}
