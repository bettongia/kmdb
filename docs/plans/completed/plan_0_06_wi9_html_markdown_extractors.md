# WI-9: HTML / Markdown Extractors

**Status**: Complete

**PR link**: —

## Problem statement

Vault search (WI-3, WI-8) extracts text from `text/plain` (`PlainTextExtractor`,
core `kmdb`) and `application/pdf` (`PdfTextExtractor`, `kmdb_extractor_pdf`)
vault blobs. `text/html` and `text/markdown` blobs — common for web-clipped
content and note-taking exports — have no matching `VaultTextExtractor` and are
recorded `unsupported`, invisible to `searchVault()`.

This plan adds two new optional packages, following the `kmdb_extractor_<name>`
convention established by `kmdb_extractor_pdf` (WI-8) and documented in
[Technical Proposal: Vault File Search](../proposals/vault_search.md) §2.3:

- **`kmdb_extractor_html`** — `HtmlTextExtractor` for `text/html`, using the
  `html` package.
- **`kmdb_extractor_markdown`** — `MarkdownTextExtractor` for `text/markdown`,
  using the `markdown` package.

**No core `kmdb` changes are required** — same extension point WI-8 used
(`VaultTextExtractor` interface, `VaultSearchConfig.extractors` list, isolate
dispatch). Both new packages are pure Dart with no native/FFI dependencies —
substantially simpler than `kmdb_extractor_pdf`, which had to reason about
`betto_pdfium`'s native isolate composition.

A design alternative was considered and decided with the user up front: bundle
both formats into a single package (`kmdb_extractor_text`, or a generic
`betto_text_extractor` reusable outside `kmdb`) to reduce per-package overhead.
**Decision: keep two packages**, matching the already-published proposal wording
and the WI-8 precedent. `kmdb-architect` confirmed dispatch is by
`supportedMediaTypes` set membership only — nothing in code depends on package
or class naming — so this was a pure convention choice, not a technical
constraint. `kmdb_extractor_pdf` is workspace-local (`publish_to: none`), so the
"publishing" overhead of a second package is in practice just one more
`pubspec.yaml`/`README.md`/CI list entry, not a pub.dev release.

## Open questions

- [x] **Q1 — Package split.** Resolved with the user: two packages,
      `kmdb_extractor_html` and `kmdb_extractor_markdown`, per the roadmap and
      proposal §2.3 (see Problem statement).
