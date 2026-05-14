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

const hexValues = {
  '0',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  'a',
  'b',
  'c',
  'd',
  'e',
  'f',
  'A',
  'B',
  'C',
  'D',
  'E',
  'F',
};

bool isValidHexString(String value) {
  if (value.isEmpty) {
    return false;
  }
  String test;
  if (value.startsWith('0x')) {
    test = value.substring(2);
  } else {
    test = value;
  }
  for (var c in test.characters) {
    if (!hexValues.contains(c)) {
      return false;
    }
  }
  return true;
}
