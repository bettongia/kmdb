// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:betto_mediatype_detector/betto_mediatype_detector.dart'
    as betto_registry;

/// Abstract interface for detecting the MIME type of raw bytes.
///
/// The vault subsystem uses [MediaTypeDetector] at ingestion time to determine
/// the canonical `mediaType` stored in `manifest.json`. A concrete
/// implementation delegates to the FreeDesktop shared-mime-info database via
/// `package:betto_mediatype_detector`.
///
/// ## Design
///
/// The interface returns the full [MatchList] from `betto_mediatype_detector`, giving
/// callers access to both `MatchList.bestMatch` (the top-priority type) and
/// `MatchList.candidates` (all viable types in descending priority order).
///
/// When storing the detected media type in a [VaultManifest], use
/// `matchList.bestMatch` as the canonical value.
///
/// When validating a caller-supplied media type (e.g. from a package's
/// `manifest.json`), accept it if it appears anywhere in
/// `matchList.candidates`; reject only if absent entirely.
///
/// ## Fallback
///
/// When detection yields no candidates, `bestMatch` is `null`. Callers should
/// substitute `"application/octet-stream"` as a safe default.
abstract interface class MediaTypeDetector {
  /// Detects the MIME type of [bytes], optionally using [fileName] as a hint.
  ///
  /// Returns a [MatchList] whose [MatchList.bestMatch] property holds the
  /// highest-priority candidate, and whose [MatchList.candidates] iterable
  /// exposes all viable types in descending priority order.
  ///
  /// Neither [bytes] nor [fileName] is required, but supplying at least one
  /// improves detection accuracy.
  Iterable<String> detect(Uint8List bytes, {String? fileName});
}

/// Concrete [MediaTypeDetector] backed by the FreeDesktop shared-mime-info
/// database via `package:betto_mediatype_detector`.
///
/// This implementation uses magic number (byte-sequence) matching together
/// with filename glob patterns. It is the default detector used by [VaultStore].
///
/// ## Example
///
/// ```dart
/// final detector = FreedesktopMediaTypeDetector();
/// final matchList = detector.detect(jpegBytes, fileName: 'photo.jpg');
/// final mime = matchList.bestMatch ?? 'application/octet-stream';
/// ```
final class FreedesktopMediaTypeDetector implements MediaTypeDetector {
  const FreedesktopMediaTypeDetector();

  /// The MIME type used when detection yields no candidates.
  static const String kFallbackType = 'application/octet-stream';

  @override
  Iterable<String> detect(Uint8List bytes, {String? fileName}) =>
      betto_registry.detect(bytes: bytes, fileName: fileName).candidates;
}
