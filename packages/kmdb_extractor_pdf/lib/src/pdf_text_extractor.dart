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

import 'package:betto_pdfium/betto_pdfium.dart';
import 'package:kmdb/kmdb.dart';

/// Extracts plain text from `application/pdf` vault blobs using
/// [betto_pdfium] (a pure-Dart PDFium FFI/WASM wrapper).
///
/// ## Supported media types
///
/// Only `application/pdf` is handled. Other document formats (DOCX, HTML,
/// etc.) should be handled by dedicated extractors added in future work
/// items — see the `kmdb_extractor_<name>` convention in the vault search
/// proposal.
///
/// ## Scanned / image-only documents
///
/// PDFium reports [PdfPageText.hasTextLayer] per page. A document that is
/// predominantly scanned images (e.g. a photocopied paper with no embedded
/// text layer) will yield mostly-empty per-page text. Rather than returning
/// whatever sparse, OCR-adjacent fragments happen to be present — which would
/// pollute the BM25/semantic index with noise — [extract] computes the
/// fraction of pages lacking a text layer and, if that fraction meets or
/// exceeds [scannedPageRatio], discards all extracted text and returns `""`.
/// This mirrors `betto_pdfium`'s own `PdfDocument.isPlainTextExtractable`
/// heuristic (same default ratio, same `>=` comparison), but is computed
/// inline while consuming a single [PdfDocument.extractPlainText] stream
/// rather than calling `isPlainTextExtractable` (which would silently re-run
/// extraction a second time — see [extract] for the implementation note).
///
/// Both outcomes (predominantly scanned, or empty document) map to the
/// existing `VaultExtractionStatus.indexed` status with zero (or very few)
/// chunks — no core `kmdb` change is required (see the WI-8 plan's Q1).
///
/// ## Isolate composition
///
/// [VaultSearchManager]'s indexing pipeline runs each [VaultTextExtractor] on
/// a dedicated, spawned "vault indexing isolate" — extractor instances are
/// copied into that isolate at construction time and [extract] is invoked
/// there. `betto_pdfium` is not thread-safe internally (PDFium's C library
/// requires all calls to originate from a single, consistent execution
/// context), so it routes every PDFium FFI call through its own dedicated,
/// lazily-spawned, process-wide singleton isolate (`PdfiumIsolate`), shared by
/// every [PdfDocument] instance regardless of which isolate constructs it.
/// [PdfTextExtractor] therefore does nothing isolate-aware itself: whichever
/// isolate happens to call [extract] (the main isolate in a unit test, or the
/// vault indexing isolate in production) transparently gets routed to the same
/// shared PDFium isolate. This composes safely with no special handling
/// needed — Dart isolates spawning further isolates is a normal, supported
/// pattern.
///
/// ## Known limitation
///
/// The [VaultTextExtractor] contract has no channel for an extractor to
/// report *why* extraction failed. A password-protected PDF
/// ([PdfError.passwordRequired]) and a corrupt/malformed PDF
/// ([PdfError.invalidDocument]) are therefore indistinguishable to callers —
/// both simply cause [extract] to return `null`, which the vault indexing
/// pipeline records as a generic `failed` status with the error string
/// `"Extractor returned null"`.
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
/// );
/// ```
final class PdfTextExtractor implements VaultTextExtractor {
  /// Creates a [PdfTextExtractor].
  ///
  /// [scannedPageRatio] is the fraction of pages (in `[0, 1]`) that must lack
  /// a text layer for the document to be judged predominantly scanned/image
  /// content (see the class-level doc comment). Defaults to `0.5`, matching
  /// `betto_pdfium`'s own `PdfTextExtractorConfig.scannedPageRatio` default.
  const PdfTextExtractor({this.scannedPageRatio = 0.5});

  /// The scanned-page ratio threshold used by [extract] to decide whether a
  /// document is predominantly scanned/image content (see class doc).
  ///
  /// A value of `0.5` means a document is only considered predominantly
  /// scanned when at least half of its pages yield no text layer. A single
  /// image or figure page in an otherwise text-based document will not
  /// trigger this gate.
  final double scannedPageRatio;

  @override
  Set<String> get supportedMediaTypes => const {'application/pdf'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    // `doc` is nullable because `PdfDocument.fromBytes` can throw before ever
    // assigning it (e.g. `PdfError.passwordRequired` / `invalidDocument`) — the
    // `finally` block below must null-check before calling `close()`.
    PdfDocument? doc;
    try {
      doc = await PdfDocument.fromBytes(bytes);

      // Single pass over the page-text stream: buffer each page's text and
      // tally pages with no text layer as they arrive. We deliberately do NOT
      // call `doc.isPlainTextExtractable()` here — it internally re-runs
      // `extractPlainText()` to completion, which would extract the document
      // twice for no benefit since we need the same per-page signal it uses.
      final pageTexts = <String>[];
      var noTextLayerCount = 0;
      await for (final page in doc.extractPlainText()) {
        pageTexts.add(page.text);
        if (!page.hasTextLayer) {
          noTextLayerCount++;
        }
      }

      final pageCount = pageTexts.length;
      // Guard against division by zero for a zero-page document. This
      // mirrors betto_pdfium's own isPlainTextExtractable, which treats a
      // zero-page document as non-extractable rather than computing a
      // (would-be NaN) ratio.
      if (pageCount == 0) {
        return '';
      }

      final scannedRatio = noTextLayerCount / pageCount;
      if (scannedRatio >= scannedPageRatio) {
        // Predominantly scanned/image content — discard any sparse text
        // fragments rather than indexing noise (see class-level doc).
        return '';
      }

      // Join all page text (including any empty strings from scanned pages
      // within an otherwise text-based document — they simply contribute
      // nothing to the join). Soft hyphens at line breaks are already
      // stripped and rejoined by PDFium/betto_pdfium, so no further cleanup
      // is needed here.
      return pageTexts.join('\n\n');
    } catch (e) {
      // Never throw, per the VaultTextExtractor contract. This covers
      // PdfExtractionException (password-required / invalid document),
      // PdfiumException (native call failures), and any other exception
      // surfaced mid-stream by extractPlainText (the await-for above sits
      // inside this try).
      return null;
    } finally {
      // Safe to call more than once, but NOT on a null handle — doc may still
      // be null if fromBytes() threw before assignment.
      await doc?.close();
    }
  }
}
