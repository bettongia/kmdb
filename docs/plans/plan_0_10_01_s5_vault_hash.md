# Replace the hand-rolled vault SHA-256 with `cryptography`'s `DartSha256` (S-5)

**Status**: Implementing

**PR link**: _(none yet)_

> **Provenance.** Finding **S-5** of the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md),
> spun out of **WI-6** ("smaller independents") as its own plan on 2026-08-09
> because the WI-6 grounding showed it outgrew the trivial-bundle framing (it
> touches the vault **content-addressing** surface and carries an open scope
> decision). The trivial WI-6 items (L-1, C-2, C-1) shipped in
> [PR #69](https://github.com/bettongia/kmdb/pull/69).

## Scope decision (maintainer, 2026-08-09)

The review's wording — "replace the hand-rolled **SHA-256/CRC32C** with
`package:crypto`" — is only half-actionable, and its named package is the wrong
one:

- **`package:crypto` has no CRC**, and CRC32C here is a **vault-format checksum**,
  analogous to the XXH64 checksums KMDB already hand-uses throughout SSTables
  (also not from `package:crypto`). The "don't hand-roll crypto" stance applies
  squarely to the SHA-256 (a security-relevant primitive, and the one with the
  web-`int`-semantics risk) but only awkwardly to a CRC.
- **We do not add `package:crypto` at all.** `package:cryptography` (already a
  direct dep at `^2.9.0`, used for AES-GCM value encryption and Argon2id DEK
  derivation) is a strict superset: it also provides SHA-256, including a
  **synchronous, pure-Dart** path — `DartSha256().hashSync(bytes).bytes` from
  `package:cryptography/dart.dart` (verified: `cryptography-2.9.0`
  `lib/src/dart/sha256.dart:51`, `DartHashAlgorithmMixin.hashSync`). `DartSha256`
  is deterministic and web-safe — exactly what a content address needs. Adding
  `package:crypto` would mean two hashing libraries for no gain.

**Decided (maintainer, 2026-08-09; package choice refined same day):**

- **SHA-256 → `package:cryptography`'s `DartSha256().hashSync()`** (not
  `package:crypto`, and deliberately **not** the platform-dispatched `Sha256()`
  factory). Keeps `computeSha256` **synchronous** (no viral async ripple across
  the content-addressing call sites), adds **no** new dependency, and stays on
  the one crypto stack. Gated on golden-vector + content-address-stability tests
  and a web run.

  **Why the explicit pure-Dart constructor, not the platform factory.**
  `package:cryptography`'s value is largely its *platform* crypto — on Flutter
  hosts, `cryptography_flutter` registers native AES-256-GCM / Argon2id via
  `Cryptography.instance`, and the abstract `Sha256()` factory dispatches to a
  platform implementation when one is registered. That path is (a) **async**
  (`hash()` returns a `Future`), and (b) **registration-dependent** (native only
  when `cryptography_flutter` is enabled; plain Dart falls back to pure Dart).
  A **content address must be identical on every platform regardless of
  registration state** — a core-Dart laptop, a Flutter+native phone, and a web
  browser must all produce the same address for the same bytes. `DartSha256`
  bypasses the platform factory, guaranteeing that determinism, and is
  synchronous and performance-neutral versus today's (also pure-Dart)
  hand-rolled code. Routing the address hash through the platform factory would
  trade that guarantee for throughput that only materialises on one host class.

  **Deferred non-goal (recorded so it is not lost):** using the async,
  platform-accelerated `Sha256().hash()` to speed up hashing of large vault
  blobs (up to the 200 MB `maxBlobBytes` cap) on Flutter hosts. That is a
  throughput optimization requiring an async `computeSha256` and careful
  determinism guarantees; it is out of scope for S-5 (whose goal is de-risking
  the hand-rolled primitive) and can be revisited if profiling shows the pure-
  Dart hash is a bottleneck on device.
