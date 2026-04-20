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

import 'package:intl/intl.dart';
import 'package:intl/locale.dart';
import 'package:kmdb_util/util.dart';
import 'package:test/test.dart';

Future<void> main() async {
  group('IntlString - localised exception messages', () {
    final au = Locale.fromSubtags(languageCode: 'en', countryCode: 'AU');
    final us = Locale.fromSubtags(languageCode: 'en', countryCode: 'US');
    final de = Locale.fromSubtags(languageCode: 'de');

    final strings = IntlStrings([
      IntlString("g'day", locale: au),
      IntlString('hallo', locale: de),
    ]);
    test('failure - exception message in en', () async {
      Intl.withLocale('en', () async {
        await initializeMessages('en');
        expect(
          strings.getString(locale: us).exception!.message,
          'No value found for locale en-US',
        );
      });
    });

    test('failure - exception message in de', () async {
      Intl.withLocale('de', () async {
        await initializeMessages('de');
        expect(
          strings.getString(locale: us).exception!.message,
          'Für das Gebietsschema wurde kein Wert gefunden en-US',
        );
      });
    });
  });
}
