# WI-8: PDF Extractor (`kmdb_extractor_pdf`)

**Status**: Investigated

**PR link**: —

## Problem statement

Vault search (WI-3, shipped) only extracts text from `text/plain` blobs via
`PlainTextExtractor`. `application/pdf` blobs are stored and retrievable but
are invisible to `searchVault()` — they are recorded `unsupported` and never
indexed.

`betto_pdfium` (PDFium FFI wrapper) is now published on pub.dev. As of
0.1.0-dev.3 it supports macOS, Linux, Windows, iOS, Android, and web/WASM, and
exposes `PdfDocument.extractPlainText()` with per-page `hasTextLayer`
detection for scanned/image-only pages. The publication blocker noted on the
roadmap is fully lifted.

This plan implements a new optional package, `kmdb_extractor_pdf`, providing a
`PdfTextExtractor` that implements the existing `VaultTextExtractor` interface
(`packages/kmdb/lib/src/vault/search/vault_text_extractor.dart`) for
`application/pdf` content, following the `kmdb_extractor_<name>` convention
already named in the vault search proposal (§2.3).

**No changes to core `kmdb` are required.** The extension point — the
`VaultTextExtractor` interface, `VaultSearchConfig.extractors` registration
list, and the isolate dispatch/status-mapping logic — was built and shipped as
part of WI-3 and WI-10 specifically to support this kind of package. This is a
new, independently-versioned optional package plus documentation updates.

## Open questions

- [x] **Q1 — Scanned/image-only PDF status.** Resolved: no core change (option
      (a)). Refined per feedback: `PdfTextExtractor` takes a configurable
      `scannedPageRatio` (`double`, default `0.5` — matching
      `PdfTextExtractorConfig`'s own default) in its constructor. While
      consuming the `extractPlainText()` stream once, the extractor tracks the
      fraction of pages with `hasTextLayer == false` itself (it does **not**
      call `isPlainTextExtractable()`, which would re-run extraction a second
      time — see Investigation). If that fraction meets or exceeds
      `scannedPageRatio`, the document is judged predominantly scanned/image
      content and `extract()` returns `""` outright — discarding any sparse
      OCR-adjacent fragments from a stray text page — rather than joining
      whatever partial text happened to be present. Below the threshold, all
      page text is joined and returned normally (scanned pages within an
      otherwise text-based document simply contribute nothing to the join, no
      special-casing needed). Both outcomes still map to the existing
      `indexed` status with 0 (or few) chunks — no `VaultExtractionStatus`
      enum change.
- [x] **Q2 — Page join separator.** Resolved: `"\n\n"` between pages, as
      proposed.
- [x] **Q3 — Test fixture sourcing.** Resolved: reuse the `betto_pdfium` test
      corpus directly rather than generating synthetic fixtures. The local
      clone at `/Users/gonk/development/bettongia/pdfium/packages/betto_pdfium/`
      has exactly what's needed under `test/data/` and `test/fixtures/`:
      - `test/data/arxiv/*.pdf` — five real-world, multi-page, multi-column
        academic papers, each with a pre-extracted `*.txt.json` (produced by
        an **independent** tool, `pypdf`, via `scripts/extract_text.py` — not
        by `betto_pdfium`/PDFium itself, so it's a genuinely independent
        oracle, not circular). `test/data/arxiv/citations.md` has the
        attribution table for each paper **and now records the licence
        explicitly: all five are CC-BY**. Redistribution is therefore
        confirmed, not just attributed — the reviewer's licensing advisory
        (raised before this table had a licence column) is resolved.
        `citations.md` itself **must be copied verbatim** alongside the PDFs
        it licenses (see Implementation plan) — it is the licence evidence,
        not just documentation, so a paraphrase elsewhere is not a
        substitute for shipping the file. Because the oracle is a different
        extraction engine, comparisons must be **fuzzy** (key-term/substring presence,
        word-count-in-range, non-empty-per-page checks) — not exact string
        equality — since PDFium and `pypdf` will not byte-for-byte agree on
        whitespace, ligatures, or column-reading order.
      - `test/fixtures/scanned.pdf` — image-only, no text layer (drives the Q1
        scanned-ratio path).
      - `test/fixtures/multi_column.pdf`, `single_column.pdf` — layout
        coverage.
      - `test/fixtures/password.pdf` — password-protected → exercises the
        `PdfError.passwordRequired` → `null` path.
      - `test/fixtures/corrupt.pdf` — malformed bytes → `PdfError.invalidDocument`
        → `null` path.
      - `test/fixtures/large.pdf` — memory/size sanity check.
      - `test/fixtures/soft_hyphens.pdf` — verifies the join doesn't
        reintroduce artifacts around PDFium's own soft-hyphen stripping.
      - `test/data/00_empty.pdf`, `01_basic.pdf` — minimal golden-path cases.
      - No RTL-script fixture exists in the upstream corpus. This is a
        residual gap: RTL extraction quality is **not** covered by this plan's
        test suite. Defer to a follow-up if/when a suitable
        permissively-licensed RTL sample is identified — do not block this
        plan on it, and do not claim RTL support in docs without it.
      - `scripts/extract_text.py` / `extract_meta.py` are available if any
        additional golden-output regeneration is needed later, but the
        existing checked-in `.txt.json`/`.meta.json` files should be copied
        as-is rather than regenerated.

## Investigation

### The `VaultTextExtractor` contract (shipped, unchanged)

`packages/kmdb/lib/src/vault/search/vault_text_extractor.dart:42`:

```dart
abstract interface class VaultTextExtractor {
  Set<String> get supportedMediaTypes;
  Future<String?> extract(Uint8List bytes, VaultManifest manifest);
}
```

Contract: MUST NOT throw; return `null` on failure; `bytes` are the raw,
**already-decrypted** blob bytes (`VaultStore.getBytes` decrypts transparently
before the extractor is called, per WI-10). The extractor has **no
responsibility for chunking or byte offsets** — `VaultChunker.chunk(String)`
(`vault_chunker.dart:91`) does all of that downstream, working purely on the
returned string's char index → UTF-8 byte offset. This is a significant
simplification for a PDF extractor: no PDF-native page/coordinate offsets need
to be threaded through.

Reference implementation `PlainTextExtractor`
(`packages/kmdb/lib/src/vault/search/plain_text_extractor.dart:54`) is the
template to follow: `final class ... implements VaultTextExtractor`, a `const`
`supportedMediaTypes` set, a try/catch that never rethrows, returning `null`
on any internal error.

### Status/isolate mapping (shipped, unchanged)

`VaultIndexingIsolate` (`vault_indexing_isolate.dart:328-393`) maps extractor
output to `VaultExtractionStatus`:

- No extractor matches media type → `unsupported`.
- Extractor throws or returns `null` → `failed` (generic error string
  `"Extractor returned null"` — there is no channel for the extractor to
  supply a specific reason, e.g. "password protected" vs. "corrupt").
- Extractor returns `""` or any string → `indexed` (0 chunks for empty text).

This confirms Q1's option (a) requires no code change — returning `""` (either
because the document is genuinely empty or because `PdfTextExtractor` judged
it predominantly scanned per its `scannedPageRatio` gate) is already the
default `indexed`/0-chunks behavior for any extractor that returns a
possibly-empty string.

