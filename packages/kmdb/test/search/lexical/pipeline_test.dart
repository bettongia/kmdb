// Copyright 2026 The Authors
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
import 'package:betto_lexical/betto_lexical.dart'
    show RegExpTokenizer, getStopWords;
import 'package:test/test.dart';

final defaultStopwords = getStopWords(Locale.fromSubtags(languageCode: 'en'));

void main() {
  final tokenizer = RegExpTokenizer();

  // ── tokeniseAndNormalise ────────────────────────────────────────────────────

  group('tokeniseAndNormalise', () {
    test('empty string returns empty list', () {
      expect(tokeniseAndNormalise('', tokenizer), isEmpty);
    });

    test('whitespace-only string returns empty list', () {
      expect(tokeniseAndNormalise('   \t\n  ', tokenizer), isEmpty);
    });

    test('lowercases ASCII tokens', () {
      expect(
        tokeniseAndNormalise('Hello World', tokenizer),
        equals(['hello', 'world']),
      );
    });

    test('lowercases mixed-case identifier (Jekyll → jekyll)', () {
      expect(tokeniseAndNormalise('Jekyll', tokenizer), equals(['jekyll']));
    });

    test('lowercases sentence with punctuation', () {
      final result = tokeniseAndNormalise('Dr. Jekyll and Mr. Hyde', tokenizer);
      expect(result, equals(['dr', 'jekyll', 'and', 'mr', 'hyde']));
    });

    test('produces same result as calling tokenizer + lowercase manually', () {
      const text = 'The Quick Brown Fox';
      final expected = tokenizer
          .tokenise(text)
          .map((t) => t.toLowerCase())
          .toList();
      expect(tokeniseAndNormalise(text, tokenizer), equals(expected));
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
      expect(stem([], languageCode: 'en'), isEmpty);
    });

    test('investigates → investig', () {
      expect(stem(['investigates'], languageCode: 'en'), equals(['investig']));
    });

    test('occurring → occur', () {
      expect(stem(['occurring'], languageCode: 'en'), equals(['occur']));
    });

    test('disturbing → disturb', () {
      expect(stem(['disturbing'], languageCode: 'en'), equals(['disturb']));
    });

    test('multiple tokens are each stemmed', () {
      final result = stem(['running', 'jumps', 'foxes'], languageCode: 'en');
      // Snowball English: running→run, jumps→jump, foxes→fox
      expect(result, equals(['run', 'jump', 'fox']));
    });

    test('already-stemmed word is stable (idempotent)', () {
      final once = stem(['run'], languageCode: 'en');
      final twice = stem(once, languageCode: 'en');
      expect(once, equals(twice));
    });

    // ── WI-6: language-aware stemming ───────────────────────────────────────

    test('French: chats/chiens → chat/chien', () {
      expect(
        stem(['chats', 'chiens'], languageCode: 'fr'),
        equals(['chat', 'chien']),
      );
    });

    test('German: Häuser → Haus', () {
      expect(stem(['Häuser'], languageCode: 'de'), equals(['Haus']));
    });

    test('Spanish: gatos → gat', () {
      expect(stem(['gatos'], languageCode: 'es'), equals(['gat']));
    });

    test('null languageCode skips stemming entirely (tokens unchanged)', () {
      expect(
        stem(['running', 'jumps'], languageCode: null),
        equals(['running', 'jumps']),
      );
    });

    test('unsupported languageCode (no Snowball algorithm) skips stemming '
        'entirely rather than falling back to English', () {
      // 'ja' (Japanese) has no Snowball algorithm in betto_lexical's
      // Stemmer — this must not throw and must not silently apply the
      // English stemmer.
      expect(
        stem(['running', 'jumps'], languageCode: 'ja'),
        equals(['running', 'jumps']),
      );
    });

    test('repeated calls with an unsupported languageCode do not re-throw '
        '(cached ArgumentError miss)', () {
      expect(() => stem(['a'], languageCode: 'zh'), returnsNormally);
      expect(() => stem(['b'], languageCode: 'zh'), returnsNormally);
    });

    test('en behaviour is unaffected by other cached languages', () {
      // Prime the cache with a non-English language, then confirm English
      // stemming still works correctly (cache keyed correctly per language).
      stem(['chats'], languageCode: 'fr');
      expect(stem(['running'], languageCode: 'en'), equals(['run']));
    });
  });

  // ── preprocess (full pipeline) ──────────────────────────────────────────────

  group('preprocess', () {
    test('empty string returns empty list', () {
      expect(preprocess('', tokenizer, languageCode: 'en'), isEmpty);
    });

    test('stop-word filtering disabled by default', () {
      // 'the' and 'is' should survive without stopWords option.
      final result = preprocess(
        'the dog is running',
        tokenizer,
        languageCode: 'en',
      );
      // 'the' → stem('the') = 'the'; 'is' → stem('is') = 'is'
      expect(result, contains('the'));
      expect(result, contains('is'));
    });

    test('stop-word filtering removes stop words when enabled', () {
      final result = preprocess(
        'the dog is running',
        tokenizer,
        stopWords: defaultStopwords.listing,
        languageCode: 'en',
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
          tokenizer,
          stopWords: defaultStopwords.listing,
          languageCode: 'en',
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
      final result = preprocess('mTLS protocol', tokenizer, languageCode: 'en');
      expect(result.length, greaterThan(0));
    });

    test('hex identifier survives pipeline (0x8004210B)', () {
      // RegExpTokenizer strips non-word chars; '0x8004210B' → '0x8004210B'
      // (one token). The pipeline must not panic.
      final result = preprocess(
        'error code 0x8004210B',
        tokenizer,
        languageCode: 'en',
      );
      expect(result.length, greaterThan(0));
    });

    test('query with all stop words returns empty list when filtering on', () {
      final result = preprocess(
        'the and is',
        tokenizer,
        stopWords: defaultStopwords.listing,
        languageCode: 'en',
      );
      expect(result, isEmpty);
    });

    test('identical input produces identical output (index == query path)', () {
      const text = 'full text search is powerful';
      final indexed = preprocess(
        text,
        tokenizer,
        stopWords: defaultStopwords.listing,
        languageCode: 'en',
      );
      final queried = preprocess(
        text,
        tokenizer,
        stopWords: defaultStopwords.listing,
        languageCode: 'en',
      );
      expect(indexed, equals(queried));
    });

    // ── WI-6: language-aware stemming ───────────────────────────────────────

    test('French text is stemmed with the French Snowball algorithm', () {
      final result = preprocess(
        'Les chats et les chiens',
        tokenizer,
        languageCode: 'fr',
      );
      expect(result, containsAll(['chat', 'chien']));
    });

    test('null languageCode leaves tokens unstemmed', () {
      final result = preprocess('running jumps', tokenizer, languageCode: null);
      expect(result, equals(['running', 'jumps']));
    });

    test(
      'unsupported languageCode leaves tokens unstemmed (no English fallback)',
      () {
        final result = preprocess(
          'running jumps',
          tokenizer,
          languageCode: 'ja',
        );
        expect(result, equals(['running', 'jumps']));
      },
    );
  });
}
