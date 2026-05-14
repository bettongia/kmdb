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
import 'dart:collection' show UnmodifiableMapView;

import 'package:characters/characters.dart' show StringCharacters;

import 'package:intl/intl.dart';
import 'formats/duration.dart' show isValidDuration;

import 'package:uuid/validation.dart';

import 'formats/email.dart' show isValidEmail;
import 'formats/hex.dart';
import 'formats/isbn.dart' show isValidIsbn13;
import 'formats/roman.dart';

class StringValidator {
  final String name;
  final String description;
  final bool Function(String) function;

  StringValidator(this.name, this.description, this.function);
}

abstract class StringValidatorService {
  Map<String, StringValidator> get supportedValidators;
  StringValidator? getValidator(String name);
}

class StringFormatValidator implements StringValidatorService {
  @override
  Map<String, StringValidator> get supportedValidators =>
      UnmodifiableMapView(_supportedValidators);

  @override
  StringValidator? getValidator(String name) => _supportedValidators[name];

  final _supportedValidators = {
    'uri': StringValidator(
      'uri',
      'A string instance is valid against this attribute if it is a valid URI,'
          ' according to RFC3986',
      (value) => Uri.tryParse(value) != null ? true : false,
    ),
    'duration': StringValidator(
      'duration',
      'A string instance is valid against this attribute if it is a valid '
          'representation according to RFC3339',
      isValidDuration,
    ),
    'email': StringValidator(
      'email',
      'A string instance is valid against this attribute if it is a valid '
          'representation of a pragmatic subset of RFC 5322',
      isValidEmail,
    ),
    'date-time': StringValidator(
      'date-time',
      'A string instance is valid against this attribute if it is a valid '
          'representation according to the "date-time" ABNF rule in ISO8601',
      (value) => DateTime.tryParse(value) != null ? true : false,
    ),
    'date': StringValidator(
      'date',
      'A string instance is valid against this attribute if it is a valid '
          'representation according to the "date" ABNF rule in RFC3339',
      isValidDate,
    ),
    'time': StringValidator(
      'time',
      'A string instance is valid against this attribute if it is a valid '
          'representation according to the "time" ABNF rule in RFC3339',
      (value) => DateFormat('HH:mm:ss.SSS').tryParseStrict(value) != null,
    ),
    'uuid': StringValidator(
      'uuid',
      'A string instance is valid against this attribute if it is a valid '
          'string representation of a UUID, according to RFC9562',
      (value) => UuidValidation.isValidUUID(fromString: value, noDashes: false),
    ),
    'regex': StringValidator(
      'regex',
      'A regular expression, which SHOULD be valid '
          'according to the ECMA-262 [ecma262] regular expression dialect.',
      isValidRegex,
    ),
    'hex-string': StringValidator(
      'hex-string',
      'The string represents a valid '
          'series of characters for a hexadecimal number',
      isValidHexString,
    ),
    'digit-string': StringValidator(
      'digit-string',
      'The string represents a valid '
          'series of characters for a decimal number',
      isValidDigitString,
    ),
    'roman-numeral': StringValidator(
      'roman-numeral',
      'The string represents a valid '
          'series of characters for a Roman numeral',
      isValidRomanNumeral,
    ),
    'isbn-13': StringValidator(
      'isbn-13',
      'The string represents a valid'
          ' International Standard Book Number (ISBN) if it meets the '
          'required check digit calculation',
      isValidIsbn13,
    ),
  };
}

bool isValidRegex(String value) {
  try {
    RegExp(value);
  } on FormatException {
    return false;
  }
  return true;
}

bool isValidDate(String value) {
  // Reject anything that isn't strictly YYYY-MM-DD.
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final d = DateTime.tryParse(value);
  if (d == null) return false;
  // Reject overflow dates (e.g. month 13) by re-formatting and comparing.
  final reformatted =
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return reformatted == value;
}

/// A string that only contains decimal (0-9)digits.
///
/// Does not handle fingers, thumbs or toes.
bool isValidDigitString(String value) {
  for (var c in value.characters) {
    var val = int.tryParse(c);
    if (val == null) {
      return false;
    }
  }
  return true;
}
