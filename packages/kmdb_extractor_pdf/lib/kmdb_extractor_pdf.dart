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

/// PDF text extractor for KMDB vault search.
///
/// Provides [PdfTextExtractor] — a `VaultTextExtractor` implementation
/// (defined in `package:kmdb`) for `application/pdf` vault blobs, wrapping
/// [betto_pdfium](https://pub.dev/packages/betto_pdfium) (PDFium FFI/WASM).
///
/// ## Quick start
///
/// ```dart
/// import 'package:kmdb/kmdb.dart';
/// import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';
///
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
/// );
/// ```
///
/// ## Platform support
///
/// This package runs exclusively in the native-only vault indexing pipeline
/// (see `package:kmdb`'s `VaultSearchManager`) — vault content search is not
/// available on web. Supported platforms are macOS, Linux, Windows, iOS, and
/// Android. See the package `README.md` for mobile setup notes.
library;

export 'src/pdf_text_extractor.dart' show PdfTextExtractor;