### Registration (shipped, unchanged)

There is no extractor registry class — `VaultSearchConfig.extractors` is a
plain ordered list, first-match-wins by media type
(`vault_search_config.dart:91,112`). `PlainTextExtractor` is always prepended
automatically; nothing else is. A consuming app opts into PDF support with:

```dart
KmdbDatabase.open(
  vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
)
```

`kmdb_extractor_pdf` needs no core `kmdb` change to be wired in.

### Isolate execution model — betto_pdfium composes cleanly with the vault indexing isolate

`VaultIndexingIsolate.spawn(extractors)` copies extractor instances into a
spawned isolate at construction time and calls `extract()` **inside** that
isolate (`vault_indexing_isolate.dart:181-207,365`). This means
`PdfTextExtractor` must be a plain, isolate-sendable object (no native handles
held at construction).

Inspecting `betto_pdfium` 0.1.0-dev.3 source directly
(`~/.pub-cache/hosted/pub.dev/betto_pdfium-0.1.0-dev.3/lib/src/document/pdfium_isolate.dart`)
confirms this composes safely:

- PDFium is not thread-safe (`FPDF_InitLibraryWithConfig` is a one-time
  process-wide call), so `betto_pdfium` itself already routes **all** PDFium
  FFI calls through its own dedicated, lazily-spawned, process-wide singleton
  isolate (`PdfiumIsolate`) — held for the process lifetime, shared by every
  `PdfDocument` instance regardless of which isolate calls `fromBytes()`.
