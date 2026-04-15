// Copyright 2026 The Aurochs KMesh Authors
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
// ignore: avoid_relative_lib_imports
import 'third_party/snowball_stemmer/lib/snowball_stemmer.dart';

class Stemmer {
  final Locale _locale;
  final SnowballStemmer _stemmer;

  Stemmer._internal(Locale locale, SnowballStemmer stemmer)
    : _locale = locale,
      _stemmer = stemmer;

  factory Stemmer(Locale locale) {
    switch (locale.languageCode) {
      case 'en':
        return Stemmer._internal(locale, SnowballStemmer(Algorithm.english));
    }
    throw ArgumentError.value(
      'The requested locale with language code ${locale.languageCode}'
      ' is not currently supported.',
    );
  }

  String stem(String word) {
    return _stemmer.stem(word);
  }

  String get languageCode => _locale.languageCode;
}
