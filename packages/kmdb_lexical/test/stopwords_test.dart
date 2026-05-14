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
// ── kEnglishStopWords constant ─────────────────────────────────────────────
import 'package:intl/locale.dart';
import 'package:kmdb_lexical/lexical.dart' show getStopWords;
import 'package:test/test.dart';

void main() {
  final defaultStopwords = getStopWords(Locale.fromSubtags(languageCode: 'en'));
  group('defaultStopwords', () {
    test('contains common function words', () {
      for (final word in ['the', 'is', 'and', 'a', 'an', 'in', 'of', 'to']) {
        expect(defaultStopwords.listing, contains(word));
      }
    });

    test('does not contain content words', () {
      for (final word in ['dog', 'fast', 'database', 'search']) {
        expect(defaultStopwords.listing, isNot(contains(word)));
      }
    });
  });
}