- `PdfTextExtractor.extract()` therefore does nothing isolate-aware itself —
  it just calls `PdfDocument.fromBytes(bytes)` and `extractPlainText()`
  normally. Whichever isolate happens to call it (main isolate in a unit test,
  or the vault indexing isolate in production) transparently gets routed to
  the same shared PDFium isolate. Dart isolates spawning further isolates is
  a normal, supported pattern — no special handling is needed.
- This resolves what would otherwise be the single biggest architectural risk
  in this plan. It should still be covered by an explicit integration test
  (see Implementation plan) since it is the first extractor with this shape.

### `betto_pdfium` 0.1.0-dev.3 API (verified against package source, not just the README)

`PdfDocument` (`lib/src/document/pdf_document.dart`):

- `static Future<PdfDocument> fromBytes(Uint8List bytes, {String? dylibPath})`
  — throws `PdfExtractionException(PdfError.passwordRequired |
  PdfError.invalidDocument)` on failure. Matches our raw-bytes input exactly;
  no file-path indirection needed.
- `Stream<PdfPageText> extractPlainText({int? pageIndex, PdfTextExtractorConfig config})`
  — yields one `PdfPageText` per page in index order. Each carries `pageIndex`,
  `text` (empty when `hasTextLayer` is false), `hasTextLayer`, and
  `hasUnicodeErrors`. Soft hyphens at line breaks are already stripped and
  joined by PDFium/betto_pdfium — no extra cleanup needed on our side.
- `Future<bool> isPlainTextExtractable({PdfTextExtractorConfig config})` — a
  document-level heuristic (`scannedPageRatio`, default 0.5). **Internally
  re-runs `extractPlainText()` to completion**, so calling both this and
  `extractPlainText()` would extract the document twice.
  `PdfTextExtractor` needs the same `scannedPageRatio` verdict (per Q1) but
  must not pay for two extraction passes — so it does **not** call
  `isPlainTextExtractable()`. Instead it inlines the identical logic while
  consuming its own single `extractPlainText()` stream: count pages where
  `hasTextLayer == false` as they arrive, and after the stream completes,
  compare `noTextLayerCount / pageCount` against the configured
  `scannedPageRatio` before deciding what to return (see Q1).
- `Future<void> close()` — must always be called (`try`/`finally`) to release
  the native handle; safe to call more than once.
- No multi-column or RTL claims appear anywhere in the package's README or
  doc comments — the roadmap's mention of these was aspirational, not a
  documented guarantee. Treat as unverified; the test fixtures (Q3) exist
  precisely to observe actual behavior rather than assert a claim.
- Byte-offset correctness for non-Latin scripts is unaffected either way:
  `VaultChunker` computes offsets from the returned string's own UTF-8 bytes,
  not from anything PDF-native, so it works correctly for whatever text
  PDFium hands back (§32, "Chunking").

### Platform scope

Vault search indexing runs exclusively in the native-only vault indexing
isolate — web is excluded from text search entirely (CLAUDE.md, spec §20).
`betto_pdfium`'s web/WASM support is therefore **not used** by this package;
scope is macOS, Linux, Windows, iOS, Android.

- **Desktop (macOS/Linux/Windows):** `betto_pdfium`'s native-assets hook
  auto-downloads the prebuilt PDFium binary
  ([bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries))
  on first use — no setup needed, matching the existing `betto_zstd` pattern
  already in `kmdb`. This is the lane kmdb's CI actually exercises
  (`cicd_linux_base`, `cicd_macos`, `cicd_windows` in `make_cicd.mk`).
- **iOS:** requires the companion `betto_pdfium_ios` Flutter plugin (delivers
  the PDFium xcframework via Swift Package Manager) in the **consuming app**,
  mirroring the existing `betto_onnxrt` / `betto_onnxrt_ios` split already
  documented in CLAUDE.md's Repository Layout. `kmdb_extractor_pdf` itself
  adds no `ios/` folder, `Package.swift`, or CocoaPods artifact — consistent
  with the SPM-only rule in CLAUDE.md.
- **Android:** `betto_pdfium` requires a one-time `make fetch_mobile_binaries`
  (its own repo tooling) for local/on-device testing. kmdb has **no existing
  Android CI lane** at all (`make_cicd.mk` has Linux/macOS/Windows/iCloud
  (macOS Flutter)/Flutter (macOS)/web targets only) — this is a pre-existing
  gap in the project, not something this plan needs to fix. `kmdb_extractor_pdf`
  is therefore validated on Android manually/at release time, same as other
  mobile-only concerns already called out in `docs/spec/28_release_checklist.md`.

