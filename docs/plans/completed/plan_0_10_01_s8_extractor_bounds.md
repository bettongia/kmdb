# Resource bounds for the text extractors (S-8)

**Status**: Complete

_(Q1–Q4 resolved; Q2/Q3 maintainer decisions taken 2026-08-09; the reviewer's
three final-pass corrections V1–V3 have been folded into Phases 2–3. See "Final
verification pass (2026-08-09)".)_

**PR link**: [PR #71](https://github.com/bettongia/kmdb/pull/71) (merged 2026-08-10, kmdb-qa PASS)

> **Provenance.** Finding **S-8** of the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md),
> spun out of **WI-6** ("smaller independents") as its own plan on 2026-08-09
> because the WI-6 grounding showed it needs a decided bounds policy across three
> packages plus a non-trivial PDF-timeout mechanism (it does not fit the
> trivial-bundle framing). The trivial WI-6 items (L-1, C-2, C-1) shipped in
> [PR #69](https://github.com/bettongia/kmdb/pull/69); S-5 (the vault hash swap)
> is a sibling plan.

## Problem statement

The three text extractors turn untrusted blob bytes into text with **no
resource bounds** on the work they do. A malicious or degenerate document is a
denial-of-service vector:

- **Recursion depth — unbounded.** `HtmlTextExtractor._walkNode`
  (`packages/kmdb_extractor_html/lib/src/html_text_extractor.dart:255`) and
  `MarkdownTextExtractor._walkNode`
  (`packages/kmdb_extractor_markdown/lib/src/markdown_text_extractor.dart:237`)
  recurse over the parsed tree with no depth limit. A pathologically nested
  document is a stack-overflow / CPU bomb.
- **Time — unbounded.** `PdfTextExtractor`
  (`packages/kmdb_extractor_pdf/lib/src/pdf_text_extractor.dart:108`) wraps
  native `betto_pdfium` `extractPlainText()` with no timeout. A malicious or
  degenerate PDF can spin or hang. This is the highest-risk of the three (native
  FFI) and it interacts with the vault indexing isolate (see the mechanism
  question below; related to review finding D-1).
- **Input size — bounded only inside the vault pipeline.** A 200 MB
  `VaultSearchConfig.maxBlobBytes` cap
  (`packages/kmdb/lib/src/vault/search/vault_search_config.dart:81`) already
  stops oversized blobs reaching an extractor *within the vault indexing
  pipeline*. But all three extractors are **public, independently-consumable
  packages** (`kmdb_extractor_pdf`/`html`/`markdown`) — a direct caller has no
  such gate, so each extractor should carry its own defensive size check.

All three already honour the `VaultTextExtractor` contract
(`vault_text_extractor.dart:47-49`): **MUST NOT throw; return `null` on
failure.** So every bound must surface as a graceful `null` (extraction
declined), never an exception.

## Why now

A cheap-to-add hardening before `0.1.0`. **Not** format-freeze sensitive (no
on-disk change) — but it closes a DoS class on the ingest path, and the PDF
timeout ties into the D-1 isolate-lifecycle work, so it is best decided while
that context is fresh. It can land any time before WI-9.

## Design — an `ExtractorLimits` policy

Rather than three ad-hoc checks, introduce a small shared value object so the
three extractors (and any future `kmdb_extractor_*`) apply a uniform, tunable
policy:

```dart
class ExtractorLimits {
  final int maxInputBytes;      // decline blobs larger than this
  final int maxRecursionDepth;  // decline documents nested deeper than this
  final Duration maxDuration;   // decline extraction that exceeds this wall-clock
  const ExtractorLimits({...});
  static const ExtractorLimits defaults = ExtractorLimits(...);
}
```

The **placement/threading** of this object and the **PDF timeout mechanism** are
the two real design decisions — see Open Questions.

## Open questions

Reviewer note (2026-08-09): Q1 and Q4 are **resolved** below (code-grounded, no
maintainer call needed). Q2 and Q3 remain genuine maintainer decisions, but Q3
has been **recast** — the reviewer's investigation of `betto_pdfium` changes the
options materially (see the Review section). The precise maintainer-decision
list is at the end of this block.

- [x] **Q1 — Where does `ExtractorLimits` live and how is it threaded?**
      **Resolved: option (a), constructor parameter on each extractor**, with the
      `ExtractorLimits` type **defined in and exported from core `kmdb`** (next to
      `VaultTextExtractor` in `vault/search/`). Grounding:
      - All three extractor packages already `import 'package:kmdb/kmdb.dart'`, so
        a kmdb-exported `ExtractorLimits` is shared with zero new cross-package
        dependency. Defining it inside any one extractor package would not be
        reachable by the others.
      - The three extractors have `const` constructors
        (`HtmlTextExtractor()`, `MarkdownTextExtractor()`,
        `PdfTextExtractor({scannedPageRatio = 0.5})`). Adding
        `{ExtractorLimits limits = ExtractorLimits.defaults}` preserves `const`
        provided `ExtractorLimits.defaults` is itself a `const` value.
      - Registration is caller-side (`VaultSearchConfig(extractors: [PdfTextExtractor(), ...])`),
        so a standalone/direct caller can pass custom limits without any contract
        change — exactly the property (b) would lose.
      - **`PlainTextExtractor` (core) should also take the constructor param** for
        the `maxInputBytes` bound (it has no recursion and no native call, but it
        *does* decode all bytes unbounded on the standalone path). Uniform is
        better than "all extractors but one."
      - **Testing dividend (decisive):** because limits are constructor-injected,
        the fault-injection tests can construct an extractor with a *tiny*
        `maxInputBytes` / `maxRecursionDepth` instead of allocating tens of MB or
        nesting 512 levels — fast, deterministic tests. This is a concrete reason
        (a) beats (c).
- [x] **Q2 — Default values. RESOLVED (maintainer, 2026-08-09):
      `maxInputBytes = 32 MiB`, `maxRecursionDepth = 512`, PDF
      `maxDuration = 20 s`.** 32 MiB is well below the 200 MiB vault blob cap and
      also serves as the parser-stage stack-overflow guard; 512 is reviewer-
      confirmed safe for the walk; 20 s is strictly less than the existing 30 s
      `kWorkTimeout` so the extractor declines gracefully before the backstop
      trips. All three are per-extractor-overridable via the constructor.
      Reviewer caveats that still shape the implementation:
      - **`maxRecursionDepth ≈ 512` is safe against stack overflow *in the walk*.**
        `_walkNode`/`_walkElement` is a shallow mutual recursion (~2–3 stack
        frames per level); 512 levels is well within Dart's default stack. The
        check must increment-then-check **before** descending. **But** the
        *parser* runs first (`html_parser.parse` / `md.Document.parse`) and builds
        its own tree recursively — a pathologically nested doc can blow the stack
        **inside the parser, before `_walkNode` is ever reached.** The
        input-size gate is the real first line of defence there (deeply-nested
        input is also large); the bare `catch (e)` in each `extract()` does catch
        `StackOverflowError` (Dart's untyped `catch` catches `Error`s too), so a
        parser-stage overflow already degrades to `null` — but the test fixture
        must be sized to pass the byte gate yet still exercise the walk cap, and
        the implementer must not assume the depth cap alone protects the parse
        stage. **Recommend documenting the depth cap as protecting the walk, with
        `maxInputBytes` as the parser-stage guard.**
      - **PDF `maxDuration` must be reconciled with the existing 30 s
        `VaultIndexingIsolate.kWorkTimeout`** (see Q3 / Review). If the
        extractor-level budget is *also* 30 s it races the isolate backstop; the
        extractor budget should be **strictly less** than `kWorkTimeout` so the
        extractor declines gracefully (`null` → `failed: "Extractor returned
        null"`) before the backstop trips (`StateError` → `failed: "Isolate error"`).
        A value like 20 s is a defensible default; the maintainer sets the number.
- [x] **Q3 — The PDF time bound. RESOLVED (maintainer, 2026-08-09).** Mechanism:
      **(a) primary** — a cumulative wall-clock budget (`maxDuration`, 20 s) inside
      `PdfTextExtractor.extract()` across the `async*` page stream, returning
      `null` gracefully on exceed (works standalone *and* in the pipeline, no
      betto_pdfium change); **(b) backstop** — keep the existing 30 s
      `kWorkTimeout`; **(c) in scope for this plan** — the manager-side
      **discard + re-spawn on timeout** in `VaultIndexingIsolate`/`VaultSearchManager`,
      which fixes the two residual defects (each post-timeout PDF eating another
      full 30 s; the latent stale-result mis-delivery). The maintainer chose to
      land (c) here rather than defer it to the D-1 track. **(d)** the true
      OS-level native-hang of the process-wide `PdfiumIsolate` (which no vault-side
      restart can recover) stays release-checklist **RC-25** — extend/annotate,
      do not force-automate. Background (verified by the reviewer):
      - `betto_pdfium`'s `extractPlainText()` is **not a single blocking FFI
        call** — it is an `async*` stream that issues **one FFI round-trip per
        page** to a **process-wide singleton `PdfiumIsolate`**, yielding to the
        event loop between pages, with clean, leak-free cancellation. So
        **Q3-iii (cumulative wall-clock check across the page stream) is already
        available today** — the plan's "needs investigation of that external API"
        is answered: the capability exists.
      - **Q3-ii as written does not work for the true native-hang case.** Killing
        the `VaultIndexingIsolate` is safe (confirmed: no durable writes) but the
        native PDFium work runs in a *different*, process-wide singleton isolate
        that the kill does **not** touch — a genuinely wedged native call
        poisons all future PDF extraction process-wide regardless of how many
        times the vault isolate is restarted.
      - A **30 s `kWorkTimeout` backstop already exists** (D-1) in
        `VaultIndexingIsolate.sendWork`; the pipeline already degrades a hung
        extraction to a `failed` status today. The residual pipeline defects are
        (1) the isolate is **not** killed/re-spawned on timeout, so each
        subsequent PDF item also eats the full timeout, and (2) a latent
        stale-result mis-delivery on the timeout path (see Review). Both are
        fixed by manager-side **discard + re-spawn on timeout**, which is
        simpler than Q3-ii's mid-extraction kill and *does* recover everything
        except a native-wedged `PdfiumIsolate`.
      - **Reviewer recommendation:** primary bound = a **cumulative wall-clock
        budget inside `PdfTextExtractor.extract()`** across the page stream
        (works standalone *and* in the pipeline, returns `null` gracefully, no
        isolate machinery, no betto_pdfium change); keep the existing
        `kWorkTimeout` as the backstop for the one case the extractor budget
        cannot interrupt (a single page hanging in native code); optionally add
        manager-side re-spawn-on-timeout to stop repeated-timeout wedging. The
        real native-crash/native-hang recovery is already release-checklist
        item **RC-25** (D-1) — extend/annotate it rather than trying to automate
        an OS-level native hang.
- [x] **Q4 — Does the input-size check duplicate `maxBlobBytes`?** **Resolved:
      they compose cleanly, stricter wins, no conflict.** `maxBlobBytes` (200 MiB)
      is enforced in `VaultSearchManager` *before* the item is sent to the isolate
      (records `failed` and returns — `vault_search_manager.dart` ~L597–610); the
      per-extractor `maxInputBytes` is an independent second gate that fires
      inside `extract()`. In the pipeline both apply and the smaller (extractor)
      wins; for a standalone caller the extractor gate is the *only* protection —
      which is the whole point of putting it on the extractor.

### Maintainer decisions — RESOLVED (2026-08-09)

1. **Q2 numbers:** `maxInputBytes = 32 MiB`, `maxRecursionDepth = 512`, PDF
   `maxDuration = 20 s` (all per-extractor-overridable).
2. **Q3 mechanism & scope:** extractor-level cumulative wall-clock budget + keep
   `kWorkTimeout` backstop, **and** land the manager-side discard + re-spawn-on-
   timeout (fixing repeated-timeout wedging + the latent stale-result bug) **in
   this plan**. The OS-level native-hang of the process-wide `PdfiumIsolate`
   stays RC-25.

## Review (kmdb-plan-reviewer, 2026-08-09)

**Verdict: not yet `Investigated` — `Questions`.** The problem is real, in scope,
and correctly sized for `0.1.0` hardening. The pure-Dart bounds (Phases 1 & 3 for
HTML/MD) are implementation-ready once Q1/Q2 land. The **PDF time bound (Q3) is
not implementation-ready** and, as originally written, would ship a mechanism
that does not achieve its goal. The two genuine maintainer calls are the Q2
defaults and the Q3 mechanism.

### Factual claims — verified against current code

- **No per-extractor input-size check today: TRUE.** None of the three
  extractors inspects `bytes.length`; the only gate is
  `VaultSearchConfig.maxBlobBytes` (200 MiB, `vault_search_config.dart:81`),
  enforced in `VaultSearchManager` before the isolate send.
- **Unbounded recursion in HTML/MD: TRUE.** `HtmlTextExtractor._walkNode`/
  `_walkElement` (recurses at `html_text_extractor.dart:234-235`) and
  `MarkdownTextExtractor._walkNode`/`_walkElement` (recurses at
  `markdown_text_extractor.dart:216`) have no depth counter. (Note: the plan's
  line cites `:255`/`:237` are the *entry* calls in `extract()`; the actual
  recursive self-calls are a few lines up — implementer should target the
  `_walkElement` recursion sites.)
- **PDF has no time bound: TRUE**, but the surrounding machinery is richer than
  the plan states — see below.

### Q3 is wrong as written — corrected findings on `betto_pdfium` + the isolate

1. **`extractPlainText()` is a page-streaming `async*`, not one blocking FFI
   call.** `_document_native.dart:_extractPlainTextImpl` loops over page indices
   and does **one `_isolate.send(PdfiumExtractPageTextCommand)` round-trip per
   page**, `yield`ing each `PdfPageText` (`pdf_document.dart:180`,
   `_document_native.dart:196-216`). Between pages the event loop runs, and the
   public API documents that **cancelling the subscription immediately stops
   further processing with page handles released each round-trip** (no leak).
   ⇒ **Q3-iii is available today** — the plan's "requires betto_pdfium to expose
   per-page extraction; needs investigation" is answered: it already does. A
   cumulative wall-clock check across the `await for` loop (or a `.timeout` on
   the stream) is the natural, in-scope PDF bound and surfaces as `null` cleanly.

2. **Q3-ii's premise ("killing the vault isolate is the natural home for the PDF
   time bound") is only half true and, for the real hang, ineffective.** Killing
   `VaultIndexingIsolate` is indeed *safe* — confirmed no durable writes
   (`vault_indexing_isolate.dart:23-33`; it returns plain data, main isolate does
   all FS/LSM/embedding work). **But** PDFium runs in a **separate, process-wide
   singleton `PdfiumIsolate`** (`betto_pdfium`'s `pdfium_isolate.dart:15-33`),
   lazily spawned on first `fromBytes()`, held for process lifetime, shared by
   every `PdfDocument` regardless of which isolate created it (because
   `FPDF_InitLibraryWithConfig` is a one-time process-wide call). Killing the
   vault isolate does **not** stop a native call already running in that
   singleton; a genuinely wedged native call poisons **all** future PDF
   extraction process-wide, no matter how many times the vault isolate restarts.
   So Q3-ii cannot deliver a hard PDF time bound for the native-hang case.

3. **A 30 s work-item backstop already exists (D-1) — the plan re-invents part of
   it.** `VaultIndexingIsolate.sendWork` already wraps the result in
   `.timeout(kWorkTimeout /* 30 s */)` (`vault_indexing_isolate.dart:240,331-345`)
   and `VaultSearchManager` already converts that `StateError` into a `failed`
   extraction status (`vault_search_manager.dart:624-632`). So the pipeline
   already degrades a hung PDF to `failed` today. The **residual** pipeline
   defects the plan should target instead of re-deriving a timeout are:
   (a) on timeout the isolate is **not** killed and `_isolate` stays non-null
   (`_dead` stays `false`), so the *next* PDF item is sent to the same
   possibly-wedged isolate and also burns 30 s — repeated-timeout wedging; and
   (b) a **latent stale-result mis-delivery**: after a timeout clears `_inflight`,
   a late result for item N arrives while item N+1 is in flight and completes
   N+1's completer with N's result (mismatched `sha256`). Both are fixed by
   **manager-side discard + re-spawn on timeout** (`shutdown()` the isolate, set
   `_isolate = null`), which is simpler than mid-extraction kill and recovers
   everything except a native-wedged `PdfiumIsolate` (non-PDF work on the fresh
   isolate is fine; PDF work re-routes to the same wedged singleton).

4. **Recommended mechanism (grounded):** extractor-level **cumulative wall-clock
   budget inside `PdfTextExtractor.extract()`** across the page stream as the
   primary bound (standalone + pipeline, `null` on exceed, no isolate machinery,
   no betto_pdfium change); **keep `kWorkTimeout` as the backstop** for the one
   residual case the extractor budget cannot interrupt (a single page hanging in
   native code); **optionally** land the manager-side re-spawn-on-timeout in this
   plan. The unautomatable native-hang/native-crash recovery is **already**
   release-checklist **RC-25** (D-1, "real native crash recovery") — S-8 should
   *extend/annotate RC-25* to name the PDF time-bound expectation, not attempt to
   automate an OS-level native hang.

### Testability gaps the implementer must close (drive from Q3's resolution)

- **HTML/MD depth + size bounds: testable in-suite and fast** — construct the
  extractor with a tiny `maxRecursionDepth` / `maxInputBytes` (Q1 makes this
  possible) rather than allocating huge/deep fixtures. Ensure the deeply-nested
  fixture passes the byte gate but still reaches the walk (and beware the
  parser-stage overflow — see Q2).
- **PDF time bound is *not* trivially testable at the extractor** —
  `PdfTextExtractor.extract()` calls `PdfDocument.fromBytes(bytes)` directly with
  **no injection seam** for a slow/hanging page stream. Testing the cumulative
  budget therefore needs either (i) a small refactor to inject a document/stream
  factory, or (ii) testing the budget at the isolate/manager layer with a fake
  `VaultTextExtractor` that delays — for which there is precedent: RC-25 cites
  `test/query/kmdb_database_close_isolate_death_test.dart` using "an extractor
  whose `extract()` never returns." **The plan must state which seam it uses.**
- A **real hanging/crashing PDF is un-automatable** (RC-25 already documents
  why). The "slow/hanging PDF fixture" bullet in Phase 3 must be split: the
  *Dart-level* budget/backstop is automated with a fake delaying extractor; the
  *real native* case is verified via RC-25 at release time.

## Final verification pass (kmdb-plan-reviewer, 2026-08-09)

**Verdict: still `Questions`.** The Q2/Q3 maintainer decisions are the right
calls and the extractor-level bounds (Phases 1 & 3 HTML/MD) are ready. But the
expanded isolate-lifecycle scope (Q3(c)) is specified in a way that is
**partly wrong and partly underspecified** against the actual code in
`vault_indexing_isolate.dart` / `vault_search_manager.dart`. Three concrete
corrections are needed before this is safe for a Sonnet implementer. None are
maintainer decisions — they are code-grounded specification fixes.

### V1 — Re-spawn mechanism: located wrong, `_dead = true` is not implementable as written

The plan says (Phase 2, Q3(c)): *"shutdown() the isolate and set
`_isolate = null`/`_dead = true`."* This conflates two different objects and
names a mechanism the caller cannot invoke:

- `_isolate` is a **`VaultSearchManager` field** (`vault_search_manager.dart:138`).
- `_dead` is a **private field inside `VaultIndexingIsolate`**
  (`vault_indexing_isolate.dart:228`) with **no setter** and is read only by
  that instance's own `sendWork`. The manager cannot set it, and setting it on
  an isolate you are about to discard is pointless. Worse, the only in-isolate
  way to "mark dead on timeout" would make every *future* `sendWork` fast-fail —
  which breaks indexing entirely rather than recovering it. **Drop `_dead = true`
  from the spec.**

The **only** place re-spawn can live is the manager's existing `sendWork` catch
block (`vault_search_manager.dart:623-632`). The correct, implementable shape is:

- In that catch, **capture the instance into a local and null the field
  synchronously, then await shutdown**:
  `final dead = _isolate; _isolate = null; await dead?.shutdown();` — before the
  method returns. The next `_processNextItem` then re-runs
  `_isolate ??= await VaultIndexingIsolate.spawn(...)` (:613) and gets a fresh
  isolate. Capture-null-*before*-await matters: it prevents a concurrent
  `close()` (which does `await _isolate?.shutdown(); _isolate = null;`, :528-529)
  from shutting the same instance down twice. (Double-shutdown is in fact
  idempotent — `kill()`/`RawReceivePort.close()` tolerate repeats and `_inflight`
  is already null on the timeout path so the drain is skipped — but capture-null
  first keeps the intent clean.)
- The catch at :625 currently catches **all** `sendWork` failures (timeout,
  `_onIsolateDeath` death, and the `_dead` fast-fail). Re-spawning on **any** of
  them is correct and simplest — the spec should say "discard + null `_isolate`
  in the sendWork catch," not "on `kWorkTimeout`" specifically.
- **Scope note the plan must add:** re-spawn does **not** fire on the *primary*
  20 s extractor-budget path. That path returns `null` → `_processWorkItem`
  builds a `VaultIndexResult(error: 'Extractor returned null')` → `sendWork`
  completes **normally** → manager hits the `result.isFailed` branch (:645), not
  the catch. The isolate stays healthy and is correctly reused. Re-spawn is only
  for the 30 s backstop / death path. Good — but state it, because "re-spawn on
  timeout" reads as if every declined PDF discards the isolate.
- **Honest limitation to record:** for a *natively*-wedged `PdfiumIsolate`,
  re-spawning the vault isolate does not fix repeated 30 s timeouts — the fresh
  isolate re-routes PDF work to the same wedged process-wide singleton and times
  out again (→ RC-25). Re-spawn fixes repeated-wedging only for **Dart-level**
  wedging (a pure-Dart runaway extractor, or slow-but-finishing work). The plan's
  "fixes the repeated-30 s wedging" should be qualified to "for the Dart-level
  case."

### V2 — Stale-result guard: no protocol change needed, but the `_inflight` reorder is unstated (and the guard is redundant with V1)

Good news for implementability: **no new id needs to be added to the work/result
protocol.** `VaultWorkItem.sha256` (:79) and `VaultIndexResult.sha256` (:114,
echoed from the item) already exist. The only change is that `_PendingWork`
(:416, currently just `completer`) must gain an `expectedSha256` recorded by
`sendWork` from `item.sha256`.

But the plan omits the **load-bearing subtlety**: `_onResult` (:374-384)
currently does `_inflight = null` **first**, then completes. The guard must
**not** clear `_inflight` on a mismatch — otherwise a stale reply would abandon
the *legitimately* in-flight item. Correct shape: read `_inflight`; if
`message.sha256 != pending.expectedSha256`, **return without touching `_inflight`
and without completing** (drop the stale message); only on a match clear
`_inflight` and complete. An implementer following the current code's
"null-first" pattern would get this wrong.

**However** — verified against the code — with V1's re-spawn done correctly the
mis-delivery is **structurally impossible**, so this guard is **defense-in-depth,
not a second independent bug fix**:

- On timeout, `onTimeout` already sets `_inflight = null` (:340), so any late
  result in the window before shutdown hits `_onResult` with `pending == null`
  and is already discarded (:375-378).
- Re-spawn then kills the old isolate and closes its `_rawPort`; the next item
  runs on a **different** `VaultIndexingIsolate` instance, so the old instance's
  late result can never reach the new item's completer.

The original bug the review identified only exists **because the current code
reuses the same isolate after a timeout** — which V1 eliminates. The plan should
say plainly that **V1 (re-spawn) is the load-bearing fix and subsumes the
mis-delivery**, and V2 is optional belt-and-suspenders the maintainer chose to
land anyway. (Also note the guard is not airtight on its own: a reindex can
re-enqueue the *same* sha256, so a late result would still "match" — harmlessly,
since it is the same blob's content. This is another reason V1, not V2, is the
real fix.) Keeping both is fine; mislabeling V2 as the fix is not.

### V3 — Test seam is still uncommitted, and the two listed options are not alternatives

Phase 3 still says the PDF budget is tested *"(document/stream-factory injection
into `PdfTextExtractor`, **or** a fake delaying `VaultTextExtractor` at the
isolate/manager layer)."* This is the exact gap flagged in the first pass and it
is **not resolved** — and the "or" is misleading because the two options test
**different code**, so the plan needs *both*, one per concern:

- **The extractor-level 20 s cumulative budget lives inside
  `PdfTextExtractor.extract()`** (`pdf_text_extractor.dart:123`, the
  `await for (page in doc.extractPlainText())` loop). A fake `VaultTextExtractor`
  at the manager layer **cannot** exercise it — it is not a PDF extractor. This
  needs one of: (i) inject a document/stream factory into `PdfTextExtractor`
  (adds public API to a published package), **or** (ii) — simpler, no API change —
  use a **real multi-page fixture** (the repo already ships them, e.g.
  `test/fixtures/arxiv/*.pdf`, `large.pdf`) with `maxDuration` set to
  `Duration.zero` (or ~1 ms) so the per-page check trips deterministically after
  the first page's real FFI round-trip (elapsed > 0). The plan must **commit to
  one**. Recommendation: (ii) — it needs no new public surface and the fixtures
  exist; verify the budget check is placed so `Duration.zero` reliably trips
  (check-after-each-page, and a document with ≥ 2 pages).
- **The re-spawn (V1) and stale-result (V2) behaviour lives in the
  manager/isolate**, and *that* is where the fake-delaying-`VaultTextExtractor`
  precedent (`test/query/kmdb_database_close_isolate_death_test.dart`, "extract()
  that never returns") applies: drive a work item into `kWorkTimeout`, assert the
  timed-out item is `failed`, and assert the **next** item succeeds on a **fresh**
  isolate (V1) and never receives the stale item's result (V2).

So Phase 3 should read: fixture-based `Duration.zero` test for the extractor
budget; fake-delaying-extractor test at the manager layer for re-spawn +
stale-result. The plan must name both, not offer them as an either/or.

### What is already correct (no change needed)

- `killing the vault isolate is durability-safe` — confirmed: the isolate holds
  no `KvStore`/`WriteBatch`/FS handles (:23-33); `kill(beforeNextEvent)` parks it
  at the cross-isolate `await`, not inside native code (native work is in the
  separate `PdfiumIsolate`). Re-spawn is safe.
- Keeping `maxDuration (20 s) < kWorkTimeout (30 s)` so the extractor declines
  gracefully before the backstop — correct and confirmed against `:240`.
- RC-25 (native-hang) staying release-checklist-only — correct; re-spawn
  provably cannot recover a wedged process-wide `PdfiumIsolate`.

### Maintainer / implementer actions to reach `Investigated` — DONE (2026-08-09)

- [x] **V1:** Phase 2's re-spawn bullet rewritten — manager `sendWork` catch
      (`vault_search_manager.dart:623-632`),
      `final dead = _isolate; _isolate = null; await dead?.shutdown();`,
      `_dead = true` removed, both qualifications added.
- [x] **V2:** Phase 2 stale-result bullet now states `_PendingWork` gains
      `expectedSha256` (no protocol change — `sha256` already on both messages),
      the "do not clear `_inflight` on mismatch" reorder in `_onResult`, and
      labels V2 as defense-in-depth that V1 subsumes.
- [x] **V3:** Phase 3 splits the two seams — extractor budget via the
      real-multi-page-fixture + `Duration.zero` seam; manager-layer
      fake-delaying-extractor for the re-spawn/stale-result tests. "Or" framing
      removed.

## Investigation

### Extractor entry points

| Package | Entry | Recursion | Native |
| :--- | :--- | :--- | :--- |
| `kmdb_extractor_pdf` | `pdf_text_extractor.dart:108` | — | **yes** (`betto_pdfium`) |
| `kmdb_extractor_html` | `html_text_extractor.dart` `extract` → `_walkNode:255` | **yes** | no |
| `kmdb_extractor_markdown` | `markdown_text_extractor.dart` `extract` → `_walkNode:237` | **yes** | no |

### Contract + invocation

- `VaultTextExtractor.extract(Uint8List, VaultManifest) → Future<String?>`
  (`vault_text_extractor.dart:69`); MUST NOT throw, `null` on failure.
- In the vault pipeline, extraction runs in `VaultIndexingIsolate` — one blob at
  a time, no durable writes in the isolate (Q3-ii rests on this).
- Existing upstream gate: `VaultSearchConfig.maxBlobBytes = 200 MiB`
  (`vault_search_config.dart:81`).

## Implementation plan

### Phase 1 — `ExtractorLimits` + the two pure-Dart bounds

- [x] Define `ExtractorLimits` in core `kmdb` (next to `VaultTextExtractor`,
      exported from `package:kmdb/kmdb.dart`), with a **`const` `defaults`** of
      `maxInputBytes = 32 * 1024 * 1024`, `maxRecursionDepth = 512`,
      `maxDuration = Duration(seconds: 20)`. Add
      `{ExtractorLimits limits = ExtractorLimits.defaults}` to the three
      extractors' (and `PlainTextExtractor`'s) constructors, preserving `const`.
      Note: `PlainTextExtractor`'s constructor could not stay `const` — its
      pre-existing `lastCharset` field is mutable (non-`final`), which alone
      already precluded `const` before this change; documented in its doc
      comment.
- [x] **Input-size bound** in all four extractors: decline (`return null`) when
      `bytes.length > limits.maxInputBytes`, **before any parsing** (this is also
      the parser-stage stack-overflow guard — see Q2).
- [x] **Recursion-depth bound** in the HTML and Markdown `_walkElement` recursion
      sites (`html_text_extractor.dart:234-235`, `markdown_text_extractor.dart:216`
      — not the `extract()` entry call): thread a depth counter, increment-then-
      check **before** descending; on exceeding `maxRecursionDepth`, decline
      gracefully — a hostile document should yield `null`, not a
      truncated-but-plausible result. Document the depth cap as protecting the
      *walk*, with `maxInputBytes` guarding the *parser* stage.

### Phase 2 — The PDF time bound (per Q3 — recast by review)

> Do **not** implement the original "kill the vault isolate" framing: it does not
> stop native work in the process-wide `PdfiumIsolate` singleton (see Review).
> Implement the mechanism the maintainer confirms from the recast Q3.

- [x] **Primary bound:** cumulative wall-clock budget inside
      `PdfTextExtractor.extract()` across the `await for (page in doc.extractPlainText())`
      loop — on exceeding `limits.maxDuration`, stop iterating (subscription
      cancellation releases handles) and `return null`. Works standalone and in
      the pipeline; no isolate machinery.
- [x] **Backstop (already exists — do not duplicate):** the 30 s
      `VaultIndexingIsolate.kWorkTimeout` remains for the single-page native-hang
      case the extractor budget cannot interrupt. Keep `maxDuration < kWorkTimeout`.
- [x] **In scope (maintainer confirmed 2026-08-09) — re-spawn on `kWorkTimeout`.**
      **(V1, corrected against code.)** Do this in the manager's existing
      `sendWork` catch (`vault_search_manager.dart:623-632`), **not** by touching
      `_dead`: `_dead` is private to `VaultIndexingIsolate` (`:228`) with no setter
      and is read only by that instance's own `sendWork` — the manager cannot (and
      must not) set it. Capture-and-null **before** the await so a concurrent
      `close()` (`:528-529`) can't double-drive the same instance:
      `final dead = _isolate; _isolate = null; await dead?.shutdown();`
      (double-shutdown is idempotent; `_inflight` is already null on the timeout
      path so `shutdown()`'s 5 s drain is skipped). The next item then spawns a
      fresh isolate. **Two qualifications:** (a) re-spawn fires **only** on the
      `kWorkTimeout` backstop path — the 20 s extractor budget returns `null`, so
      `sendWork` completes *normally* and lands at the `result.isFailed` branch
      (`:645`), not the catch; (b) it cures only **Dart-level** wedging — a
      natively-wedged process-wide `PdfiumIsolate` re-wedges the fresh isolate's
      PDF work (→ RC-25).
- [x] **In scope (same decision) — stale-result guard (V2, defense-in-depth, not
      the fix).** No protocol change is needed: `VaultWorkItem.sha256` (`:79`) and
      `VaultIndexResult.sha256` (`:114`) already exist; only `_PendingWork`
      (`:416`) gains an `expectedSha256`. In `_onResult` (`:374-384`) — which nulls
      `_inflight` **first** — on a `sha256` mismatch **return without clearing
      `_inflight`** (else a stale reply abandons the legitimately in-flight item).
      Note honestly: once V1's re-spawn is correct, the old isolate is killed and
      its ports closed, so mis-delivery is **structurally impossible** — this guard
      is belt-and-braces, not the primary fix.
- [x] Ensure a timed-out extraction surfaces as `null`/`failed` and, in the
      pipeline, does not wedge the indexing queue.

### Phase 3 — Tests (fault injection, per CLAUDE.md — not golden path)

- [x] **Deeply-nested HTML** and **Markdown** fixtures (nesting well past the
      depth cap) → assert `null` in bounded time, no stack overflow.
      (`html_text_extractor_test.dart`/`markdown_text_extractor_test.dart`,
      group `ExtractorLimits (S-8)`, using a tiny `maxRecursionDepth: 5`.)
- [x] **Oversized input** for each extractor → assert `null` without parsing.
      (Same groups, plus `plain_text_extractor_test.dart` — new file, since no
      dedicated `PlainTextExtractor` unit test existed before this plan.)
- [x] **PDF extractor budget (V3 — needs its OWN seam; the two seams test
      different code).** The 20 s cumulative budget lives *inside*
      `PdfTextExtractor.extract()` (`pdf_text_extractor.dart:123`) — a fake
      `VaultTextExtractor` at the manager layer **cannot** reach it. Test it with a
      **real multi-page fixture + `maxDuration: Duration.zero`** (the repo ships
      `test/fixtures/arxiv/*.pdf` / `large.pdf`; the budget trips deterministically
      after page 1's FFI round-trip) → assert `null`. No new public API on the
      published package. (`pdf_text_extractor_test.dart`, using the 26-page
      `arxiv/2404.16130v2.pdf` fixture.)
- [x] **Re-spawn-on-timeout (manager-layer seam):** using a **fake delaying
      `VaultTextExtractor`** (precedent:
      `test/query/kmdb_database_close_isolate_death_test.dart`), drive a work item
      past `kWorkTimeout` and assert the item is `failed` **and the next item is
      served by a fresh isolate** and succeeds.
      (`vault_search_manager_respawn_test.dart` — new file; real-time test, ~30s
      wall clock since a spawned isolate's event loop cannot be driven by a
      virtual/fake clock.)
- [x] **Stale-result regression (manager-layer seam):** a late result for a
      timed-out item N must NOT complete item N+1 (assert N+1 gets its own result
      or `failed`, never N's). Implementation note: with V1 correctly landed, the
      manager always discards a timed-out item's isolate before sending the next
      item, which makes the mis-delivery structurally unreachable *through the
      manager* (confirmed empirically — see the plan's V2 note above). To
      actually exercise `_onResult`'s sha256 guard, this test drives
      `VaultIndexingIsolate` directly (bypassing `VaultSearchManager`, no
      `shutdown()` between sends), reusing the same isolate instance across two
      `sendWork()` calls — reproducing the interleaving V1 makes unreachable in
      production. (`vault_indexing_isolate_test.dart`, group "V2 stale-result
      guard"; also ~35s wall clock for the same reason as the re-spawn test.)
- [x] **Real hanging/crashing PDF is NOT automatable** — do not attempt a native
      fixture in the suite. Extend/annotate release-checklist **RC-25** (D-1) to
      cover the PDF time-bound expectation at release time.
- [x] Golden-path regression: normal PDF/HTML/MD still extract correctly under
      the default limits (use fixtures small/shallow enough to pass the bounds).
      (Pre-existing golden-path tests continue to pass unmodified against the
      new default-limits constructor parameter; new `ExtractorLimits (S-8)`
      groups add explicit "input at/below limit still extracts" cases.)

### Phase 4 — Spec

- [x] Document the `ExtractorLimits` policy and the "never throw → null" bound
      behaviour in the §24 vault / `VaultTextExtractor` contract section, and note
      the extractor-package READMEs if they describe usage.

**Final step — QA sign-off and pre-commit:**

- [ ] `make coverage` — >95% on changed files; ≥90% overall. **Note:** these
      changes span `kmdb_extractor_*` packages, which `make pre_commit`'s
      kmdb-scoped test step does **not** run — run each affected package's own
      tests (`cd packages/kmdb_extractor_<x> && dart test`) plus `kmdb`'s vault
      suites.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off; then `make pre_commit`.
- [ ] Licence headers (2026) on new files.

## Summary

_To be completed when the work is done._
