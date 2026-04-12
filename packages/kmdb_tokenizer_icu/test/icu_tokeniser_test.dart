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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart';
import 'package:test/test.dart';

void main() {
  // Run the shared Tokeniser contract tests against both implementations.
  _tokeniserContractTests('IcuTokeniser', IcuTokeniser());
  _tokeniserContractTests('RegExpTokeniser', const RegExpTokeniser());

  // ICU-specific behaviour: verify that UAX #29 WORD rules fire correctly for
  // cases that motivated the ICU choice over a plain regexp.
  group('IcuTokeniser — UAX #29 specifics', () {
    late IcuTokeniser icu;

    setUpAll(() => icu = IcuTokeniser());

    test('keeps hex literal as a single token', () {
      // ICU WORD rules treat "0x8004210B" as a single numeric token.
      final tokens = icu.tokenise('error 0x8004210B');
      expect(tokens, contains('0x8004210B'));
    });

    test('keeps mTLS as a single token', () {
      final tokens = icu.tokenise('mTLS handshake');
      expect(tokens, contains('mTLS'));
    });

    test('punctuation and whitespace are not returned as tokens', () {
      final tokens = icu.tokenise('Hello, world! How are you?');
      for (final t in tokens) {
        expect(t.trim(), isNotEmpty);
        expect(t, isNot(contains(',')));
        expect(t, isNot(contains('!')));
        expect(t, isNot(contains('?')));
      }
    });

    test('numeric token is returned', () {
      final tokens = icu.tokenise('published in 1886.');
      expect(tokens, contains('1886'));
    });

    test('implements Tokeniser interface', () {
      expect(icu, isA<Tokeniser>());
    });
  });
}

/// Shared contract tests run against both [IcuTokeniser] and [RegExpTokeniser].
///
/// Any [Tokeniser] implementation must satisfy these invariants.
void _tokeniserContractTests(String label, Tokeniser t) {
  group('$label — Tokeniser contract', () {
    test('empty string returns empty list', () {
      expect(t.tokenise(''), isEmpty);
    });

    test('whitespace-only string returns empty list', () {
      expect(t.tokenise('   \t\n  '), isEmpty);
    });

    test('single word', () {
      expect(t.tokenise('Jekyll'), equals(['Jekyll']));
    });

    test('strips trailing punctuation', () {
      // "Hyde," should yield "Hyde", not "Hyde,"
      final tokens = t.tokenise('Hyde,');
      expect(tokens, isNotEmpty);
      expect(tokens.first, isNot(endsWith(',')));
    });

    test('prose sentence — returns only word tokens', () {
      const sentence =
          '"The Strange Case of Dr. Jekyll and Mr. Hyde" by Robert Louis Stevenson.';
      final tokens = t.tokenise(sentence);
      // Key words must be present
      expect(tokens, containsAll(['The', 'Strange', 'Case', 'Jekyll', 'Hyde']));
      // Punctuation-only entries must not appear
      expect(tokens, everyElement(isNot(equals('"'))));
      expect(tokens, everyElement(isNot(equals('.'))));
    });

    test('multiple spaces between words', () {
      final tokens = t.tokenise('Jekyll   Hyde');
      expect(tokens, equals(['Jekyll', 'Hyde']));
    });

    test('numbers are included', () {
      final tokens = t.tokenise('published in 1886');
      expect(tokens, contains('1886'));
    });
  });
}
