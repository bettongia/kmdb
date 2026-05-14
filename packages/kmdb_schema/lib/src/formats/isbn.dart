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

import '../formats_base.dart';

/// An International Standard Book Number (ISBN).
///
/// See:
///
/// - [ISBN Users' Manual](https://www.isbn-international.org/content/isbn-users-manual/29)
/// - [OCLC International Standard Book Number](https://www.oclc.org/bibformats/en/0xx/020.html)
/// - [Administration of the ISBN System](https://isbn-information.com/administration-of-the-isbn-system.html)
bool isValidIsbn13(String value) {
  const weights = [1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3];

  if (value.characters.length != 13 || !isValidDigitString(value)) {
    return false;
  }

  final checkDigit = int.tryParse(value.characters.elementAt(12));

  if (checkDigit == null) {
    return false;
  }

  var sumProd = 0;
  for (var i = 0; i < 12; i++) {
    final val = int.tryParse(value.characters.elementAt(i));
    if (val == null) {
      return false;
    }
    sumProd += val * weights[i];
  }

  return (10 - sumProd % 10) % 10 == checkDigit;
}