### Package layout

No `kmdb_extractor_*` package exists yet to copy verbatim — this is the first.
`packages/kmdb_google_drive` is the closest structural template: a pure-Dart
optional workspace member (`publish_to: none`, `resolution: workspace`,
`dependencies: kmdb`, own `test/`, `example/`, `README.md`,
`analysis_options.yaml`). No platform channels or Flutter plugin machinery are
needed — `betto_pdfium` handles its own native loading via native-assets, so
`kmdb_extractor_pdf` is pure Dart, same as `kmdb` consuming `betto_zstd`.

Workspace wiring required (outside the new package directory):

- `pubspec.yaml`: add `packages/kmdb_extractor_pdf` to `workspace:`; add
  `betto_pdfium: ^0.1.0-dev.3` to `dependency_overrides:`.
- `make_cicd.mk`: add `packages/kmdb_extractor_pdf` to the `dart format`
  package list in `cicd_linux_base`. `melos run analyze` / `melos coverage` /
  `melos benchmarks` auto-discover new workspace members, no change needed
  there.
- Native-asset caveat (CLAUDE.md) applies: `dart test` for this package must
  run from inside `packages/kmdb_extractor_pdf/` (which `melos`/`make test`
  already do) — never `dart test packages/kmdb_extractor_pdf/test` from the
  workspace root.

### Documentation impact

- `docs/spec/32_vault_search.md` — add a `PdfTextExtractor` row to the
  extraction table (currently only lists `PlainTextExtractor`).
- `CLAUDE.md` Repository Layout — add `kmdb_extractor_pdf` to the package
  list, noting the `betto_pdfium` / optional `betto_pdfium_ios` companion
  split (mirrors the existing `betto_onnxrt` / `betto_onnxrt_ios` entries).
- `docs/roadmap/0_06.md` — flip WI-8's status as the plan progresses.
- New package `README.md` — installation, platform support table (native
  only, explicitly no web), and pointers to `betto_pdfium_ios` /
  `make fetch_mobile_binaries` for mobile consumers.
- Run `make site` after spec edits.

## Implementation plan

- [ ] Scaffold `packages/kmdb_extractor_pdf/` (pubspec, `analysis_options.yaml`,
      license header, `lib/kmdb_extractor_pdf.dart` barrel export).
- [ ] Add `packages/kmdb_extractor_pdf` to root `pubspec.yaml` `workspace:`
      list; add `betto_pdfium: ^0.1.0-dev.3` to `dependency_overrides:`.
- [ ] Add `packages/kmdb_extractor_pdf` to the `dart format` list in
      `cicd_linux_base` (`make_cicd.mk`).
- [ ] Implement `PdfTextExtractor implements VaultTextExtractor`:
  - [ ] `supportedMediaTypes => const {'application/pdf'}`.
  - [ ] Constructor accepts `scannedPageRatio` (`double`, default `0.5`).
  - [ ] `extract()`: `PdfDocument.fromBytes(bytes)` → consume the
        `extractPlainText()` stream once, buffering each page's `text` and
        tallying pages where `hasTextLayer == false` → after the stream
        completes, **guard `pageCount == 0` first** (a zero-page document
        returns `""` outright — do not compute the ratio, which would divide
        by zero; this mirrors `betto_pdfium`'s own `isPlainTextExtractable`,
        which returns `false` for `totalPages == 0`); then if
        `noTextLayerCount / pageCount >= scannedPageRatio` return `""`;
        otherwise join the buffered page texts with `"\n\n"` (Q2) and return
        that.
  - [ ] Structure as `PdfDocument? doc; try { doc = await fromBytes(...); ... }
        catch (e) { return null; } finally { await doc?.close(); }` — the
        `finally` MUST null-check the handle because `fromBytes` can throw
        before `doc` is assigned (`password.pdf` / `corrupt.pdf` paths).
        `close()` is safe to call more than once but not on a null handle.
  - [ ] Catch `PdfExtractionException`, `PdfiumException`, and any other
        exception (including errors surfaced mid-stream by `extractPlainText`,
        since the `await for` sits inside the `try`) → return `null` (never
        throw), per the interface contract. A bare `catch (e)` is sufficient;
        naming the concrete types is for doc clarity only.
  - [ ] Full doc comments per CLAUDE.md, including the isolate-composition
        note (why no special isolate handling is needed), the
        `scannedPageRatio` gate's rationale, and the known limitation that
        failure reasons (password vs. corrupt) are not surfaced beyond a
        generic `failed` status.
