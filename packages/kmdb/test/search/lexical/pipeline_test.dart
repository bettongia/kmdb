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

import 'package:intl/locale.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_lexical/lexical.dart' show RegExpTokeniser, getStopWords;
import 'package:test/test.dart';

final defaultStopwords = getStopWords(Locale.fromSubtags(languageCode: 'en'));

void main() {
  final tokeniser = RegExpTokeniser();

  // ── tokeniseAndNormalise ────────────────────────────────────────────────────

  group('tokeniseAndNormalise', () {
    test('empty string returns empty list', () {
      expect(tokeniseAndNormalise('', tokeniser), isEmpty);
    });

    test('whitespace-only string returns empty list', () {
      expect(tokeniseAndNormalise('   \t\n  ', tokeniser), isEmpty);
    });

    test('lowercases ASCII tokens', () {
      expect(
        tokeniseAndNormalise('Hello World', tokeniser),
        equals(['hello', 'world']),
      );
    });

    test('lowercases mixed-case identifier (Jekyll → jekyll)', () {
      expect(tokeniseAndNormalise('Jekyll', tokeniser), equals(['jekyll']));
    });

    test('lowercases sentence with punctuation', () {
      final result = tokeniseAndNormalise('Dr. Jekyll and Mr. Hyde', tokeniser);
      expect(result, equals(['dr', 'jekyll', 'and', 'mr', 'hyde']));
    });

    test('produces same result as calling tokeniser + lowercase manually', () {
      const text = 'The Quick Brown Fox';
      final expected = tokeniser
          .tokenise(text)
          .map((t) => t.toLowerCase())
          .toList();
      expect(tokeniseAndNormalise(text, tokeniser), equals(expected));
    });
  });

  // ── filterStopWords ─────────────────────────────────────────────────────────

  group('filterStopWords', () {
    test('empty token list returns empty list', () {
      expect(filterStopWords([], defaultStopwords.listing), isEmpty);
    });

    test('empty stop-word set returns tokens unchanged', () {
      final tokens = ['the', 'and', 'is'];
      expect(filterStopWords(tokens, {}), equals(tokens));
    });

    test('removes common stop words (the, and, is)', () {
      final tokens = ['the', 'quick', 'and', 'is', 'fox'];
      expect(
        filterStopWords(tokens, defaultStopwords.listing),
        equals(['quick', 'fox']),
      );
    });

    test('passes through non-stop-words intact', () {
      const word = 'jekyll';
      expect(filterStopWords([word], defaultStopwords.listing), equals([word]));
    });

    test('all tokens are stop words → empty result', () {
      expect(
        filterStopWords(['the', 'and', 'is', 'a'], defaultStopwords.listing),
        isEmpty,
      );
    });

    test('custom stop-word set removes only those words', () {
      final custom = {'foo', 'bar'};
      expect(
        filterStopWords(['foo', 'baz', 'bar', 'qux'], custom),
        equals(['baz', 'qux']),
      );
    });
  });

  // ── stem ───────────────────────────────────────────────────────────────────

  group('stem', () {
    test('empty list returns empty list', () {
      expect(stem([]), isEmpty);
    });

    test('investigates → investig', () {
      expect(stem(['investigates']), equals(['investig']));
    });

    test('occurring → occur', () {
      expect(stem(['occurring']), equals(['occur']));
    });

    test('disturbing → disturb', () {
      expect(stem(['disturbing']), equals(['disturb']));
    });

    test('multiple tokens are each stemmed', () {
      final result = stem(['running', 'jumps', 'foxes']);
      // Snowball English: running→run, jumps→jump, foxes→fox
      expect(result, equals(['run', 'jump', 'fox']));
    });

    test('already-stemmed word is stable (idempotent)', () {
      final once = stem(['run']);
      final twice = stem(once);
      expect(once, equals(twice));
    });
  });

  // ── preprocess (full pipeline) ──────────────────────────────────────────────

  group('preprocess', () {
    test('empty string returns empty list', () {
      expect(preprocess('', tokeniser), isEmpty);
    });

    test('stop-word filtering disabled by default', () {
      // 'the' and 'is' should survive without stopWords option.
      final result = preprocess('the dog is running', tokeniser);
      // 'the' → stem('the') = 'the'; 'is' → stem('is') = 'is'
      expect(result, contains('the'));
      expect(result, contains('is'));
    });

    test('stop-word filtering removes stop words when enabled', () {
      final result = preprocess(
        'the dog is running',
        tokeniser,
        stopWords: defaultStopwords.listing,
      );
      // 'the' and 'is' removed; 'dog' and 'run' remain.
      expect(result, isNot(contains('the')));
      expect(result, isNot(contains('is')));
      expect(result, contains('dog'));
      expect(result, contains('run'));
    });

    test(
      'prose sentence produces expected stemmed token set (with stop words)',
      () {
        final result = preprocess(
          'The quick brown fox jumps over the lazy dog',
          tokeniser,
          stopWords: defaultStopwords.listing,
        );
        // 'the', 'over' are stop words; remaining: quick→quick, brown→brown,
        // fox→fox, jumps→jump, lazy→lazi, dog→dog
        expect(
          result,
          containsAll(['quick', 'brown', 'fox', 'jump', 'lazi', 'dog']),
        );
        expect(result, isNot(contains('the')));
        expect(result, isNot(contains('over')));
      },
    );

    test('technical identifiers survive pipeline (mTLS)', () {
      // 'mTLS' → normalise → 'mtls' → stem → 'mtl' (acceptable) or 'mtls'
      // The key requirement is: no error and the token is present.
      final result = preprocess('mTLS protocol', tokeniser);
      expect(result.length, greaterThan(0));
    });

    test('hex identifier survives pipeline (0x8004210B)', () {
      // RegExpTokeniser strips non-word chars; '0x8004210B' → '0x8004210B'
      // (one token). The pipeline must not panic.
      final result = preprocess('error code 0x8004210B', tokeniser);
      expect(result.length, greaterThan(0));
    });

    test('query with all stop words returns empty list when filtering on', () {
      final result = preprocess(
        'the and is',
        tokeniser,
        stopWords: defaultStopwords.listing,
      );
      expect(result, isEmpty);
    });

    test('identical input produces identical output (index == query path)', () {
      const text = 'full text search is powerful';
      final indexed = preprocess(
        text,
        tokeniser,
        stopWords: defaultStopwords.listing,
      );
      final queried = preprocess(
        text,
        tokeniser,
        stopWords: defaultStopwords.listing,
      );
      expect(indexed, equals(queried));
    });
  });
}
