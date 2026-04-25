# Coverage Uplift — FFI / Native / Flutter packages to ≥90%

**Status**: Open

**PR link**: _none yet_

## Problem statement

Several packages sit far below the 90% coverage bar because their code is
exercised end-to-end against native libraries (ONNX Runtime, ICU, Zstd) or
through Flutter widgets. The 2026-04-25 audit numbers (real coverage, after
excluding `third_party/` and generated `lib/src/g/`):

- **`kmdb_inferencing`** — 7.9% (BERT tokenizer, ORT session, ORT library all
  0%)
- **`kmdb_ui`** — 30.7% (most dialogs and providers untested)
- **`kmdb_lexical`** — 50% (only the regex tokenizer and stopwords are tested;
  the stemmer wrapper is unexercised)
- **`kmdb_mimeinfo`** — 58.5% (xml.dart, icon.dart, parts of magic.dart,
  glob.dart untested)
- **`kmdb_tokenizer_icu`** — 69.8% (error paths in the FFI loader)
- **`kmdb_zstd`** — 82.9% (mostly there; a few decode-error branches)

The closest-to-the-bar (`kmdb_zstd`, `kmdb_tokenizer_icu`) should be addressed
first; `kmdb_inferencing` and `kmdb_ui` will require new test infrastructure and
may justify a documented exemption rather than a 90% target.

## Open questions

- [ ] Should we adopt an explicit "native dylib required" CI gate so
      `kmdb_inferencing` tests can run in coverage builds? Or stub `ort_*` with
      a fake implementation behind a `dart.library.io` switch?
- [ ] Is the project willing to vendor a small ICU dylib for unit tests of
      `kmdb_tokenizer_icu`, or should the FFI layer be tested via injection?
- [ ] For `kmdb_ui`: are widget tests in scope, or is the package exempt from
      the 90% rule (with explicit documentation in CLAUDE.md)?

## Investigation

The FFI/Flutter packages share three test-environment shortcomings:

1. **Native asset loading.** `kmdb_inferencing/ort_*` and
   `kmdb_tokenizer_icu/icu_tokenizer` require dylibs that the test harness does
   not currently materialise. Coverage runs miss everything past the
   `lookupFunction` boundary.
2. **No widget tests.** `kmdb_ui` ships only a handful of integration smoke
   tests; dialogs (`new_database_dialog`, `add_document_dialog`,
   `new_collection_dialog`) and providers carry minimal coverage.
3. **Pure-Dart wrappers near 100%.** Within each FFI package, the pure-Dart
   surface (e.g. `sq8.dart`, `zstd_base.dart`) is well-tested — the coverage
   shortfall is exactly the FFI boundary.

## Implementation plan

### Sub-plan A — `kmdb_zstd` (closest to bar)

- [ ] Add tests for malformed-frame and truncated-input decode errors.
- [ ] Add tests for compression-level boundary values (1, 22, out of range).
- [ ] Re-run coverage and confirm ≥ 90%.

### Sub-plan B — `kmdb_tokenizer_icu`

- [ ] Add tests for FFI loader error paths (missing dylib, wrong version).
- [ ] Add tests for unicode boundary edge cases (combining marks, RTL, CJK).
- [ ] Re-run coverage and confirm ≥ 90%.

### Sub-plan C — `kmdb_lexical` stemmer wrapper

- [ ] Add a thin wrapper test exercising the snowball English entry point
      against a curated word list (covers `lib/src/stemmer.dart`).
- [ ] Re-run coverage and confirm ≥ 90% (excluding `third_party/`).

### Sub-plan D — `kmdb_mimeinfo`

- [ ] Add unit tests for `xml.dart` registry parsing.
- [ ] Add unit tests for icon resolution (`icon.dart`).
- [ ] Expand `glob.dart` and `magic.dart` failure-path tests.

### Sub-plan E — `kmdb_inferencing` (decision required)

- [ ] Decide: vendor the ONNX Runtime dylib in CI, or document an exemption.
- [ ] If exemption: add a CLAUDE.md note + `coverage:exclude` for the package's
      FFI files.
- [ ] If vendored: add ORT session smoke tests covering load → infer → free.

### Sub-plan F — `kmdb_ui` (decision required)

- [ ] Decide: bring widget coverage to ≥ 90% or document an exemption for
      "Flutter desktop UI".
- [ ] If pursuing coverage: add `flutter_test` widget tests for each dialog and
      provider state transition.

## Summary

_(left blank — fill in after implementation)_