- [ ] Copy test fixtures into `packages/kmdb_extractor_pdf/test/fixtures/`
      from the local `betto_pdfium` checkout
      (`/Users/gonk/development/bettongia/pdfium/packages/betto_pdfium/`):
      `test/fixtures/scanned.pdf`, `multi_column.pdf`, `single_column.pdf`,
      `password.pdf`, `corrupt.pdf`, `large.pdf`, `soft_hyphens.pdf`; and
      `test/data/00_empty.pdf` / `01_basic.pdf`.
  - [ ] Copy the arXiv sub-corpus into its own
        `test/fixtures/arxiv/` directory: the five `*.pdf` files, their
        `*.txt.json` oracles, **and `citations.md` itself, copied verbatim**
        — do not merely paraphrase its contents elsewhere. `citations.md` is
        the actual evidence for the CC-BY redistribution claim (all five
        papers confirmed CC-BY, per the Q3 resolution), so the file must
        travel with the PDFs it licenses, not just be summarised in prose.
  - [ ] The package's own `test/fixtures/README.md` (or top-level `README.md`)
        should link to `arxiv/citations.md` for the licence/attribution
        details rather than duplicating the table — one source of truth for
        the licence text, alongside the PDFs it covers.
- [ ] Unit tests (direct extractor calls, no isolate):
  - [ ] Golden path — non-empty text extracted from each arXiv fixture;
        fuzzy-compare (key-term/substring presence, not exact match) against
        the copied `*.txt.json` oracle, since it was produced by an
        independent tool (`pypdf` via `scripts/extract_text.py`), not PDFium.
        Compare **only the `text` field content**. Do NOT cross-check the
        oracle's `hasTextLayer`/`hasUnicodeErrors` fields against PDFium's:
        the oracle derives `hasTextLayer` from pypdf's own `bool(text)`
        heuristic (not PDFium's text-layer probe), so the two engines can
        legitimately disagree on those flags.
  - [ ] Zero-page / degenerate document (`00_empty.pdf`) → `extract()` returns
        `""` (not `null`, not a throw) — exercises the `pageCount == 0` guard.
  - [ ] `scanned.pdf` → `extract()` returns `""` (not `null`) — confirms the
        Q1 `scannedPageRatio` gate end to end.
  - [ ] Multi-page arXiv fixture → verify page-join behavior and that
        `VaultChunker.chunk()` produces correct byte offsets across the
        joined text (integration with the existing chunker, no chunker
        changes expected).
  - [ ] `multi_column.pdf` / `single_column.pdf` → assert on actual observed
        extraction quality (no supported-claim to verify against, per Q3).
  - [ ] `soft_hyphens.pdf` → confirm the join doesn't reintroduce hyphenation
        artifacts PDFium already stripped.
  - [ ] `password.pdf` → `extract()` returns `null`.
  - [ ] `corrupt.pdf` and zero-length bytes → `extract()` returns `null`,
        never throws (fault-injection style, per CLAUDE.md's emphasis on
        failure scenarios, not just golden path).
- [ ] Integration test: register `PdfTextExtractor` in a real
      `VaultSearchConfig`/`VaultIndexingIsolate` (reusing the WI-3 test
      harness pattern) to prove the nested-isolate composition
      (vault indexing isolate → `betto_pdfium`'s own `PdfiumIsolate`) works
      end to end, including a case where the vault blob itself was stored
      with encryption enabled (WI-10 integration — bytes must already be
      decrypted by the time `extract()` sees them).
- [ ] `example/` — a minimal script showing `KmdbDatabase.open(vaultSearch:
      VaultSearchConfig(extractors: [PdfTextExtractor()]))` and a
      `searchVault()` call.
- [ ] `packages/kmdb_extractor_pdf/README.md` — installation, platform
      support table, mobile setup pointers.
- [ ] Update `docs/spec/32_vault_search.md` extraction table.
- [ ] Update `CLAUDE.md` Repository Layout.
- [ ] Update `docs/roadmap/0_06.md` WI-8 status/plan link.
- [ ] Run `make site` after spec edits.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Reviewer feedback (2026-07-03)

Full critical pass. Every load-bearing technical claim was verified against the
current source (`packages/kmdb/lib/src/vault/search/*` and the published
`betto_pdfium` 0.1.0-dev.3 in the pub cache), not taken on assertion. The plan
holds up and is promoted to **Investigated**. Findings:

**Verified correct (no change needed):**

- `VaultTextExtractor` interface, contract, and isolate-sendability requirement
  (`vault_text_extractor.dart:42`; `plain_text_extractor.dart:54`).
- Status mapping: no-match → `unsupported`, `null` → `failed`, any string
  (incl. `""`) → `indexed` with 0 chunks. Confirmed in
  `vault_indexing_isolate.dart:341-393`. Q1's "return `""`" strategy therefore
  needs no core change. (Minor doc nit: the *enum* mapping to
  `VaultExtractionStatus` happens in `VaultSearchManager`, not the isolate
  file, which maps to `VaultIndexResult.isSuccess/isFailed/isUnsupported` —
  immaterial to implementation since no core change is claimed.)
- The charset read-back at `vault_indexing_isolate.dart:368` is a concrete
  `is PlainTextExtractor` check performed **inside the spawned isolate**,
  confirming `extract()` runs in that isolate. `PdfTextExtractor` (a plain
  object with one `double` field) is isolate-sendable and needs no equivalent.
- `VaultChunker.chunk()` operates purely on the returned string; empty text →
  empty chunk list (`vault_chunker.dart:91`). No PDF-native offsets needed.
- `betto_pdfium` public API is fully reachable via the barrel:
  `pdf_document.dart` re-exports `pdf_types.dart` (line 34), so `PdfError`,
  `PdfExtractionException`, `PdfPageText`, and `PdfTextExtractorConfig` are all
  public; `PdfiumException` comes from `pdf_exception.dart`. `PdfPageText`
  carries `pageIndex/text/hasTextLayer/hasUnicodeErrors`. `fromBytes`,
  `Stream<PdfPageText> extractPlainText(...)`, and `Future<void> close()` match.
- Q1 `>=` semantics are faithful: `betto_pdfium`'s own
  `isPlainTextExtractable` returns `scannedRatio < scannedPageRatio` for
  "extractable" (`_document_native.dart:301-302`), i.e. `>=` ⟺ "predominantly
  scanned". Default 0.5 matches.
- Nested-isolate composition is safe: `PdfiumIsolate` is a process-wide,
  lazily-spawned singleton (`pdfium_isolate.dart:2708-2806`), shared by every
  `PdfDocument` regardless of calling isolate.
- **Q3 oracle independence holds.** I initially suspected the `.txt.json`
  files were PDFium-generated (their field names match `PdfPageText`), but
  `scripts/extract_text.py` uses `pypdf`'s `page.extract_text()` and only
  reshapes the output to the PDFium JSON layout. The `text` content is a
  genuinely independent engine — fuzzy comparison is the right call.
- All named fixtures exist in the local clone: the five `arxiv/*.pdf` +
  `*.txt.json`, `scanned/multi_column/single_column/password/corrupt/large/
  soft_hyphens.pdf`, and `00_empty/01_basic.pdf`. Roadmap WI-8 links this plan;
  spec §32's extraction table (line 224) is the right edit target.

**Refinements folded into the checklist (were latent ambiguities):**

1. **Zero-page guard.** The inlined ratio `noTextLayerCount / pageCount` divides
   by zero for a 0-page document. `betto_pdfium` guards this (`totalPages == 0
   → false`); the plan now specifies an explicit `pageCount == 0 → ""` guard
   plus a `00_empty.pdf` test, rather than relying on NaN-comparison accident.
2. **`close()` null-safety.** `fromBytes` can throw before a document exists,
   so the `finally` must `await doc?.close()`. The checklist now spells out the
   `PdfDocument? doc; try/catch/finally` shape.
3. **Oracle comparison scope.** Tests must fuzzy-compare only the `text`
   content, never the oracle's `hasTextLayer`/`hasUnicodeErrors` (pypdf-derived,
   not PDFium's probe). Noted in the test checklist.

**Advisory (owner's call — not implementation blockers):**

- ~~**Fixture redistribution in a now-public repo.**~~ **Resolved 2026-07-03.**
  Upstream `betto_pdfium`'s `test/data/arxiv/citations.md` was updated with an
  explicit licence column: all five arXiv papers are **CC-BY**, confirming
  redistribution rights (not just attribution). See the Q3 resolution above.
- **RTL gap** is already correctly documented as a deferred, non-blocking
  residual — do not claim RTL support in docs without a fixture.

## Summary

_(To be completed after implementation.)_
