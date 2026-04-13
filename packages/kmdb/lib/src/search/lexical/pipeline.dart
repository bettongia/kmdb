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

import 'package:snowball_stemmer/snowball_stemmer.dart';

import '../tokeniser.dart';

/// Singleton English Snowball stemmer used by [stem].
///
/// Instantiated once and reused. [SnowballStemmer] is not thread-safe, but
/// KMDB is single-isolate so this is safe.
final _englishStemmer = SnowballStemmer(Algorithm.english);

/// Stage 1 + 2: tokenise [text] with [tokeniser] and lowercase each token.
///
/// Returns an empty list for empty or whitespace-only input without error.
/// Lowercasing is applied after tokenisation, so the tokeniser sees the
/// original casing and boundary detection is not affected.
///
/// ## Example
///
/// ```dart
/// final t = RegExpTokeniser();
/// tokeniseAndNormalise('Dr. Jekyll and Mr. Hyde', t);
/// // → ['dr', 'jekyll', 'and', 'mr', 'hyde']
/// ```
List<String> tokeniseAndNormalise(String text, Tokeniser tokeniser) {
  if (text.isEmpty) return const [];
  // Tokenise first, then lowercase. Unicode-safe: toLowerCase() uses platform
  // locale for case folding, adequate for English.
  return tokeniser.tokenise(text).map((t) => t.toLowerCase()).toList();
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
/// - [tokeniser] — the [Tokeniser] implementation to use for segmentation.
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
///   RegExpTokeniser(),
///   stopWords: kEnglishStopWords,
/// );
/// // → ['quick', 'brown', 'fox', 'jump', 'lazi', 'dog']
/// ```
List<String> preprocess(
  String text,
  Tokeniser tokeniser, {
  Set<String> stopWords = const {},
}) {
  if (text.isEmpty) return const [];
  final tokens = tokeniseAndNormalise(text, tokeniser);
  final filtered = filterStopWords(tokens, stopWords);
  return stem(filtered);
}

/// English stop words from the Stopwords ISO 'en' list.
///
/// Applied during [filterStopWords] when stop-word filtering is enabled on an
/// [FtsIndexDefinition]. Covers the most common English function words whose
/// presence adds noise to BM25 ranking without contributing term signal.
const Set<String> kEnglishStopWords = {
  'a',
  'about',
  'above',
  'after',
  'again',
  'against',
  'all',
  'am',
  'an',
  'and',
  'any',
  'are',
  "aren't",
  'as',
  'at',
  'be',
  'because',
  'been',
  'before',
  'being',
  'below',
  'between',
  'both',
  'but',
  'by',
  "can't",
  'cannot',
  'could',
  "couldn't",
  'did',
  "didn't",
  'do',
  'does',
  "doesn't",
  'doing',
  "don't",
  'down',
  'during',
  'each',
  'few',
  'for',
  'from',
  'further',
  'get',
  'got',
  'had',
  "hadn't",
  'has',
  "hasn't",
  'have',
  "haven't",
  'having',
  'he',
  "he'd",
  "he'll",
  "he's",
  'her',
  'here',
  "here's",
  'hers',
  'herself',
  'him',
  'himself',
  'his',
  'how',
  "how's",
  'i',
  "i'd",
  "i'll",
  "i'm",
  "i've",
  'if',
  'in',
  'into',
  'is',
  "isn't",
  'it',
  "it's",
  'its',
  'itself',
  "let's",
  'me',
  'more',
  'most',
  "mustn't",
  'my',
  'myself',
  'no',
  'nor',
  'not',
  'of',
  'off',
  'on',
  'once',
  'only',
  'or',
  'other',
  'ought',
  'our',
  'ours',
  'ourselves',
  'out',
  'over',
  'own',
  'same',
  "shan't",
  'she',
  "she'd",
  "she'll",
  "she's",
  'should',
  "shouldn't",
  'so',
  'some',
  'such',
  'than',
  'that',
  "that's",
  'the',
  'their',
  'theirs',
  'them',
  'themselves',
  'then',
  'there',
  "there's",
  'these',
  'they',
  "they'd",
  "they'll",
  "they're",
  "they've",
  'this',
  'those',
  'through',
  'to',
  'too',
  'under',
  'until',
  'up',
  'very',
  'was',
  "wasn't",
  'we',
  "we'd",
  "we'll",
  "we're",
  "we've",
  'were',
  "weren't",
  'what',
  "what's",
  'when',
  "when's",
  'where',
  "where's",
  'which',
  'while',
  'who',
  "who's",
  'whom',
  'why',
  "why's",
  'will',
  'with',
  "won't",
  'would',
  "wouldn't",
  'you',
  "you'd",
  "you'll",
  "you're",
  "you've",
  'your',
  'yours',
  'yourself',
  'yourselves',
};
