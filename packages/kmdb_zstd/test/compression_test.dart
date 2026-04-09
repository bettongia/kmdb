// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:kmdb_zstd/zstd.dart';

void main() {
  group('ZstdSimple', () {
    late ZstdSimple zstd;

    setUp(() {
      zstd = ZstdSimple();
    });

    test('version is correct', () {
      expect(zstd.version, isNotEmpty);
    });

    test('min and max compression levels are valid', () {
      expect(minCLevel(), lessThanOrEqualTo(maxCLevel()));
    });

    test('compress and decompress random bytes', () {
      final random = Random(42);
      final original = Uint8List.fromList(
        List.generate(1024, (_) => random.nextInt(256)),
      );

      final compressed = zstd.compress(original);
      expect(compressed, isNot(equals(original)));

      final decompressed = zstd.decompress(compressed);
      expect(decompressed, equals(original));
    });

    test('compress and decompress empty list', () {
      final original = Uint8List(0);
      final compressed = zstd.compress(original);
      final decompressed = zstd.decompress(compressed);
      expect(decompressed, equals(original));
    });

    test('invalid compression level throws ArgumentError', () {
      expect(() => ZstdSimple(level: 1000), throwsArgumentError);
      expect(() => ZstdSimple(level: -200000), throwsArgumentError);
    });

    test('decompressing invalid data throws Exception', () {
      final invalidData = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(() => zstd.decompress(invalidData), throwsException);
    });
  });
}
