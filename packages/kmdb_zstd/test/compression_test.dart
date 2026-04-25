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

    test('compress and decompress at minimum compression level', () {
      final zstdMin = ZstdSimple(level: minCLevel());
      final original = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
      final decompressed = zstdMin.decompress(zstdMin.compress(original));
      expect(decompressed, equals(original));
    });

    test('compress and decompress at maximum compression level', () {
      final zstdMax = ZstdSimple(level: maxCLevel());
      final original = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
      final decompressed = zstdMax.decompress(zstdMax.compress(original));
      expect(decompressed, equals(original));
    });

    test('just below minimum level throws ArgumentError', () {
      expect(() => ZstdSimple(level: minCLevel() - 1), throwsArgumentError);
    });

    test('just above maximum level throws ArgumentError', () {
      expect(() => ZstdSimple(level: maxCLevel() + 1), throwsArgumentError);
    });

    test('truncated compressed data throws Exception', () {
      final original = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      final compressed = zstd.compress(original);
      // Keep the header (so getFrameContentSize returns the real size) but
      // cut the payload so decompress fails mid-stream.
      final truncated = compressed.sublist(0, compressed.length ~/ 2);
      expect(() => zstd.decompress(truncated), throwsException);
    });

    test('single byte round-trip', () {
      final original = Uint8List.fromList([0x42]);
      final decompressed = zstd.decompress(zstd.compress(original));
      expect(decompressed, equals(original));
    });

    test('highly compressible data produces smaller output', () {
      // All-zero bytes compress extremely well.
      final original = Uint8List(4096);
      final compressed = zstd.compress(original);
      expect(compressed.length, lessThan(original.length));
    });

    test('compress returns Uint8List', () {
      final result = zstd.compress(Uint8List.fromList([1, 2, 3]));
      expect(result, isA<Uint8List>());
    });

    test('decompress returns Uint8List', () {
      final compressed = zstd.compress(Uint8List.fromList([1, 2, 3]));
      final result = zstd.decompress(compressed);
      expect(result, isA<Uint8List>());
    });
  });
}
