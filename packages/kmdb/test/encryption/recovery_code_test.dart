// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:kmdb/src/encryption/recovery_code.dart';
import 'package:test/test.dart';

void main() {
  group('RecoveryCode.encode', () {
    test('produces a 16-word space-separated string', () {
      final entropy = Uint8List(16); // all zeros
      final code = RecoveryCode.encode(entropy);
      expect(code.split(' '), hasLength(16));
    });

    test('is deterministic', () {
      final entropy = Uint8List.fromList(List.generate(16, (i) => i));
      final c1 = RecoveryCode.encode(entropy);
      final c2 = RecoveryCode.encode(entropy);
      expect(c1, equals(c2));
    });

    test('all-zero entropy encodes to the same word 16 times', () {
      final entropy = Uint8List(16); // all zeros → word 0 = 'able'
      final code = RecoveryCode.encode(entropy);
      expect(code.split(' ').every((w) => w == 'able'), isTrue);
    });

    test('all-0xFF entropy encodes to the last word 16 times', () {
      final entropy = Uint8List(16)..fillRange(0, 16, 0xFF);
      final code = RecoveryCode.encode(entropy);
      final words = code.split(' ');
      final lastWord = words.first;
      expect(words.every((w) => w == lastWord), isTrue);
    });

    test('throws ArgumentError if entropy is not 16 bytes', () {
      expect(
        () => RecoveryCode.encode(Uint8List(15)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RecoveryCode.encode(Uint8List(17)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RecoveryCode.encode(Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('RecoveryCode.decode', () {
    test('round-trips: decode(encode(entropy)) == entropy', () {
      final entropy = Uint8List.fromList(List.generate(16, (i) => i * 15));
      final code = RecoveryCode.encode(entropy);
      final decoded = RecoveryCode.decode(code);
      expect(decoded, equals(entropy));
    });

    test('is case-insensitive (uppercase input)', () {
      final entropy = Uint8List.fromList(List.generate(16, (i) => i));
      final code = RecoveryCode.encode(entropy).toUpperCase();
      final decoded = RecoveryCode.decode(code);
      expect(decoded, equals(entropy));
    });

    test('handles extra whitespace between words', () {
      final entropy = Uint8List.fromList(List.generate(16, (i) => i));
      final code = RecoveryCode.encode(entropy);
      // Replace single spaces with double spaces.
      final spacey = code.replaceAll(' ', '  ');
      final decoded = RecoveryCode.decode(spacey);
      expect(decoded, equals(entropy));
    });

    test('throws FormatException for wrong number of words', () {
      expect(
        () => RecoveryCode.decode('able acid'),
        throwsA(isA<FormatException>()),
      );
      expect(() => RecoveryCode.decode(''), throwsA(isA<FormatException>()));
    });

    test('throws FormatException for unknown word', () {
      // 15 valid words + one invented word.
      const bad =
          'able acid aged also apex arch area army atom aunt auto axis baby back ball XXXXXX';
      expect(() => RecoveryCode.decode(bad), throwsA(isA<FormatException>()));
    });

    test('decodes all 256 distinct byte values', () {
      for (var b = 0; b < 256; b++) {
        final entropy = Uint8List(16)..fillRange(0, 16, b);
        final code = RecoveryCode.encode(entropy);
        final decoded = RecoveryCode.decode(code);
        expect(decoded, equals(entropy), reason: 'byte value $b');
      }
    });
  });
}
