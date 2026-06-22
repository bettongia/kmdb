# WI-2: Charset detection for vault text extraction

**Status**: Complete

**PR link**: https://github.com/bettongia/kmdb/pull/51

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

- [x] **Q1 — BOM stripping for UTF-8.** `decodeText` explicitly strips a
      leading U+FEFF from the decoded string when the label is `'utf-8'`.
      `dart:convert`'s `utf8.decode` does not strip it, so `decodeText` does
      it with a `startsWith` guard after decoding. UTF-16/UTF-32 BOMs are
      stripped by the `charset` codec itself — no extra step needed there.
- [x] **Q2 — Label → decoder dispatch table.** Two-branch dispatch:
      - `'utf-8'` → `utf8.decode(bytes)`, then strip leading U+FEFF if present.
      - All other labels → `Charset.getByName(label)!.decode(bytes)`.
      The `iso-8859-1` → `latin1` fallback inside `getByName` is relied upon,
      not special-cased. `ascii` is never returned — ASCII content passes UTF-8
      structural validation and is reported as `'utf-8'`.
- [x] **Q3 — UTF-16/UTF-32 endianness.** In `charset 2.0.1`, both `utf-16be`
      and `utf-16le` map to the same `utf16` codec (likewise `utf-32be`/`utf-32le`
      → `utf32`); endianness is derived from the leading BOM in the byte content,
      not the label. Because `detectCharset` only emits these labels when a BOM
      is present, `getByName(label).decode(bytes)` works correctly and strips the
      BOM. This is acceptable; a code comment in `decodeText` must document it so
      the implementer does not try to force LE/BE via the label.
- [x] **Q4 — Decode-failure contract.** `null` is not reachable. The
      `windows-1252` fallback accepts any byte sequence, and all other decoders
      are chosen only behind a validated BOM or UTF-8 structural check. Change
      `String?` to `String` in the return type — no null branch, no dead code,
      no coverage concern.
- [x] **Q5 — Export visibility.** Internal only. `CharsetDecodeResult` and
      `decodeText` are **not** exported from `packages/kmdb/lib/kmdb.dart`. WI-3's
      `PlainTextExtractor` imports them directly from
      `src/vault/search/charset_util.dart`. No public API stability obligation.

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
/// [charset] is the detected IANA encoding label (e.g. `"utf-8"`,
/// `"windows-1252"`). [text] is the decoded string. Both fields are always
/// non-null — decoding cannot fail for the closed label set returned by
/// `detectCharset`.
typedef CharsetDecodeResult = ({String charset, String text});

