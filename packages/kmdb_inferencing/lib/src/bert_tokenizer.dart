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

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

/// A BERT WordPiece tokeniser backed by a `vocab.txt` file.
///
/// Converts arbitrary text into BERT token IDs suitable for feeding into the
/// BGE Small En v1.5 ONNX model via [OrtInferenceSession.run].
///
/// ## Pipeline
///
/// 1. **Normalise** — lower-case and strip combining accent characters.
/// 2. **Word segmentation** — delegate to the [Tokeniser] supplied at
///    construction time. [RegExpTokeniser] is used by default; `IcuTokeniser`
///    from `package:kmdb_tokenizer_icu` can be substituted as a drop-in
///    replacement for superior Unicode coverage.
/// 3. **WordPiece** — split each word into sub-word pieces and look up IDs in
///    the vocabulary loaded from `vocab.txt`. Unknown pieces map to `[UNK]`.
/// 4. **Assemble** — prepend `[CLS]` (101), append `[SEP]` (102), and pad to
///    [maxLength] with `[PAD]` (0).
///
/// ## Token ID space
///
/// BERT token IDs are entirely distinct from the stemmed token strings
/// produced by the lexical search pipeline (FtsManager / BM25). They must
/// not be interchanged.
///
/// ## IcuTokeniser
///
/// ```dart
/// import 'package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart';
/// final tokenizer = await BertTokenizer.load(vocabPath,
///   tokeniser: IcuTokeniser());
/// ```
class BertTokenizer {
  final Map<String, int> _vocab;
  final int _maxLength;
  final Tokeniser _tokeniser;

  /// [CLS] token ID — always the first token in BERT input sequences.
  static const int clsId = 101;

  /// [SEP] token ID — marks the end of a segment in BERT input sequences.
  static const int sepId = 102;

  /// [UNK] token ID — substituted for vocabulary entries not found in WordPiece
  /// decomposition.
  static const int unkId = 100;

  /// [PAD] token ID — used to fill sequences shorter than [maxLength].
  static const int padId = 0;

  BertTokenizer._(this._vocab, this._maxLength, this._tokeniser);

