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

/// Unit tests for [PlainTextExtractor], calling `extract()` directly (no
/// isolate).
///
/// [PlainTextExtractor] is otherwise only exercised indirectly (via
/// [VaultIndexingIsolate]/[VaultSearchManager] tests); this file adds direct
/// coverage of its own [extract] behaviour, including the S-8
/// [ExtractorLimits.maxInputBytes] bound.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:kmdb/src/vault/search/extractor_limits.dart';
import 'package:kmdb/src/vault/search/plain_text_extractor.dart';
import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A minimal [VaultManifest] for a `text/plain` blob — the extractor does
/// not inspect manifest fields, but the interface requires one.
VaultManifest _manifest() => VaultManifest(
  sha256: 'a' * 64,
  size: 0,
  crc32c: '00000000',
  mediaType: 'text/plain',
  originalName: 'note.txt',
  createdAt: '2026-01-01T00:00:00.000Z',
);

void main() {
  group('PlainTextExtractor', () {
    test('supportedMediaTypes is exactly text/plain', () {
      final extractor = PlainTextExtractor();
      expect(extractor.supportedMediaTypes, equals({'text/plain'}));
    });

    test(
      'golden path — UTF-8 bytes decode and lastCharset is recorded',
      () async {
        final extractor = PlainTextExtractor();
        final bytes = Uint8List.fromList(utf8.encode('hello vault search'));

        final text = await extractor.extract(bytes, _manifest());

        expect(text, equals('hello vault search'));
        expect(extractor.lastCharset, isNotNull);
      },
    );

    test('default limits are ExtractorLimits.defaults', () {
      final extractor = PlainTextExtractor();
      expect(extractor.limits, same(ExtractorLimits.defaults));
    });

    // ── S-8: ExtractorLimits resource bounds ────────────────────────────

    group('ExtractorLimits (S-8)', () {
      test('input larger than maxInputBytes declines (null) before any '
          'decoding — a tiny limit keeps the test fast', () async {
        final extractor = PlainTextExtractor(
          limits: ExtractorLimits(
            maxInputBytes: 8,
            maxRecursionDepth: ExtractorLimits.defaults.maxRecursionDepth,
            maxDuration: ExtractorLimits.defaults.maxDuration,
          ),
        );
        final bytes = Uint8List.fromList(
          utf8.encode('this string is definitely longer than 8 bytes'),
        );
        expect(bytes.length, greaterThan(8));

        final text = await extractor.extract(bytes, _manifest());

        expect(text, isNull);
        // lastCharset must also be reset/left null — no decoding happened.
        expect(extractor.lastCharset, isNull);
      });

      test(
        'input at or below maxInputBytes is still decoded normally',
        () async {
          final bytes = Uint8List.fromList(utf8.encode('fits'));
          final extractor = PlainTextExtractor(
            limits: ExtractorLimits(
              maxInputBytes: bytes.length,
              maxRecursionDepth: ExtractorLimits.defaults.maxRecursionDepth,
              maxDuration: ExtractorLimits.defaults.maxDuration,
            ),
          );

          final text = await extractor.extract(bytes, _manifest());

          expect(text, equals('fits'));
        },
      );
    });
  });
}
