# S-2 consumption: thread KMDB's decoded-value bound into `betto_zstd` decompress

**Status**: Complete

**PR link**: _(none yet)_

> **Provenance.** The KMDB-side companion to **WI-8** of the 0.10.01 hardening
> track. WI-8 added a pre-allocation frame-size cap to `betto_zstd`
> (`decompress(..., {int maxOutputBytes})`, throwing `ZstdLimitExceededException`)
> and shipped in **`betto_zstd 0.1.0-dev.4`** (published 2026-08-24). Without this
> plan, KMDB keeps calling `decompress(data)` with **no** bound and so falls back
> to betto_zstd's **64 MiB default** — a bounded allocation (S-2's unbounded-OOM
> is closed), but 64× KMDB's actual 1 MiB decoded-value contract. This plan
> threads KMDB's own bound so S-2 is closed at the contract, and is what lets the
> roadmap tick **S-2 fully closed**.

## Problem statement

`ValueCodec.decode` decompresses a value and *then* checks its size:

- Plaintext branch: [value_codec.dart:266-267](../../packages/kmdb/lib/src/encoding/value_codec.dart#L266-L267)
- Encrypted branch: [value_codec.dart:246-247](../../packages/kmdb/lib/src/encoding/value_codec.dart#L246-L247)

Both call the platform `decompress(compressionFlag, payload)` wrapper, then
`_checkDecodedSize(cborBytes)` which rejects `cborBytes.length >
kMaxDecodedValueBytes` (**1 MiB**,
[value_codec.dart:123](../../packages/kmdb/lib/src/encoding/value_codec.dart#L123)).
The size check fires **after** the allocation — the exact ordering the S-2 review
flagged as insufficient.

betto_zstd now offers a pre-allocation bound, but KMDB does not use it. The two
call sites pass no `maxOutputBytes`:

- [compression_io.dart:46](../../packages/kmdb/lib/src/encoding/compression_io.dart#L46): `ZstdSimple().decompress(data)`
- [compression_web.dart:52](../../packages/kmdb/lib/src/encoding/compression_web.dart#L52): `ZstdSimple().decompress(data)`

So a peer's tiny frame declaring, say, 60 MiB decompresses into a 60 MiB
allocation (under the 64 MiB default) before `_checkDecodedSize` rejects it —
64× the 1 MiB a KMDB value may legitimately reach. Threading
`maxOutputBytes: kMaxDecodedValueBytes` makes betto_zstd reject the frame
**before** allocating, closing S-2 at KMDB's contract.

## Open questions

- [x] **Map `ZstdLimitExceededException` to `DecodedValueTooLargeException`, or
      let it propagate?** **DECISION (reviewer, 2026-08-24): MAP.**
      `DecodedValueTooLargeException` is caught **nowhere** in the tree (verified
      — `grep` finds it only thrown at `value_codec.dart:281`, defined at `:345`,
      and asserted in two tests; it appears in no `catch`/`on` clause), so
      mapping is **not** required for the per-document skip-and-continue
      guarantee. Two things make MAP the right call anyway:
      1. `ValueCodec.decode`'s doc contract promises `DecodedValueTooLargeException`
         for an over-limit value; letting a `betto_zstd` type escape KMDB's decode
         contract on the zstd path (while the uncompressed path still throws the
         KMDB type) is an inconsistent surface that leaks a dependency's exception.
      2. The **existing** test `value_codec_test.dart:387` compresses a highly
         compressible over-limit value and asserts
         `throwsA(isA<DecodedValueTooLargeException>())`. After this change that
         test's throw moves *from* `_checkDecodedSize` *to* betto_zstd's
         pre-allocation reject. Under MAP it stays green; under *propagate* it
         would throw `ZstdLimitExceededException` and this existing test would
         **fail** (and would have to be rewritten). MAP is the lower-churn,
         contract-preserving choice.

      Implementation: catch `ZstdLimitExceededException` and rethrow
      `DecodedValueTooLargeException(decodedSize: e.declaredSize, limit:
      kMaxDecodedValueBytes)`. Field types line up (`declaredSize`/`limit` are
      plain `int`s, per `zstd_exception.dart:48,51`; `ZstdLimitExceededException`
      extends `ZstdException`, so catch the subtype specifically). Since KMDB
      always passes `maxOutputBytes: kMaxDecodedValueBytes`, `e.limit` already
      equals `kMaxDecodedValueBytes` — using the constant directly is equivalent
      and clearer.

## Investigation

Grounded against HEAD; the betto_zstd API verified against the published
`0.1.0-dev.4` (`maxOutputBytes` param, `ZstdLimitExceededException` with `int`
`declaredSize`/`limit`, `defaultMaxOutputBytes` const — all exported from
`package:betto_zstd/betto_zstd.dart`).

- **The bound to pass is exactly `kMaxDecodedValueBytes`.** The decompressed
  output *is* the `cborBytes` that `_checkDecodedSize` bounds at 1 MiB, so
  passing `maxOutputBytes: kMaxDecodedValueBytes` rejects any frame declaring
  more than the contract ceiling, pre-allocation. A valid frame declares ≤ 1 MiB
  and proceeds unchanged.
- **`_checkDecodedSize` stays — it is not made redundant.** It still guards the
  **uncompressed** path (`CompressionFlag.none`, where `decompress` returns the
  bytes as-is with no betto_zstd involvement) and remains a cheap defence-in-depth
  backstop on the zstd path. Do **not** remove it.
- **One wrapper, three implementations, two call sites.** `decompress` is
  dispatched through the `compression.dart` conditional-export barrel over
  `compression_io.dart` (native), `compression_web.dart` (web), and
  `compression_stub.dart` (unsupported). All three `decompress` signatures gain
  the bound parameter; both `value_codec.decode` branches pass
  `kMaxDecodedValueBytes`. `compression_stub.dart`'s `zstd` arm throws today and
  continues to; only its signature changes.
- **`tryCompress` is untouched.** Only `decompress` is bounded.
- **Exception fields line up.** `ZstdLimitExceededException.declaredSize`/`limit`
  map cleanly onto `DecodedValueTooLargeException.decodedSize`/`limit` if the
  open question resolves to "map".
- **Pin.** `dependency_overrides` currently has
  [`betto_zstd: ^0.1.0-dev.3`](../../pubspec.yaml#L39). Bump to an **explicit
  `0.1.0-dev.4`** (mirroring the `betto_pdfium: 0.1.0-dev.4` precedent) — the new
  `decompress` signature does not exist in dev.3, so the pin must move for this
  code to compile, and an explicit pin is more deterministic than relying on the
  caret to resolve up.
- **Spec.** `docs/spec/05_value_encoding.md` currently documents the S-2
  limitation as "the KMDB cap fires *after* `decompress` returns; the frame-size
  cap belongs upstream in betto_zstd". With this change that upstream cap exists
  **and KMDB now passes its bound to it**, so the value is rejected before
  allocation. Update that section to describe the pre-allocation reject and the
  `kMaxDecodedValueBytes` bound handed to betto_zstd.
- **No format change, no benchmark risk.** This only adds a rejection branch on
  the read path for over-limit frames; the compress path and all valid decodes
  are byte-for-byte unchanged.

## Implementation plan

- [x] **Bump the pin.** `dependency_overrides: betto_zstd: 0.1.0-dev.4` (explicit)
      with a short comment noting the S-2 `maxOutputBytes` API; `dart pub get`.
- [x] **Thread the bound through the wrapper.** Add `int maxOutputBytes` to
      `decompress(CompressionFlag, Uint8List, ...)` in `compression_io.dart`,
      `compression_web.dart`, and `compression_stub.dart`; pass it to
      `ZstdSimple().decompress(data, maxOutputBytes: maxOutputBytes)` on the
      `zstd` arm.
- [x] **Pass `kMaxDecodedValueBytes` at both call sites** in `value_codec.decode`
      (encrypted `:246`, plaintext `:266`). Keep `_checkDecodedSize` after each.
      Implemented via a new private `ValueCodec._decompressBounded` helper
      used by both branches (avoids duplicating the try/catch).
      **Deviation found during implementation:** a *third* direct
      `decompress(...)` call site exists outside `ValueCodec`, at
      `lib/src/versioning/version_entry.dart:182`
      (`VersionEntry.decodeIsDeleteSync`, a synchronous compaction-path
      helper) — the plan's grep/investigation missed it because it isn't
      reached from `value_codec.dart`. It does not compile once the
      `decompress` signature changes, so it now also passes
      `maxOutputBytes: ValueCodec.kMaxDecodedValueBytes`. No exception
      mapping was added there: the call already sits inside a broad
      `try { ... } catch (_) { return false; }` fail-safe (any decode error
      → treat as "not a delete version", never incorrectly pruned), so
      `ZstdLimitExceededException` falls through to the existing catch-all
      with the same fail-safe behaviour it already had for every other decode
      failure on that path.
- [x] **Exception handling** (per the open question). If mapping: wrap the
      `decompress` call (or the wrapper's `zstd` arm) to catch
      `ZstdLimitExceededException` and rethrow
      `DecodedValueTooLargeException(decodedSize: e.declaredSize, limit:
      kMaxDecodedValueBytes)`.
- [x] **Tests** (`packages/kmdb/test/encoding/`): a frame declaring > 1 MiB is
      rejected at `decode` **before** the large allocation — build it the cheap
      way (compress several MiB of a repeating byte, which lands in a few hundred
      bytes, then decode) and assert the resolved exception type + sizes; assert
      it fires on **both** the plaintext and encrypted branches; a normal value
      round-trips unchanged; the uncompressed (`none`) over-limit path still
      throws via `_checkDecodedSize`. Add/extend the sync hostile-input coverage
      if the S-2 corpus (from `plan_0_10_01_sync_trust_boundary`) has a natural
      hook.
      - **Reviewer note — the `none`-path test needs *incompressible* data.** A
        repeating byte compresses to the `zstd` flag and so exercises the
        pre-allocation reject, **not** `_checkDecodedSize`. To keep the
        `_checkDecodedSize` guard covered (its sole remaining job is the `none`
        path), build that value from > 1 MiB of **incompressible** bytes (e.g. a
        seeded PRNG / `Random`) so `tryCompress` returns `CompressionFlag.none`
        and the payload reaches `decode` uncompressed. Confirm the flag byte is
        `none` in the test to avoid it silently drifting onto the zstd path.
      - **Reviewer note — the existing test at `value_codec_test.dart:387` shifts
        meaning.** It currently exercises `_checkDecodedSize` on a *compressed*
        bomb; after this change it exercises the betto_zstd pre-alloc reject
        (mapped to `DecodedValueTooLargeException`). It stays green under the MAP
        decision — no edit required — but the new plaintext/encrypted
        pre-alloc-reject assertions should be added as *additional* tests, not by
        repurposing this one.
      - **Reviewer note — web lane is ready.** `value_codec_test.dart:39` already
        calls `ZstdSimple.init()` in `setUpAll` (no-op on native), so
        `cd packages/kmdb && dart test --platform chrome test/encoding/value_codec_test.dart`
        exercises `compression_web.dart`'s bounded `decompress` with no extra
        wiring.
      - **Implementation note — tests as written.** Added to
        `test/encoding/value_codec_test.dart`: the cheap-frame plaintext-branch
        pre-alloc-reject test (asserts `DecodedValueTooLargeException.limit`
        and `.decodedSize` via `.having(...)`) and the incompressible
        `none`-path test — the latter hand-rolls the wire bytes (same
        technique as the existing "legacy Deflate" test) rather than routing
        through `ValueCodec.encode`, because a `List<int>` of random bytes
        still contains enough CBOR structural repetition (the `0x18` marker
        byte ahead of every value ≥ 24) for Zstd to compress it onto the
        `zstd` path — confirmed by a failing run before the fix. Added to
        `test/encryption/value_codec_encryption_test.dart`: the encrypted-branch
        equivalent, using `AesGcmEncryptionProvider`. All four verified on both
        VM (`dart test`) and Chrome (`dart test --platform chrome`).
        **Deviation:** a third `decompress(...)` call site was found outside
        `ValueCodec` at `version_entry.dart:182`
        (`VersionEntry.decodeIsDeleteSync`) — see the "Thread the bound"
        checklist item above. Added a companion test to
        `test/versioning/version_entry_test.dart` confirming this synchronous
        compaction-path helper still fail-safe returns `false` for an
        over-limit decompression-bomb entry (it has no bespoke exception
        mapping — the existing broad `catch (_) { return false; }` already
        covers `ZstdLimitExceededException` the same as any other decode
        error). The sync-trust-boundary hostile-SSTable test
        (`test/engine/sstable_hostile_parsing_test.dart`, "a
        decompression-bomb value... rejected at ValueCodec.decode, not at
        ingest (S-2)") was re-run and confirmed to stay green under MAP with
        no edit needed, as the reviewer predicted.
- [x] **Spec.** Update `docs/spec/05_value_encoding.md`'s "Decompressed-Size
      Bound (S-2)" section (starts at line 131). The current text says the bound
      "fires *after* `betto_zstd`'s `decompress()` call returns" and that "there
      is no way to inspect a frame's declared size and reject it *before* the
      corresponding allocation, because that internal frame-inspection function
      is not part of the package's public API" (lines 156–163). Rewrite this to
      state that betto_zstd (≥ 0.1.0-dev.4) now exposes a bounded
      `decompress(..., maxOutputBytes:)` that reads the frame's *declared*
      decompressed size and rejects it **before** allocating, and that KMDB
      passes `kMaxDecodedValueBytes` as that bound — so an over-limit frame is
      now rejected pre-allocation on the zstd path. **Reviewer note:** be precise
      — betto_zstd did *not* make its frame-inspection function public; it kept
      `_getFrameContentSize` private and exposed the *bound* via the new
      parameter. Also update the "immediately after `decompress()` returns"
      wording (lines 140–142) to reflect that `_checkDecodedSize` is now a
      defence-in-depth backstop on the zstd path and the primary guard only on
      the uncompressed (`none`) path.
- [x] **Roadmap.** Update `docs/roadmap/0_10_01.md` — three concrete edits:
      (a) the **WI-8 table row** (line 68) `Open` → `Complete` with a link to
      this plan/PR and a note that betto_zstd 0.1.0-dev.4 shipped the cap and
      KMDB now consumes it; (b) the **⚠️ S-2 caveat box** (lines 122–136) —
      resolve it: both the betto_zstd cap *and* KMDB's consumption of it have
      landed, so **mark S-2 fully closed**; (c) the **checklist item** at line
      892 (`WI-8 — betto_zstd frame cap landed, S-2 fully closed`) — tick it.
      **Reviewer note:** the roadmap frames "both halves" as (KMDB post-check +
      betto_zstd cap) and has no separate line item for KMDB *consuming* the cap
      — this plan is that closing action, so nothing in the roadmap needs a new
      WI; WI-8's own status flips to Complete on this merge.

**Final step — QA sign-off and pre-commit:**

- [x] `make coverage` — ≥ baseline. Touches `kmdb` (production + tests); the
      `kmdb`-scoped `make pre_commit` covers it, but run
      `cd packages/kmdb && dart test` and the web tests
      (`dart test --platform chrome` for the encoding suite) so both `decompress`
      implementations are exercised.
      **Result:** overall coverage 95.0% (matches the 95% baseline). VM
      `dart test` (full `kmdb` suite): all pass. Chrome
      `dart test --platform chrome` on `test/encoding/value_codec_test.dart`
      (42/42) and `test/encryption/value_codec_encryption_test.dart` (20/20):
      all pass, exercising `compression_web.dart`'s bounded `decompress`.
      `test/engine/sstable_hostile_parsing_test.dart` and
      `test/versioning/version_entry_test.dart` also verified green.
- [x] Hand off to **`kmdb-qa`** for sign-off. **PASS (2026-08-24)** — the
      coordinator ran `kmdb-qa`; verdict: bound threaded correctly at every
      call site (incl. the unplanned third), MAP implemented exactly as
      decided, `_checkDecodedSize` retained as sole `none`-path guard, new
      branches empirically hit on VM + Chrome, spec correctly notes betto_zstd
      kept its frame-inspection routine private. The third call site
      (`decodeIsDeleteSync`) confirmed genuinely fail-safe (`catch (_) → return
      false` = retain, never mis-prune). No missed call sites; zero blocking
      issues.
- [x] `make pre_commit` — format, analyze, license_check, tests green. Run
      directly via Bash (exit code 0): `format_check` (522 files, 0 changed),
      `analyze` (all 7 packages, no issues), `license_check`
      (`addlicense --check`, clean), `pre_commit_test` (`kmdb` scope, 2653
      tests, all passed).
- [x] Verify licence headers on any new files. No new files were created by
      this plan — only existing files were edited, and each already carries
      the license header (confirmed via the `license_check` pass above).

## Reviewer sign-off (2026-08-24)

Verified against HEAD (Dart 3.13.1) and the published `betto_zstd 0.1.0-dev.4`
tarball. All six review points check out:

1. **Decode flow & call sites — confirmed.** `value_codec.dart` encrypted branch
   `decompress` at `:246` + `_checkDecodedSize` at `:247`; plaintext branch at
   `:266`/`:267`; `_checkDecodedSize` body at `:280` bounding at
   `kMaxDecodedValueBytes` (`:123`). Dispatched via the `compression.dart`
   conditional-export barrel over `compression_io.dart` (`:44–47`),
   `compression_web.dart` (`:50–53`), `compression_stub.dart` (`:30–35`); both
   real call sites pass no bound today (`compression_io.dart:46`,
   `compression_web.dart:52`).
2. **Bound value — confirmed exact.** The decompressed output *is* `cborBytes`;
   no overhead reason for `+N`. betto_zstd rejects `declaredSize > maxOutputBytes`
   (strict `>`, `zstd_native.dart:190` / `zstd_web.dart:299`) and
   `_checkDecodedSize` rejects `length > kMaxDecodedValueBytes` (strict `>`) —
   identical boundary semantics, so a value declaring exactly 1 MiB passes both.
   `_checkDecodedSize` is **not** redundant: `decompress` returns `none`-flagged
   bytes as-is with no betto_zstd involvement, so it remains the sole guard on
   that path.
3. **Open question — resolved to MAP** (see above). "Caught nowhere" independently
   verified via full-tree grep.
4. **Pin — confirmed real & necessary.** dev.3's `ZstdSimple.decompress(List<int>
   data)` has no `maxOutputBytes` (cached at
   `~/.pub-cache/.../betto_zstd-0.1.0-dev.3`), so the new call won't compile
   against it; dev.4 is the current pub.dev latest and its `decompress` carries
   the parameter (`zstd_native.dart:167–170`, `zstd_web.dart:269–272`,
   `zstd_unsupported.dart:47–50`), with `defaultMaxOutputBytes = 64 * 1024 * 1024`
   (`zstd_limits.dart:40`) and `ZstdLimitExceededException(int declaredSize, int
   limit)` (`zstd_exception.dart:41–56`), all exported from the barrel
   (`betto_zstd.dart:33–34`). Explicit `0.1.0-dev.4` pin mirrors the
   `betto_pdfium: 0.1.0-dev.4` precedent (`pubspec.yaml:50`).
5. **Spec + roadmap scope — confirmed**, with the specificity refinements folded
   into the checklist above. The betto_zstd pre-allocation reject is genuine on
   **both** platforms (declared frame size read via `_getFrameContentSize` /
   `zstdGetFrameContentSize32`, checked before `malloc` of the destination
   buffer).
6. **Test adequacy — confirmed**, with three refinements folded into the test
   checklist item: the `none`-path test must use *incompressible* data; the
   existing `value_codec_test.dart:387` test shifts meaning (stays green under
   MAP); the chrome lane is ready because `setUpAll` already inits the WASM
   module.

**Status → Investigated.** No open questions remain; the design is specific
enough for mechanical execution.

## Summary

**Complete — `kmdb-qa` PASS (2026-08-24).** S-2 is now fully closed: the
betto_zstd frame-size cap (WI-8, published in `0.1.0-dev.4`) plus this KMDB
thread mean an over-declared frame is rejected before allocation at KMDB's
1 MiB contract. QA confirmed the bound at every call site (incl. the third),
the MAP, and the fail-safe third-site reasoning; VM + Chrome green.

- Bumped `dependency_overrides: betto_zstd` from `^0.1.0-dev.3` to explicit
  `0.1.0-dev.4` in the workspace `pubspec.yaml`.
- Threaded a `required int maxOutputBytes` parameter through
  `decompress(CompressionFlag, Uint8List, ...)` in all three platform
  dispatch files (`compression_io.dart`, `compression_web.dart`,
  `compression_stub.dart`), passing it to `ZstdSimple().decompress(data,
  maxOutputBytes: maxOutputBytes)` on the `zstd` arm.
- Added `ValueCodec._decompressBounded`, a private helper used by both the
  encrypted and plaintext branches of `decode()`, that calls `decompress`
  with `maxOutputBytes: kMaxDecodedValueBytes` and catches
  `ZstdLimitExceededException`, re-throwing `DecodedValueTooLargeException`
  so the exception surface `decode()` promises stays consistent regardless
  of which guard (betto_zstd's pre-allocation reject, or the existing
  post-decompression `_checkDecodedSize`) rejected the value.
- **Deviation from the plan:** found and fixed a third direct `decompress`
  call site outside `ValueCodec`, at
  `VersionEntry.decodeIsDeleteSync` (`version_entry.dart`) — a synchronous
  compaction-path helper the plan's investigation had not covered. It now
  also passes `maxOutputBytes: ValueCodec.kMaxDecodedValueBytes`; no
  exception mapping was needed there since it already had a broad
  fail-safe `catch (_) { return false; }`.
- Updated the doc comments on `ValueCodec.kMaxDecodedValueBytes`,
  `ValueCodec.decode`, and `_checkDecodedSize` to describe the new
  pre-allocation reject and `_checkDecodedSize`'s narrowed role (sole guard
  on the uncompressed path, defence-in-depth backstop on the zstd path).
- Tests added: cheap-frame pre-allocation-reject tests (plaintext and
  encrypted branches, asserting both the exception type and its
  `decodedSize`/`limit` fields), an incompressible-data test confirming
  `_checkDecodedSize` still guards the uncompressed path, and a companion
  test for `VersionEntry.decodeIsDeleteSync`'s fail-safe behaviour on an
  over-limit entry. All verified on both the Dart VM and
  `--platform chrome`. The pre-existing hostile-SSTable S-2 test and the
  pre-existing compressible-bomb `value_codec_test.dart` test were
  confirmed to stay green under the MAP decision, as predicted.
- Updated `docs/spec/05_value_encoding.md`'s "Decompressed-Size Bound (S-2)"
  section to describe the pre-allocation reject, being precise that
  betto_zstd's frame-inspection routine stayed private — only the
  `maxOutputBytes` bound is public.
- Updated `docs/roadmap/0_10_01.md`: the WI-8 table row, the S-2 caveat box,
  the WI-8 detail section, and the exit checklist all now mark **S-2 fully
  closed**.
- Coverage: 95.0% overall (matches the 95% baseline). `make pre_commit`
  (format_check, analyze, license_check, `kmdb`-scoped tests) passes with
  exit code 0.
- No new files were created; no format/API break beyond the additive
  `maxOutputBytes` parameter on the platform-internal `decompress` function
  (not part of KMDB's public API surface).