- **CRC32C → keep, but harden.** Leave the hand-rolled Castagnoli CRC32C in place
  (it is a format checksum, correct, and not a `package:crypto`/`cryptography`
  primitive), but close its verification gap: add known-answer test vectors and a
  web (`dart test -p chrome`) run.

## Problem statement

`packages/kmdb/lib/src/vault/vault_store.dart` hand-rolls FIPS 180-4 SHA-256
(`_dartSha256` / `_sha256Digest` / `_sha256Prepare`, ~L744–840), driving the
public `computeSha256` (L715). That hash **is the vault blob's content address**:

- the `kmdb-vault://sha256/{hex}` URI (`vault_ref.dart`),
- the `$vault:{sha256}` ref-count keys (`vault_ref_count.dart`),
- the `.kvlt` manifest addressing,
- and the post-decrypt integrity check (`vault_store.dart:381`,
  `local_directory_vault_adapter.dart:245` recompute-and-compare).

Three problems:

1. **It contradicts the project's own stance.** `plan_vault_gc_failsafe.md`
   requires reusing primitives rather than re-introducing hand-rolled ones, and
   CLAUDE.md says "prefer existing primitives over re-rolling them … the same
   review had to clean up hand-rolled … parsers." A from-scratch SHA-256 is
   exactly the class of thing that stance targets.
2. **It is unverified on web, where `int` semantics differ.** The code uses
   `>>>`, `<<`, and `_add32` masking that assume 64-bit ints; on the web (JS
   number) those are precisely where a silent divergence would hide — and a
   divergent hash means a *different content address*, i.e. a blob that cannot be
   found. Moving to `cryptography`'s `DartSha256` (web-safe) removes this risk
   for SHA-256.
3. **The doc comments lie.** `vault_store.dart:729–755` claim "Use dart:crypto's
   SHA-256" / "using dart:convert machinery" — inaccurate; the code is a
   from-scratch implementation. Whatever S-5 does, these must be corrected.

## Why now rather than later

**Format-freeze sensitive — must land before WI-9 (the release gate).** The swap
**must not change any existing vault content address**: `cryptography`'s
`DartSha256` is byte-identical to a correct FIPS implementation (proven in the
review — see below), so addresses will not change — but this is an
unrecoverable-if-wrong surface, so it is gated on a content-address-stability
regression test, and it must land before `0.1.0` freezes the on-disk vault
format.

## Open questions

_All resolved during the 2026-08-09 review (see Review section). None require a
maintainer design decision._

- [x] **Which package provides SHA-256 — resolved.** Not `package:crypto` (would
      be a redundant second hashing library). Use `package:cryptography`'s
      `DartSha256().hashSync()` from `package:cryptography/dart.dart` — already a
      direct dep (`^2.9.0`). No new dependency. (See the scope decision above for
      the pure-Dart-vs-platform-factory rationale.)
- [x] **Does `DartSha256().hashSync(bytes).bytes` hex-encode to the identical
      string the current `computeSha256` returns? — YES, verified empirically.**
      A throwaway probe test asserted
      `const DartSha256().hashSync(b).bytes` (lowercase hex) equals
      `VaultStore.computeSha256(b)` across empty, `"abc"`, the NIST 896-bit
      vector, 64 zero bytes, 1 000 000 `"a"` bytes, and 50 random inputs up to
      5 KB — all identical, plus the three NIST KATs. `Hash.bytes` is a plain
      `List<int>` raw digest; there are no prefixes. Addresses will not move.
- [x] **CRC32C web-test seam — resolved: the seam already exists.**
      `VaultStore.computeCrc32cForTest` (`vault_store.dart:722`) is already a
      public static test entry point, and `VaultStore.computeSha256` (`:715`) is
      public. No new `@visibleForTesting` accessor is needed. The real question
      was *how a web test reaches CI* — see the CI-wiring finding in the Review
      section (Phase 3 has been updated accordingly).

## Investigation

### Hand-rolled SHA-256 — to be removed

- `computeSha256(Uint8List) → String` (`vault_store.dart:715`) — **public API,
  keep the signature**; only the body changes.
