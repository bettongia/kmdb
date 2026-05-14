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

import 'package:characters/characters.dart';

const romanDigits = <String, int>{
  'i': 1,
  'v': 5,
  'x': 10,
  'l': 50,
  'c': 100,
  'd': 500,
  'm': 1000,
  'I': 1,
  'V': 5,
  'X': 10,
  'L': 50,
  'C': 100,
  'D': 500,
  'M': 1000,
};

/// Only a basic check of [input] is performed - namely that it is
/// not empty and contains only valid Roman numerals (as defined in
/// [romanDigits]).
bool isValidRomanNumeral(String input) {
  // Check for empty string
  if (input.isEmpty) {
    return false;
  }

  for (final c in input.characters) {
    if (!romanDigits.containsKey(c)) {
      return false;
    }
  }
  return true;
}
