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
import 'charset_util.dart';
import 'vault_text_extractor.dart';

/// Extracts plain text from `text/plain` vault blobs.
///
/// Uses the charset detection and decoding pipeline from WI-2
/// ([decodeText] in `charset_util.dart`) to handle a wide range of
/// text encodings (UTF-8, UTF-16, Windows-1252, ISO-8859-*, Shift-JIS, etc.).
///
/// ## Supported media types
///
/// Only `text/plain` is handled. Other media types should be handled by
/// dedicated extractors (PDF, HTML, etc.) added in future WIs.
///
/// ## Charset detection
///
/// After a successful [extract] call, [lastCharset] holds the IANA encoding
/// label detected by [decodeText]. [VaultSearchManager] reads this immediately
/// after [extract] returns to record the charset in the `$$vault:extract`
/// status entry.
///
/// ## Error handling
///
/// This extractor does not throw. Any error during detection or decoding is
/// caught and `null` is returned. [lastCharset] is `null` when extraction
/// returned `null`.
///
/// ## Example
///
/// ```dart
/// final extractor = PlainTextExtractor();
/// final text = await extractor.extract(bytes, manifest);
/// if (text != null) {
///   print('Detected charset: ${extractor.lastCharset}');
/// }
/// ```
final class PlainTextExtractor implements VaultTextExtractor {
  /// Creates a [PlainTextExtractor].
  PlainTextExtractor();

  @override
  Set<String> get supportedMediaTypes => const {'text/plain'};

  /// The IANA charset label detected during the most recent [extract] call.
  ///
  /// `null` before the first successful call or when extraction returned `null`.
  /// Reset to `null` at the start of each [extract] call.
  ///
  /// This field is read by [VaultSearchManager] immediately after awaiting
  /// [extract] to record the charset in the `$$vault:extract` status entry.
  String? lastCharset;

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    // Reset per-call state.
    lastCharset = null;

    try {
      final result = decodeText(bytes);
      // Record the detected charset for the caller.
      lastCharset = result.charset;
      return result.text;
    } catch (e) {
      // Extraction should not throw (charset fallbacks cover all byte sequences),
      // but guard defensively so a bug here does not crash the indexing pipeline.
      return null;
    }
  }
}
