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

import 'package:kmdb/kmdb.dart';
// See kmdb_extractor_html's html_text_extractor.dart for the identical
// rationale: decodeText/CharsetDecodeResult are intentionally internal to
// `kmdb` (charset_util.dart's own library doc says so), but this extractor
// reuses the same WI-2 charset-detection utility PlainTextExtractor uses
// rather than re-implementing it or requiring a core kmdb export change.
// ignore: implementation_imports
import 'package:kmdb/src/vault/search/charset_util.dart';
import 'package:markdown/markdown.dart' as md;

/// Extracts plain text from `text/markdown` vault blobs by walking the
/// [markdown](https://pub.dev/packages/markdown) package's parsed AST.
///
/// ## Why not `Node.textContent`?
///
/// The `markdown` package's built-in `textContent` getter (`ast.dart`) is a
/// bare `children.map((c) => c.textContent).join()` with no block-boundary
/// separator and no special-casing for code blocks, links, or images — the
/// same class of primitive-choice bug as HTML's `Element.text` (see
/// `kmdb_extractor_html`'s `HtmlTextExtractor` doc comment for the shared
/// rationale, discovered together during this plan's investigation).
/// [MarkdownTextExtractor] implements its own recursive walk instead
/// ([_walkNode]), applying the rules below.
///
/// ## `Document` configuration — not the bare default
///
/// This extractor constructs
/// `Document(encodeHtml: false, extensionSet: ExtensionSet.gitHubWeb)`,
/// **not** the bare `Document()` default. Two reasons, both load-bearing:
///
/// 1. **`encodeHtml` defaults to `true`.** With the default, the parser
///    HTML-escapes text *at parse time*, mutating the AST's `Text` node data
///    itself (not just rendered HTML output) — a backslash-escaped or
///    literal `&`/`<`/`>`/`"` in prose becomes `&amp;`/`&lt;`/… in the `Text`
///    node. Walking the AST would then yield `&amp;` where the author wrote
///    `&` — the exact silent-corruption class this plan was written to
///    avoid. `encodeHtml: false` keeps `Text` nodes holding raw characters.
/// 2. **The default `extensionSet` (`commonMark`) has no table support.**
///    GFM tables, strikethrough, and extension autolinks are only parsed
///    into structured AST nodes under `gitHubFlavored`/`gitHubWeb` — under
///    `commonMark` a Markdown table arrives as literal `|`/`-` paragraph
///    text. Note exports (Obsidian, Bear, GitHub) routinely use these
///    extensions, so `ExtensionSet.gitHubWeb` (a superset of
///    `gitHubFlavored`, additionally adding heading-id anchors, emoji
///    shortcodes, color swatches, and GitHub alert blocks) is the closer
///    match to real-world vault content.
///
/// `gitHubWeb`'s extra syntaxes all park their non-prose payload (heading
/// `id`s, checkbox `input` elements, color-swatch `style` attributes, alert
/// `class` attributes) in element *attributes*, which this visitor never
/// reads — only `Text`-node data and `img`'s `alt` attribute are emitted, so
/// none of the extra syntaxes reintroduce the corruption class described
/// above. An emoji shortcode (e.g. `:smile:`) is emitted as a plain `Text`
/// node by `EmojiSyntax`, so it comes through as the real emoji character.
///
/// ## Walk algorithm
///
/// - `Text` nodes — appended verbatim.
/// - `pre` elements — the entire subtree is **skipped** (drops both fenced
///   and indented code block content). This is a deliberate, documented v1
///   limitation, not a bug: source code tokens add BM25/embedding noise with
///   little retrieval value, and code-aware search is a different, harder
///   problem than prose search. A bare `code` element (inline code, never
///   `pre`-wrapped in this package's AST) is **not** skipped — it recurses
///   normally, keeping its text with the backtick markers already stripped
///   by the parser.
/// - `img` elements — always self-closing (no children); the visible
///   content lives in the `alt` attribute, not as a child node, so this is
///   special-cased: `element.attributes['alt']` is emitted if present and
///   non-empty. The image URL (`src` attribute) is never read.
/// - `a` (link) elements — recursed into normally; the visible link text is
///   an ordinary child node, while the URL lives only in the `href`
///   attribute (never visited), so link text is kept and the URL dropped for
///   free with no special-casing needed.
/// - Other block-level elements (`p`, headings, `li`, `blockquote`, table
///   rows, etc.) get a `\n` boundary on both sides of their children, for
///   the same anti-fusion reason as the HTML extractor; everything else
///   (including elements introduced by `gitHubWeb`'s extra syntaxes that
///   this visitor doesn't explicitly know about, like `div` alert blocks or
///   `input` checkboxes) falls through to a plain-space boundary via the
///   generic recurse-into-children behavior, so unrecognized/extension
///   syntax degrades gracefully instead of being silently dropped.
///
/// ## Charset handling
///
/// Raw bytes are decoded via `decodeText()` (the same WI-2 utility
/// `PlainTextExtractor`/`HtmlTextExtractor` use) before parsing. Markdown has
/// no in-document charset declaration equivalent to HTML's `<meta
/// charset>`, so there is no analogous "declared vs. detected" gap here.
///
/// ## Why not round-trip through HTML?
///
/// This extractor walks the `markdown` package's own AST directly rather
/// than rendering to HTML (`markdownToHtml()`) and reusing
/// `kmdb_extractor_html`'s walk. That would pull `kmdb_extractor_markdown`
/// into a transitive dependency on both the `html` package and
/// `kmdb_extractor_html`, double-parse the content, and make code-block/
/// link/image handling implicit against HTML rendering choices rather than
/// explicit against the `markdown` package's own AST shapes.
///
/// ## Example
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
/// );
/// ```
final class MarkdownTextExtractor implements VaultTextExtractor {
  /// Creates a [MarkdownTextExtractor].
  const MarkdownTextExtractor();

