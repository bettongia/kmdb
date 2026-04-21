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

import 'package:characters/characters.dart';
import 'package:kmdb_schema/src/formats_base.dart' show StringFormatValidator;
import 'package:test/test.dart';

void main() {
  final validator = StringFormatValidator()
      .getValidator("hex-string")
      ?.function;
  if (validator == null) {
    throw Exception('Could not find validator');
  }
  group('HexString', () {
    var s = '0123456789abcdefABCDEF';
    for (var ch in s.characters) {
      test('Is hex: $ch', () async {
        expect(validator(ch), isTrue);
      });

      var h = '0x$ch';
      test('Is hex: $h', () async {
        expect(validator(h), isTrue);
      });
    }

    var sNon = 'ghijklmnopqrstuvwxyz😀';
    for (var ch in sNon.characters) {
      test('Is not hex: $ch', () async {
        expect(validator(ch), isFalse);
      });

      var h = '0x$ch';
      test('Is not hex: $h', () async {
        expect(validator(h), isFalse);
      });
    }
  });
}
