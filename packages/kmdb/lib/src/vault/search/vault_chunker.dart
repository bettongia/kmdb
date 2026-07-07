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

import 'package:betto_lexical/betto_lexical.dart'
    show OffsetTokenizer, createDefaultTokenizer, getStopWords;
import 'package:intl/locale.dart' show Locale;

import '../../search/lexical/pipeline.dart';
import 'vault_chunk.dart';
import 'vault_search_config.dart';

/// English stop words — loaded once, shared across all [VaultChunker] instances.
final _englishStopWords = getStopWords(
  Locale.fromSubtags(languageCode: 'en'),
).listing;

/// Result of a [VaultChunker.chunk] call.
///
/// Contains the list of [VaultChunk] metadata records alongside the
/// per-chunk preprocessed BM25 term frequency maps that the indexing pipeline
/// needs to write `$$vault:fts:` entries.
final class VaultChunkResult {
  /// Creates a [VaultChunkResult].
  const VaultChunkResult({required this.chunks, required this.termFrequencies});

  /// Chunk metadata: byte offsets and word counts in `text.txt`.
  final List<VaultChunk> chunks;

  /// BM25 preprocessed term-frequency map for each chunk.
  ///
  /// `termFrequencies[i]` corresponds to `chunks[i]`. Keys are stemmed,
  /// stop-word-filtered lowercase tokens. Values are term frequencies.
  final List<Map<String, int>> termFrequencies;
}

/// Splits extracted vault text into overlapping word-count chunks.
///
/// Uses an [OffsetTokenizer] to find token spans (including their character
/// positions in the source string), groups them into sliding windows of
/// [VaultSearchConfig.chunkSize] words with [VaultSearchConfig.chunkOverlap]
/// words of overlap between adjacent chunks, and applies the BM25 preprocessing
/// pipeline (lowercase → stop-word filter → Snowball stem) to each window.
///
/// Byte offsets in each [VaultChunk] reference the UTF-8–encoded text string
/// (i.e. `text.txt`), not the original blob bytes.
///
/// ## Algorithm
///
/// 1. Scan [text] with the injected [OffsetTokenizer] to find all word token
///    spans (position-aware). This avoids running the tokenizer twice.
/// 2. Group token spans into windows: window `[i]` covers raw tokens
///    `[i * step, i * step + chunkSize)` where `step = chunkSize - chunkOverlap`.
/// 3. Compute the UTF-8 byte span of each window using a pre-built
///    char-index → byte-offset lookup table.
/// 4. Preprocess each window's raw token strings (lowercase → stop-word
///    filter → stem) to build BM25 term frequency maps.
///
/// ## Empty and short text
///
/// - Empty text → empty chunk list.
/// - Text with no word tokens (e.g. punctuation-only) → empty chunk list.
/// - Text shorter than one chunk → single chunk covering the full text.
///
/// ## Non-ASCII correctness
///
/// The default tokenizer (`IcuTokenizer`, via [createDefaultTokenizer]) is
/// UAX #29-conformant, so word boundaries are correct for non-Latin scripts
/// (CJK, Arabic, Cyrillic, Devanagari, Thai, etc.), unlike a hand-rolled ASCII
/// regex. Byte offsets are computed from character-index positions via a
/// pre-built offset table that correctly handles multi-byte UTF-8 characters
/// (CJK, emoji, accented letters).
final class VaultChunker {
  /// Creates a [VaultChunker] from the given [config].
  ///
  /// [tokenizer] defaults to [createDefaultTokenizer]'s result cast to
  /// [OffsetTokenizer] — safe because vault indexing is native-only (per
  /// CLAUDE.md), where [createDefaultTokenizer] always resolves to
  /// `IcuTokenizer`, which implements [OffsetTokenizer]. A fake
  /// [OffsetTokenizer] may be injected for deterministic testing.
  ///
  /// Not `const` — an injected or default [OffsetTokenizer] (`IcuTokenizer`
  /// holds native FFI resources) is not a compile-time constant.
  VaultChunker(this._config, {OffsetTokenizer? tokenizer})
    : _tokenizer = tokenizer ?? createDefaultTokenizer() as OffsetTokenizer;

  final VaultSearchConfig _config;
  final OffsetTokenizer _tokenizer;

