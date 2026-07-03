# Test fixtures

The PDF fixtures in this directory (and `arxiv/`) are copied verbatim from the
[`betto_pdfium`](https://github.com/bettongia/pdfium) test corpus
(`packages/betto_pdfium/test/data/` and `test/fixtures/`), per the WI-8 plan's
Q3 resolution — reusing real-world PDF content rather than generating
synthetic fixtures.

## Files

- `00_empty.pdf`, `01_basic.pdf` — minimal golden-path cases (zero-page and
  basic single/multi-page documents).
- `scanned.pdf` — image-only, no text layer. Drives the `scannedPageRatio`
  gate (see `PdfTextExtractor`'s doc comment).
- `multi_column.pdf`, `single_column.pdf` — layout coverage.
- `password.pdf` — password-protected, exercises the
  `PdfError.passwordRequired` → `null` path.
- `corrupt.pdf` — malformed bytes, exercises the `PdfError.invalidDocument` →
  `null` path.
- `large.pdf` — memory/size sanity check.
- `soft_hyphens.pdf` — verifies the page-join doesn't reintroduce hyphenation
  artifacts that PDFium already stripped.

## `arxiv/` — real-world academic paper corpus

Five real-world, multi-page, multi-column academic papers with pre-extracted
`*.txt.json` oracles (produced by an **independent** tool, `pypdf`, via
`betto_pdfium`'s `scripts/extract_text.py` — not by PDFium/`betto_pdfium`
itself, so it is a genuinely independent oracle for fuzzy-comparison tests,
not a circular one).

**Licence and attribution:** see [`arxiv/citations.md`](arxiv/citations.md),
copied verbatim from upstream — it is the licence evidence for these five
PDFs (all confirmed **CC-BY**, so redistribution here is permitted), not just
documentation, so it travels with the PDFs rather than being paraphrased.

Because the oracle was produced by a different extraction engine than
PDFium, tests compare fuzzily (key-term/substring presence, word-count-in-range,
non-empty-per-page checks) — never exact string equality, and never against
the oracle's own `hasTextLayer`/`hasUnicodeErrors` fields (those are derived
from `pypdf`'s own heuristics, not PDFium's, and can legitimately disagree).