/// Detects the character encoding of [bytes] and decodes them to a string.
///
/// Detection uses `betto_charset_detector`'s three-stage pipeline (BOM
/// inspection → UTF-8 structural validation → candidate probe). Decoding
/// uses a two-branch dispatch:
///
/// - `'utf-8'` → `dart:convert`'s `utf8.decode`, with a leading U+FEFF
///   (UTF-8 BOM) stripped from the result if present.
/// - All other labels → `Charset.getByName(label).decode(bytes)`.
///   UTF-16/UTF-32 endianness is derived from the leading BOM in the byte
///   content by the `charset` codec (not the label) — do not attempt to
///   force LE/BE via the label string.
///   `iso-8859-1` resolves via `getByName`'s internal fallback to `latin1`.
CharsetDecodeResult decodeText(Uint8List bytes);
```

The record return type keeps both values together without an out-param.
Callers destructure with `final (:charset, :text) = decodeText(bytes);`.

### File location

`packages/kmdb/lib/src/vault/search/charset_util.dart`

WI-3 will create the `vault/search/` subtree in full; this WI creates only
the `charset_util.dart` file within it. The directory does not exist yet and
must be created as part of this WI.

### Edge cases to exercise in tests

| Scenario | Expected behaviour |
| -------- | ------------------ |
| Valid UTF-8, no BOM | `text` = decoded string, `charset` = `"utf-8"` |
| UTF-8 with BOM (0xEF 0xBB 0xBF) | `text` has no leading U+FEFF — stripped by `decodeText`; `charset` = `"utf-8"` |
| UTF-16 BE with BOM | Decoded correctly, BOM stripped by `charset` codec; `charset` = `"utf-16be"` |
| UTF-16 LE with BOM | Decoded correctly, BOM stripped by `charset` codec; `charset` = `"utf-16le"` |
| Windows-1252 (no BOM, high bytes) | Decoded correctly, `charset` = `"windows-1252"` |
| ISO-8859-1 (Latin-1 text) | Decoded correctly via `getByName` → `latin1` fallback; `charset` = `"iso-8859-1"` |
| Shift-JIS | Decoded correctly, `charset` = `"shift-jis"` |
| EUC-JP | Decoded correctly, `charset` = `"euc-jp"` |
| GBK | Decoded correctly, `charset` = `"gbk"` |
| Empty bytes | `text` = `""`, `charset` = `"utf-8"` |
| ASCII-only bytes | `text` = decoded string, `charset` = `"utf-8"` (ASCII never returned as its own label) |
| Bytes valid as UTF-8 but authored as Windows-1252 | `charset` = `"utf-8"` (structural validation is a hard gate — documented limitation, assert explicitly in tests) |

The UTF-8 structural validation gate is intentional: valid UTF-8 bytes are
always classified as `"utf-8"` regardless of original authoring encoding. Tests
must assert this to put the limitation on record.

### Coverage target

`charset_util.dart` is small, the label set is closed, and `text` is always
non-null (Q4) so there is no dead branch. 100% line coverage is expected.
Run `make coverage` to verify; the project gate is >90%.

### Spec impact

Add a brief note to `docs/spec/20_text_search.md` (or the forthcoming vault
search spec section) recording that charset detection precedes UTF-8 decoding
for plain-text blobs, and that the detected label is stored in
`extract_status.json`. No new spec file is needed for this WI alone.

## Implementation plan

- [x] Add `betto_charset_detector` to workspace `pubspec.yaml`
      `dependency_overrides` (check pub.dev for the current published version
      — the proposal references `^0.1.0-dev.2`). Added at `^0.1.0-dev.2`.
- [x] Add `betto_charset_detector` and `charset` to `packages/kmdb/pubspec.yaml`
      `dependencies`. (`charset` added as direct dep since it is imported
      directly in `charset_util.dart` and the test; `charset` also pinned in
      root `dependency_overrides` at `^2.0.1`.)
- [x] Run `dart pub get` from the workspace root to resolve.
- [x] Create `packages/kmdb/lib/src/vault/search/` directory.
- [x] Implement `decodeText` in
      `packages/kmdb/lib/src/vault/search/charset_util.dart` with licence
      header (year 2026). Keep the implementation free of side effects —
      pure bytes-in, string-out.
      **Implementation note:** In Dart 3.x, `utf8.decode` already strips the
      UTF-8 BOM automatically — no explicit post-decode stripping is needed.
      The original plan's Q1 answer assumed older Dart behaviour. The dead
      branch was removed per CLAUDE.md's no-dead-code policy.
- [x] Do **not** export `CharsetDecodeResult` or `decodeText` from
      `packages/kmdb/lib/kmdb.dart` — internal `src/` symbols only.
- [x] Write `packages/kmdb/test/vault/search/charset_util_test.dart`
      covering all rows in the edge-case table above plus a round-trip test
      for each supported IANA label.
      **Test note:** EUC-KR round-trip tests assert label correctness and
      non-empty output (not exact string equality) because the `charset`
      package's `eucKr` codec covers only the KSX 1001 character set and
      has limited character coverage.
- [x] Run `make coverage` and confirm >90% on `charset_util.dart`.
      `charset_util.dart`: 5/5 lines = **100%**. Package overall: **95.3%**.
- [x] Add a `charset_util` note to `docs/spec/20_text_search.md` (one or
      two sentences; no structural change to the spec).
- [x] Run `make pre_commit` — format, analyze, license_check, tests all
      green. (One pre-existing `info` lint in `local_only_namespace_test.dart`,
      not introduced by this WI.)

## Review (kmdb-plan-reviewer, 2026-06-20)

**Verdict: Questions — close, but not yet mechanically implementable.** The
problem is real and well-scoped, the package choice is sound and verified, but
the *decode* half of the utility (which is the only thing this WI actually
builds) is under-specified at exactly the points where the package's behaviour
is non-obvious. An implementer following the plan literally would ship a
function that fails the plan's own asserted edge cases.

### What's strong
- **Problem statement is correct and worth solving.** Silent mis-decode of
  legacy-encoded plain text corrupting both the BM25 index and embedding input
  is a genuine data-quality bug, and it aligns with proposal §10.1 / roadmap
  WI-2. Splitting the dependency + utility out of WI-3 is good scoping —
  keeps detection concerns out of the larger vault-search change.
- **Package is verified, not assumed.** Confirmed against pub.dev:
  `betto_charset_detector 0.1.0-dev.2` resolves and pulls `charset 2.0.1`; pure
  Dart, no native assets (so the native-asset `dart test` caveat does not apply
  here). Public API is exactly one function, `detectCharset(Uint8List) ->
  String` (lowercase IANA label). The three-stage pipeline, the >15% high-byte
  CJK promotion, the `windows-1252` fallback, and the empty-input → `utf-8`
  behaviour described in the plan all match the source.
- **Dependency wiring matches house style.** The checklist's split (bare dep in
  `packages/kmdb/pubspec.yaml`, version pin in root `dependency_overrides`)
  matches how every other `betto_*` package is wired in this workspace. Good.

### What blocks Investigated (see Open questions Q1–Q5)
The crux: `detectCharset` **only returns a label and never decodes or strips
BOMs.** The entire value of `decodeText` is the detect→decode→(BOM-strip)
dispatch, and that dispatch is the part the plan hand-waves:

1. **BOM stripping is unspecified and the plan's own edge case is wrong as
   written (Q1).** `utf8.decode` does not strip a leading U+FEFF, so the
   asserted "UTF-8 with BOM → BOM stripped" outcome will not happen unless
   `decodeText` does it explicitly. By contrast the `charset` UTF-16/UTF-32
   decoders *do* strip the BOM. So the behaviour differs by family and must be
   pinned down per-family, not asserted uniformly.
2. **The label→decoder table is the core deliverable and isn't written down
   (Q2).** The label set is small, closed, and known — there is no excuse to
   leave the mapping implicit. Spell out the `switch`/map. Watch the
   `iso-8859-1` trap: it is absent from the `charset` name map and only resolves
   via `getByName`'s internal `Encoding.getByName` fallback to `latin1`.
3. **UTF-16/32 endianness comes from the BOM, not the label (Q3)** — a
   non-obvious quirk that, undocumented, will send an implementer down a dead
   end trying to honour the `be`/`le` label.
4. **The `text: null` branch may be unreachable dead code (Q4)**, which
   collides head-on with the 90%+ coverage requirement. Either produce a
   triggering input or drop `String?` to `String`. This must be decided before
   implementation, not discovered during it.
5. **Export visibility is a real choice (Q5)** with public-API-stability
   consequences; "export from the library" is ambiguous about whether that
   means `kmdb.dart` (public) or an internal `src/` symbol.

### Smaller notes
- **Edge-case table row 12 is stale.** "`detectedCharset` out-param is
  populated / Label written to buffer" describes an out-parameter API that this
  plan explicitly rejected in favour of the record return type. Delete the row;
  it would confuse the implementer.
- **Coverage claim needs the Q4 resolution.** "100% in practice" is only true
  if the `null` branch is removed or made reachable. As written, the `String?`
  with an unreachable `null` assignment caps achievable line coverage below
  100% and possibly trips the 90% gate on such a small file.
- **Spec impact note is adequate but soft.** "Add a brief note to
  `20_text_search.md` (or the forthcoming vault search spec section)" is fine
  for a utility this small. Per `docs/plans/README.md`, do not hard-code a spec
  number; since WI-3 will own the vault-search spec section, a one-line forward
  note in `20_text_search.md` here is reasonable. No release-checklist entry is
  needed — this is pure-Dart and fully exercisable in the automated suite.
- **No architectural concerns.** This touches none of the LSM/sync/cache
  invariants; it is a leaf utility with no storage, sync, or platform-branching
  implications. OPFS/web is unaffected (pure Dart, no `dart:io`).

### Path to Investigated
Resolve Q1–Q5 in the plan text (most are quick decisions, not research), fix
the two table/coverage notes, and replace the "Proposed utility API" doc
comment's reference to `extract_status.json` with a forward-reference phrasing.
Once the decode dispatch table, BOM-strip rule, and `null`-reachability are
written down, this is a genuinely small, mechanical implementation and can move
to `Investigated`.

## Summary

- Added `betto_charset_detector ^0.1.0-dev.2` (detection) and `charset ^2.0.1`
  (legacy codec decoding) as direct dependencies of `packages/kmdb`; both
  pinned in root `dependency_overrides`.
- Implemented `decodeText(Uint8List) → CharsetDecodeResult` in
  `packages/kmdb/lib/src/vault/search/charset_util.dart` (new file).
  `CharsetDecodeResult` is `({String charset, String text})` — internal only,
  not exported from `kmdb.dart`. Pure bytes-in, string-out; no side effects.
- Two-branch decode dispatch: `'utf-8'` → `dart:convert`'s `utf8.decode`;
  all other labels → `Charset.getByName(label)!.decode(bytes)`.
- **Q1 finding:** In Dart 3.x, `utf8.decode` already strips the UTF-8 BOM
  automatically. The plan's Q1 answer assumed older Dart behaviour; the
  previously planned explicit post-decode strip guard would have been dead code
  and was not included.
- 39 tests in `packages/kmdb/test/vault/search/charset_util_test.dart`
  covering all plan edge-case table rows, BOM-stripping semantics, dispatch
  paths, `iso-8859-1` → `latin1` fallback, return-type contract, and
  per-IANA-label round-trips. EUC-KR tests assert label and non-empty text
  (not exact equality) due to the `charset` package's limited KSX 1001 coverage.
- 100% line coverage on `charset_util.dart`; 95.3% overall package coverage;
  2047/2047 tests passing; `make pre_commit` green.
- Brief charset detection section added to `docs/spec/20_text_search.md`.