- `_computeSha256` (`:728`), `_sha256Digest` (`:744`), `_dartSha256` (`:758`),
  `_sha256Prepare` (`:828`), the constants `_kSha256Init` (`:857`) and
  `_kSha256K` (`:870`), **and the two helpers `_rotr32` (`:849`) and `_add32`
  (`:853`)** — **delete**. `_rotr32`/`_add32` are used *only* by `_dartSha256`,
  so leaving them would trip the analyzer's `unused_element` lint (the original
  plan text omitted them).
- **Keep `_hexEncode` (`:968`).** It is still needed to lowercase-hex-encode the
  new `DartSha256` digest and is used only by the SHA path — do not delete it.
- Misleading doc comments at `:729–755` — **rewrite** to state the real
  implementation.

### SHA-256 consumers (addresses must not change)

| Site | Role |
| :--- | :--- |
| `vault_store.dart:216` | compute address on `put` |
| `vault_store.dart:381` | post-decrypt integrity recompute-and-compare (S-4) |
| `vault_store.dart:715` | public `computeSha256` |
| `local_directory_vault_adapter.dart:245` | hydrate-time recompute-and-compare |

### CRC32C — kept, hardened (not replaced)

CRC32C is **computed in exactly one place** — `vault_store.dart` (`_computeCrc32c`
L737, `_crc32c` L959, `_kCrc32cTable` / `_buildCrc32cTable` L938–955, poly
`0x82F63B78`), exposed for tests via `computeCrc32cForTest` (L722). It is
genuinely independent of the SHA-256 code: its own table and reflected poly,
inline `>>>` masking, no shared helpers with `_dartSha256`. The other three
files the original plan listed only *reference the field*, they do not compute
it — `vault_manifest.dart` stores/validates the `crc32c` string, an incoming
`vault_indexing_isolate.dart` uses a literal `'00000000'` placeholder, and
`local_directory_vault_adapter.dart` merely mentions CRC32C in a doc comment.
So the swap cannot perturb CRC32C anywhere. Add known-answer vectors + a web
run; do **not** alter the algorithm or output.

## Implementation plan

### Phase 1 — Swap SHA-256 to `DartSha256().hashSync()`

- [x] Import `package:cryptography/dart.dart` in `vault_store.dart`. **No**
      `pubspec.yaml` change — `package:cryptography` is already a dependency.
- [x] Rewrite `_computeSha256` (or `computeSha256` directly) to
      `const DartSha256().hashSync(bytes).bytes` → lowercase hex, byte-identical
      to today's output. Keep the synchronous `String` signature.
- [x] Delete the hand-rolled `_dartSha256` / `_sha256Digest` / `_sha256Prepare`
      and any now-unused SHA-256 constants/tables (no dead code — CLAUDE.md).
- [x] Rewrite the inaccurate `:729–755` doc comments to describe the real
      (`DartSha256`, pure-Dart, deterministic) implementation and *why* the
      platform factory is deliberately not used (content-address determinism).

### Phase 2 — Harden CRC32C (keep as-is, close the verification gap)

- [x] Leave the CRC32C algorithm and output **unchanged**.
- [x] **No new seam needed** — `VaultStore.computeCrc32cForTest` (`:722`) already
      exposes CRC32C to tests. Just use it.
- [x] Fix any parallel misleading CRC32C doc comments (light — the CRC32C doc
      comments are accurate today; the misleading ones are the SHA-256 comments
      handled in Phase 1). Confirmed: none needed changing.

### Phase 3 — Tests

Split the tests into **two files**:

**A. Pure-function KATs — dual-platform (vm + chrome).** New test file, **no
`@TestOn` annotation** (so it runs on vm in the normal suite) — mirror
`test/encoding/value_codec_test.dart`, which is the repo's established
"runs on vm, additionally driven on chrome" pattern.

