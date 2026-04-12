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

import 'package:bge_embeddings/src/tokenizer.dart';
import 'package:test/test.dart';

/// Builds a minimal BERT vocab file in [dir] and returns its path.
///
/// The vocab has the required special tokens at their canonical IDs:
///   0=[PAD], 100=[UNK], 101=[CLS], 102=[SEP]
/// plus a small set of real word tokens starting at ID 103.
Future<String> _writeMinimalVocab(Directory dir, List<String> words) async {
  final file = File('${dir.path}/vocab.txt');
  final lines = List<String>.generate(103, (i) {
    if (i == 0) return '[PAD]';
    if (i == 100) return '[UNK]';
    if (i == 101) return '[CLS]';
    if (i == 102) return '[SEP]';
    return '[unused$i]';
  });
  lines.addAll(words);
  await file.writeAsString(lines.join('\n'));
  return file.path;
}

void main() {
  late Directory tempDir;
  late String vocabPath;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('bge_test_');
    vocabPath = await _writeMinimalVocab(tempDir, [
      'hello',
      'world',
      'dart',
      'is',
      'great',
    ]);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  group('BertTokenizer', () {
    test('all output lists have length == maxLength', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      final out = tok.encode('hello world');
      expect(out.inputIds.length, equals(16));
      expect(out.attentionMask.length, equals(16));
      expect(out.tokenTypeIds.length, equals(16));
    });

    test('output starts with [CLS] (101)', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      expect(tok.encode('hello').inputIds[0], equals(101));
    });

    test('output contains [SEP] (102) after real tokens', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      final ids = tok.encode('hello').inputIds;
      expect(ids.contains(102), isTrue);
      // [SEP] must come after [CLS]
      expect(ids.indexOf(102), greaterThan(0));
    });

    test('attention mask is 1 for content tokens and 0 for padding', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      final out = tok.encode('hello world');
      final sepIdx = out.inputIds.indexOf(102);
      for (var i = 0; i <= sepIdx; i++) {
        expect(
          out.attentionMask[i],
          equals(1),
          reason: 'slot $i should be attended',
        );
      }
      for (var i = sepIdx + 1; i < 16; i++) {
        expect(
          out.attentionMask[i],
          equals(0),
          reason: 'slot $i should be padding',
        );
      }
    });

    test('padding slots use [PAD] token (0)', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      final out = tok.encode('hello');
      final sepIdx = out.inputIds.indexOf(102);
      for (var i = sepIdx + 1; i < 16; i++) {
        expect(out.inputIds[i], equals(0));
      }
    });

    test('token type IDs are all zero', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      for (final id in tok.encode('hello world').tokenTypeIds) {
        expect(id, equals(0));
      }
    });

    test('out-of-vocab subword produces [UNK] (100)', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 16);
      final ids = tok.encode('zzzyyyxxx').inputIds; // nothing in vocab
      expect(ids.contains(100), isTrue);
    });

    test('empty input encodes to [CLS][SEP] followed by [PAD]', () async {
      final tok = await BertTokenizer.load(vocabPath, maxLength: 8);
      final out = tok.encode('');
      expect(out.inputIds[0], equals(101)); // [CLS]
      expect(out.inputIds[1], equals(102)); // [SEP]
      for (var i = 2; i < 8; i++) {
        expect(out.inputIds[i], equals(0)); // [PAD]
        expect(out.attentionMask[i], equals(0));
      }
    });

    test(
      'text longer than maxLength is truncated to maxLength tokens',
      () async {
        // maxLength=8 → [CLS] + 6 tokens + [SEP]
        final tok = await BertTokenizer.load(vocabPath, maxLength: 8);
        final out = tok.encode('hello world dart is great hello world dart');
        expect(out.inputIds.length, equals(8));
        expect(out.inputIds.last, equals(102)); // ends with [SEP]
      },
    );
  });
}
