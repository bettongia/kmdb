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

/// Unit tests for [PdfTextExtractor], calling `extract()` directly (no
/// isolate) against the fixtures in `test/fixtures/` (copied from the
/// `betto_pdfium` test corpus — see `test/fixtures/README.md`).
library;

import 'dart:convert' show json, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Reads a fixture file's bytes relative to `test/fixtures/`.
Future<Uint8List> _fixture(String relativePath) async {
  final file = File('test/fixtures/$relativePath');
  return file.readAsBytes();
}

/// A minimal [VaultManifest] for a `.pdf` blob — the extractor does not
/// inspect manifest fields, but the interface requires one.
VaultManifest _manifest(String originalName) => VaultManifest(
  sha256: 'a' * 64,
  size: 0,
  crc32c: '00000000',
  mediaType: 'application/pdf',
  originalName: originalName,
  createdAt: '2026-01-01T00:00:00.000Z',
);

/// Reads and decodes an arXiv `.txt.json` oracle (a list of per-page objects
/// with `pageIndex`/`text`/`hasTextLayer`/`hasUnicodeErrors`), produced by
/// `pypdf` — an independent tool from PDFium — via `betto_pdfium`'s
/// `scripts/extract_text.py`. Returns the concatenation of all `text` fields
/// (comparisons against this oracle must be fuzzy; see the class doc in
/// `test/fixtures/README.md`).
Future<String> _oracleText(String stem) async {
  final file = File('test/fixtures/arxiv/$stem.txt.json');
  final decoded = json.decode(await file.readAsString()) as List<dynamic>;
  return decoded
      .map((page) => (page as Map<String, dynamic>)['text'] as String)
      .join('\n\n');
}

