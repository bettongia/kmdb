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

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:kmdb/kmdb.dart';
// `decodeText`/`CharsetDecodeResult` are intentionally internal to `kmdb`
// (see charset_util.dart's own library doc: "internal only ... not exported
// from kmdb.dart") — `PlainTextExtractor` (in-package) is the only intended
// caller today. Per the WI-9 plan, this extractor reuses the same WI-2
// charset-detection utility rather than re-implementing it or requiring a
// core `kmdb` export change, so this import intentionally reaches into
// `kmdb`'s `src/` tree; the lint is suppressed for this one, deliberate case.
// ignore: implementation_imports
import 'package:kmdb/src/vault/search/charset_util.dart';

/// Extracts plain text from `text/html` vault blobs using the
/// [html](https://pub.dev/packages/html) package's tolerant DOM parser.
///
/// ## Why not `Element.text`/`Node.text`?
///
/// The `html` package's built-in `text` getter (`dom.dart`'s
/// `_ConcatTextVisitor`) is a bare recursive visitor that concatenates every
/// descendant `Text` node's data with **no separator** and **no tag-based
/// filtering**. Using it directly would silently corrupt extracted text in
/// two ways:
///
/// 1. **Token fusion across block boundaries.** `<p>Hello</p><p>World</p>`
///    would flatten to `"HelloWorld"` — two paragraphs' worth of prose glued
///    into one word, actively harmful to both BM25 and embedding-based
///    retrieval.
/// 2. **Script/style source leakage.** `<script>`/`<style>` subtrees are not
///    excluded, so their raw JS/CSS source would be concatenated in as if it
///    were prose, polluting the index with code tokens.
///
/// [HtmlTextExtractor] therefore implements its own recursive node walk
/// ([_walkNode]/[_walkElement]) that skips non-prose subtrees and inserts
/// boundary whitespace around every element, rather than reusing that getter.
/// This mirrors the same class of primitive-choice bug WI-6 found and fixed
/// in `VaultChunker` (using the wrong text-extraction primitive silently
/// produces `indexed`-but-garbage content, not a crash).
///
/// ## Walk algorithm
///
/// - Prefers walking `document.body` (present for any well-formed document —
///   the `html` package tolerantly synthesizes `<html>`/`<head>`/`<body>`
///   per the WHATWG parsing algorithm, matching real browser behavior for
///   malformed input). Falls back to the whole [dom.Document] if `body` is
///   somehow absent (a defensive fallback for pathological fragments; not
///   expected to trigger given `parse()`'s tolerant synthesis).
/// - `script`, `style`, and `noscript` element subtrees are skipped
///   entirely — neither their text nor their descendants are visited.
/// - Every other element contributes a boundary character on both sides of
///   its recursed children: `\n` for a fixed set of known block-level tags
///   (`p`, `div`, `li`, headings, table rows, etc. — see [_blockTags]),
///   a single space for everything else (inline elements like `span`,
///   `a`, `b`/`strong`, `i`/`em`). Adding the boundary on *both* sides (not
///   just between siblings) guards against fusion even when two elements are
///   textually adjacent in the source with no whitespace between them (e.g.
///   `<b>Hello</b><i>World</i>`).
/// - `Text` node data is appended verbatim — HTML entity decoding is already
///   handled by the parser (`Text.data` holds decoded character data), so no
///   extra unescaping step is needed.
/// - The raw walk output (full of single-purpose boundary characters) is
///   collapsed at the end: any run of whitespace containing a newline
///   collapses to a single `\n`; any remaining run of horizontal whitespace
///   collapses to a single space. **This collapse must never reduce a
///   boundary to zero characters** — collapsing `\n{2,}` to `\n` (not to
///   `""`) is what keeps adjacent blocks from re-fusing after the whitespace
///   cleanup pass undoes the separator the walk just inserted.
///
/// ## Charset handling (known limitation)
///
/// Raw bytes are decoded via `decodeText()` (the same WI-2 charset-detection
/// utility [PlainTextExtractor] uses) before being handed to `html`'s
/// `parse()`. The detected charset is **not** recorded anywhere —
/// `VaultIndexingIsolate`'s charset side-channel is wired to the concrete
/// `PlainTextExtractor` type only (a hardcoded `is PlainTextExtractor`
/// check), and generalizing it to other extractors is a core `kmdb` change
/// out of scope for this package. This matches [PdfTextExtractor]'s existing
/// behavior — it also records no charset. A practical consequence: a
/// `<meta charset="...">` declaration that disagrees with `decodeText()`'s
/// byte-level heuristic is not specially honored. This is a narrow, accepted
/// gap — most HTML in the wild is UTF-8, where the two approaches agree.
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(extractors: [HtmlTextExtractor()]),
/// );
/// ```
final class HtmlTextExtractor implements VaultTextExtractor {
  /// Creates an [HtmlTextExtractor].
  ///
  /// [limits] bounds the input size this extractor will attempt to parse
  /// and the depth of the document tree walk it will perform; defaults to
  /// [ExtractorLimits.defaults]. A document that exceeds either bound is
  /// declined (`null`) rather than truncated — see [ExtractorLimits] for
  /// the rationale, and the class-level doc for why the depth cap alone
  /// does not protect the parser stage.
  const HtmlTextExtractor({this.limits = ExtractorLimits.defaults});

