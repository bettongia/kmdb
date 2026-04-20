// Copyright 2024 The KMDB Authors
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

import 'package:intl/intl.dart';
import 'package:intl/locale.dart';
import 'package:kmdb_util/util.dart';

import 'package:test/test.dart';

void main() {
  group('IntlString', () {
    test('Constructor - default locale', () async {
      Intl.defaultLocale = 'en_AU';

      final s = IntlString('hello');

      final locale = Locale.tryParse('en_AU');

      expect(s.value, 'hello');
      expect(s.locale, locale);
    });

    test('Constructor - supplied locale', () async {
      final locale = Locale.tryParse('en-AU');

      final s = IntlString('hello', locale: locale);

      expect(s.value, 'hello');
      expect(s.locale, locale);

      expect(s.toString(), {'value': 'hello', 'locale': 'en-AU'}.toString());
    });

    test('Constructor - supplied locale using tryParseLocale', () async {
      final locale = IntlString.tryParseLocale('en-AU');

      final s = IntlString('hello', locale: locale);

      expect(s.value, 'hello');
      expect(s.locale, locale);

      expect(s.toString(), {'value': 'hello', 'locale': 'en-AU'}.toString());
    });

    test('Equality', () async {
      final locale = Locale.tryParse('en_AU');

      final s1 = IntlString('hello', locale: locale);
      final s2 = IntlString('hello', locale: locale);

      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(s1.toString(), equals(s2.toString()));
      expect(s1 == s2, true);
    });
  });

  group('IntlStrings', () {
    final en = Locale.fromSubtags(languageCode: 'en');
    final au = Locale.fromSubtags(languageCode: 'en', countryCode: 'AU');
    final nz = Locale.fromSubtags(languageCode: 'en', countryCode: 'NZ');
    final us = Locale.fromSubtags(languageCode: 'en', countryCode: 'US');
    final de = Locale.fromSubtags(languageCode: 'de');
    final japanese = Locale.fromSubtags(languageCode: 'ja', countryCode: 'JP');

    test('empty', () async {
      final s = IntlStrings([]);
      expect(s.fallbackLocale, Locale.fromSubtags(languageCode: 'en'));
    });

    test('hello', () async {
      final s = IntlStrings([
        IntlString('hello', locale: en),
        IntlString("g'day", locale: au),
        IntlString('hallo', locale: de),
      ], defaultLocale: au);
      expect(s.fallbackLocale, Locale.fromSubtags(languageCode: 'en'));
      expect(
        s.defaultLocale,
        Locale.fromSubtags(languageCode: 'en', countryCode: 'AU'),
      );

      expect(s.locales, [en, au, de]);

      expect(s(), "g'day");
      expect(s(locale: au), "g'day");
      expect(s(locale: us), 'hello');
      expect(s(locale: nz), 'hello');
      expect(s(locale: japanese), 'hello');
      expect(s(locale: de), 'hallo');

      expect(s.string, "g'day");
      expect(s.getString().value, IntlString("g'day", locale: au));
      expect(s.getString(locale: au).value, IntlString("g'day", locale: au));
      expect(s.getString(locale: us).value, IntlString('hello', locale: en));
      expect(s.getString(locale: nz).value, IntlString('hello', locale: en));
      expect(
        s.getString(locale: japanese).value,
        IntlString('hello', locale: en),
      );
      expect(s.getString(locale: de).value, IntlString('hallo', locale: de));
    });

    test('hello - set default Locale', () async {
      Intl.withLocale('de', () {
        final s = IntlStrings([
          IntlString('hello', locale: en),
          IntlString('hallo', locale: de),
        ]);
        expect(s.string, 'hallo');
        expect(s.getString().value, IntlString('hallo', locale: de));
      });
    });

    test('failure', () async {
      final s = IntlStrings([
        IntlString("g'day", locale: au),
        IntlString('hallo', locale: de),
      ]);

      expect(s.getString(locale: us).exception, isA<IntlStringException>());
    });
  });
}