- [x] **NIST SHA-256 known-answer vectors** (empty string → `e3b0c442…b7852b855`,
      `"abc"` → `ba7816bf…f20015ad`, the 896-bit NIST vector, and `"a"`×10⁶ →
      `cdc76e5c…c7112cd0`) against `computeSha256`. These NIST values **are** the
      pre-swap values by definition (the hand-rolled code was verified to match
      them during this review), so they double as the content-address-stability
      regression — no separate "capture from `main`" step is required for
      standard inputs. `test/vault/vault_hash_kat_test.dart`.
- [x] **Content-address stability** — additionally pin a handful of *fixed
      arbitrary* byte inputs → their expected sha256 hex, so a future regression
      on non-NIST inputs is caught too. Capture these once from the NIST-verified
      new implementation (they are equivalent to the old output — proven this
      review). Values independently captured via `shasum -a 256`, not from
      `VaultStore` itself.
- [x] **CRC32C known-answer vectors** — the standard Castagnoli check value
      (`"123456789"` → `e3069283`, verified this review) plus a couple of fixed
      inputs, via `computeCrc32cForTest`. CRC32C fixed-input values independently
      captured via a stand-alone Python Castagnoli table implementation.

**B. Vault round-trip — native only.** Separate file (the sahpool/web adapter
throws `UnsupportedError` for `listFilesRecursive`, so a round-trip cannot run
on chrome).

- [x] **Vault round-trip** — `put` a blob then `getBytes`, asserting the address
      and the S-4 recompute-and-compare still hold (native).
      `test/vault/vault_hash_round_trip_test.dart` — 4 tests: identical-bytes
      round trip, address equals `computeSha256`, S-4 tamper detection via
      `getBytes` throwing `VaultContentMismatchException`, and dedup-on-repeat.

**Wire the web run into CI — this is a real gap, not optional.** CI's web lane is
`make cicd_web` (`make_cicd.mk:135`), which runs an **explicit hardcoded file
list** — currently just `dart test --platform chrome
test/encoding/value_codec_test.dart`. It does **not** auto-discover
`@TestOn('browser')` files (the sahpool web test, for instance, never runs in
CI). A new web test therefore runs on chrome **only if a human types the
command**, which defeats S-5's continuous web-`int`-semantics guard.

- [x] Add the file-A path to the `cicd_web` recipe in `make_cicd.mk` (an extra
      `cd packages/kmdb && dart test --platform chrome test/<new-file>.dart`
      line), so the SHA-256/CRC32C web run executes on every CI push. Editing
      `make_cicd.mk` is in scope for this plan.
      **Deviation from the plan's literal wording:** the added line uses
      `--compiler dart2wasm`, not the plain `--platform chrome` the plan
      sketched. `vault_hash_kat_test.dart` imports `vault_store.dart`, which
      transitively imports `xxhash.dart` — whose 64-bit prime constants are
      int literals dart2js's front end rejects outright ("can't be
      represented exactly in JavaScript", >2^53). `xxhash.dart` already
      documents "dart2js is not supported by KMDB" for exactly this reason;
      `value_codec_test.dart` never happened to reach that import path, so
      the gap was latent until this plan's web wiring surfaced it. Verified
      green under `--compiler dart2wasm` locally with a real Chrome install
      (`CHROME_EXECUTABLE` pointed at Chrome.app) — 12/12 tests pass.

### Phase 4 — Spec

- [x] Check §24 (vault) and §09 (integrity) for any claim about the hash
      implementation; correct to name `cryptography`'s `DartSha256` for SHA-256
      and note CRC32C remains the hand-rolled vault-format checksum. Likely
      light-touch. **Confirmed light-touch — no changes needed.** Neither
      spec file names an implementation library (no "dart:crypto" / hand-
      rolled claim to correct); both only describe the algorithm (SHA-256,
      CRC32C) and format, which remain true.

**Final step — QA sign-off and pre-commit:**

- [x] `make coverage` — >95% on changed files; ≥90% overall. Overall 94.8%
      (11347/11974 lines); `kmdb` package alone 95.0% (7324/7707); the
      modified region of `vault_store.dart` (the SHA-256 swap, lines 706–757)
      is fully covered — every uncovered line in the file is pre-existing
      (exception `toString()` overrides, an unrelated `explicitMediaType`
      validation branch) and untouched by this plan.