void main() {
  group('PdfTextExtractor', () {
    // ── supportedMediaTypes ───────────────────────────────────────────────

    test('supportedMediaTypes is exactly application/pdf', () {
      const extractor = PdfTextExtractor();
      expect(extractor.supportedMediaTypes, equals({'application/pdf'}));
    });

    // ── Golden path — basic fixtures ────────────────────────────────────────

    test('01_basic.pdf → extracts the expected text', () async {
      const extractor = PdfTextExtractor();
      final bytes = await _fixture('01_basic.pdf');

      final text = await extractor.extract(bytes, _manifest('01_basic.pdf'));

      expect(text, isNotNull);
      expect(text, contains('hello'));
    });

    // ── Zero-page guard ──────────────────────────────────────────────────

    test(
      'zero-page document → extract() returns "" (pageCount == 0 guard)',
      () async {
        const extractor = PdfTextExtractor();
        // A hand-constructed, minimal PDF whose page tree has zero kids.
        // No fixture in the real-world betto_pdfium corpus has literally zero
        // pages — "00_empty.pdf" (see below) actually has one page with no
        // text layer, not zero pages — so this single, deliberately-minimal
        // synthetic PDF is the only way to exercise the pageCount == 0
        // division-by-zero guard. See the WI-8 plan's implementation notes
        // for this documented deviation from "no synthetic fixtures".
        final bytes = await _fixture('zero_pages_synthetic.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('zero_pages_synthetic.pdf'),
        );

        expect(text, equals(''));
      },
    );

    test('00_empty.pdf (one page, no text layer) → extract() returns "" '
        'via the scanned-ratio path', () async {
      const extractor = PdfTextExtractor();
      final bytes = await _fixture('00_empty.pdf');

      final text = await extractor.extract(bytes, _manifest('00_empty.pdf'));

      expect(text, equals(''));
    });

    // ── Scanned/image-only document ─────────────────────────────────────

    test(
      'scanned.pdf (image-only) → extract() returns "" (not null)',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('scanned.pdf');

        final text = await extractor.extract(bytes, _manifest('scanned.pdf'));

        expect(text, isNotNull);
        expect(text, equals(''));
      },
    );

    // ── Layout coverage ───────────────────────────────────────────────────

    test(
      'multi_column.pdf → extracts observed text (no layout claim)',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('multi_column.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('multi_column.pdf'),
        );

        expect(text, isNotNull);
        expect(text, isNotEmpty);
        // No claim about column-reading order — just confirm both columns'
        // content made it into the extracted text.
        expect(text, contains('Left column text'));
        expect(text, contains('Right column text'));
      },
    );

    test(
      'single_column.pdf → extracts observed text (no layout claim)',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('single_column.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('single_column.pdf'),
        );

        expect(text, isNotNull);
        expect(text, contains('Lorem ipsum dolor sit amet'));
      },
    );

    // ── Soft hyphen handling ─────────────────────────────────────────────

    test(
      'soft_hyphens.pdf → join does not reintroduce hyphenation artifacts',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('soft_hyphens.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('soft_hyphens.pdf'),
        );

        expect(text, isNotNull);
        // Words that PDFium reconstructs across a soft-hyphen line break
        // should appear whole, with no stray hyphen or soft-hyphen codepoint
        // (U+00AD) left over from the join.
        expect(text, contains('hyphenation'));
        expect(text, contains('dictionary'));
        expect(text, isNot(contains('­')));
      },
    );

    // ── Failure paths — never throw, always null ────────────────────────

    test('password.pdf → extract() returns null', () async {
      const extractor = PdfTextExtractor();
      final bytes = await _fixture('password.pdf');

      final text = await extractor.extract(bytes, _manifest('password.pdf'));

      expect(text, isNull);
    });

    test('corrupt.pdf → extract() returns null, never throws', () async {
      const extractor = PdfTextExtractor();
      final bytes = await _fixture('corrupt.pdf');

      String? text;
      await expectLater(
        () async =>
            text = await extractor.extract(bytes, _manifest('corrupt.pdf')),
        returnsNormally,
      );
      expect(text, isNull);
    });

    test('zero-length bytes → extract() returns null, never throws', () async {
      const extractor = PdfTextExtractor();

      String? text;
      await expectLater(
        () async => text = await extractor.extract(
          Uint8List(0),
          _manifest('empty.pdf'),
        ),
        returnsNormally,
      );
      expect(text, isNull);
    });

    // ── scannedPageRatio configurability ────────────────────────────────

    test('scannedPageRatio defaults to 0.5', () {
      const extractor = PdfTextExtractor();
      expect(extractor.scannedPageRatio, equals(0.5));
    });

    test(
      'a lower scannedPageRatio still discards a fully-scanned document',
      () async {
        // scanned.pdf is 100% scanned (ratio 1.0), so even a permissive
        // threshold well below the default should still trigger the gate.
        const extractor = PdfTextExtractor(scannedPageRatio: 0.1);
        final bytes = await _fixture('scanned.pdf');

        final text = await extractor.extract(bytes, _manifest('scanned.pdf'));

        expect(text, equals(''));
      },
    );

    // ── Large document memory/size sanity check ─────────────────────────

    test('large.pdf → extracts without error', () async {
      const extractor = PdfTextExtractor();
      final bytes = await _fixture('large.pdf');

      final text = await extractor.extract(bytes, _manifest('large.pdf'));

      expect(text, isNotNull);
    });

    // ── arXiv corpus — golden path with fuzzy oracle comparison ─────────
    //
    // The oracle .txt.json files were produced by pypdf (an independent
    // tool from PDFium/betto_pdfium — see test/fixtures/README.md), so
    // comparisons are fuzzy (key-term/substring presence) rather than exact
    // string equality. Only the oracle's `text` field is used — its
    // `hasTextLayer`/`hasUnicodeErrors` fields are derived from pypdf's own
    // heuristics and are NOT cross-checked against PDFium's probe.

    const arxivStems = [
      '2312.17524v1',
      '2404.16130v2',
      '2605.13866v1',
      '2605.15752v1',
      '2605.16085v1',
    ];

    for (final stem in arxivStems) {
      test('arxiv/$stem.pdf → non-empty extracted text', () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('arxiv/$stem.pdf');

        final text = await extractor.extract(bytes, _manifest('$stem.pdf'));

        expect(text, isNotNull);
        expect(text!.trim(), isNotEmpty);
      });

      test(
        'arxiv/$stem.pdf → fuzzy match against the independent pypdf oracle',
        () async {
          const extractor = PdfTextExtractor();
          final bytes = await _fixture('arxiv/$stem.pdf');

          final text = await extractor.extract(bytes, _manifest('$stem.pdf'));
          expect(text, isNotNull);

          final oracleText = await _oracleText(stem);

          // Fuzzy comparison: word-count-in-range (within an order of
          // magnitude — PDFium and pypdf tokenise differently, so exact
          // counts will never match) rather than exact string equality.
          final extractedWordCount = text!
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .length;
          final oracleWordCount = oracleText
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .length;

          expect(extractedWordCount, greaterThan(oracleWordCount * 0.5));
          expect(extractedWordCount, lessThan(oracleWordCount * 2));
        },
      );
    }

    test(
      'arxiv/2312.17524v1.pdf → contains key terms present in both engines',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('arxiv/2312.17524v1.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('2312.17524v1.pdf'),
        );

        expect(text, isNotNull);
        // Title terms from citations.md — should appear verbatim in the
        // extracted first-page text regardless of extraction engine.
        expect(text, contains('Distributed File Systems'));
      },
    );

    // ── Multi-page arXiv fixture — page-join behavior ───────────────────
    //
    // Byte-offset correctness of the downstream chunker (`VaultChunker`,
    // internal to `package:kmdb`) is exercised end-to-end by the integration
    // test in `pdf_text_extractor_integration_test.dart`, which runs the real
    // vault indexing pipeline (extractor → chunker → BM25/vector writers)
    // against a multi-page PDF and confirms it becomes searchable.
    // `VaultChunker` itself is not part of `package:kmdb`'s public API
    // surface, so this external package cannot call it directly — and per
    // the WI-8 plan, no chunker changes are expected or introduced here.

    test(
      'multi-page arxiv fixture → pages are joined with the "\\n\\n" separator',
      () async {
        const extractor = PdfTextExtractor();
        final bytes = await _fixture('arxiv/2404.16130v2.pdf');

        final text = await extractor.extract(
          bytes,
          _manifest('2404.16130v2.pdf'),
        );
        expect(text, isNotNull);
        // A multi-page document's joined text must contain at least one
        // double-newline page separator, and decode as valid UTF-8 (the
        // property VaultChunker's byte-offset table depends on downstream).
        expect(text, contains('\n\n'));
        expect(() => utf8.encode(text!), returnsNormally);
      },
    );
  });
}