  /// Splits [text] into overlapping chunks according to [_config].
  ///
  /// [text] must be a valid UTF-8 string (as returned by a
  /// [VaultTextExtractor]). Returns an empty [VaultChunkResult] for empty
  /// input or text with no word tokens.
  ///
  /// [languageCode] is the ISO 639-1 language code used to select a BM25
  /// stemmer for this text's tokens (see [stem] in `pipeline.dart`) —
  /// required (not defaulted), so every caller must consciously supply a
  /// value (typically the best-guess code from [detectLanguageForStemming]),
  /// rather than silently inheriting the old English-only behaviour. Pass
  /// `null` when no language could be determined; stemming is then skipped
  /// entirely for this call, not downgraded to English.
  VaultChunkResult chunk(String text, {required String? languageCode}) {
    if (text.isEmpty) {
      return const VaultChunkResult(chunks: [], termFrequencies: []);
    }

    final chunkSize = _config.chunkSize;
    final chunkOverlap = _config.chunkOverlap;
    // Step size: how many tokens to advance the window each iteration.
    // Guaranteed > 0 because VaultSearchConfig asserts chunkOverlap < chunkSize.
    final step = chunkSize - chunkOverlap;

    // Step 1: Find all word tokens and their character positions, using the
    // shared OffsetTokenizer (e.g. IcuTokenizer) instead of a hand-rolled
    // ASCII-only regex — this is what makes non-Latin-script vault text
    // searchable at all (see class doc).
    final tokenSpans = _tokenizer.tokeniseSpans(text);
    if (tokenSpans.isEmpty) {
      return const VaultChunkResult(chunks: [], termFrequencies: []);
    }

    // Precompute the char-index → UTF-8-byte-offset table for byteStart/End.
    final charToByte = _buildCharToByte(text);
    final textByteLen = charToByte[text.length];

    // Step 2-4: Slide windows over token spans.
    final chunks = <VaultChunk>[];
    final termFreqsMaps = <Map<String, int>>[];

    var windowStart = 0; // index into tokenSpans
    while (windowStart < tokenSpans.length) {
      final windowEnd = (windowStart + chunkSize).clamp(0, tokenSpans.length);
      final windowSpans = tokenSpans.sublist(windowStart, windowEnd);

      // Step 3: Compute byte offsets from character positions.
      final firstCharStart = windowSpans.first.start;
      final lastCharEnd = windowSpans.last.end;

      final byteStart = charToByte[firstCharStart];
      // end is exclusive, so charToByte[lastCharEnd] is the byte at
      // the start of the character AFTER the last token character, which is
      // exactly the exclusive upper bound for this chunk's byte range.
      final byteEnd = lastCharEnd < text.length
          ? charToByte[lastCharEnd]
          : textByteLen;

      // Step 4: Preprocess raw token strings for BM25.
      final rawTokens = windowSpans.map((s) => s.text).toList();
      final preprocessed = _preprocessTokens(rawTokens, languageCode);
      final tf = _termFrequencies(preprocessed);

      chunks.add(
        VaultChunk(
          index: chunks.length,
          byteStart: byteStart,
          byteEnd: byteEnd,
          wordCount: windowSpans.length,
        ),
      );
      termFreqsMaps.add(tf);

      // Break after the last window (which may be shorter than chunkSize).
      if (windowEnd == tokenSpans.length) break;
      windowStart += step;
    }

    return VaultChunkResult(chunks: chunks, termFrequencies: termFreqsMaps);
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  /// Builds a character-index → UTF-8-byte-offset lookup table for [text].
  ///
  /// `result[i]` is the number of UTF-8 bytes before character index `i`.
  /// `result[text.length]` equals the total byte length of the UTF-8 encoding.
  ///
  /// This is O(n) in the string length and is computed once per [chunk] call.
  /// The table allows O(1) byte-offset lookup for any character position.
  List<int> _buildCharToByte(String text) {
    // Allocate one extra slot for the sentinel at text.length.
    final offsets = List<int>.filled(text.length + 1, 0);
    var byteOffset = 0;
    for (var i = 0; i < text.length; i++) {
      offsets[i] = byteOffset;
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit <= 0x7F) {
        // ASCII — 1 byte.
        byteOffset += 1;
      } else if (codeUnit <= 0x7FF) {
        // 2-byte UTF-8 sequence.
        byteOffset += 2;
      } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
        // High surrogate — part of a 4-byte supplementary character.
        // The low surrogate follows at i+1 in the Dart string. Advance i
        // to consume it and mark its offset entry as equal to the byte
        // following the 4-byte sequence (since the low surrogate is not an
        // independent code point).
        byteOffset += 4;
        i++;
        if (i < text.length) offsets[i] = byteOffset;
      } else {
        // BMP code point above 0x7FF but not a surrogate — 3-byte UTF-8.
        byteOffset += 3;
      }
    }
    offsets[text.length] = byteOffset;
    return offsets;
  }

  /// Applies the BM25 preprocessing pipeline to a list of raw token strings.
  ///
  /// Pipeline: lowercase → English stop-word filter → language-aware Snowball
  /// stem (WI-6; see [stem] in `pipeline.dart`). This mirrors [preprocess] in
  /// `pipeline.dart` but takes pre-extracted token strings (with known
  /// positions) rather than re-tokenising the text.
  ///
  /// Stop-word filtering is unaffected by [languageCode] — it remains the
  /// hard-coded English stop-word set (out of scope for WI-6; see the plan's
  /// "Stop words: still out of scope" note). Only the stemming stage is
  /// language-aware.
  List<String> _preprocessTokens(List<String> rawTokens, String? languageCode) {
    if (rawTokens.isEmpty) return const [];
    // Lowercase (mirrors tokeniseAndNormalise without the tokeniser step).
    final lowered = rawTokens.map((t) => t.toLowerCase()).toList();
    // Stop-word filter using English defaults (same set as FtsManager).
    final filtered = filterStopWords(lowered, _englishStopWords);
    // Language-aware Snowball stemmer — shared with the document-field FTS
    // pipeline (pipeline.dart's stem()). Skips stemming entirely when
    // languageCode is null or unsupported by betto_lexical's Stemmer.
    return stem(filtered, languageCode: languageCode);
  }

  /// Computes term frequencies from a list of preprocessed tokens.
  ///
  /// Returns a map from stemmed term to its count in [tokens]. Mirrors
  /// `FtsManager._termFrequencies`.
  static Map<String, int> _termFrequencies(List<String> tokens) {
    final tf = <String, int>{};
    for (final token in tokens) {
      tf[token] = (tf[token] ?? 0) + 1;
    }
    return tf;
  }
}