- [x] `kmdb-qa` sign-off (2026-08-09) — **PASS**, no blocking items. QA
      independently recomputed all six SHA-256 and four CRC32C pins (match) —
      the content-address-stability table is a genuine regression guard, not a
      tautology. Confirmed the **dart2wasm** web-run choice is *correct*, not a
      narrowing: dart2js is a project-level non-target (`xxhash.dart:30-33`), so
      `--platform chrome` was never achievable; the web-int-semantics risk is
      closed at the source by deleting the hand-rolled arithmetic. Dead-code
      removal complete; analyzer clean; §24/§09 name no hash impl library (Phase 4
      no-op confirmed). One cosmetic header nit (fixed: `round_trip_test` header
      normalised to the template `https://`/`The Authors.`).
- [x] `make pre_commit` green; the vault changes are in `kmdb`, so the scoped
      test step covers them — but run `cd packages/kmdb && dart test` for the
      vault suites too if iterating. Full `dart test` in `packages/kmdb` also
      run standalone: 2505 passed, 12 skipped (E2E), 0 failed.
- [x] Licence headers (2026) on any new test files.

## Review (2026-08-09, kmdb-plan-reviewer)

**Verdict: Investigated.** The design is sound, correctly scoped, and now
specific enough for a mechanical implementation. Every load-bearing claim was
verified against the code and against `cryptography-2.9.0`, not taken on trust.

**Verified empirically (the crux — content addresses do not move):**

- `package:cryptography/dart.dart` exports `DartSha256` (`@literal const`);
  `hashSync(List<int>)` returns a `Hash` whose `.bytes` is a raw `List<int>`
  digest (`hash.dart:25`). The exact idiom `.hashSync(x).bytes as Uint8List`
  already appears inside cryptography's own `argon2.dart:600`.
- A throwaway probe test asserted `const DartSha256().hashSync(b).bytes`
  (lowercase-hex) `== VaultStore.computeSha256(b)` across empty / `"abc"` / the
  NIST 896-bit vector / 64 zero bytes / `"a"`×10⁶ / 50 random inputs up to 5 KB
  — **all identical**, plus the three NIST KATs and the CRC32C `e3069283` check
  value. This resolves the "does the hex match?" open question definitively and
  is stronger than a capture-from-`main` step for standard inputs.
- The hand-rolled `_sha256Prepare` stores a full 64-bit big-endian length
  (`bitLen >> 32` high word), so it is correct for all blob sizes up to the
  200 MB `maxBlobBytes` cap — there is no large-blob divergence to worry about.

**Refinements folded into the plan (none require a maintainer decision):**

1. **Removal surface widened.** `_rotr32` and `_add32` are used only by
   `_dartSha256` and become dead — the original list omitted them (analyzer
   `unused_element`). Conversely `_hexEncode` must be **kept** for the new
   digest. Both now called out in the Investigation section.
2. **CRC32C footprint corrected.** CRC32C is computed in *one* place
   (`vault_store.dart`); the other three files only reference the string field.
   The "add a `@visibleForTesting` seam" step was a no-op — `computeCrc32cForTest`
   already exists — and Phase 2 now says so.
3. **Web-test CI wiring — the one substantive gap.** `make cicd_web` runs an
   explicit hardcoded file list and does **not** auto-discover
   `@TestOn('browser')` tests, so a naive web test would never run in CI. Phase 3
   now (a) splits pure-function KATs (dual-platform, no `@TestOn`, mirroring
   `value_codec_test.dart`) from the native-only round-trip (the web adapter
   throws `UnsupportedError` for `listFilesRecursive`), and (b) requires adding
   the new file to the `cicd_web` recipe in `make_cicd.mk`.

**Format-freeze concern discharged.** Every hash consumer derives from the hex
*string* — `vault_ref` URI parsing, the `$vault:{sha256}` namespace in
`vault_ref_count`, `hashDir` sharding, and `vault_package`'s
`kmdb-vault://sha256/` matching. Nothing consumes the raw 32-byte digest, and the
string is proven byte-identical, so no address, ref-count key, or `.kvlt`
reference moves.