  /// The resource bounds this extractor honours. See [ExtractorLimits].
  final ExtractorLimits limits;

  /// Element subtrees whose content (and descendants) are never visited —
  /// their text is not prose and would otherwise pollute the extracted text
  /// with JS/CSS source or noscript fallback markup.
  static const _skippedTags = {'script', 'style', 'noscript'};

  /// A fixed, deliberately-not-exhaustive set of block-level tags that get a
  /// `\n` boundary (rather than a plain space) on both sides of their
  /// content. This is the "simple, defensible v1 rule" called for by the
  /// plan's investigation: newline around a known set of block tags, space
  /// everywhere else, then collapse excess whitespace.
  static const _blockTags = {
    'p',
    'div',
    'br',
    'li',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'tr',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'caption',
    'blockquote',
    'ul',
    'ol',
    'dl',
    'dd',
    'dt',
    'section',
    'article',
    'header',
    'footer',
    'nav',
    'aside',
    'figure',
    'figcaption',
    'pre',
    'hr',
    'address',
    'main',
    'details',
    'summary',
    'form',
    'fieldset',
    'legend',
  };

  /// Collapses whitespace introduced by the walk while preserving at least
  /// one boundary character between blocks/inline runs.
  ///
  /// Any run of whitespace that contains a newline collapses to a single
  /// `\n`; any remaining run of horizontal whitespace collapses to a single
  /// space. The result is then trimmed of leading/trailing whitespace. This
  /// never collapses a boundary to nothing — see the class-level doc for why
  /// that invariant matters (a plan-reviewer-flagged correctness note).
  static String _collapseWhitespace(String raw) {
    final withCollapsedNewlines = raw.replaceAll(
      RegExp(r'[ \t]*\n[ \t\n]*'),
      '\n',
    );
    final withCollapsedSpaces = withCollapsedNewlines.replaceAll(
      RegExp(r'[ \t]+'),
      ' ',
    );
    return withCollapsedSpaces.trim();
  }

