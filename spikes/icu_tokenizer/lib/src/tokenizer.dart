// Copyright 2026 The KMDB Authors.
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

/// Abstract interface for text segmentation.
///
/// Implementations segment a string into word-like tokens, discarding
/// whitespace and punctuation boundaries. The pipeline then normalises and
/// stems the returned tokens; this interface is responsible only for the
/// segmentation step.
///
/// ## Current limitation — English only
///
/// The production implementation ([RegExpTokenizer]) is adequate for
/// English-language prose and technical identifiers but is **not** suitable
/// for non-Latin scripts (CJK, Thai, Arabic, etc.) where word boundaries do
/// not follow whitespace. A future implementation should replace
/// [RegExpTokenizer] with an ICU FFI binding (see [IcuTokenizer]) once
/// multi-language support is added to the lexical search index.
///
/// The interface is intentionally narrow so the implementation can be swapped
/// without touching the indexing pipeline.
///
/// Example:
/// ```dart
/// final tokenizer = RegExpTokenizer();
/// final tokens = tokenizer.tokenise('Dr. Jekyll and Mr. Hyde');
/// // → ['Dr', 'Jekyll', 'and', 'Mr', 'Hyde']
/// ```
abstract interface class Tokenizer {
  /// Segment [text] into word tokens.
  ///
  /// Returns only word-like spans (letters, numbers, mixed-case identifiers).
  /// Punctuation, whitespace, and other non-word spans are discarded.
  List<String> tokenise(String text);
}