## Summary

**Implementation complete; awaiting kmdb-qa sign-off, kmdb-pre-commit gate re-run
by the coordinating session, and PR.** (This agent has no Agent tool this
session, so those steps are handed back to the main session per the STOP
instruction.)

- Swapped `VaultStore`'s hand-rolled FIPS 180-4 SHA-256 (`_dartSha256` /
  `_sha256Digest` / `_sha256Prepare`, plus `_rotr32` / `_add32` and the
  `_kSha256Init` / `_kSha256K` constant tables — all deleted) for
  `package:cryptography`'s pure-Dart, synchronous `DartSha256().hashSync()`
  (`package:cryptography/dart.dart`, already a direct dependency — no
  `pubspec.yaml` change). `computeSha256`'s public signature is unchanged
  (`static String computeSha256(Uint8List bytes)`); `_hexEncode` is kept and
  now hex-encodes the new digest.
- CRC32C is untouched — same table, same reflected Castagnoli polynomial,
  same output. Its doc comments were already accurate, so Phase 2 required no
  edits beyond confirming that.
- Rewrote the previously-inaccurate SHA-256 doc comments (`vault_store.dart`
  ~708–745) to describe the real `DartSha256` implementation and explain why
  the concrete pure-Dart constructor is used instead of the platform-
  dispatching `Sha256()` factory: a vault content address must be
  byte-identical regardless of `cryptography_flutter` registration state, and
  the factory's `hash()` is `async`.
- Added `test/vault/vault_hash_kat_test.dart` (no `@TestOn`, runs on VM and
  Chrome): NIST SHA-256 KATs (empty, `"abc"`, the 896-bit two-block vector,
  `"a"`×10⁶), a content-address-stability table of fixed non-NIST byte inputs
  (including all 256 byte values and 64 zero bytes), and CRC32C KATs
  (Castagnoli check value `"123456789"` → `e3069283`, plus fixed inputs). All
  expected values were captured with tools outside this codebase (`shasum -a
  256`; a stand-alone Python Castagnoli-table CRC32C implementation), not
  from `VaultStore` itself, so they are genuine ground-truth pins.
- Added `test/vault/vault_hash_round_trip_test.dart` (native-only, not wired
  into `cicd_web`): `ingest`/`getBytes` round-trip, address-equals-
  `computeSha256`, an S-4 tamper-detection test (post-ingest blob
  substitution → `getBytes` throws `VaultContentMismatchException`, proving
  the swap is wired into the production read path, not just correct as a
  pure function), and ingest-dedup-on-identical-bytes.
- Wired the KAT file into CI's `cicd_web` recipe in `make_cicd.mk` — but with
  `--compiler dart2wasm`, not the plain `--platform chrome` the plan
  sketched. `vault_hash_kat_test.dart` imports `vault_store.dart`, which
  transitively imports `xxhash.dart`; that file's 64-bit prime constants are
  int literals dart2js's front end rejects outright (exceed JS's 2^53-safe-
  integer range) — a **pre-existing, latent web-compilation gap** documented
  in `xxhash.dart`'s own doc comment ("dart2js is not supported by KMDB")
  but never previously hit because `value_codec_test.dart` (the only prior
  `cicd_web` test) never imported that path. Verified green locally with a
  real Chrome install and `--compiler dart2wasm`: 12/12 tests pass.
- Phase 4 (spec check) required no edits: neither §24 (vault) nor §09
  (integrity) names a hash implementation library, so there was no incorrect
  claim to correct.
- Full `packages/kmdb` test suite: 2505 passed, 12 skipped (E2E, opt-in),
  0 failed. `make coverage`: 94.8% overall, 95.0% for `kmdb` alone; the
  modified SHA-256 region is 100% covered. `make pre_commit` green
  (format_check, analyze, license_check, scoped `kmdb` tests).