- [x] **Q2 — HTML text-flattening strategy.** Resolved: **do not** use
      `Element.text`/`Node.text` (the `html` package's built-in getter). Its
      implementation (`dom.dart:1103`, `_ConcatTextVisitor`) is a bare
      `TreeVisitor` that (a) concatenates all descendant `Text` node data with
      **no boundary whitespace** between elements, and (b) does **not** exclude
      `<script>`/`<style>` subtrees — their raw JS/CSS source would be
      concatenated in as if it were prose. Both are silent-corruption bugs, not
      crashes — the same class of issue WI-6 found and fixed in `VaultChunker`
      (using the wrong text-extraction primitive produces technically-non-null,
      technically-`indexed`, but garbage or token-fused content).
      `HtmlTextExtractor` must implement its own recursive node walk (see
      Investigation) that skips `script`/`style` subtrees and inserts a
      separator between block-level elements.
- [x] **Q3 — HTML charset handling.** Resolved: reuse `decodeText()`
      (`charset_util.dart`, the same WI-2 utility `PlainTextExtractor` uses) to
      decode the raw bytes to a `String` before handing it to `html`'s
      `parse()`. **Known, accepted limitation:** the charset side-channel
      (`VaultIndexingIsolate`'s `lastCharset` read, gated by a hardcoded
      `is PlainTextExtractor` check at `vault_indexing_isolate.dart:397`) does
      not extend to other extractors without a core change, which is out of
      scope here (WI-9's premise is no core changes). `HtmlTextExtractor`
      therefore records no charset in `VaultExtractionState` (`charset: null`,
      diagnostic-only field) — same as `PdfTextExtractor` today. A
      `<meta charset="...">` declaration that disagrees with `decodeText()`'s
      byte-level heuristic is not specially honored; this is a narrow,
      documented gap (most HTML in the wild is UTF-8, where the two approaches
      agree) rather than something to build a second decoding pass for. Markdown
      has no equivalent in-document charset declaration, so this limitation is
      HTML-only.
- [x] **Q4 — Markdown code block handling.** Resolved: **drop the content of
      fenced and indented code blocks entirely** (not just the fence/indent
      markers) in v1, matching the roadmap's literal wording ("removing fenced
      code blocks ... is sufficient"). Rationale: source code tokens
      (identifiers, punctuation-heavy syntax) add BM25/embedding noise with
      little retrieval value, and code-aware search is a different, harder
      problem than prose search. **Inline code spans are kept** (e.g.
      `` `foo()` `` in running text) — only their backtick markers are stripped,
      which the parser already does by representing them as an AST node rather
      than literal characters. This is a clean distinction in the `markdown`
      package's AST: both fenced (`fenced_code_block_syntax.dart:44`) and
      indented (`code_block_syntax.dart:65`) code blocks are always wrapped as
      `Element('pre', [Element.text('code', content)])`, while inline code
      (`code_syntax.dart:64`) is a bare `Element.text('code', ...)` with no
      `pre` parent. The visitor therefore only needs to special-case the `pre`
      tag (skip its subtree) — a standalone `code` element is always inline and
      its text is kept. Noted as a documented v1 limitation (not a bug): code
      content is not searchable. A future opt-in flag could change this without
      an interface change.
- [x] **Q5 — Markdown extraction strategy.** Resolved: implement
      `MarkdownTextExtractor` as a direct AST walk (custom
      `NodeVisitor`/recursive `Node` walk over `Document().parse(text)`'s
      output), **not** by rendering to HTML (`markdownToHtml()`) and reusing
      `kmdb_extractor_html`'s logic. Keeps the two packages fully independent
      per Q1 (pulling in `kmdb_extractor_markdown` would otherwise transitively
      pull in the `html` package and `kmdb_extractor_html`'s flattening logic),
      avoids a double-parse, and keeps code-block/link/image handling explicit
      against the `markdown` package's own AST rather than its HTML rendering.
- [x] **Q6 — Link and image text.** Resolved, verified against `markdown` 7.3.1
      source: `a` (link) elements carry the visible link text as normal child
      nodes — walking children naturally keeps the text and drops the URL (which
      lives only in the `href` attribute, never visited). `img` (image) elements
      are always self-closing (`Element.empty('img')`, `image_syntax.dart:22`)
      with alt text stored in the `alt` **attribute**, not as a child — these
      must be special-cased: emit `element.attributes['alt']` if non-empty when
      the visitor encounters an `img` tag, since there are no children to
      recurse into.
- [x] **Q7 — HTML `lang` attribute / source-declared language metadata.**
      Resolved: **out of scope for this plan.** §32 of the spec already notes an
      HTML `lang` attribute as a plausible future input to
      `VaultExtractionState.language`/`script`, but no such field-population
      path exists today (WI-6's `language`/`script` fields are populated only
      from `dominantScript()`/`detectLanguageForStemming()` run over extracted
      text). Wiring source-declared language metadata into extraction state
      would be a core change and is a separate, future-facing enhancement — not
      needed for HTML text to be searchable.
- [x] **Q9 — Markdown `Document` configuration (BLOCKING — reviewer 2026-07-09;
      ratified by plan author 2026-07-09).** The implementation checklist
      previously said `Document().parse(decoded)`. The bare default constructor
      is **wrong for a text extractor** on two counts, both verified against
      `markdown` 7.3.1 source: 1. **`encodeHtml` defaults to `true`**
      (`document.dart:52`), and with it the parser HTML-escapes text _at parse
      time_, mutating the AST `Text` node data — not just the rendered HTML
      output. A backslash-escaped or literal `&`/`<`/`>`/`"` in prose becomes
      `&amp;`/`&lt;`/… in the `Text` node (`escape_syntax.dart:25`,
      `escape_html_syntax.dart:15`, `code_syntax.dart:60`). Walking the AST
      therefore yields `&amp;` where the author wrote `&` — the _exact_
      silent-corruption class this plan was written to avoid (mirror of Q2's
      `Element.text` pitfall, but on the Markdown side). **Resolved: the
      extractor constructs `Document(encodeHtml:        false, …)`** so `Text`
      nodes hold raw characters — not a real choice, a bug fix. A test fixture
      whose prose contains `&`, `<`, `>` asserts they survive un-escaped. 2.
      **The default `extensionSet` is `ExtensionSet.commonMark`**
      (`document.dart:67`), which does **not** include `TableSyntax` (only
      `gitHubWeb`/`gitHubFlavored` do — `extension_set.dart:57,77`). Under
      commonMark, GFM tables, strikethrough, and extension autolinks are never
      parsed into structured AST nodes — table markup arrives as literal `|`/`-`
      paragraph text. Note exports (Obsidian, Bear, GitHub) routinely use these.
      **Resolved: pass `extensionSet: ExtensionSet.gitHubWeb`.** Verified
      against `extension_set.dart`: `gitHubWeb` is a superset of
      `gitHubFlavored` (adds `HeaderWithIdSyntax`/`SetextHeaderWithIdSyntax` —
      anchor `id` attributes, irrelevant to text extraction since we walk
      children regardless; `EmojiSyntax` — renders `:emoji:` shortcodes as real
      characters, useful for searchable text; `ColorSwatchSyntax`;
      `AlertBlockSyntax` — GitHub-style `> [!NOTE]` blocks, common in note
      exports) plus `TableSyntax`/strikethrough/autolinks shared with
      `gitHubFlavored`. Closer to what Obsidian/Bear/GitHub actually produce
      than bare commonMark, so it's the right default for vault content. The
      "tables … if enabled by default — confirm" test item is updated to a
      definite expectation below (tables **are** parsed into `TableSyntax` nodes
      and flattened to prose text via the normal block-boundary walk). Does not
      affect the HTML side: the `html` package stores decoded character data in
      `Text.data` regardless, so the plan's "entity decoding already handled"
      claim there is unaffected.
- [x] **Q8 — Test fixture sourcing.** Resolved: unlike WI-8's PDF corpus
      (third-party arXiv papers with licensing considerations), HTML and
      Markdown fixtures can be **first-party and synthetic** with no licensing
      concerns — small, purpose-built `.html`/`.md` files covering each behavior
      below, plus a couple of excerpts from this repository's own Markdown docs
      (e.g. a trimmed copy of a `README.md`) as realistic golden-path content.
      No external corpus needed.

## Investigation

### The `VaultTextExtractor` contract (shipped, unchanged)

`packages/kmdb/lib/src/vault/search/vault_text_extractor.dart:42`:

```dart
abstract interface class VaultTextExtractor {
  Set<String> get supportedMediaTypes;
  Future<String?> extract(Uint8List bytes, VaultManifest manifest);
}
```

MUST NOT throw; return `null` on failure; `bytes` are raw, already-decrypted
blob bytes. No chunking/offset responsibility — `VaultChunker.chunk(String)`
handles that downstream from the returned string alone. Status mapping
(`vault_indexing_isolate.dart`): no extractor matches → `unsupported`; `null` →
`failed`; any string (including `""`) → `indexed` (0 chunks if empty). Both new
extractors should return `""` for genuinely empty results (e.g. an HTML document
that is 100% `<script>`/`<style>`, or a Markdown document that is 100% code
fences) rather than `null` — that is a successful extraction of zero prose text,
not a failure.

Registration has no registry class — `VaultSearchConfig.extractors` is a plain
ordered list, first-match-wins by media type. `PlainTextExtractor` is always
prepended and claims only `text/plain` in code (see the doc-drift note below),
so it does not shadow `text/html`/`text/markdown`.

### Doc drift found: §32's extraction table

`docs/spec/32_vault_search.md` (line 240) currently lists `PlainTextExtractor`
as covering `text/plain, text/*` — this is stale versus
`plain_text_extractor.dart:59` (`supportedMediaTypes => const {'text/plain'}`,
`text/plain` only). If the doc claim were true it would swallow `text/html` and
`text/markdown` before either new extractor could run. This plan corrects that
row alongside adding the two new ones.

### HTML extraction (`kmdb_extractor_html`)

`html` 0.15.6's `parse()` (`package:html/parser.dart`) takes a `String` (or
bytes with an internal decoder) and returns a `Document` (DOM). Do not call
`Element.text`/`Node.text` — verified via source (`dom.dart:1103`,
`_ConcatTextVisitor`) that it is a bare recursive `TreeVisitor` writing every
`Text` node's `data` with no separator and no tag-based filtering, so it would
both fuse adjacent block elements' text (`<p>Hello</p><p>World</p>` →
`"HelloWorld"`) and include `<script>`/`<style>` source verbatim.
`HtmlTextExtractor` implements its own walk instead:

- Prefer walking `document.body` if present (a well-formed HTML document); fall
  back to the whole `Document` for fragments with no `<html>`/`<body>` wrapper
  (the `html` package tolerantly synthesizes structure like a browser, so this
  should be rare but is not guaranteed absent for hand-authored/exported
  fragments).
- Skip `script`, `style`, and `noscript` element subtrees entirely (do not
  recurse into their children).
- Insert a separator (a single `\n`) before/after block-level elements (`p`,
  `div`, `br`, `li`, headings `h1`–`h6`, `tr`, `table`, `blockquote`, etc.) so
  adjacent blocks don't fuse; a plain space is sufficient between inline
  elements (`span`, `a`, `b`/`strong`, `i`/`em`, etc.). A simple, defensible v1
  rule: newline around a fixed known set of block tags, space everywhere else,
  then collapse runs of whitespace at the end (avoids chunking on long runs of
  blank lines from deeply nested empty markup).
- HTML entity decoding is already handled by the parser — `Text.data` is the
  decoded string, no extra work needed.
- Malformed/unclosed tags: the `html` package is deliberately browser-tolerant
  (implements the WHATWG parsing algorithm's error recovery), so malformed input
  should not throw — verify this with a fixture rather than assume it.

### Markdown extraction (`kmdb_extractor_markdown`)

`markdown` 7.3.1's `Document().parse(text)` (`document.dart:84`) returns
`List<Node>` (`Element`/`Text` per `ast.dart`). Do not use `Node.textContent`
(the package's built-in getter, `ast.dart:52`/`68`) for the same reason as
HTML's `Element.text` — it is a bare `children.map((c) => c.textContent).join()`
with no block-boundary separators and no code/link/image special-casing.
`MarkdownTextExtractor` implements a custom `NodeVisitor`
(`accept`/`visitElementBefore`/`visitElementAfter`/`visitText`, per
`ast.dart:94`) or an equivalent recursive walk:

- `visitText` — append the text verbatim.
- Element `pre` — skip the subtree (drops both fenced
  `fenced_code_block_syntax.dart:44` and indented `code_block_syntax.dart:65`
  code blocks, per Q4). A bare `code` element (never `pre`-wrapped) is inline
  code — recurse normally, keeping its text.
- Element `img` — self-closing (no children, per `image_syntax.dart:22`); emit
  `element.attributes['alt']` if present and non-empty, per Q6.
- Element `a` — recurse into children normally; the URL lives only in the `href`
  attribute and is never visited, so link text is kept and the URL dropped for
  free.
- Block-level elements (`p`, headings, `li`, `blockquote`, table rows, etc.) —
  insert a `\n` boundary the same way as the HTML extractor, for the same
  token-fusion reason.
- Any node type not explicitly handled falls through to the generic
  recurse-into-children behavior, so unrecognized/extension syntax degrades
  gracefully rather than being dropped silently.

### Charset

Both extractors decode raw bytes via `decodeText()`
(`packages/kmdb/lib/src/vault/search/charset_util.dart`, the same WI-2 utility
`PlainTextExtractor` uses) before parsing. Neither extractor populates
`VaultExtractionState`'s charset field — that side-channel is wired to the
concrete `PlainTextExtractor` type only (`vault_indexing_isolate.dart:397`,
`if (extractor is PlainTextExtractor)`) and generalizing it is a core change out
of scope here (matches `PdfTextExtractor`'s existing behavior — it also records
no charset).

### Package layout

Both follow the `kmdb_extractor_pdf` template exactly (see
`docs/plans/completed/plan_0_06_wi8_pdf_extractor.md`), but simpler — pure Dart,
no native-assets hook, no isolate-composition concerns:

```
packages/kmdb_extractor_html/
  lib/
    kmdb_extractor_html.dart        (barrel export)
    src/html_text_extractor.dart
  test/
    html_text_extractor_test.dart
    fixtures/                       (synthetic .html files)
  example/html_extractor_example.dart
  pubspec.yaml
  analysis_options.yaml
  README.md

packages/kmdb_extractor_markdown/
  lib/
    kmdb_extractor_markdown.dart
    src/markdown_text_extractor.dart
  test/
    markdown_text_extractor_test.dart
    fixtures/                       (synthetic .md files)
  example/markdown_extractor_example.dart
  pubspec.yaml
  analysis_options.yaml
  README.md
```

Both `pubspec.yaml`s: `publish_to: none`, `resolution: workspace`, depend on
`kmdb:` (for the `VaultTextExtractor` interface — note the interface itself is
not exported from the public `kmdb.dart` barrel today; confirm during
implementation whether it needs adding, since `kmdb_extractor_pdf` already
depends on and implements it, so it likely already is) plus `html: ^0.15.6` or
`markdown: ^7.3.1` respectively as a plain dependency — **no root
`dependency_overrides` entry needed**, since neither package is a
Bettongia-controlled package subject to the workspace's version-pinning
convention (unlike `betto_pdfium`, `betto_zstd`, etc.).

Workspace wiring required:

- Root `pubspec.yaml`: add both packages to the `workspace:` list.
- `make_cicd.mk` `cicd_linux_base`: add both to the `dart format` package list
  (line 30-33).
- Native-asset caveat does **not** apply to these two packages (no native build
  hooks), but `make`/`melos` targets still run `dart test` from inside each
  package directory as standard practice.

### Documentation impact

- `docs/spec/32_vault_search.md` — add `HtmlTextExtractor`/
  `MarkdownTextExtractor` rows to the extraction table; fix the stale
  `text/plain, text/*` claim for `PlainTextExtractor` to just `text/plain`;
  update the "Additional extractors (DOCX, HTML) are out of scope for v1"
  sentence (HTML no longer out of scope; DOCX remains so).
- `packages/kmdb/lib/src/vault/search/vault_text_extractor.dart` — refresh the
  doc comment listing built-in/future extractors (currently says "Future WIs
  will add PDF and HTML extractors"; PDF has shipped, HTML/Markdown are shipping
  now — update to reflect current state, note DOCX as the remaining future
  candidate).
- `CLAUDE.md` Repository Layout — add both new packages, following the
  `kmdb_extractor_pdf` entry's style.
- `docs/roadmap/0_06.md` — flip WI-9's status as the plan progresses.
- Two new package `README.md`s — installation, a short usage example, explicit
  note on the v1 limitations decided in Q3 (no charset side-channel) and Q4
  (code block content dropped).
- Run `make site` after spec edits.

## Implementation plan

- [x] Scaffold `packages/kmdb_extractor_html/` and
      `packages/kmdb_extractor_markdown/` (pubspec, `analysis_options.yaml`,
      license header, barrel export files).
- [x] Add both packages to root `pubspec.yaml` `workspace:` list.
- [x] Add both to the `dart format` list in `cicd_linux_base` (`make_cicd.mk`).
- [x] Confirm `VaultTextExtractor` (and `VaultManifest`) are reachable from the
      public `package:kmdb/kmdb.dart` barrel for external packages to implement
      against; add the export if missing (`kmdb_extractor_pdf` already depends
      on it successfully, so this is likely already fine — verify, don't
      assume). **Verified: both already exported** (`kmdb.dart` lines 124/139,
      per the reviewer's note); no core change needed. **Also discovered:**
      `decodeText`/`CharsetDecodeResult` (`charset_util.dart`) are intentionally
      _not_ exported from `kmdb.dart` (its own library doc says "internal
      only"). Both new extractors import the file directly
      (`package:kmdb/src/vault/search/charset_util.dart`) with a targeted
      `// ignore: implementation_imports` and an explanatory comment, rather
      than adding a new core export — keeps the "no core kmdb changes" premise
      intact while still reusing the WI-2 utility as directed.
- [x] Implement `HtmlTextExtractor implements VaultTextExtractor`:
  - [x] `supportedMediaTypes => const {'text/html'}`.
  - [x] `extract()`: `decodeText(bytes)` → `html.parse(decoded)` → custom
        recursive text walk per Investigation (skip `script`/`style`/ `noscript`
        subtrees, block-boundary `\n`, inline-boundary space, collapse excess
        whitespace at the end) → never throw, `try`/`catch` returning `null` on
        any internal error.
  - [x] Full doc comments per CLAUDE.md: note the `Element.text` pitfall
        explicitly (why a custom walk is required — the two silent-corruption
        failure modes found in Investigation), the no-charset-side-channel
        limitation (Q3), and the extension point convention.
- [x] Implement `MarkdownTextExtractor implements VaultTextExtractor`:
  - [x] `supportedMediaTypes => const {'text/markdown'}`.
  - [x] `extract()`: `decodeText(bytes)` →
        `Document(encodeHtml: false, extensionSet: ExtensionSet.gitHubWeb).parse(decoded)`
        (NOT the bare `Document()` — see Q9: bare defaults escape entities in
        the AST and drop GFM tables) → custom `NodeVisitor`/recursive walk per
        Investigation (skip `pre` subtrees, keep bare `code`, special-case `img`
        alt attribute, keep `a` link text via normal child recursion,
        block-boundary `\n`) → never throw.
  - [x] Full doc comments: the code-block-dropped limitation (Q4), the
        link/image text-vs-URL behavior (Q6), why this does not round-trip
        through HTML (Q5).
- [x] Unit tests for `HtmlTextExtractor` (synthetic fixtures):
  - [x] Golden path — nested block/inline elements, verify no token fusion
        across block boundaries.
  - [x] `<script>`/`<style>` content excluded from output.
  - [x] Document that is 100% `<script>`/`<style>` → `extract()` returns `""`,
        not `null`.
  - [x] HTML entities decode correctly (parser-provided, but assert it).
  - [x] Malformed/unclosed tags → does not throw, produces best-effort text
        (verify actual tolerant-parsing behavior rather than assuming it).
  - [x] Empty bytes / whitespace-only document → `""`.
  - [x] Fragment with no `<html>`/`<body>` wrapper.
- [x] Unit tests for `MarkdownTextExtractor` (synthetic fixtures + a trimmed
      excerpt of a repo `README.md`):
  - [x] Golden path — headings, paragraphs, lists, blockquotes; verify
        block-boundary separation.
  - [x] Fenced code block content excluded; inline code span text kept
        (backticks stripped).
  - [x] Prose containing `&`, `<`, `>` (and backslash-escaped `\&` etc.)
        survives **un-escaped** in the output (regression guard for Q9's
        `encodeHtml: false` requirement — with the default `Document()` these
        would surface as `&amp;`/`&lt;`).
  - [x] Indented code block content excluded.
  - [x] Link `[text](url)` → `text` kept, `url` absent from output.
  - [x] Image `![alt](url)` → `alt` kept, `url` absent; image with empty/no alt
        → contributes nothing.
  - [x] Document that is 100% a single fenced code block → `extract()` returns
        `""`, not `null`.
  - [x] Empty bytes / whitespace-only document → `""`.
  - [x] GFM table (`ExtensionSet.gitHubWeb` parses `TableSyntax` nodes, per Q9 —
        not a "confirm if enabled" question, they are enabled) flattens to
        reasonable text via the normal block-boundary walk.
  - [x] **Attribute-leakage guard (per Q9 follow-up).** `gitHubWeb` adds several
        syntaxes that store non-prose data in element _attributes_ and rely on
        the visitor's generic recurse-into-children fall-through: a GitHub alert
        block (`> [!NOTE]`) → `Element('div', [p 'Note', …])` with `class`
        attrs; a task-list item (`- [x]`) → an `li` containing an
        `Element('input')` with `type`/`checked` attrs; a color swatch
        (`` `#f00` ``) →
        `Element('code', [Text('#f00'), span with style attr])`. Assert the
        output contains the _prose/title_ text (e.g. "Note", the list item's
        text, `#f00`) but **none** of the attribute payloads (`checkbox`,
        `checked`, `markdown-alert`, `gfm-color_chip`, `background-color`). This
        is the structural invariant that keeps the extra syntaxes from
        reintroducing the Q2/Q9 corruption class — the visitor emits only
        `Text`-node data and `img` alt, never attributes.
  - [x] Emoji shortcode (`:smile:`) → the real emoji character appears in the
        output (`EmojiSyntax` emits a plain `Text` node, not an element), per
        Q9's rationale.
- [x] Integration test (one per package, or shared pattern copied from
      `kmdb_extractor_pdf`'s integration test): register the extractor in a real
      `VaultSearchConfig` on a real `KmdbDatabase`, verify
      `vaultIndexingStatus()`/`watchVaultIndexingStatus` reports `indexed` end
      to end through the real vault indexing isolate. Reuse whatever
      `_NativeVaultStore`-style test double `kmdb_extractor_pdf`'s integration
      test needed for `VaultStore.listFilesRecursive` (a known, documented
      pre-existing core gap — do not attempt to fix it here). Written as
      `_TestVaultStore` (the actual class name in WI-8's test, per the
      reviewer's note) in both packages' own `*_integration_test.dart`,
      including the WI-10 encryption scenario.
- [x] `example/` for each package — minimal runnable script showing
      `KmdbDatabase.open(vaultSearch: VaultSearchConfig(extractors: [...]))`.
      Both verified to run cleanly end-to-end (`dart run example/...`).
- [x] `packages/kmdb_extractor_html/README.md` and
      `packages/kmdb_extractor_markdown/README.md` — installation, usage,
      documented v1 limitations (Q3, Q4).
- [x] Update `docs/spec/32_vault_search.md` extraction table + stale `text/*`
      row + "out of scope" sentence.
- [x] Update `vault_text_extractor.dart` doc comment.
- [x] Update `CLAUDE.md` Repository Layout.
- [x] Update `docs/roadmap/0_06.md` WI-9 status/plan link. (Set to
      `Implementing` for now; will flip to `Complete` at the final plan-move
      step alongside the PR.)
- [x] Run `make doc_site` after spec edits. (Note: `site` is not itself a
      real make target — it names the already-checked-in `site/` directory,
      so a bare `make site` silently no-ops. Fixed the stale command in
      `CLAUDE.md`'s Commands section to `make doc_site` as a drive-by fix,
      discovered while completing this checklist item.)

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new files. Both new packages
      are at 100% line coverage (`kmdb_extractor_html`: 28/28 lines;
      `kmdb_extractor_markdown`: 37/37 lines) after adding a
      `coverage:ignore-start/end` block (with rationale comment) around the
      one genuinely defensive, empirically-unreachable-via-`html.parse()`
      fallback branch in `HtmlTextExtractor._walkNode`.
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
      **Sign-off received (2026-07-10):** PASS. Verified spec/Q2/Q4/Q6/Q9
      fidelity, 100% coverage on both new packages (28/28, 37/37 lines), all
      30 tests passing including the attribute-leakage and emoji-passthrough
      guards, doc comment completeness, and code health. Fixed one trivial
      malformed dartdoc reference (`html_text_extractor.dart`) inline during
      review. No blocking issues found.
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      Run directly via Bash (the `kmdb-pre-commit` agent itself could not be
      invoked for the same tool-availability reason) — exit 0, all four
      stages clean.
- [x] Verify licence headers on all new files (2026). Confirmed via a direct
      grep of every new `.dart` file's first line.

## Reviewer notes (2026-07-09)

Full critical pass by `kmdb-plan-reviewer`. **Verdict: Questions** — the plan is
thorough, technically accurate, and all but ready; one blocking correctness gap
(Q9) must be pinned before `Investigated`.

**Claims verified against current source (all hold):**

- `VaultTextExtractor` contract (`vault_text_extractor.dart:42`), MUST-NOT-throw
  / `null`-on-failure, raw decrypted bytes — accurate.
- Status mapping (`vault_indexing_isolate.dart`): no match → `unsupported`
  (`:370`); `null` or throw → `failed` (`:411`, `:400`); any string incl. `""` →
  `indexed`. The "return `""` for genuinely empty" idiom is correct.
- Charset side-channel is a hardcoded `if (extractor is PlainTextExtractor)` at
  `vault_indexing_isolate.dart:397` — confirmed; other extractors cannot surface
  charset without a core change. Q3's accepted-limitation framing is right.
- §32 doc drift confirmed: the extraction table lists `PlainTextExtractor` as
  `text/plain`, `text/*` (stale vs `plain_text_extractor.dart:59`
  `const {'text/plain'}`), and the "DOCX, HTML … out of scope for v1" sentence
  is present. Both corrections are valid.
- `html` `_ConcatTextVisitor` (`dom.dart:1103`/`:1110`) — bare `TreeVisitor`, no
  separator, no `script`/`style` filtering. Q2's rationale for a custom walk is
  correct. `Text.data` holds decoded character data, so "entity decoding already
  handled" is right for the HTML side.
- `markdown` AST shapes all confirmed: fenced/indented code →
  `Element('pre', [Element.text('code', …)])`
  (`fenced_code_block_syntax.dart:44,53`, `code_block_syntax.dart:65`); inline
  code → bare `Element.text('code', code)` (`code_syntax.dart:64`); `img` →
  `Element.empty('img')` with alt in the `alt` attribute
  (`image_syntax.dart:22,27`); `textContent` joins children with no separator
  (`ast.dart:54,58`). Q4/Q5/Q6 are sound.
- **Barrel export is already satisfied:** `VaultTextExtractor`
  (`kmdb.dart:139`), `VaultManifest` (`:124`), and `VaultSearchConfig` (`:138`)
  are all exported. The "confirm/add if missing" checklist item will find
  nothing to add — leave it as a verify step, but it is not a real risk.
- CI wiring is correct and complete: `cicd_linux_base`'s `dart format` list
  (`make_cicd.mk:30-33`) is the only per-package format list covering the
  non-Flutter workspace members; the `macos`/`windows` lanes use
  `melos test_dart` and need no edit. Workspace-wide `melos coverage` picks up
  the new packages automatically once they are in the root `workspace:` list.
- The WI-8 integration-test pattern the plan defers to exists
  (`pdf_text_extractor_integration_test.dart`), including the `VaultStore`
  subclass overriding `listFilesRecursive` for `MemoryStorageAdapter`.

**Blocking:** Q9 (Markdown `Document` config — `encodeHtml: false` is mandatory
for correctness; `extensionSet` is a real choice to ratify).

**Non-blocking clarifications for the implementer (not gating):**

1. **Whitespace-collapse must preserve boundaries.** Q2/HTML says "collapse runs
   of whitespace at the end" while also inserting `\n` between blocks. The
   collapse must leave _at least one_ whitespace char between blocks (e.g.
   collapse `\n{2,}` → `\n`, not → `""`), otherwise it undoes the anti-fusion
   separator it just added. The token-fusion invariant
   (`<p>Hello</p><p>World</p>` ≠ `HelloWorld`) is the thing to assert;
   space-vs-newline doesn't matter to `VaultChunker` beyond "some whitespace
   present."
2. **The integration test defers to two _distinct_ WI-8 accommodations, not
   one.** (a) `_TestVaultStore extends VaultStore` overrides
   `listFilesRecursive` because `MemoryStorageAdapter` is a flat key space (a
   test-double accommodation, not a core bug); (b) the test stops at
   `vaultIndexingStatus()` rather than `searchVault()` because of a _separate_
   real core gap — `VaultRefInterceptor` keys `$vault` refcounts by 64-char
   SHA-256 while `KeyCodec` accepts only 32-char UUIDv7 keys. The plan's
   checklist conflates these under "`listFilesRecursive` … pre-existing core
   gap." Copy the WI-8 test's structure verbatim and do not attempt to fix
   either — but know they are two things.
3. The class in WI-8's test is named `_TestVaultStore`, not `_NativeVaultStore`
   as the checklist says — trivial, the implementer will find it.

## Reviewer follow-up (2026-07-09 — Q9 ratification verified)

Second pass by `kmdb-plan-reviewer` after the plan author ratified Q9
(`encodeHtml: false` mandatory; `extensionSet: ExtensionSet.gitHubWeb`).
**Verdict: Investigated.** All Q9 claims re-verified against `markdown` 7.3.1
source (`.pub-cache/hosted/pub.dev/markdown-7.3.1/lib/src/extension_set.dart`
and the individual syntax files):

- **`TableSyntax` is in `gitHubWeb`: confirmed** — `gitHubWeb.blockSyntaxes`
  lists `const TableSyntax()` alongside `FencedCodeBlockSyntax`,
  `HeaderWithIdSyntax`, `SetextHeaderWithIdSyntax`,
  `Unordered/OrderedListWithCheckboxSyntax`, `FootnoteDefSyntax`,
  `AlertBlockSyntax`; inline set adds `StrikethroughSyntax`, `EmojiSyntax`,
  `ColorSwatchSyntax`, `AutolinkExtensionSyntax`. It is a genuine superset of
  `gitHubFlavored`.
- **No extra `gitHubWeb` syntax reintroduces the Q2/Q9 corruption class.** The
  visitor emits only `Text`-node data plus `img` alt attributes; every extra
  syntax parks its non-prose payload in element _attributes_ the visitor never
  reads:
  - `HeaderWithId`/`SetextHeaderWithId` → `id` attribute (text stays in
    children).
  - `EmojiSyntax` → `parser.addNode(Text(emoji))`, a plain `Text` node with the
    real emoji char — kept verbatim (plan's claim correct).
  - `ColorSwatchSyntax` → `Element('code', [Text('#f00'), span..style])`, a bare
    `code` (not `pre`); Q4 keeps it, `#f00` emitted, the child `span` has no
    text children and its `style` attr is dropped.
  - `AlertBlockSyntax` → `Element('div', [p 'Note', …children])` with `class`
    attrs; handled by generic fall-through, inner `p`s carry boundaries, class
    dropped. It injects a synthetic title word ("Note"/"Warning"/…) — benign
    English prose, not corruption.
  - checkbox lists → `li` with an `Element('input')` child (`type`/`checked`
    attrs, no text children → emits nothing).
  - `FootnoteDefSyntax` → `Element('li', …)` + `id` attr.
- **Descriptive nit (non-blocking):** Q9's rationale enumerates gitHubWeb's
  "extras" as HeaderWithId/SetextHeaderWithId/Emoji/ColorSwatch/AlertBlock and
  calls TableSyntax/strikethrough/autolinks the shared set — it omits the
  checkbox-list and footnote syntaxes, which are also shared with
  `gitHubFlavored`. Harmless to implementation.
- **Guard added:** `div` (alert), nested `span` (color), and `input` (checkbox)
  are not in the visitor's enumerated block/inline tag lists — they ride the
  generic recurse-into-children fall-through, which is correct as specified.
  Added an explicit attribute-leakage regression test to the Markdown test
  checklist so a future implementer who naively emits attributes is caught, plus
  an emoji-passthrough assertion.

No further open questions. The plan clears the implementation-readiness bar.

## Summary

Implemented as planned, with no design deviations from the `Investigated`
checklist. Two new pure-Dart, optional workspace packages were added:

- **`kmdb_extractor_html`** — `HtmlTextExtractor`, a custom DOM walk (not
  `Element.text`) that skips `script`/`style`/`noscript` subtrees and inserts
  block/inline boundary whitespace to prevent token fusion.
- **`kmdb_extractor_markdown`** — `MarkdownTextExtractor`, built on
  `Document(encodeHtml: false, extensionSet: ExtensionSet.gitHubWeb)` per Q9,
  with a custom AST walk that drops fenced/indented code block content, keeps
  inline code, captures `img` alt text, and keeps link text while dropping
  URLs.

Both packages reached 100% line coverage (28/28 and 37/37 lines), passed
`kmdb-qa` sign-off with only one trivial doc-comment fix, and passed
`make pre_commit` cleanly (format, analyze, license_check, tests). Docs
(`docs/spec/32_vault_search.md`, `vault_text_extractor.dart`, `CLAUDE.md`,
`docs/roadmap/0_06.md`) were updated to reflect the new extractors, including
a drive-by fix of a stale `make site` command reference in `CLAUDE.md`
(corrected to `make doc_site`).

One process note for future plans: this implementation ran across three
separate agent invocations (`kmdb-plan-implement`, then `kmdb-qa`, then
`kmdb-pre-commit`, orchestrated by the main session) because the initial
`kmdb-plan-implement` session had no `Agent`/`Task` tool available to invoke
`kmdb-qa` itself. All work was otherwise completed to spec on the first pass.
