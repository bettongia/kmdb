# kmdb_extractor_pdf

PDF text extractor for [KMDB](https://github.com/bettongia/kmdb) vault
search — a `VaultTextExtractor` implementation for `application/pdf` blobs,
wrapping [`betto_pdfium`](https://pub.dev/packages/betto_pdfium) (a pure-Dart
PDFium FFI/WASM wrapper).

---

## Overview

`package:kmdb_extractor_pdf` provides `PdfTextExtractor`, which implements
`VaultTextExtractor` from `package:kmdb`. Register it on
`VaultSearchConfig.extractors` to make `application/pdf` vault blobs
searchable via `KmdbCollection.searchVault()`:

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';

final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  vaultStore: vaultStore,
  vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
);
```

`PlainTextExtractor` (`text/plain`) is always included automatically by
`VaultSearchConfig` — most applications only need to add `PdfTextExtractor()`
to the list.

See `example/pdf_extractor_example.dart` for a complete, runnable example.

---

## Scanned / image-only documents

PDFium reports a per-page `hasTextLayer` flag. If a document is
predominantly scanned images (few or no pages with a real text layer),
`PdfTextExtractor` discards any sparse OCR-adjacent text fragments and
returns an empty string rather than indexing noise. The threshold is
configurable:

```dart
// Treat a document as "scanned" only when 80% or more of its pages lack
// a text layer (default is 50%).
PdfTextExtractor(scannedPageRatio: 0.8)
```

An empty string still results in the blob being marked `indexed` (with zero
searchable chunks) — not `failed` or `unsupported` — consistent with how
`PlainTextExtractor` handles an empty `text/plain` blob.

---

## Platform support

Vault search indexing runs exclusively in a native (non-web) indexing
pipeline — web is excluded from KMDB text search entirely. Supported
platforms:

| Platform            | Support                                                          |
| :------------------- | :----------------------------------------------------------------- |
| macOS, Linux, Windows | Works out of the box. `betto_pdfium`'s native-assets hook auto-downloads a prebuilt PDFium binary ([bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)) on first use. |
| iOS                   | Requires the companion `betto_pdfium_ios` Flutter plugin (delivers the PDFium xcframework via Swift Package Manager) in your **consuming app** — mirrors the `betto_onnxrt` / `betto_onnxrt_ios` split. `kmdb_extractor_pdf` itself adds no `ios/` folder or CocoaPods artifact. |
| Android               | Requires a one-time `make fetch_mobile_binaries` (from the `betto_pdfium` repo) for local/on-device testing. |
| Web                   | Not supported (vault text search does not run on web). |

---

## Known limitations

- **Failure reason is not surfaced.** The `VaultTextExtractor` contract has
  no channel for an extractor to report *why* extraction failed — a
  password-protected PDF and a corrupt/malformed PDF both simply cause
  `extract()` to return `null`, which the vault indexing pipeline records as
  a generic `failed` status.
- **No multi-column or RTL support claim.** `betto_pdfium`'s own
  documentation makes no guarantee about multi-column layout or right-to-left
  script extraction quality — treat these as unverified rather than
  guaranteed. This package's test suite exercises real-world multi-column
  fixtures but does not assert a specific layout-preserving behaviour.

---

## Development

This package is part of the KMDB Dart workspace. From the workspace root:

```bash
dart pub get
cd packages/kmdb_extractor_pdf
dart test
```

Native-asset build hooks (used by `betto_pdfium`) require `dart test` to be
invoked from **inside** this package's directory — see the workspace
`CLAUDE.md` for details.

Test fixtures under `test/fixtures/` (including the `arxiv/` real-world paper
corpus) are copied from the
[`betto_pdfium`](https://github.com/bettongia/pdfium) test suite — see
`test/fixtures/README.md` and `test/fixtures/arxiv/citations.md` for
licensing and attribution.
