# Lexical Search: Wire `BrowserTokenizer` as the Default Web Tokenizer

**Status**: Implementing

**PR link**: _(pending)_

## Problem statement

`betto_icu` now ships a `BrowserTokenizer` backed by the browser's native
`Intl.Segmenter` API (`dart:js_interop`). It gives UAX #29-quality word
segmentation on web at zero bundle cost — the browser's own ICU handles it.

Two gaps prevent `kmdb_lexical` and the FTS pipeline from using it:

1. `kmdb_lexical/lexical.dart` does not re-export `BrowserTokenizer`, so
   consumers of the package cannot reach it.
2. `FtsManager` hardcodes `RegExpTokenizer()` at four call sites. On web it
   should use `BrowserTokenizer` instead for better segmentation quality; on
   native it should continue to use `RegExpTokenizer` (or `IcuTokenizer` if the
   caller needs UAX #29 compliance).

The spec (§20) notes "lexical search may be revisited separately" for web —
this is that revisit. The FTS pipeline (`pipeline.dart`) already accepts
`Tokenizer` polymorphically, so no pipeline changes are needed. The fix is
entirely in `kmdb_lexical` (re-export + platform-aware factory) and
`FtsManager` (use the factory).

## Open questions

_(none — investigation complete)_

## Investigation

### Current wiring

| Layer | File | Current state |
|---|---|---|
| `betto_icu` | `lib/betto_icu.dart` | Exports `BrowserTokenizer` via `if (dart.library.js_interop)` conditional. Real impl on web; stub (throws `UnsupportedError`) on native. ✅ |
| `kmdb_lexical` | `lib/lexical.dart` | Re-exports `Tokenizer`, `RegExpTokenizer`, `IcuTokenizer` — **`BrowserTokenizer` absent**. ❌ |
| `FtsManager` | `lib/src/search/lexical/fts_manager.dart` | Hardcodes `RegExpTokenizer()` at lines 223, 289, 469, 599. No tokenizer injection. ❌ |
| Pipeline | `lib/src/search/lexical/pipeline.dart` | `preprocess()` accepts `Tokenizer` polymorphically. ✅ |
| Spec §20 | `docs/spec/20_text_search.md` | Lists web lexical search as out-of-scope with a "may be revisited" note. Needs updating. |
| Spec §21 | `docs/spec/21_lexical_search.md` | Tokenizer table lists `RegExpTokenizer` and `IcuTokenizer` only. Needs `BrowserTokenizer` row. |

### Why not constructor injection on `FtsManager`?

`FtsManager` is an internal type constructed inside `KmdbDatabase.open()`. An
optional `Tokenizer?` constructor parameter would need to thread through
`KmdbDatabase.open()` too, adding public API surface for a platform-selection
concern. A platform-aware factory function in `kmdb_lexical` — the package
that already owns all tokenizer types — is the right home for this logic and
keeps it invisible to callers.

### Proposed approach: `createDefaultTokenizer()` conditional factory

Add two files to `kmdb_lexical/lib/src/`:

- `default_tokenizer_native.dart` — returns `RegExpTokenizer()`
- `default_tokenizer_web.dart` — returns `BrowserTokenizer()`

Wire the selection in `lexical.dart`:

```dart
export 'src/default_tokenizer_native.dart'
    if (dart.library.js_interop) 'src/default_tokenizer_web.dart'
    show createDefaultTokenizer;
```

`FtsManager` imports `createDefaultTokenizer` from `kmdb_lexical` and replaces
the four `RegExpTokenizer()` call sites. No public API changes; no new
constructor parameters.

### Key files

| File | Change |
|---|---|
| `packages/kmdb_lexical/lib/lexical.dart` | Add `BrowserTokenizer` re-export; add `createDefaultTokenizer` conditional export |
| `packages/kmdb_lexical/lib/src/default_tokenizer_native.dart` | New — `createDefaultTokenizer()` → `RegExpTokenizer()` |
| `packages/kmdb_lexical/lib/src/default_tokenizer_web.dart` | New — `createDefaultTokenizer()` → `BrowserTokenizer()` |
| `packages/kmdb/lib/src/search/lexical/fts_manager.dart` | Import `createDefaultTokenizer`; replace 4 × `RegExpTokenizer()` |
| `docs/spec/21_lexical_search.md` | Add `BrowserTokenizer` row to the tokenizer table |
| `docs/spec/20_text_search.md` | Revise the web lexical search out-of-scope note |

### Edge cases and notes

- `RegExpTokenizer` already works on web (pure Dart), so the FTS pipeline is
  not broken today. This change improves segmentation quality; it does not
  fix a crash.
- The `BrowserTokenizer` stub on native throws `UnsupportedError` — hence the
  conditional export rather than a runtime platform check.
- `IcuTokenizer` is the right upgrade on native where UAX #29 is needed.
  That is a caller concern (advanced usage) and out of scope here.
- Index token counts will differ between `RegExpTokenizer` and
  `BrowserTokenizer` for some edge-case inputs (e.g. contractions, currency
  symbols). Existing FTS indexes built with `RegExpTokenizer` are device-local
  and will be rebuilt automatically on next `ensureBuilt()` — no migration
  needed.
- Tests run on native only in CI, so `createDefaultTokenizer()` resolves to
  `RegExpTokenizer()` there. The `BrowserTokenizer` path is verified via the
  existing `betto_icu` tests and by the fact that the conditional export is
  identical in structure to the one already proven in `betto_icu`.

## Implementation plan

### Phase 1 — `kmdb_lexical` factory

- [x] Add `packages/kmdb_lexical/lib/src/default_tokenizer_native.dart`:
  ```dart
  // [license header]
  import 'package:betto_icu/betto_icu.dart';
  /// Returns the default [Tokenizer] for native platforms ([RegExpTokenizer]).
  Tokenizer createDefaultTokenizer() => RegExpTokenizer();
  ```
- [x] Add `packages/kmdb_lexical/lib/src/default_tokenizer_web.dart`:
  ```dart
  // [license header]
  import 'package:betto_icu/betto_icu.dart';
  /// Returns the default [Tokenizer] for web platforms ([BrowserTokenizer]).
  Tokenizer createDefaultTokenizer() => BrowserTokenizer();
  ```
- [x] Update `packages/kmdb_lexical/lib/lexical.dart`:
  - Add `BrowserTokenizer` to the `show` list on the `betto_icu` export.
  - Add the `createDefaultTokenizer` conditional export.
- [x] Ensure license headers on both new files (use `header_template.txt`).

### Phase 2 — `FtsManager` wiring

- [x] In `packages/kmdb/lib/src/search/lexical/fts_manager.dart`:
  - Update the import from `kmdb_lexical` to include `createDefaultTokenizer`
    and remove the now-unused `RegExpTokenizer` import (keeping `getStopWords`).
  - Replace all four `RegExpTokenizer()` call sites (lines 223, 289, 469, 599)
    with `createDefaultTokenizer()`.

### Phase 3 — Tests

- [x] Add a test to `packages/kmdb_lexical/test/` asserting that
  `createDefaultTokenizer()` returns a working `Tokenizer` that tokenises a
  simple English sentence correctly.
- [x] Confirm the existing `kmdb_lexical` and `kmdb` FTS tests still pass:
  `cd packages/kmdb_lexical && dart test`
  `cd packages/kmdb && dart test`

### Phase 4 — Spec and docs

- [x] Update `docs/spec/21_lexical_search.md` tokenizer table — add a
  `BrowserTokenizer` row with `Default: Yes (web)` (per reviewer correction:
  the table must honestly reflect that `BrowserTokenizer` is the web default).
- [x] Update `docs/spec/20_text_search.md` — revise the web lexical search
  out-of-scope note to reflect that lexical search now works on web via
  `BrowserTokenizer`.
- [x] Run `make pre_commit` and confirm it passes.

### Phase 5 — PR

- [ ] Open a pull request with all changes; update plan status to `Complete`
  and move the file to `docs/plans/completed/`.

## Reviewer notes (kmdb-plan-reviewer, 2026-06-09)

Verified against the codebase. Every load-bearing claim checks out:

- The four `RegExpTokenizer()` call sites in `fts_manager.dart` are exactly at
  lines 223 (`_interceptInsert`), 289 (`_interceptUpdate`), 469 (rebuild /
  `ensureBuilt` path), and 599 (query path). Routing all four through one
  factory is correct **and important** — index-write and query-read must
  tokenise identically, and a single factory guarantees that.
- `kmdb_lexical/lib/lexical.dart` currently re-exports only
  `Tokenizer, RegExpTokenizer, IcuTokenizer` — `BrowserTokenizer` is indeed
  absent.
- `betto_icu` (pub.dev `^0.1.0-dev.1`, consumed only by `kmdb_lexical`) exports
  `BrowserTokenizer` via `if (dart.library.js_interop)` with a native stub that
  throws `UnsupportedError` **at construction time**. This confirms the plan's
  central design decision: a conditional export is required, not a runtime
  platform check, because merely constructing the stub throws.
- `kmdb` does **not** depend on `betto_icu` directly — it reaches tokenizers
  through `kmdb_lexical`. Putting `createDefaultTokenizer` in `kmdb_lexical` is
  the right home: it keeps `FtsManager` off a direct `betto_icu` dependency and
  respects the existing package boundary. The "why not constructor injection"
  rationale (§Investigation) is sound.
- `BrowserTokenizer()` has a defaulted optional `locale` parameter, so the
  zero-arg construction in `default_tokenizer_web.dart` is valid.
- `pipeline_test.dart` constructs `RegExpTokenizer()` directly to test the
  pipeline; it does not assert anything about `FtsManager`'s tokenizer choice,
  so this change breaks no existing test.

**Strengths.** Tightly scoped, no public API surface added, no sync/storage
invariants touched (`$fts:` namespaces are local-only and excluded from sync),
and the conditional-export structure mirrors a pattern already proven in
`betto_icu`. The note that existing indexes are device-local and rebuilt on next
`ensureBuilt()` is correct — no migration concern.

**Two minor corrections to fold into the work (not blockers):**

1. **Spec §21 "Default" column.** The table at `21_lexical_search.md:20-23` has
   a **Default** column (not the "Web: Yes / Default: No" shape the checklist
   describes). On web this change makes `BrowserTokenizer` the *de facto*
   default, while `RegExpTokenizer` stays the native default. The new row should
   say so honestly — e.g. mark Default as "Web" / "Yes (web)" rather than "No",
   and add a sentence clarifying that the default tokenizer is now
   platform-selected. Don't ship a table that claims `BrowserTokenizer` is never
   the default when the whole point of the change is to make it the web default.

2. **`RegExpTokenizer` import in `fts_manager.dart`.** After the change,
   `RegExpTokenizer` is no longer referenced in that file (all four sites move
   to `createDefaultTokenizer`), so the import on line 24 must drop
   `RegExpTokenizer` and add `createDefaultTokenizer` (keeping `getStopWords`).
   The checklist already hedges this ("if applicable") — it is applicable;
   leaving the unused import will fail `analyze`. State it definitively.

**Testing strategy — adequate, with one gap to acknowledge in the plan rather
than fix.** CI runs native only, so `createDefaultTokenizer()` resolves to
`RegExpTokenizer()` and the `BrowserTokenizer` branch is never exercised by the
automated suite. The plan acknowledges this. The Phase 3 test (factory returns a
working tokenizer on native) is the right and only automated assertion available.
This is consistent with how the rest of the web/OPFS surface is handled and does
**not** warrant a release-checklist entry on its own — `BrowserTokenizer`'s own
behaviour is covered by `betto_icu`'s tests, and this plan only wires it in.
No new `docs/spec/28_release_checklist.md` entry is required.

**Verdict.** Implementation-ready. A Sonnet implementer can execute this
mechanically: the files, the export shape, the call sites, and the dependency
boundary are all pinned down, and the two corrections above are spelled out.
Status remains **Investigated**.

## Summary

_(To be filled in after implementation.)_