  /// Recursively walks [node], appending extracted text to [sb].
  ///
  /// Dispatches to [_walkElement] for [dom.Element] nodes (which may be
  /// skipped or bounded per the class-level rules); [dom.Text] node data is
  /// appended verbatim; any other node type simply recurses into its
  /// children with no boundary. This generic fallback exists for two node
  /// types that both never appear with children when reached via this
  /// walk in practice with the current `html` package version — verified
  /// empirically, not merely assumed:
  ///
  /// - [dom.Comment] nodes can appear nested inside a document's `<body>`
  ///   subtree (e.g. `<p>Hello<!-- x -->World</p>`), but [dom.Comment.nodes]
  ///   is always empty, so the loop body below never executes for them.
  /// - The `document.body ?? document` fallback in [extract] only takes the
  ///   `document` (whole [dom.Document]) branch when `body` is absent —
  ///   which `html.parse()`'s tolerant WHATWG-style synthesis means does not
  ///   happen for any input tried (empty, whitespace-only, fragments with no
  ///   `<html>`/`<body>` wrapper all still get a synthesized `<body>`). This
  ///   branch is kept as defensive coding per the plan's investigation notes
  ///   (a future `html` package version is not guaranteed to preserve that
  ///   synthesis behavior), not as evidence it is exercised today.
  ///
  /// Both cases are therefore excluded from coverage accounting below —
  /// they are deliberately-defensive, not dead, code.
  ///
  /// [depth] is the current node's nesting depth (0 at the walk root);
  /// threaded through so [_walkElement] can enforce [ExtractorLimits.maxRecursionDepth]
  /// at its own recursive descent, per the class-level doc's depth-cap note.
  static void _walkNode(
    dom.Node node,
    StringBuffer sb,
    int depth,
    ExtractorLimits limits,
  ) {
    if (node is dom.Text) {
      sb.write(node.data);
    } else if (node is dom.Element) {
      _walkElement(node, sb, depth, limits);
    } else {
      // coverage:ignore-start
      for (final child in node.nodes) {
        _walkNode(child, sb, depth, limits);
      }
      // coverage:ignore-end
    }
  }

  /// Walks [element]'s subtree, applying the skip/boundary rules described
  /// in the class-level doc comment.
  ///
  /// Enforces [ExtractorLimits.maxRecursionDepth]: before descending into
  /// this element's children, the depth counter is incremented and checked.
  /// A document nested deeper than the limit throws [_RecursionLimitExceeded],
  /// which propagates up through the recursive calls to [extract]'s
  /// catch-all — a hostile document must yield `null`, not a
  /// truncated-but-plausible result.
  static void _walkElement(
    dom.Element element,
    StringBuffer sb,
    int depth,
    ExtractorLimits limits,
  ) {
    final tag = element.localName;
    if (tag != null && _skippedTags.contains(tag)) {
      // Skip the entire subtree — neither this element's descendants' text
      // nor any boundary character for it is emitted.
      return;
    }
    final boundary = (tag != null && _blockTags.contains(tag)) ? '\n' : ' ';
    sb.write(boundary);
    final childDepth = depth + 1;
    if (childDepth > limits.maxRecursionDepth) {
      throw const _RecursionLimitExceeded();
    }
    for (final child in element.nodes) {
      _walkNode(child, sb, childDepth, limits);
    }
    sb.write(boundary);
  }

  @override
  Set<String> get supportedMediaTypes => const {'text/html'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    // Decline oversized input before any parsing begins. This is also the
    // parser-stage stack-overflow guard: a pathologically nested document is
    // necessarily large, so this gate catches it before html_parser.parse()
    // ever builds a tree (see ExtractorLimits' class doc).
    if (bytes.length > limits.maxInputBytes) {
      return null;
    }

    try {
      final decoded = decodeText(bytes).text;
      final document = html_parser.parse(decoded);
      // Prefer the <body> subtree (present for any well-formed document —
      // parse() tolerantly synthesizes html/head/body per the WHATWG
      // algorithm); fall back to the whole Document for the defensive case
      // where body is somehow absent.
      final root = document.body ?? document;

      final buffer = StringBuffer();
      _walkNode(root, buffer, 0, limits);
      return _collapseWhitespace(buffer.toString());
    } catch (e) {
      // Never throw, per the VaultTextExtractor contract. Catches both
      // ordinary parse/decode errors and _RecursionLimitExceeded.
      return null;
    }
  }
}

/// Thrown internally by [HtmlTextExtractor._walkElement] when a document's
/// tree walk exceeds [ExtractorLimits.maxRecursionDepth]. Caught by
/// [HtmlTextExtractor.extract]'s catch-all, which returns `null` per the
/// [VaultTextExtractor] contract. Never escapes the extractor.
final class _RecursionLimitExceeded implements Exception {
  const _RecursionLimitExceeded();
}
