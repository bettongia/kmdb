/*
 Copyright 2024 The KMDB Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'package:intl/locale.dart';

import 'mapper.dart';
import 'result.dart';

/// Returns the current locale.
///
/// Used as the default in the [IntlString] constructor.
Locale getCurrentLocale() => Locale.parse(Intl.getCurrentLocale());

/// Aligns a String with its locale
class IntlString implements MappedObject<String> {
  /// The value of the string
  final String value;

  /// The language tag backing the string
  final String? _languageTag;

  /// The locale of the string
  Locale get locale =>
      _languageTag != null ? Locale.parse(_languageTag) : getCurrentLocale();

  /// Constructor
  ///
  /// Notes:
  ///
  /// - If [locale] is not set or is null, [currentLocaleFunction] will be used.
  /// - If [currentLocaleFunction] is not null, it will be called to get the
  /// current locale.
  /// - If [Locale] is set, it will be used and [currentLocaleFunction] will
  ///   be ignored.
  IntlString(
    this.value, {
    Locale? locale,
    Locale Function()? currentLocaleFunction,
  }) : _languageTag =
           (locale ??
                   (currentLocaleFunction != null
                       ? currentLocaleFunction()
                       : getCurrentLocale()))
               .toLanguageTag();

  /// A strict const constructor for static code-generation.
  const IntlString.constant(this.value, {String? languageTag})
    : _languageTag = languageTag;

  /// Return `true` if the [localeIdentifier] can be parsed, null otherwise.
  static Locale? tryParseLocale(String localeIdentifier) =>
      Locale.tryParse(localeIdentifier);

  @override
  bool operator ==(Object other) =>
      other is IntlString &&
      other.runtimeType == runtimeType &&
      other.value == value &&
      other.locale == locale;

  @override
  int get hashCode => Object.hashAll([value, locale]);

  @override
  String toString() => toMap().toString();

  @override
  Map<String, String> toMap() => {
    'value': value,
    'locale': locale.toLanguageTag(),
  };
}

/// A map of locales to IntlStrings
class IntlStrings implements MappedObject<Map<String, String>> {
  /// A map of locales to IntlStrings
  final Map<Locale, IntlString> _strings;

  /// The default locale to use when a locale isn't requested
  final Locale defaultLocale;

  /// The locale to use when no match is found - 'en' by default
  final Locale fallbackLocale;

  /// Constructor
  ///
  /// Notes:
  ///
  /// - If [locale] is not set or is null, [currentLocaleFunction] will be used.
  /// - If [currentLocaleFunction] is not null, it will be called to get the
  ///   current locale.
  /// - If [Locale] is set, it will be used and [currentLocaleFunction] will
  ///   be ignored.
  IntlStrings(
    List<IntlString> values, {
    Locale? defaultLocale,
    Locale Function()? currentLocaleFunction,
    Locale? fallbackLocale,
  }) : _strings = Map.fromEntries(values.map((s) => MapEntry(s.locale, s))),
       defaultLocale =
           defaultLocale ??
           (currentLocaleFunction != null
               ? currentLocaleFunction()
               : getCurrentLocale()),
       fallbackLocale =
           fallbackLocale ?? Locale.fromSubtags(languageCode: 'en');

  /// Given a locale, return the corresponding IntlString if it exists.
  ///
  /// If not, it will return the first IntlString that matches the locale's
  /// language (but not region).
  ///
  /// As a final try, it will return the IntlString that matches the
  /// [fallbackLocale].
  ///
  /// If no match can be found, a [Failure] [Result] will be returned.
  ///
  /// If [locale] is not set or is null, the [defaultLocale] will be used
  Result<IntlString, IntlStringException> getString({Locale? locale}) {
    locale ??= defaultLocale;

    var v = _strings[locale];

    if (v != null) {
      return Success(v);
    }

    Locale ll = Locale.parse(Intl.shortLocale(locale.toLanguageTag()));

    v = _strings[ll];

    if (v != null) {
      return Success(v);
    }

    v = _strings[fallbackLocale];
    if (v != null) {
      return Success(v);
    }

    return Failure(
      IntlStringException(
        IntlStringException.noValueFound(locale.toLanguageTag()),
      ),
    );
  }

  /// Convenience property to call [call] with no locale
  String? get string => call();

  /// Convenience method to call [getString]
  String? call({Locale? locale}) {
    final result = getString(locale: locale).value;
    if (result != null) {
      return result.value;
    }
    return null;
  }

  /// The list of all mapped locales
  Set<Locale?> get locales => UnmodifiableSetView(_strings.keys.toSet());

  @override
  Map<String, Map<String, String>> toMap() {
    return _strings.map(
      (locale, value) => MapEntry(locale.toLanguageTag(), value.toMap()),
    );
  }
}

class IntlStringException implements Exception {
  final String message;
  IntlStringException(this.message);

  static String noValueFound(String languageTag) => Intl.message(
    'No value found for locale $languageTag',
    args: [languageTag],
    name: 'IntlStringException_noValueFound',
  );
}
