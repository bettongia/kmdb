# Technical Proposal: `betto_icu` — ICU Tokenizer Package

## 1. Overview

KMDB's Unicode-aware word tokenization is currently spread across two packages:

- `kmdb_lexical` defines the `Tokenizer` interface and provides `RegExpTokenizer`
  (a pure-Dart UAX #29 approximation for Latin scripts) alongside the
  `Stemmer` and `Stopwords` linguistic utilities.
- `kmdb_tokenizer_icu` provides `IcuTokenizer` — a full UAX #29 implementation
  backed by the system ICU library via FFI.

Neither of these has any dependency on KMDB-specific types. `Tokenizer`,
`RegExpTokenizer`, and `IcuTokenizer` together form a self-contained Unicode
text segmentation package that is useful to any Dart application doing text
processing — not only KMDB. Keeping them inside the KMDB monorepo means they
cannot be consumed as standalone dependencies by other projects in the Bettongia
ecosystem or by external users.

This proposal extracts them into a standalone `betto_icu` package (separate
repo, following the `betto_zstd` / `betto_onnxrt` package family convention).

### Goals

- Provide the `Tokenizer` interface and two implementations — `IcuTokenizer`
  (system ICU FFI, UAX #29 conformant) and `RegExpTokenizer` (pure Dart,
  Latin-script fallback) — as a reusable Dart package with no KMDB dependency.
- Make `IcuTokenizer` accessible without adding `kmdb_tokenizer_icu` as a
  separate dependency. After extraction, `betto_icu` is a transitive dependency
  of `kmdb_lexical`, so KMDB users and other Bettongia packages get both
  implementations automatically.
- Simplify the KMDB package graph: `kmdb_tokenizer_icu` is dissolved after
  extraction; its single class (`IcuTokenizer`) lives in `betto_icu`.
- Support all current KMDB target platforms (macOS, iOS, Android, Linux,
  Windows). ICU is a system library on all of them — no binary bundling,
  no build hook, no native-assets machinery.

### Non-goals

- Stemming, stopwords, or other linguistic processing beyond tokenization.
  `Stemmer` and `Stopwords` remain in `kmdb_lexical` — they are KMDB-domain
  linguistic utilities with no general-purpose audience.
- ICU collation, normalisation, locale-sensitive formatting, or any ICU
  service beyond `UBreakIterator` word-boundary analysis. Keep scope narrow;
  add APIs when concrete needs arise.
- Binary bundling. ICU is a system library on every target platform (see §3).
  There is no build hook, no `hook/build.dart`, no SHA-256 artifact manifest.
  This distinguishes `betto_icu` from `betto_zstd` and `betto_onnxrt`.

---

## 2. What moves where

| Item | Currently in | Moves to |
|---|---|---|
| `Tokenizer` abstract interface | `kmdb_lexical` | `betto_icu` |
| `RegExpTokenizer` (pure-Dart UAX #29 approx.) | `kmdb_lexical` | `betto_icu` |
| `IcuTokenizer` (system ICU FFI, full UAX #29) | `kmdb_tokenizer_icu` | `betto_icu` |
| `Stemmer` (Snowball) | `kmdb_lexical` | stays |
| `Stopwords` | `kmdb_lexical` | stays |
| `kmdb_tokenizer_icu` package | — | dissolved |

After extraction, `kmdb_lexical` depends on `betto_icu` for the `Tokenizer`
interface and its implementations, and retains `Stemmer` + `Stopwords` as its
own value-add. `kmdb` core depends on `kmdb_lexical` as today; `IcuTokenizer`
becomes available to any `kmdb` consumer transitively via
`kmdb` → `kmdb_lexical` → `betto_icu`, without requiring a separate
`kmdb_tokenizer_icu` dependency.

---

## 3. ICU platform availability

ICU is a system library on all of KMDB's target platforms — no bundling
is required and there is no App Store risk for ICU-based tokenization (contrast
with ONNX Runtime, which requires build-time bundling):

| Platform | Library | Notes |
|---|---|---|
| macOS / iOS | `libicucore.dylib` (ships with OS) | Always present; version tied to OS |
| Android | `libicuuc.so` (NDK) | Available on all NDK API levels |
| Linux | `libicuuc.so.NN` (system package) | Common across distributions; versioned name fallback already implemented |
| Windows | `icu.dll` (Windows 10+, build 1903+) | Built-in since 2019 |

The `_openIcuLibrary()` function in the current `icu_tokenizer.dart` already
handles this per-platform resolution, including the Linux versioned-name
fallback. That logic transfers verbatim to `betto_icu`.

One platform subtlety (already documented in `IcuTokenizer`): Apple's
`libicucore` does not include UAX #29 rule-status tags in its compiled word
break rules, so `ubrk_getRuleStatus()` returns non-standard values on
macOS/iOS. The current implementation works around this by using Dart's own
Unicode `RegExp` for span classification rather than rule-status codes —
boundary *positions* from the ICU iterator are correct on all platforms.
This workaround is part of `IcuTokenizer` and transfers with it.

---

## 4. Package structure

```
betto_icu/                           (separate repo, github.com/bettongia/icu)
  lib/
    betto_icu.dart                   ← public barrel: Tokenizer, IcuTokenizer,
                                       RegExpTokenizer
    src/
      tokenizer.dart                 ← Tokenizer abstract interface (moved from
                                       kmdb_lexical)
      icu_tokenizer.dart             ← IcuTokenizer FFI implementation (moved from
                                       kmdb_tokenizer_icu)
      regexp_tokenizer.dart          ← RegExpTokenizer pure-Dart implementation
                                       (moved from kmdb_lexical)
  test/
    icu_tokenizer_test.dart          ← moved from kmdb_tokenizer_icu
    regexp_tokenizer_test.dart       ← moved from kmdb_lexical
  pubspec.yaml                       ← dependencies: ffi, package:ffi
```

No `hook/` directory — no build hook needed (system library, no binary to
stage). `pubspec.yaml` lists `dart:ffi` (SDK) and `package:ffi` (pub.dev, for
`calloc` / `Utf8`); no other dependencies. The package is pure-Dart-plus-FFI
with no transitive dependencies on any Bettongia or KMDB package.

---

## 5. API

The API is unchanged from the current implementations — this is a packaging
move, not a redesign.

```dart
/// Segments text into word tokens. Implementations conform to UAX #29
/// Unicode Text Segmentation.
abstract interface class Tokenizer {
  List<String> tokenise(String text);
}

/// Full UAX #29 word-boundary tokenizer backed by the system ICU library.
/// Handles non-Latin scripts (CJK, Thai, Arabic, etc.) correctly.
/// Throws [UnsupportedError] if the ICU library cannot be found.
class IcuTokenizer implements Tokenizer { ... }

/// Pure-Dart UAX #29 approximation using Unicode RegExp word boundaries.
/// Suitable for Latin-script text and technical identifiers.
/// No native dependency — works on all platforms including web.
class RegExpTokenizer implements Tokenizer { ... }
```

`RegExpTokenizer` gains `implements Tokenizer` explicitly (it may already have
it via `kmdb_lexical`; confirm during extraction). No other API changes.

---

## 6. Aftermath in the KMDB monorepo

| Package | Change |
|---|---|
| `kmdb_lexical` | Add `betto_icu: ^1.0.0` dependency. Remove `Tokenizer`, `RegExpTokenizer`, `tokenizer.dart`, `regexp_tokenizer.dart`, and their tests. Re-export `Tokenizer`/`RegExpTokenizer`/`IcuTokenizer` from `lexical.dart` so that existing `import 'package:kmdb_lexical/lexical.dart'` call sites in `kmdb` and `kmdb_cli` are unaffected. |
| `kmdb_tokenizer_icu` | Deprecated and dissolved. The package's only class (`IcuTokenizer`) is now in `betto_icu` and available transitively via `kmdb_lexical`. Consumer apps that listed `kmdb_tokenizer_icu` in their `pubspec.yaml` drop it and import `IcuTokenizer` from `kmdb_lexical` (or `betto_icu` directly). |
| `kmdb_inferencing` | No change. It depends on `kmdb_lexical` for `Stemmer`/`Stopwords`, not for the tokenizer. |
| `kmdb` (core) | No change. It depends on `kmdb_lexical`; `Tokenizer` arrives transitively. |
| `kmdb_cli` | No change unless it imports `kmdb_tokenizer_icu` directly — confirm during extraction. |

The re-export from `kmdb_lexical` is the key backward-compatibility bridge.
Consumer code that does `import 'package:kmdb_lexical/lexical.dart' show
IcuTokenizer` continues to work without any changes to the consumer.

---

## 7. Comparison with `betto_zstd` and `betto_onnxrt`

| | `betto_zstd` | `betto_onnxrt` | `betto_icu` |
|---|---|---|---|
| Binary source | Build from source (C, CMake-free) | Prebuilt ORT artifacts | System library (OS-provided) |
| Build hook | Yes (`CBuilder`, source compile) | Yes (download + stage prebuilt) | **No** |
| App Store risk | None (source-built) | None (build-time bundle) | None (system library) |
| pub.dev published package size | Small (hook source + C) | Small (hook source + manifest) | **Tiny (pure Dart + FFI only)** |
| First-run network dependency | No | No (runtime bundled by hook) | No |

`betto_icu` is the simplest of the three: no hook, no binary staging, no
size concern. It is a straightforward Dart package that wraps a system API
and provides a pure-Dart fallback.

---

## 8. Sequencing

`betto_icu` has no dependency on `betto_onnxrt` or the configurable embedding
model plan and can be worked on in parallel. It is the simpler extraction:
no build hook, no iOS SPM spike, no new CI pipeline for binary artifacts.

Suggested order within the v0.05 platform infrastructure track:

1. Create `betto_icu` repo with the transferred sources and tests.
2. Publish to pub.dev (or add `git:` ref alongside other `betto_*` packages
   until the full suite is ready to publish).
3. Update `kmdb_lexical` to depend on `betto_icu`; add re-exports; remove
   migrated files.
4. Deprecate `kmdb_tokenizer_icu`; update any consumer pubspec files.

Step 1–2 can land before or after `plan_configurable_embedding_model.md`;
steps 3–4 should land as a single PR to keep the dependency graph coherent.

---

## 9. Open questions

### Q1 — `RegExpTokenizer` in `kmdb_lexical`: re-export or remove?

`kmdb_lexical` currently exports `RegExpTokenizer`. After `betto_icu`, it would
re-export `RegExpTokenizer` from `betto_icu`. The alternative is to remove the
re-export and let consumers that need it import `betto_icu` directly. The
re-export is simpler for existing consumers; the direct import is more honest
about the dependency. Decision: **re-export** (backward-compatible; `kmdb`
consumers don't need to update their imports).

### Q2 — `Tokenizer` interface: own it in `betto_icu` or keep in `kmdb_lexical`?

Moving the interface to `betto_icu` makes `betto_icu` fully self-contained and
keeps `kmdb_lexical` as a downstream dependent. The alternative — keeping
`Tokenizer` in `kmdb_lexical` and having `betto_icu` depend on `kmdb_lexical`
for the interface — would create a circular dependency (`kmdb_lexical` →
`betto_icu` → `kmdb_lexical`), which is not viable. **`betto_icu` must own the
`Tokenizer` interface.** `kmdb_lexical` re-exports it.

### Q3 — Scope: word breaking only, or broader ICU surface?

The current `IcuTokenizer` uses only `ubrk_open`, `ubrk_next`, `ubrk_close`
from ICU's break-iterator API. The package name `betto_icu` implies the door is
open to ICU collation, normalisation, or locale utilities in future versions.
This is fine — the name is accurate and the scope can expand incrementally. The
v1 public API is limited to `Tokenizer` / `IcuTokenizer` / `RegExpTokenizer`;
nothing else is committed.
