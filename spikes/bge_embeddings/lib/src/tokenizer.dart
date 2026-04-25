// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io';
import 'dart:typed_data';

import 'package:icu_tokenizer/icu_tokenizer.dart' show RegExpTokenizer;

// Replace with your actual UAX #29 import, e.g.:
// import 'package:your_uax29_package/your_uax29_package.dart';

class BertTokenizer {
  final Map<String, int> _vocab;
  final int _maxLength;

  static const int _clsId = 101;
  static const int _sepId = 102;
  static const int _unkId = 100;
  static const int _padId = 0;

  BertTokenizer._(this._vocab, this._maxLength);

  /// Load vocabulary from vocab.txt (one token per line; line index = token ID).
  static Future<BertTokenizer> load(
    String vocabPath, {
    int maxLength = 512,
  }) async {
    final lines = await File(vocabPath).readAsLines();
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      vocab[lines[i].trim()] = i;
    }
    return BertTokenizer._(vocab, maxLength);
  }

  TokenizerOutput encode(String text) {
    final normalized = _normalize(text);

    // ── Replace with your UAX #29 word segmentation call: ────────────────────
    // final words = segmentWords(normalized);
    final words = RegExpTokenizer().tokenise(normalized);
    // ─────────────────────────────────────────────────────────────────────────

    final tokenIds = <int>[_clsId];
    outer:
    for (final word in words) {
      if (word.isEmpty) continue;
      for (final id in _wordPiece(word)) {
        if (tokenIds.length >= _maxLength - 1) break outer;
        tokenIds.add(id);
      }
    }
    tokenIds.add(_sepId);

    final attentionMask = List<int>.filled(tokenIds.length, 1, growable: true);
    while (tokenIds.length < _maxLength) {
      tokenIds.add(_padId);
      attentionMask.add(0);
    }

    return TokenizerOutput(
      inputIds: Int64List.fromList(tokenIds),
      attentionMask: Int64List.fromList(attentionMask),
      tokenTypeIds: Int64List.fromList(List.filled(_maxLength, 0)),
    );
  }

  /// Map token IDs back to their original strings from the vocabulary.
  List<String> decode(List<int> ids) {
    final inverse = <int, String>{};
    _vocab.forEach((k, v) => inverse[v] = k);
    return ids.map((id) => inverse[id] ?? '[UNK]').toList();
  }

  String _normalize(String text) {
    final buf = StringBuffer();
    for (final char in text.toLowerCase().runes) {
      if (char >= 0x0300 && char <= 0x036F) continue; // strip combining accents
      buf.writeCharCode(char);
    }
    return buf.toString();
  }

  List<int> _wordPiece(String word) {
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
      if (found == null) return [_unkId];
      ids.add(found);
      start = end;
    }
    return ids;
  }
}

class TokenizerOutput {
  final Int64List inputIds;
  final Int64List attentionMask;
  final Int64List tokenTypeIds;
  const TokenizerOutput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
  });
}
