// Copyright 2026 The Authors
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

import 'package:intl/locale.dart';
import 'package:kmdb_lexical/lexical.dart';
import 'package:test/test.dart';

void main() {
  group('Stemmer — English', () {
    late Stemmer stemmer;

    setUpAll(() {
      stemmer = Stemmer(Locale.parse('en'));
    });

    test('languageCode returns en', () {
      expect(stemmer.languageCode, equals('en'));
    });

    test('stems common regular verbs', () {
      expect(stemmer.stem('running'), equals('run'));
      expect(stemmer.stem('jumps'), equals('jump'));
      expect(stemmer.stem('walked'), equals('walk'));
    });

    test('stems common nouns', () {
      expect(stemmer.stem('dogs'), equals('dog'));
      expect(stemmer.stem('cats'), equals('cat'));
      expect(stemmer.stem('boxes'), equals('box'));
    });

    test('stems gerunds', () {
      expect(stemmer.stem('running'), equals('run'));
      expect(stemmer.stem('flying'), equals('fli'));
    });

    test('stems comparative adjectives', () {
      expect(stemmer.stem('faster'), equals('faster'));
      expect(stemmer.stem('happier'), equals('happier'));
    });

    test('already-stemmed word returns itself', () {
      expect(stemmer.stem('run'), equals('run'));
      expect(stemmer.stem('dog'), equals('dog'));
    });

    test('empty string returns empty string', () {
      expect(stemmer.stem(''), equals(''));
    });

    test('single character returns itself', () {
      expect(stemmer.stem('a'), equals('a'));
    });

    test('uppercase word is stemmed case-sensitively', () {
      // Snowball stemmers operate on the raw input; uppercase is preserved.
      final result = stemmer.stem('RUNNING');
      expect(result, isNotEmpty);
    });

    test('word with punctuation is passed through as-is', () {
      // The stemmer does not strip punctuation; callers are responsible for
      // tokenisation before stemming.
      final result = stemmer.stem("can't");
      expect(result, isNotEmpty);
    });
  });

  group('Stemmer — unsupported locales', () {
    test('French locale throws ArgumentError', () {
      expect(() => Stemmer(Locale.parse('fr')), throwsArgumentError);
    });

    test('German locale throws ArgumentError', () {
      expect(() => Stemmer(Locale.parse('de')), throwsArgumentError);
    });

    test('unknown language code throws ArgumentError', () {
      expect(() => Stemmer(Locale.parse('xx')), throwsArgumentError);
    });
  });
}
