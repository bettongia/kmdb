# Test fixtures

`multi_column.pdf` is copied verbatim from
`packages/kmdb_extractor_pdf/test/fixtures/multi_column.pdf` (itself copied
from the [`betto_pdfium`](https://github.com/bettongia/pdfium) test corpus —
see that directory's own `README.md` for provenance/licence details). It is a
small, text-bearing PDF containing distinctive, non-stopword Greek-letter
placeholder words ("alpha", "gamma", "epsilon", ...), used by
`database_opener_test.dart` to exercise `PdfTextExtractor` end-to-end via the
CLI's production `DatabaseOpener.open()` wiring (WI-12, Phase A) without
duplicating the extractor's own, much larger fixture corpus.

Note: `kmdb_extractor_pdf`'s own `01_basic.pdf` fixture (text: "hello") was
tried first but rejected — "hello" is, somewhat surprisingly, present in
`betto_lexical`'s English stop-word list, so it is filtered out of the BM25
index entirely and can never produce a lexical hit. `multi_column.pdf`'s
Greek-letter placeholders avoid that trap.