  /// Block-level tags that get a `\n` boundary (rather than a plain space)
  /// on both sides of their content — mirrors `HtmlTextExtractor`'s
  /// `_blockTags` list, adapted to the tag vocabulary the `markdown` package
  /// actually emits (headings, list items, blockquotes, table rows, etc.).
  static const _blockTags = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'ul',
    'ol',
    'blockquote',
    'tr',
    'table',
    'thead',
    'tbody',
    'hr',
  };

  /// Collapses whitespace introduced by the walk while preserving at least
  /// one boundary character between blocks/inline runs — identical policy to
  /// `HtmlTextExtractor._collapseWhitespace` (see its doc for the rationale).
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
  static void _walkNode(md.Node node, StringBuffer sb) {
    if (node is md.Text) {
      sb.write(node.text);
    } else if (node is md.Element) {
      _walkElement(node, sb);
    }
    // md.UnparsedContent should not appear in a fully-parsed document (it is
    // an internal placeholder used only mid-parse to gather reference link
    // definitions — see the markdown package's own ast.dart doc comment), so
    // no case is needed for it here.
  }

  /// Walks [element]'s subtree, applying the skip/special-case/boundary
  /// rules described in the class-level doc comment.
  static void _walkElement(md.Element element, StringBuffer sb) {
    final tag = element.tag;

    if (tag == 'pre') {
      // Drop fenced/indented code block content entirely (Q4) — never
      // recurse into a pre subtree.
      return;
    }

    if (tag == 'img') {
      // Self-closing — alt text lives in the attribute, not a child node.
      final alt = element.attributes['alt'];
      if (alt != null && alt.isNotEmpty) {
        sb
          ..write(' ')
          ..write(alt)
          ..write(' ');
      }
      return;
    }

    // 'a' (link) elements, bare 'code' (inline code), and every other
    // element type (including gitHubWeb extras like alert-block 'div',
    // checkbox 'input', or color-swatch 'span' this visitor doesn't
    // explicitly special-case) all fall through to the same generic
    // recurse-into-children behavior below — only the boundary character
    // differs based on whether the tag is a known block-level tag.
    final boundary = _blockTags.contains(tag) ? '\n' : ' ';
    sb.write(boundary);
    final children = element.children;
    if (children != null) {
      for (final child in children) {
        _walkNode(child, sb);
      }
    }
    sb.write(boundary);
  }

  @override
  Set<String> get supportedMediaTypes => const {'text/markdown'};

  @override
  Future<String?> extract(Uint8List bytes, VaultManifest manifest) async {
    try {
      final decoded = decodeText(bytes).text;
      final document = md.Document(
        encodeHtml: false,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );
      final nodes = document.parse(decoded);

      final buffer = StringBuffer();
      for (final node in nodes) {
        _walkNode(node, buffer);
      }
      return _collapseWhitespace(buffer.toString());
    } catch (e) {
      // Never throw, per the VaultTextExtractor contract.
      return null;
    }
  }
}
