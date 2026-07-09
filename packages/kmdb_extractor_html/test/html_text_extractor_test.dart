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

/// Unit tests for [HtmlTextExtractor], calling `extract()` directly (no
/// isolate) against the synthetic fixtures in `test/fixtures/`.
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_html/kmdb_extractor_html.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Reads a fixture file's bytes relative to `test/fixtures/`.
Future<Uint8List> _fixture(String relativePath) async {
  final file = File('test/fixtures/$relativePath');
  return file.readAsBytes();
}

/// A minimal [VaultManifest] for a `.html` blob — the extractor does not
/// inspect manifest fields, but the interface requires one.
VaultManifest _manifest(String originalName) => VaultManifest(
  sha256: 'a' * 64,
  size: 0,
  crc32c: '00000000',
  mediaType: 'text/html',
  originalName: originalName,
  createdAt: '2026-01-01T00:00:00.000Z',
);

void main() {
  group('HtmlTextExtractor', () {
    test('supportedMediaTypes is exactly text/html', () {
      const extractor = HtmlTextExtractor();
      expect(extractor.supportedMediaTypes, equals({'text/html'}));
    });

    // ── Golden path — no token fusion across block boundaries ──────────

    test(
      'golden_path.html — nested block/inline elements, no token fusion',
      () async {
        const extractor = HtmlTextExtractor();
        final bytes = await _fixture('golden_path.html');

        final text = await extractor.extract(
          bytes,
          _manifest('golden_path.html'),
        );

        expect(text, isNotNull);
        expect(text, contains('Section Heading'));
        expect(text, contains('Hello bold and italic world.'));
        expect(text, contains('Second paragraph.'));
        expect(text, contains('First item'));
        expect(text, contains('Second item'));
        expect(text, contains('A quoted thought.'));
        // The key invariant: adjacent block elements must not fuse into one
        // run-on word — "world.Second" would indicate the walk failed to
        // insert a boundary between the two <p> elements.
        expect(text, isNot(contains('world.Second')));
        expect(text, isNot(contains('itemSecond')));
      },
    );

    test('adjacent paragraphs with no whitespace between tags do not fuse '
        '(<p>Hello</p><p>World</p> must not become "HelloWorld")', () async {
      const extractor = HtmlTextExtractor();
      final bytes = Uint8List.fromList(
        utf8.encode('<html><body><p>Hello</p><p>World</p></body></html>'),
      );

      final text = await extractor.extract(bytes, _manifest('fused.html'));

      expect(text, isNotNull);
      expect(text, isNot(contains('HelloWorld')));
      expect(text, contains('Hello'));
      expect(text, contains('World'));
    });

    // ── script/style/noscript exclusion ─────────────────────────────────

    test('script_style.html — <script>/<style>/<noscript> content excluded, '
        'prose retained', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('script_style.html');

      final text = await extractor.extract(
        bytes,
        _manifest('script_style.html'),
      );

      expect(text, isNotNull);
      expect(text, contains('Visible prose sentence.'));
      expect(text, contains('More visible prose.'));
      expect(text, isNot(contains('console-only-css-token')));
      expect(text, isNot(contains('consoleOnlyJsToken')));
      expect(text, isNot(contains('noscript-fallback-token')));
    });

    test('all_script_style.html (100% script/style/noscript) → extract() '
        'returns "" (not null)', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('all_script_style.html');

      final text = await extractor.extract(
        bytes,
        _manifest('all_script_style.html'),
      );

      expect(text, isNotNull);
      expect(text, equals(''));
    });

    // ── HTML entity decoding ─────────────────────────────────────────────

    test('entities.html — HTML entities decode correctly', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('entities.html');

      final text = await extractor.extract(bytes, _manifest('entities.html'));

      expect(text, isNotNull);
      expect(text, contains('Fish & chips <tag> "quoted" © 2026'));
      // Should not contain the raw, undecoded entity source.
      expect(text, isNot(contains('&amp;')));
      expect(text, isNot(contains('&lt;')));
    });

    // ── Malformed / unclosed tags ────────────────────────────────────────

    test('malformed.html (unclosed tags) → does not throw, produces '
        'best-effort text', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('malformed.html');

      String? text;
      await expectLater(
        () async =>
            text = await extractor.extract(bytes, _manifest('malformed.html')),
        returnsNormally,
      );

      expect(text, isNotNull);
      expect(text, contains('Unclosed paragraph one'));
      expect(text, contains('Unclosed paragraph two'));
      expect(text, contains('Unclosed div with unclosed bold text'));
    });

    // ── Empty / whitespace-only input ───────────────────────────────────

    test('empty bytes → extract() returns "" (not null)', () async {
      const extractor = HtmlTextExtractor();

      final text = await extractor.extract(
        Uint8List(0),
        _manifest('empty.html'),
      );

      expect(text, isNotNull);
      expect(text, equals(''));
    });

    test('whitespace_only.html (body with only blank lines) → extract() '
        'returns ""', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('whitespace_only.html');

      final text = await extractor.extract(
        bytes,
        _manifest('whitespace_only.html'),
      );

      expect(text, isNotNull);
      expect(text, equals(''));
    });

    // ── Fragment with no <html>/<body> wrapper ──────────────────────────

    test('fragment.html (no explicit <html>/<body> wrapper) — still extracts '
        'text correctly', () async {
      const extractor = HtmlTextExtractor();
      final bytes = await _fixture('fragment.html');

      final text = await extractor.extract(bytes, _manifest('fragment.html'));

      expect(text, isNotNull);
      expect(text, contains('Just a fragment paragraph.'));
      expect(text, contains('Another fragment paragraph.'));
    });

    // ── Never throws — general contract ─────────────────────────────────

    test('extract() never throws for arbitrary non-HTML bytes', () async {
      const extractor = HtmlTextExtractor();
      final bytes = Uint8List.fromList([0xff, 0xfe, 0x00, 0x01, 0x02]);

      String? text;
      await expectLater(
        () async =>
            text = await extractor.extract(bytes, _manifest('binary.html')),
        returnsNormally,
      );
      expect(text, isNotNull);
    });
  });
}
