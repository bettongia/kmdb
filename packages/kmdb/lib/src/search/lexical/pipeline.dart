// Copyright 2026 The KMDB Authors
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

// import 'package:snowball_stemmer/snowball_stemmer.dart';
import 'package:intl/locale.dart';
import 'package:kmdb_lexical/lexical.dart' show Stemmer, Tokenizer;

/// Singleton English Snowball stemmer used by [stem].
///
/// Instantiated once and reused. [SnowballStemmer] is not thread-safe, but
/// KMDB is single-isolate so this is safe.
///
/// This is accessed via the kmdb_lexical package
final _englishStemmer = Stemmer(Locale.fromSubtags(languageCode: 'en'));

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

/// Stage 4: apply the Snowball English stemmer to each token.
///
/// Returns an empty list for empty input. Each token is stemmed independently;
/// the result list has the same length as [tokens]. Stemming is idempotent
/// for already-stemmed strings, so calling it multiple times is safe.
///
/// ## Example
///
/// ```dart
/// stem(['investigates', 'occurring', 'disturbing']);
/// // → ['investig', 'occur', 'disturb']
/// ```
List<String> stem(List<String> tokens) {
  if (tokens.isEmpty) return const [];
  return tokens.map((t) => _englishStemmer.stem(t)).toList();
}

/// Full preprocessing pipeline: tokenise → normalise → [stop-word filter] → stem.
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
/// - [stopWords] — the stop-word set to apply. Pass [kEnglishStopWords] to
///   enable English stop-word removal; pass an empty set (the default) to
///   disable filtering. Custom sets may also be supplied.
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
/// );
/// // → ['quick', 'brown', 'fox', 'jump', 'lazi', 'dog']
/// ```
List<String> preprocess(
  String text,
  Tokenizer tokenizer, {
  Set<String> stopWords = const {},
}) {
  if (text.isEmpty) return const [];
  final tokens = tokeniseAndNormalise(text, tokenizer);
  final filtered = filterStopWords(tokens, stopWords);
  return stem(filtered);
}
