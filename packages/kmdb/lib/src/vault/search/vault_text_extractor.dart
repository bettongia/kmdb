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

import '../vault_manifest.dart';

/// Interface for vault blob text extractors.
///
/// Implementations are responsible for decoding raw blob bytes to a plain-text
/// UTF-8 string for a specific set of media types. The extraction pipeline uses
/// the first extractor in [VaultSearchConfig.extractors] whose
/// [supportedMediaTypes] set contains the blob's [VaultManifest.mediaType].
///
/// ## Built-in implementations
///
/// - [PlainTextExtractor] — handles `text/plain` via charset detection (WI-2).
///
/// ## Optional extension packages (not core `kmdb` dependencies)
///
/// - `kmdb_extractor_pdf`'s `PdfTextExtractor` — `application/pdf` (WI-8),
///   wraps `betto_pdfium`.
/// - `kmdb_extractor_html`'s `HtmlTextExtractor` — `text/html` (WI-9), wraps
///   the `html` package with a custom node walk.
/// - `kmdb_extractor_markdown`'s `MarkdownTextExtractor` — `text/markdown`
///   (WI-9), wraps the `markdown` package with a custom AST walk.
///
/// These ship as separate optional packages (following the
/// `kmdb_extractor_<name>` convention) rather than as core `kmdb`
/// dependencies, and are registered by the library user via
/// [VaultSearchConfig.extractors]. DOCX remains a candidate for a future
/// extension package.
///
/// ## Contract
///
/// - Implementations MUST NOT throw; return `null` to indicate that extraction
///   failed or is not possible for this blob.
/// - Implementations MUST return valid UTF-8 text (or `null`).
/// - The input [bytes] are the **raw, decrypted** blob bytes. Encryption is
///   handled transparently by [VaultStore.getBytes] before calling the extractor.
abstract interface class VaultTextExtractor {
  /// The set of MIME media types this extractor can handle.
  ///
  /// For example, `{'text/plain'}` or `{'application/pdf'}`. The search
  /// manager matches against [VaultManifest.mediaType].
  Set<String> get supportedMediaTypes;

  /// Extracts plain text from [bytes] according to [manifest].
  ///
  /// Returns the extracted UTF-8 text, or `null` if extraction fails or is
  /// not possible for this blob. The returned string may be empty.
  ///
  /// [manifest] provides metadata such as the original filename — some
  /// extractors may use it for format hints or logging.
  ///
  /// Implementations MUST NOT throw. Any internal error should be caught and
  /// logged, and `null` returned to indicate failure.
  Future<String?> extract(Uint8List bytes, VaultManifest manifest);
}