  /// Loads the vocabulary from [vocabPath] and returns a [BertTokenizer].
  ///
  /// [vocabPath] must point to a `vocab.txt` file where each line is a
  /// vocabulary token and the line index (0-based) is the token ID. The BGE
  /// Small En v1.5 vocabulary has 30,522 entries.
  ///
  /// [maxLength] is the maximum sequence length including the `[CLS]` and
  /// `[SEP]` sentinel tokens (default 512 per the BERT specification).
  ///
  /// [tokeniser] controls word segmentation before WordPiece splitting.
  /// Defaults to [RegExpTokeniser]. Supply `IcuTokeniser()` from
  /// `package:kmdb_tokenizer_icu` for improved Unicode coverage.
  static Future<BertTokenizer> load(
    String vocabPath, {
    int maxLength = 512,
    Tokeniser? tokeniser,
  }) async {
    final lines = await File(vocabPath).readAsLines();
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      vocab[lines[i].trim()] = i;
    }
    return BertTokenizer._(vocab, maxLength, tokeniser ?? RegExpTokeniser());
  }

  /// Encodes [text] into a [TokenizerOutput] ready for ONNX inference.
  ///
  /// The output always starts with `[CLS]` (101) and ends with `[SEP]` (102).
  /// If [text] contains more WordPiece tokens than `maxLength - 2` (510 usable
  /// tokens), the excess is silently discarded and
  /// [TokenizerOutput.truncated] is `true`.
  ///
  /// An empty or whitespace-only [text] produces a two-token sequence
  /// `[CLS][SEP]` with all remaining positions padded — [TokenizerOutput.truncated]
  /// is `false`.
  ///
  /// All three output arrays ([TokenizerOutput.inputIds],
  /// [TokenizerOutput.attentionMask], [TokenizerOutput.tokenTypeIds]) have
  /// exactly [maxLength] elements.
  TokenizerOutput encode(String text) {
    final normalized = _normalize(text);
    final words = _tokeniser.tokenise(normalized);

    // Build the token ID list starting with [CLS].
    // Leave one slot for the closing [SEP] token.
    final tokenIds = <int>[clsId];
    var wasTruncated = false;

    outer:
    for (final word in words) {
      if (word.isEmpty) continue;
      for (final id in _wordPiece(word)) {
        // Reserve the last slot for [SEP].
        if (tokenIds.length >= _maxLength - 1) {
          wasTruncated = true;
          break outer;
        }
        tokenIds.add(id);
      }
    }
    tokenIds.add(sepId);

    // Build attention mask: 1 for real tokens, 0 for padding.
    final attentionMask = List<int>.filled(tokenIds.length, 1, growable: true);
    while (tokenIds.length < _maxLength) {
      tokenIds.add(padId);
      attentionMask.add(0);
    }

    return TokenizerOutput(
      inputIds: Int64List.fromList(tokenIds),
      attentionMask: Int64List.fromList(attentionMask),
      // BERT token_type_ids are all-zeros for single-segment input.
      tokenTypeIds: Int64List.fromList(List.filled(_maxLength, 0)),
      truncated: wasTruncated,
    );
  }

  /// Decodes a list of token IDs back to vocabulary strings.
  ///
  /// Unknown IDs are mapped to `'[UNK]'`. Primarily for diagnostics.
  List<String> decode(List<int> ids) {
    final inverse = <int, String>{};
    _vocab.forEach((k, v) => inverse[v] = k);
    return ids.map((id) => inverse[id] ?? '[UNK]').toList();
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  /// Lower-cases [text] and strips Unicode combining accent characters
  /// (U+0300–U+036F) which BERT treats as noise.
  String _normalize(String text) {
    final buf = StringBuffer();
    for (final char in text.toLowerCase().runes) {
      // Strip combining diacritical marks (accents, cedillas, etc.)
      if (char >= 0x0300 && char <= 0x036F) continue;
      buf.writeCharCode(char);
    }
    return buf.toString();
  }

  /// Splits [word] into sub-word pieces using the WordPiece algorithm and
  /// returns the corresponding vocabulary token IDs.
  ///
  /// All sub-word pieces after the first are prefixed with `##` per the BERT
  /// convention. Returns `[unkId]` if any position cannot be decomposed.
  List<int> _wordPiece(String word) {
    // Fast path: the whole word is in the vocabulary.
    if (_vocab.containsKey(word)) return [_vocab[word]!];

    final ids = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      int? found;
      while (start < end) {
        final sub = start == 0
            ? word.substring(start, end)
            : '##${word.substring(start, end)}';
        if (_vocab.containsKey(sub)) {
          found = _vocab[sub];
          break;
        }
        end--;
      }
      // If no sub-word piece was found, map the entire word to [UNK].
      if (found == null) return [unkId];
      ids.add(found);
      start = end;
    }
    return ids;
  }
}

/// The output of [BertTokenizer.encode]: three parallel int64 arrays ready for
/// ONNX Runtime inference.
///
/// All three arrays have exactly `maxLength` elements. Padding positions have
/// `inputIds = 0`, `attentionMask = 0`, `tokenTypeIds = 0`.
final class TokenizerOutput {
  /// Creates a [TokenizerOutput].
  const TokenizerOutput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
    required this.truncated,
  });

  /// BERT token IDs, starting with `[CLS]` (101) and ending with `[SEP]`
  /// (102), then zero-padded to [BertTokenizer.maxLength].
  final Int64List inputIds;

  /// 1 for real tokens (including `[CLS]` and `[SEP]`), 0 for padding.
  final Int64List attentionMask;

  /// Segment IDs — all zeros for single-segment BERT input.
  final Int64List tokenTypeIds;

  /// `true` if the input text exceeded the usable token budget and was
  /// silently truncated before the `[SEP]` token.
  final bool truncated;
}
