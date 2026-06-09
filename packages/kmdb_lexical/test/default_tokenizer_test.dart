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

import 'package:kmdb_lexical/lexical.dart';
import 'package:test/test.dart';

void main() {
  group('createDefaultTokenizer', () {
    // In the CI environment (native), createDefaultTokenizer() resolves to
    // RegExpTokenizer(). On web it resolves to BrowserTokenizer() — that path
    // is exercised by betto_icu's own test suite and the conditional-export
    // structure is identical to the pattern already proven there.
    test('returns a working Tokenizer that segments an English sentence', () {
      final tokenizer = createDefaultTokenizer();
      expect(tokenizer, isA<Tokenizer>());

      final tokens = tokenizer.tokenise('The quick brown fox');
      expect(tokens, containsAll(['The', 'quick', 'brown', 'fox']));
    });

    test('tokenises technical identifiers', () {
      final tokenizer = createDefaultTokenizer();
      final tokens = tokenizer.tokenise('mTLS 0x8004210B');
      // Both RegExpTokenizer and BrowserTokenizer treat these as word tokens.
      expect(tokens, isNotEmpty);
    });

    test('returns empty list for empty input', () {
      final tokenizer = createDefaultTokenizer();
      expect(tokenizer.tokenise(''), isEmpty);
    });

    test('returns empty list for whitespace-only input', () {
      final tokenizer = createDefaultTokenizer();
      expect(tokenizer.tokenise('   '), isEmpty);
    });

    test('successive calls return independent tokenizers', () {
      // Ensures the factory is side-effect-free and creates new instances.
      final t1 = createDefaultTokenizer();
      final t2 = createDefaultTokenizer();
      expect(t1, isNot(same(t2)));
      expect(t1.tokenise('hello world'), equals(t2.tokenise('hello world')));
    });
  });
}
