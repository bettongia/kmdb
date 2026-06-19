# WI-2: Charset detection for vault text extraction

**Status**: Open

**PR link**: —

## Problem statement

Vault search (WI-3) will extract plain text from `text/plain` blobs for BM25
and semantic indexing via a `PlainTextExtractor`. Decoding raw bytes as UTF-8
unconditionally is incorrect: many real-world plain-text files use legacy
encodings — Windows-1252, ISO-8859-\*, Shift-JIS, EUC-JP, EUC-KR, GBK —
and decoding them as UTF-8 silently produces garbled text. That garbled text
would propagate into both the inverted index and the embedding model input,
corrupting both search paths without any error being raised.

`betto_charset_detector` is a pure-Dart, published package that handles
this detection in three ordered stages: BOM inspection → UTF-8 structural
validation → candidate encoding probe (see §10.1 of
`docs/proposals/vault_search.md`). It has no native dependencies and
works on all platforms.

This WI:

1. Adds `betto_charset_detector` to the workspace and `kmdb` package.
2. Introduces a `decodeText` utility function that combines detection and
   decoding into a single call — the seam WI-3's `PlainTextExtractor` will
   use.
3. Delivers >90% test coverage on the utility, including all supported
   encodings and known edge cases.

`PlainTextExtractor` itself is not introduced here — that is WI-3. This WI
establishes the dependency and the tested utility so WI-3 can consume it
without mixing detection concerns into the larger vault-search implementation.

## Open questions

_(none — design is settled by the proposal and package is published)_

## Investigation

### Current state

- `betto_charset_detector` is **not** present in the workspace
  `pubspec.yaml` `dependency_overrides` or in
  `packages/kmdb/pubspec.yaml`.
- No text decoding of any kind exists in `packages/kmdb` today: vault
  (Phase 10) stores and retrieves blobs opaquely, and vault search has not
  yet been built.
- The `charset` package (used internally by `betto_charset_detector`) is
  not currently in the dependency graph.

### `betto_charset_detector` capabilities

`detectCharset(Uint8List bytes)` returns a lowercase IANA encoding label.
Detection proceeds:

1. **BOM inspection** — deterministic; handles UTF-8 BOM, UTF-16 BE/LE,
   UTF-32 BE/LE.
2. **UTF-8 structural validation** — first 8 KB decoded with
   `utf8.decode(allowMalformed: false)`; valid → `"utf-8"`.
3. **Candidate probe** — tests `windows-1252`, `iso-8859-1`, `iso-8859-2`,
   `iso-8859-15`, `shift-jis`, `euc-jp`, `euc-kr`, `gbk` via
   `Charset.canDecode`. CJK encodings are promoted when >15% of sample
   bytes are ≥ 0x80. Fallback: `windows-1252`.

Empty input returns `"utf-8"`.

### Decoding after detection

The `betto_charset_detector` package returns only the label; the caller must
decode the bytes. `dart:convert` handles the Unicode family natively
(`utf8`, `latin1`, `ascii`). The `charset` package provides
`Charset.getByName(label).decode(bytes)` for the legacy 8-bit and CJK
encodings. The `decodeText` utility function wraps both paths so callers
never need to branch on the label.

### Proposed utility API

```dart
// packages/kmdb/lib/src/vault/search/charset_util.dart

/// The result of charset detection and decoding.
///
/// [charset] is the IANA encoding label (e.g. `"utf-8"`, `"windows-1252"`)
/// detected from [bytes]. Stored in `extract_status.json` by WI-3.
///
/// [text] is the decoded string, or `null` if decoding failed after detection
/// (a rare fallback case — e.g. the detected encoding cannot decode the bytes).
typedef CharsetDecodeResult = ({String charset, String? text});

/// Detects the character encoding of [bytes] and decodes them to a string.
///
/// Returns a [CharsetDecodeResult] with the detected IANA label and the
/// decoded text. The [text] field is `null` only if decoding fails after
/// detection.
CharsetDecodeResult decodeText(Uint8List bytes);
```

The record return type keeps both the charset label and decoded text together
without an out-param, making the `extract_status.json` write in WI-3
straightforward: `final (:charset, :text) = decodeText(bytes);`.

### File location

`packages/kmdb/lib/src/vault/search/charset_util.dart`

WI-3 will create the `vault/search/` subtree in full; this WI creates only
the `charset_util.dart` file within it. The directory does not exist yet and
must be created as part of this WI.

### Edge cases to exercise in tests

| Scenario | Expected behaviour |
| -------- | ------------------ |
| Valid UTF-8, no BOM | Returns decoded string, label `"utf-8"` |
| UTF-8 with BOM | BOM stripped from output, label `"utf-8"` |
| UTF-16 BE with BOM | Decoded correctly, label `"utf-16be"` |
| UTF-16 LE with BOM | Decoded correctly, label `"utf-16le"` |
| Windows-1252 (no BOM, high bytes) | Decoded correctly, label `"windows-1252"` |
| ISO-8859-1 (Latin-1 text) | Decoded correctly, label `"iso-8859-1"` |
| Shift-JIS | Decoded correctly, label `"shift-jis"` |
| EUC-JP | Decoded correctly, label `"euc-jp"` |
| GBK | Decoded correctly, label `"gbk"` |
| Empty bytes | Returns empty string, label `"utf-8"` |
| Bytes that pass UTF-8 validation but are actually Windows-1252 | `"utf-8"` (structural match takes priority — documented limitation) |
| `detectedCharset` out-param is populated | Label written to buffer |

The last row is important: `betto_charset_detector`'s UTF-8 structural
validation is a hard gate — valid UTF-8 bytes are always classified as
`"utf-8"` even if the file was authored in a superset encoding. This is
the expected and documented behaviour, not a bug. The test should assert
it explicitly so the limitation is on record.

### Coverage target

The `charset_util.dart` file is small and all paths are reachable. >90%
coverage is expected to be achievable at 100% in practice. Run
`make coverage` to verify.

### Spec impact

Add a brief note to `docs/spec/20_text_search.md` (or the forthcoming vault
search spec section) recording that charset detection precedes UTF-8 decoding
for plain-text blobs, and that the detected label is stored in
`extract_status.json`. No new spec file is needed for this WI alone.

## Implementation plan

- [ ] Add `betto_charset_detector` to workspace `pubspec.yaml`
      `dependency_overrides` (check pub.dev for the current published version
      — the proposal references `^0.1.0-dev.2`).
- [ ] Add `betto_charset_detector` to `packages/kmdb/pubspec.yaml`
      `dependencies`.
- [ ] Run `dart pub get` from the workspace root to resolve.
- [ ] Create `packages/kmdb/lib/src/vault/search/` directory.
- [ ] Implement `decodeText` in
      `packages/kmdb/lib/src/vault/search/charset_util.dart` with licence
      header (year 2026). Keep the implementation free of side effects —
      pure bytes-in, string-out.
- [ ] Export `CharsetDecodeResult` and `decodeText` from the library.
- [ ] Write `packages/kmdb/test/vault/search/charset_util_test.dart`
      covering all rows in the edge-case table above plus a round-trip test
      for each supported IANA label.
- [ ] Run `make coverage` and confirm >90% on `charset_util.dart`.
- [ ] Add a `charset_util` note to `docs/spec/20_text_search.md` (one or
      two sentences; no structural change to the spec).
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all
      green.

## Summary

_(to be completed after implementation)_
