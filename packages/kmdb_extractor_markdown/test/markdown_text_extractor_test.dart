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

/// Unit tests for [MarkdownTextExtractor], calling `extract()` directly (no
/// isolate) against the synthetic fixtures in `test/fixtures/`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Reads a fixture file's bytes relative to `test/fixtures/`.
Future<Uint8List> _fixture(String relativePath) async {
  final file = File('test/fixtures/$relativePath');
  return file.readAsBytes();
}

/// A minimal [VaultManifest] for a `.md` blob — the extractor does not
/// inspect manifest fields, but the interface requires one.
VaultManifest _manifest(String originalName) => VaultManifest(
  sha256: 'a' * 64,
  size: 0,
  crc32c: '00000000',
  mediaType: 'text/markdown',
  originalName: originalName,
  createdAt: '2026-01-01T00:00:00.000Z',
);

void main() {
  group('MarkdownTextExtractor', () {
    test('supportedMediaTypes is exactly text/markdown', () {
      const extractor = MarkdownTextExtractor();
      expect(extractor.supportedMediaTypes, equals({'text/markdown'}));
    });

    // ── Golden path — headings, paragraphs, lists, blockquotes ─────────

    test('golden_path.md — headings/paragraphs/lists/blockquotes, no token '
        'fusion across block boundaries', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('golden_path.md');

      final text = await extractor.extract(bytes, _manifest('golden_path.md'));

      expect(text, isNotNull);
      expect(text, contains('Section Heading'));
      expect(text, contains('Hello bold and italic world.'));
      expect(text, contains('Second paragraph.'));
      expect(text, contains('First item'));
      expect(text, contains('Second item'));
      expect(text, contains('A quoted thought.'));
      expect(text, isNot(contains('world.Second')));
      expect(text, isNot(contains('itemSecond')));
    });

    // ── Code block handling (Q4) ────────────────────────────────────────

    test('code_blocks.md — fenced code content dropped, inline code kept, '
        'indented code content dropped', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('code_blocks.md');

      final text = await extractor.extract(bytes, _manifest('code_blocks.md'));

      expect(text, isNotNull);
      expect(text, contains('Prose before the fenced code block.'));
      expect(
        text,
        contains('Prose after the fenced code block, with an inline'),
      );
      // Inline code span text is kept, backticks stripped by the parser.
      expect(text, contains('codeSpanToken()'));
      expect(text, contains('Prose after the indented code block.'));
      // Fenced and indented code block *content* must be dropped entirely.
      expect(text, isNot(contains('consoleOnlyCodeToken')));
      expect(text, isNot(contains('computeSomethingWithFencedCodeTokens')));
      expect(text, isNot(contains('indentedCodeToken')));
    });

    test('all_code.md (100% a single fenced code block) → extract() returns '
        '"" (not null)', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('all_code.md');

      final text = await extractor.extract(bytes, _manifest('all_code.md'));

      expect(text, isNotNull);
      expect(text, equals(''));
    });

    // ── encodeHtml: false regression guard (Q9) ─────────────────────────

    test('entities.md — prose containing &, <, >, and backslash-escaped '
        'characters survives un-escaped (Q9 regression guard)', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('entities.md');

      final text = await extractor.extract(bytes, _manifest('entities.md'));

      expect(text, isNotNull);
      expect(
        text,
        contains(
          'Fish & chips <tag> "quoted" and a literal & backslash-escaped '
          'ampersand.',
        ),
      );
      // With the bare Document() default (encodeHtml: true), these would
      // instead appear HTML-escaped — assert that did NOT happen.
      expect(text, isNot(contains('&amp;')));
      expect(text, isNot(contains('&lt;')));
      expect(text, isNot(contains('&gt;')));
    });

    // ── Link / image handling (Q6) ──────────────────────────────────────

    test('links_images.md — link text kept and URL dropped; image alt kept '
        'and URL dropped; empty alt contributes nothing', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('links_images.md');

      final text = await extractor.extract(bytes, _manifest('links_images.md'));

      expect(text, isNotNull);
      expect(text, contains('KMDB repository'));
      expect(text, contains('A descriptive alt text'));
      expect(text, isNot(contains('https://github.com/bettongia/kmdb')));
      expect(text, isNot(contains('https://example.com/image.png')));
      expect(text, isNot(contains('https://example.com/no-alt.png')));
    });

    // ── Empty / whitespace-only input ───────────────────────────────────

    test('empty bytes → extract() returns "" (not null)', () async {
      const extractor = MarkdownTextExtractor();

      final text = await extractor.extract(Uint8List(0), _manifest('empty.md'));

      expect(text, isNotNull);
      expect(text, equals(''));
    });

    test(
      'whitespace_only.md (blank lines only) → extract() returns ""',
      () async {
        const extractor = MarkdownTextExtractor();
        final bytes = await _fixture('whitespace_only.md');

        final text = await extractor.extract(
          bytes,
          _manifest('whitespace_only.md'),
        );

        expect(text, isNotNull);
        expect(text, equals(''));
      },
    );

    // ── GFM table (Q9 — gitHubWeb parses TableSyntax) ───────────────────

    test('gfm_table.md — GFM table flattens to reasonable prose text via the '
        'normal block-boundary walk', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('gfm_table.md');

      final text = await extractor.extract(bytes, _manifest('gfm_table.md'));

      expect(text, isNotNull);
      expect(text, contains('Name'));
      expect(text, contains('Role'));
      expect(text, contains('Alice'));
      expect(text, contains('Engineer'));
      expect(text, contains('Bob'));
      expect(text, contains('Designer'));
    });

    // ── Attribute-leakage regression guard (Q9 follow-up) ───────────────

    test(
      'attribute_leakage.md — alert block/checkbox/color-swatch prose text '
      'is kept but none of their attribute payloads leak into output',
      () async {
        const extractor = MarkdownTextExtractor();
        final bytes = await _fixture('attribute_leakage.md');

        final text = await extractor.extract(
          bytes,
          _manifest('attribute_leakage.md'),
        );

        expect(text, isNotNull);
        // Prose/title text is kept.
        expect(text, contains('Note'));
        expect(text, contains('This is a helpful note block.'));
        expect(text, contains('A completed checklist task'));
        expect(text, contains('An incomplete checklist task'));
        expect(text, contains('#f00'));
        // None of the non-prose attribute payloads leak into the output —
        // the visitor only ever emits Text-node data and img's alt
        // attribute, never other attributes.
        expect(text, isNot(contains('checkbox')));
        expect(text, isNot(contains('checked')));
        expect(text, isNot(contains('markdown-alert')));
        expect(text, isNot(contains('gfm-color_chip')));
        expect(text, isNot(contains('background-color')));
      },
    );

    // ── Emoji passthrough (Q9) ───────────────────────────────────────────

    test(
      'emoji.md — :smile: shortcode is emitted as the real emoji character',
      () async {
        const extractor = MarkdownTextExtractor();
        final bytes = await _fixture('emoji.md');

        final text = await extractor.extract(bytes, _manifest('emoji.md'));

        expect(text, isNotNull);
        expect(text, contains('😄'));
        expect(text, isNot(contains(':smile:')));
      },
    );

    // ── Realistic golden-path content (Q8) ──────────────────────────────

    test('readme_excerpt.md (trimmed excerpt of this repo\'s README.md) — '
        'extracts realistic prose without token fusion', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = await _fixture('readme_excerpt.md');

      final text = await extractor.extract(
        bytes,
        _manifest('readme_excerpt.md'),
      );

      expect(text, isNotNull);
      expect(text, contains('KMDB'));
      expect(
        text,
        contains('A Local-First Document Database for Dart & Flutter'),
      );
      expect(text, contains('Log-Structured Merge Tree'));
    });

    // ── Never throws — general contract ─────────────────────────────────

    test('extract() never throws for arbitrary non-Markdown bytes', () async {
      const extractor = MarkdownTextExtractor();
      final bytes = Uint8List.fromList([0xff, 0xfe, 0x00, 0x01, 0x02]);

      String? text;
      await expectLater(
        () async =>
            text = await extractor.extract(bytes, _manifest('binary.md')),
        returnsNormally,
      );
      expect(text, isNotNull);
    });
  });
}
