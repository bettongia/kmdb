# kmdb_extractor_html

HTML text extractor for [KMDB](https://github.com/bettongia/kmdb) vault
search — a `VaultTextExtractor` implementation for `text/html` blobs, using
the [`html`](https://pub.dev/packages/html) package's tolerant DOM parser.

---

## Overview

`package:kmdb_extractor_html` provides `HtmlTextExtractor`, which implements
`VaultTextExtractor` from `package:kmdb`. Register it on
`VaultSearchConfig.extractors` to make `text/html` vault blobs searchable via
`KmdbCollection.searchVault()`:

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_html/kmdb_extractor_html.dart';

final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  vaultStore: vaultStore,
  vaultSearch: VaultSearchConfig(extractors: [HtmlTextExtractor()]),
);
```

`PlainTextExtractor` (`text/plain`) is always included automatically by
`VaultSearchConfig` — most applications only need to add
`HtmlTextExtractor()` to the list.

See `example/html_extractor_example.dart` for a complete, runnable example.

---

## Why a custom text walk?

The `html` package's built-in `Element.text`/`Node.text` getter concatenates
every descendant `Text` node's data with **no separator** and **no
script/style filtering** — using it directly would fuse adjacent block
elements' text together (`<p>Hello</p><p>World</p>` → `"HelloWorld"`) and
concatenate raw `<script>`/`<style>` source in as if it were prose.
`HtmlTextExtractor` implements its own recursive walk instead: it skips
`script`/`style`/`noscript` subtrees entirely and inserts boundary
whitespace (`\n` for block-level tags, a space otherwise) around every
element, then collapses the resulting whitespace at the end without ever
reducing a boundary to nothing.

An HTML document that is 100% `<script>`/`<style>`/`<noscript>` still
results in the blob being marked `indexed` (with zero searchable chunks) —
not `failed` or `unsupported` — consistent with how `PlainTextExtractor`
handles an empty `text/plain` blob.

---

## Known limitations

- **No charset side-channel.** Raw bytes are decoded via the same WI-2
  charset-detection utility `PlainTextExtractor` uses, but the detected
  charset is not recorded anywhere — that side-channel in `package:kmdb`'s
  vault indexing isolate is wired to the concrete `PlainTextExtractor` type
  only. A practical consequence: a `<meta charset="...">` declaration that
  disagrees with the byte-level charset heuristic is not specially honored.
  This is a narrow, accepted gap — most HTML in the wild is UTF-8, where the
  two approaches agree.
- **No `lang` attribute wiring.** A source-declared `lang` attribute is not
  fed into `VaultExtractionState`'s language/script metadata — that metadata
  is populated only from text-based detection, run over the extracted text
  itself, the same as every other extractor.

---

## Platform support

Vault search indexing runs exclusively in a native (non-web) indexing
pipeline — web is excluded from KMDB text search entirely. Unlike
`kmdb_extractor_pdf`, this package is pure Dart with no native/FFI
dependencies, so macOS, Linux, Windows, iOS, and Android are all supported
with no extra setup.

---

## Development

This package is part of the KMDB Dart workspace. From the workspace root:

```bash
dart pub get
cd packages/kmdb_extractor_html
dart test
```
