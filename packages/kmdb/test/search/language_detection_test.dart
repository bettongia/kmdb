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

import 'package:kmdb/src/search/language_detection.dart';
import 'package:test/test.dart';

void main() {
  group(
    'detectLanguageForStemming — well-separated detections are trusted',
    () {
      test('English prose with real sentence structure', () {
        final result = detectLanguageForStemming(
          'The quick brown fox jumps over the lazy dog near the riverbank.',
        );
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, equals('en'));
      });

      test('French prose with real sentence structure', () {
        final result = detectLanguageForStemming(
          'trouver tous les documents correspondant à cette recherche',
        );
        expect(result.stemmerLanguageCode, equals('fr'));
        expect(result.confidentLanguageCode, equals('fr'));
      });

      test('short but well-separated French phrase', () {
        final result = detectLanguageForStemming('maison rouge');
        expect(result.stemmerLanguageCode, equals('fr'));
        expect(result.confidentLanguageCode, equals('fr'));
      });
    },
  );

  group(
    'detectLanguageForStemming — ambiguous keyword-style text defaults to en',
    () {
      // These are the exact failure cases found empirically against
      // betto_lang_detector 0.1.0-dev.1: each reports a *different* wrong
      // language at a spuriously high raw confidence (a degenerate tie), but
      // has a narrow margin over the runner-up — this is precisely what the
      // margin gate exists to catch. See language_detection.dart's doc
      // comment for the full rationale.
      test('single ambiguous word', () {
        final result = detectLanguageForStemming('test');
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });

      test('two-word keyword phrase with no function words', () {
        final result = detectLanguageForStemming('machine learning');
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });

      test('longer keyword-only phrase (no function words)', () {
        final result = detectLanguageForStemming(
          'database query result filter',
        );
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });

      test('an 8-word keyword-only phrase still has no reliable signal', () {
        final result = detectLanguageForStemming(
          'database query result filter sort limit offset page',
        );
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });
    },
  );

  group(
    'detectLanguageForStemming — single words never override the en default '
    '(2026-07-07 follow-up)',
    () {
      // Each of these single words was found to break a pre-existing FTS/
      // vault-search test: the margin gate alone trusted a *different* wrong
      // language for each, at a margin comfortably above _kMinDetectionMargin
      // (0.12) — see language_detection.dart's doc comment for the full
      // evidence table (e.g. "quick" -> la at margin 0.309). A single word
      // gives the n-gram model too little signal for its margin to be
      // meaningful, however large it looks, so the word-count gate rejects
      // all of these regardless of margin.
      for (final word in [
        'quick',
        'searchable',
        'machine',
        'lazy',
        'stable',
        'removed',
        'rebuild',
      ]) {
        test('"$word" defaults to en, not a spuriously-margined guess', () {
          final result = detectLanguageForStemming(word);
          expect(result.stemmerLanguageCode, equals('en'));
          expect(result.confidentLanguageCode, isNull);
        });
      }
    },
  );

  group(
    'detectLanguageForStemming — winner must be a Stemmer-supported language '
    '(2026-07-07 follow-up 2)',
    () {
      test('a Latin-derived English technical phrase that the n-gram model '
          'confidently (and wrongly) scores as Latin defaults to en', () {
        // "idempotent test content" clears the word-count gate (3 words)
        // and the margin gate (0.197 > 0.12), landing on `la` (Latin) — a
        // language betto_lexical's Stemmer does not implement. Trusting it
        // would silently skip stemming for this call while a same-content
        // single-word query ("idempotent", gated to `en`) *would* stem —
        // a write/query mismatch. See the library doc comment's second
        // 2026-07-07 follow-up for the full evidence, including why no
        // margin/word-count threshold alone can separate this from the
        // legitimate French "maison rouge" case above.
        final result = detectLanguageForStemming('idempotent test content');
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });

      test('the same word alone also defaults to en (word-count gate, '
          'independently sufficient)', () {
        final result = detectLanguageForStemming('idempotent');
        expect(result.stemmerLanguageCode, equals('en'));
        expect(result.confidentLanguageCode, isNull);
      });
    },
  );

  group('detectLanguageForStemming — input sampling (§18 latency)', () {
    test('a very large field value does not error and still detects correctly '
        '(the n-gram stage has no internal cap, so this exercises the local '
        'sampling cap rather than an unbounded scan)', () {
      // A large English document (well past the 5,000-character sample
      // cap). Repeating a real sentence keeps genuine word-boundary
      // structure, unlike a naive repeated single word.
      final huge = ('The quick brown fox jumps over the lazy dog. ' * 500);
      expect(huge.length, greaterThan(5000));
      final result = detectLanguageForStemming(huge);
      expect(result.stemmerLanguageCode, equals('en'));
      expect(result.confidentLanguageCode, equals('en'));
    });
  });

  group('detectLanguageForStemming — edge cases', () {
    test('empty string defaults to en with no confident code', () {
      final result = detectLanguageForStemming('');
      expect(result.stemmerLanguageCode, equals('en'));
      expect(result.confidentLanguageCode, isNull);
    });

    test('digits/punctuation-only input defaults to en', () {
      final result = detectLanguageForStemming('12345 !@#\$%');
      expect(result.stemmerLanguageCode, equals('en'));
      expect(result.confidentLanguageCode, isNull);
    });

    test(
      'script-exclusive language (Greek) is trusted with a single candidate',
      () {
        // Greek script resolves via the script pre-filter alone (a
        // deterministic Unicode-property lookup), short-circuiting before
        // the n-gram stage — Detected.ranked has exactly one entry, so there
        // is no runner-up to compute a margin against and no degenerate-tie
        // failure mode to guard against.
        final result = detectLanguageForStemming('Καλημέρα κόσμε');
        expect(result.stemmerLanguageCode, equals('el'));
        expect(result.confidentLanguageCode, equals('el'));
      },
    );

    test('stemmerLanguageCode is never null', () {
      // Type-level guarantee (non-nullable field), exercised here across a
      // representative spread of inputs already covered above plus a fresh
      // one, to document the invariant explicitly.
      for (final text in ['', 'test', 'hello world', 'maison rouge']) {
        expect(
          detectLanguageForStemming(text).stemmerLanguageCode,
          isA<String>(),
        );
      }
    });
  });
}
