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

/// Resource bounds applied by [VaultTextExtractor] implementations to guard
/// against denial-of-service documents (untrusted blob bytes with
/// pathological size, nesting depth, or extraction time).
///
/// Every [VaultTextExtractor] implementation in the `kmdb_extractor_*`
/// family (and core's `PlainTextExtractor`) accepts an [ExtractorLimits] via
/// its constructor, defaulting to [ExtractorLimits.defaults]. Because the
/// extractor contract requires extraction to never throw
/// (`VaultTextExtractor.extract` — MUST NOT throw, `null` on failure), a
/// document that exceeds any of these bounds is declined gracefully by
/// returning `null` rather than raising an exception or hanging.
///
/// ## Bounds
///
/// - [maxInputBytes] guards against oversized blobs. It is checked **before
///   any parsing begins**, which also serves as the first line of defence
///   against a parser-stage stack overflow: a pathologically nested document
///   is necessarily large, so the byte-size gate catches it before the
///   parser ever builds a tree. (Contrast with [maxRecursionDepth], which
///   only protects the *walk* over an already-parsed tree — see below.)
/// - [maxRecursionDepth] guards against pathologically nested documents
///   (HTML/Markdown) once parsed, bounding the depth of the tree walk that
///   converts parsed nodes to plain text. It does **not** protect the parser
///   itself, which recurses independently while building the tree —
///   [maxInputBytes] is the guard for that stage.
/// - [maxDuration] guards against extraction that runs for an unbounded
///   wall-clock time (for example `kmdb_extractor_pdf`'s cumulative
///   per-page budget across a multi-page PDF). It is independent of the
///   `VaultIndexingIsolate.kWorkTimeout` backstop in the vault indexing
///   pipeline, which exists to catch the residual case an extractor-level
///   budget cannot interrupt (a single unit of work — e.g. one PDF page —
///   hanging in native code).
///
/// ## Composability with pipeline-level bounds
///
/// Within the vault indexing pipeline, `VaultSearchConfig.maxBlobBytes`
/// already stops oversized blobs from reaching an extractor at all. Because
/// the extractors are also independently publishable, standalone-consumable
/// packages, [maxInputBytes] is a second, independent gate that applies
/// whether or not a caller goes through the vault pipeline — for a
/// standalone caller it is the *only* protection. The two bounds compose
/// cleanly: whichever is stricter wins.
final class ExtractorLimits {
  /// Creates a set of extractor resource bounds.
  const ExtractorLimits({
    required this.maxInputBytes,
    required this.maxRecursionDepth,
    required this.maxDuration,
  });

  /// The default bounds applied when an extractor is constructed without an
  /// explicit [ExtractorLimits].
  ///
  /// - `maxInputBytes = 32 MiB` — well below the 200 MiB
  ///   `VaultSearchConfig.maxBlobBytes` pipeline cap, and also serves as the
  ///   parser-stage stack-overflow guard (see the class doc).
  /// - `maxRecursionDepth = 512` — safe against stack overflow in the
  ///   HTML/Markdown tree walk, which is a shallow mutual recursion of a
  ///   few stack frames per level.
  /// - `maxDuration = 20 seconds` — strictly less than the 30 second
  ///   `VaultIndexingIsolate.kWorkTimeout` backstop, so a PDF extraction
  ///   that exceeds this budget declines gracefully (returns `null`) before
  ///   the isolate-level backstop trips.
  static const ExtractorLimits defaults = ExtractorLimits(
    maxInputBytes: 32 * 1024 * 1024,
    maxRecursionDepth: 512,
    maxDuration: Duration(seconds: 20),
  );

  /// The maximum size, in bytes, of input a [VaultTextExtractor] will
  /// attempt to parse. Larger inputs are declined (`null`) before any
  /// parsing begins.
  final int maxInputBytes;

  /// The maximum depth of the document tree walk a [VaultTextExtractor]
  /// will perform when converting a parsed document (HTML/Markdown) to
  /// plain text. Documents nested deeper than this are declined (`null`)
  /// rather than truncated, so a hostile document cannot masquerade as a
  /// smaller, plausible result.
  final int maxRecursionDepth;

  /// The maximum cumulative wall-clock duration a [VaultTextExtractor] will
  /// spend extracting a single document. Extraction that exceeds this
  /// budget is declined (`null`) at the next checkpoint the implementation
  /// exposes (for example, between pages of a multi-page PDF).
  final Duration maxDuration;
}
