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

/// Charset detection and decoding utilities for vault plain-text extraction.
///
/// This library is **internal only** — `CharsetDecodeResult` and `decodeText`
/// are not exported from `kmdb.dart`. WI-3's `PlainTextExtractor` imports them
/// directly from `src/vault/search/charset_util.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:betto_charset_detector/betto_charset_detector.dart';
import 'package:charset/charset.dart';

/// The result of charset detection and decoding.
///
/// [charset] is the detected IANA encoding label (e.g. `"utf-8"`,
/// `"windows-1252"`). [text] is the decoded string. Both fields are always
/// non-null — decoding cannot fail for the closed label set returned by
/// [detectCharset].
///
/// Example:
/// ```dart
/// import 'dart:typed_data';
///
/// final bytes = Uint8List.fromList([104, 101, 108, 108, 111]); // "hello"
/// final (:charset, :text) = decodeText(bytes);
/// // charset == 'utf-8', text == 'hello'
/// ```
typedef CharsetDecodeResult = ({String charset, String text});

/// Detects the character encoding of [bytes] and decodes them to a string.
///
/// Detection uses `betto_charset_detector`'s three-stage pipeline:
/// 1. **BOM inspection** — deterministic; handles UTF-8 BOM, UTF-16 BE/LE,
///    UTF-32 BE/LE.
/// 2. **UTF-8 structural validation** — first 8 KB decoded with
///    `utf8.decode(allowMalformed: false)`; valid → `"utf-8"`.
/// 3. **Candidate probe** — tests `windows-1252`, `iso-8859-1`, `iso-8859-2`,
///    `iso-8859-15`, `shift-jis`, `euc-jp`, `euc-kr`, `gbk` via
///    `Charset.canDecode`. CJK encodings are promoted when >15% of sample
///    bytes are ≥ `0x80`. Fallback: `"windows-1252"`.
///
/// Decoding uses a two-branch dispatch:
///
/// - `'utf-8'` → `dart:convert`'s `utf8.decode`. In Dart 3.x, `utf8.decode`
///   strips the UTF-8 BOM (the three-byte sequence `0xEF 0xBB 0xBF`) from the
///   result automatically. The `charset` UTF-16 / UTF-32 codecs handle their
///   own BOM stripping — no extra step is needed for those families.
/// - All other labels → `Charset.getByName(label)!.decode(bytes)`.
///
/// **UTF-16/UTF-32 endianness note.** In `charset 2.0.1`, both `"utf-16be"`
/// and `"utf-16le"` map to the same `utf16` codec (likewise `"utf-32be"` /
/// `"utf-32le"` → `utf32`). Endianness is derived from the leading BOM in the
/// byte content, not the label. [detectCharset] only emits these labels when a
/// BOM is present, so `Charset.getByName(label).decode(bytes)` works correctly
/// and strips the BOM. Do not attempt to force LE/BE via the label string.
///
/// **`iso-8859-1` note.** This label is absent from `charset`'s own name map
/// but resolves via `Charset.getByName`'s internal fallback to `latin1`
/// (`dart:convert`'s `Encoding.getByName`). The fallback is relied upon; it is
/// not special-cased.
///
/// **Decode-failure contract.** This function always returns a non-null
/// [String]. The `windows-1252` fallback accepts any byte sequence, and all
/// other codecs are chosen only behind a validated BOM or UTF-8 structural
/// check, so decode failure is not reachable for the closed label set.
///
/// Empty input returns `(charset: 'utf-8', text: '')`.
///
/// Example:
/// ```dart
/// import 'dart:typed_data';
///
/// final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, 104, 101, 108, 108, 111]);
/// final (:charset, :text) = decodeText(bytes); // charset='utf-8', text='hello'
/// ```
CharsetDecodeResult decodeText(Uint8List bytes) {
  // Stage 1/2/3 detection via betto_charset_detector.
  final label = detectCharset(bytes);

  final String text;
  if (label == 'utf-8') {
    // In Dart 3.x, utf8.decode automatically strips the UTF-8 BOM (0xEF 0xBB
    // 0xBF) from the result — no explicit stripping is needed here.
    text = utf8.decode(bytes);
  } else {
    // All other labels: delegate to the charset package. The codec is always
    // non-null because:
    //   - UTF-16/UTF-32 families resolve to the utf16/utf32 codecs in charset.
    //   - iso-8859-1 resolves via Charset.getByName's internal fallback to
    //     dart:convert's latin1 (Encoding.getByName).
    //   - All remaining labels (windows-1252, iso-8859-2, iso-8859-15,
    //     shift-jis, euc-jp, euc-kr, gbk) are directly registered in charset.
    // Null-asserting (!) here is intentional — if getByName ever returns null
    // for a label emitted by detectCharset, that indicates a version mismatch
    // between betto_charset_detector and charset that must be fixed at the
    // dependency level, not silently swallowed at runtime.
    text = Charset.getByName(label)!.decode(bytes);
  }

  return (charset: label, text: text);
}
