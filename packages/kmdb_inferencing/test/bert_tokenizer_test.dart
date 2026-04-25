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

@TestOn('vm')
library;

import 'dart:io';

import 'package:kmdb_inferencing/kmdb_inferencing.dart';
import 'package:kmdb_lexical/lexical.dart' show Tokenizer;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Path to the BGE Small En v1.5 vocab.txt asset.
String get _vocabPath {
  // Resolve relative to this test file's location.
  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  return '$scriptDir/../assets/models/bge-small-en/vocab.txt';
}

/// Returns `true` if the vocab.txt file is present.
bool get _vocabAvailable => File(_vocabPath).existsSync();

void main() {
  // Skip all tests if the model assets have not been copied yet.
  if (!_vocabAvailable) {
    group('BertTokenizer', () {
      test(
        'vocab.txt is present',
        skip: 'vocab.txt not found at $_vocabPath — copy model assets first.',
        () {},
      );
    });
    return;
  }

  late BertTokenizer tokenizer;

  setUpAll(() async {
    tokenizer = await BertTokenizer.load(_vocabPath);
  });

  group('BertTokenizer — sentinels', () {
    test('encode() starts with [CLS] token (id=101)', () {
      final out = tokenizer.encode('hello world');
      expect(out.inputIds[0], equals(BertTokenizer.clsId));
    });

    test('encode() ends with [SEP] token at the last real position', () {
      final out = tokenizer.encode('hello world');
      // Find the last non-padding token — it should be [SEP].
      final lastRealIdx = out.attentionMask.lastIndexWhere((m) => m == 1);
      expect(out.inputIds[lastRealIdx], equals(BertTokenizer.sepId));
    });

    test('output has exactly maxLength (512) elements', () {
      final out = tokenizer.encode('hello world');
      expect(out.inputIds.length, equals(512));
      expect(out.attentionMask.length, equals(512));
      expect(out.tokenTypeIds.length, equals(512));
    });

    test('token_type_ids are all zeros (single-segment input)', () {
      final out = tokenizer.encode('any text here');
      expect(out.tokenTypeIds.every((v) => v == 0), isTrue);
    });
  });

  group('BertTokenizer — known token IDs', () {
    test('hello and world have correct vocabulary IDs', () {
      // Known BGE Small En v1.5 vocab IDs: hello=7592, world=2088
      final out = tokenizer.encode('hello world');
      // inputIds[0] = CLS, inputIds[1] = hello, inputIds[2] = world, inputIds[3] = SEP
      expect(out.inputIds[1], equals(7592)); // 'hello'
      expect(out.inputIds[2], equals(2088)); // 'world'
    });

    test(
      'jekyll WordPiece splits to [je, ##ky, ##ll] = [15333, 4801, 3363]',
      () {
        final out = tokenizer.encode('jekyll');
        // CLS, je(15333), ##ky(4801), ##ll(3363), SEP, PAD...
        expect(out.inputIds[1], equals(15333));
        expect(out.inputIds[2], equals(4801));
        expect(out.inputIds[3], equals(3363));
        expect(out.inputIds[4], equals(BertTokenizer.sepId));
      },
    );
  });

  group('BertTokenizer — truncation', () {
    test('long text exceeding 510 usable tokens is truncated', () {
      // Repeat a single word 600 times — each maps to one token → exceeds limit.
      final longText = List.filled(600, 'hello').join(' ');
      final out = tokenizer.encode(longText);
      expect(out.truncated, isTrue);
      // The last real token must still be SEP.
      final lastRealIdx = out.attentionMask.lastIndexWhere((m) => m == 1);
      expect(out.inputIds[lastRealIdx], equals(BertTokenizer.sepId));
      // Exactly 512 tokens in output (padding fills the rest).
      expect(out.inputIds.length, equals(512));
    });

    test('text fitting exactly in 510 usable tokens is not truncated', () {
      // 510 words → exactly fills the usable budget (510 single-token words).
      final text = List.filled(510, 'hello').join(' ');
      final out = tokenizer.encode(text);
      expect(out.truncated, isFalse);
      // Entire attention mask should be 1 (all tokens real, no padding).
      expect(out.attentionMask.every((m) => m == 1), isTrue);
    });
  });

  group('BertTokenizer — empty input', () {
    test('empty string produces [CLS][SEP] only, no error', () {
      final out = tokenizer.encode('');
      expect(out.inputIds[0], equals(BertTokenizer.clsId));
      expect(out.inputIds[1], equals(BertTokenizer.sepId));
      // All remaining positions should be padding.
      for (var i = 2; i < 512; i++) {
        expect(out.inputIds[i], equals(BertTokenizer.padId));
        expect(out.attentionMask[i], equals(0));
      }
      expect(out.truncated, isFalse);
    });

    test('whitespace-only string produces [CLS][SEP] only', () {
      final out = tokenizer.encode('   \t\n   ');
      expect(out.inputIds[0], equals(BertTokenizer.clsId));
      expect(out.inputIds[1], equals(BertTokenizer.sepId));
      expect(out.truncated, isFalse);
    });
  });

  group('BertTokenizer — attention mask', () {
    test('attention mask is 1 for real tokens and 0 for padding', () {
      final out = tokenizer.encode('hello world');
      // Expect: CLS(1), hello(1), world(1), SEP(1), then all zeros.
      expect(out.attentionMask[0], equals(1)); // CLS
      expect(out.attentionMask[1], equals(1)); // hello
      expect(out.attentionMask[2], equals(1)); // world
      expect(out.attentionMask[3], equals(1)); // SEP
      for (var i = 4; i < 512; i++) {
        expect(out.attentionMask[i], equals(0));
      }
    });
  });

  group('BertTokenizer — tokenizer substitution', () {
    test(
      'custom Tokenizer is used for word segmentation without error',
      () async {
        // Provide a trivially correct Tokenizer — same contract as RegExpTokenizer.
        // We just verify that BertTokenizer.load accepts the parameter and
        // encode() runs without error.
        final customTokenizer = await BertTokenizer.load(
          _vocabPath,
          tokenizer: const _WhitespaceTokenizer(),
        );
        final out = customTokenizer.encode('hello world');
        expect(out.inputIds[0], equals(BertTokenizer.clsId));
        expect(out.truncated, isFalse);
      },
    );
  });
}

/// Minimal [Tokenizer] that splits on whitespace — used to verify that
/// [BertTokenizer] honours the [Tokenizer] injection point.
final class _WhitespaceTokenizer implements Tokenizer {
  const _WhitespaceTokenizer();

  @override
  List<String> tokenise(String text) =>
      text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
}
