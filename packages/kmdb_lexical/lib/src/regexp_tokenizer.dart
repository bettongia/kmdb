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

import 'tokenizer.dart';

/// The default [Tokenizer] implementation, written in pure Dart using [RegExp].
///
/// ## Scope — English only
///
/// This implementation is sufficient for English-language prose and common
/// technical identifiers (`mTLS`, `0x8004210B`, etc.). It is **not** suitable
/// for non-Latin scripts (CJK, Thai, Arabic, etc.) where word boundaries do
/// not follow whitespace rules.
///
/// When multi-language support is added to the lexical search index this class
/// should be replaced with (or fall back to) `IcuTokenizer` from the
/// `kmdb_tokenizer_icu` package, which uses the system ICU library and conforms
/// to UAX #29 Unicode Text Segmentation. The [Tokenizer] interface makes that
/// swap transparent to the indexing pipeline.
///
/// ## Why not ICU now?
///
/// Spike investigation confirmed that `IcuTokenizer` works correctly on all
/// target platforms and requires no bundling (ICU ships with every OS). The
/// RegExp path is used for Phase 1 because it is simpler (zero FFI), produces
/// identical output for English prose and common technical identifiers, and
/// avoids the platform-specific library-loading code until it is actually
/// needed.
///
/// ## Example
///
/// ```dart
/// final tokenizer = RegExpTokenizer();
/// print(tokenizer.tokenise('Hello, world!')); // ['Hello', 'world']
/// print(tokenizer.tokenise('')); // []
/// print(tokenizer.tokenise('mTLS handshake')); // ['mTLS', 'handshake']
/// ```
class RegExpTokenizer implements Tokenizer {
  /// Creates a new [RegExpTokenizer].
  const RegExpTokenizer();

  /// Matches sequences of Unicode word characters (letters, digits, and
  /// underscores), optionally allowing internal hyphens and apostrophes so
  /// that contractions and hyphenated terms are kept intact.
  ///
  /// `\w` in Dart's RegExp engine matches `[a-zA-Z0-9_]` only (ASCII).
  /// For broader Unicode letter support we use `\p{L}` and `\p{N}` with the
  /// `unicode` flag.
  static final _wordPattern = RegExp(
    r"[\p{L}\p{N}][\p{L}\p{N}_'\-]*[\p{L}\p{N}]|[\p{L}\p{N}]",
    unicode: true,
  );

  @override
  List<String> tokenise(String text) {
    if (text.isEmpty) return const [];
    return _wordPattern
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList(growable: false);
  }
}
