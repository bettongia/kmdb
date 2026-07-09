# kmdb_extractor_markdown

Markdown text extractor for [KMDB](https://github.com/bettongia/kmdb) vault
search — a `VaultTextExtractor` implementation for `text/markdown` blobs,
using the [`markdown`](https://pub.dev/packages/markdown) package's AST
parser.

---

## Overview

`package:kmdb_extractor_markdown` provides `MarkdownTextExtractor`, which
implements `VaultTextExtractor` from `package:kmdb`. Register it on
`VaultSearchConfig.extractors` to make `text/markdown` vault blobs
searchable via `KmdbCollection.searchVault()`:

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';

final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  vaultStore: vaultStore,
  vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
);
```

`PlainTextExtractor` (`text/plain`) is always included automatically by
`VaultSearchConfig` — most applications only need to add
`MarkdownTextExtractor()` to the list.

See `example/markdown_extractor_example.dart` for a complete, runnable
example.

---

## Why a custom AST walk, and non-default `Document` configuration?

The `markdown` package's built-in `Node.textContent` getter joins every
descendant node's text with no block-boundary separator and no special
handling for code blocks, links, or images. `MarkdownTextExtractor`
implements its own recursive walk instead, and constructs the parser as:

```dart
Document(encodeHtml: false, extensionSet: ExtensionSet.gitHubWeb)
```

**Not** the bare `Document()` default, for two load-bearing reasons:

1. **`encodeHtml` defaults to `true`.** With the default, the parser
   HTML-escapes text *at parse time* — a literal `&` in prose becomes
   `&amp;` in the AST's `Text` node itself, not just in rendered HTML
   output. `encodeHtml: false` keeps `Text` nodes holding raw characters.
2. **The default `extensionSet` (`commonMark`) has no table support.** GFM
   tables, strikethrough, and emoji shortcodes — all common in real
   note-taking exports (Obsidian, Bear, GitHub) — are only parsed into
   structured AST nodes under `gitHubFlavored`/`gitHubWeb`.

---

## Known limitations

- **Code block content is dropped (v1).** Fenced and indented code block
  *content* is excluded from extracted text entirely — only inline code
  spans (e.g. `` `foo()` `` in running prose) are kept. Source code tokens
  add retrieval noise with little value for prose search, and code-aware
  search is a different, harder problem. A Markdown document that is 100% a
  single code block still results in the blob being marked `indexed` (with
  zero searchable chunks), not `failed` or `unsupported`.
- **No charset side-channel.** Same limitation as `kmdb_extractor_html` —
  the detected charset is not recorded in `VaultExtractionState`. Markdown
  has no in-document charset declaration equivalent to HTML's `<meta
  charset>`, so there is no "declared vs. detected" gap here specifically.

---

## Platform support

Vault search indexing runs exclusively in a native (non-web) indexing
pipeline — web is excluded from KMDB text search entirely. Like
`kmdb_extractor_html`, this package is pure Dart with no native/FFI
dependencies, so macOS, Linux, Windows, iOS, and Android are all supported
with no extra setup.

---

## Development

This package is part of the KMDB Dart workspace. From the workspace root:

```bash
dart pub get
cd packages/kmdb_extractor_markdown
dart test
```
