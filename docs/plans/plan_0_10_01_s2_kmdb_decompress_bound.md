# S-2 consumption: thread KMDB's decoded-value bound into `betto_zstd` decompress

**Status**: Open

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

- [ ] **Map `ZstdLimitExceededException` to `DecodedValueTooLargeException`, or
      let it propagate?** *Recommended: map.* `DecodedValueTooLargeException` is
      caught **nowhere** in the tree (verified — the only handlers are broad
      `catch (e)` guards in `dump`/`export`/`scan`, which catch either type), so
      mapping is **not** required for the per-document skip-and-continue
      guarantee. But `ValueCodec.decode` is documented to throw
      `DecodedValueTooLargeException` for an over-limit value; letting a
      `betto_zstd` type escape KMDB's decode contract on the zstd path (while the
      uncompressed path still throws `DecodedValueTooLargeException`) is an
      inconsistent surface that leaks a dependency's exception type. Mapping —
      catch `ZstdLimitExceededException`, rethrow
      `DecodedValueTooLargeException(decodedSize: e.declaredSize, limit:
      kMaxDecodedValueBytes)` — keeps one "value too large" type across both
      compression flags and both decode branches, and its doc comment stays
      accurate. **Decision needed:** map (recommended) vs propagate.

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

- [ ] **Bump the pin.** `dependency_overrides: betto_zstd: 0.1.0-dev.4` (explicit)
      with a short comment noting the S-2 `maxOutputBytes` API; `dart pub get`.
- [ ] **Thread the bound through the wrapper.** Add `int maxOutputBytes` to
      `decompress(CompressionFlag, Uint8List, ...)` in `compression_io.dart`,
      `compression_web.dart`, and `compression_stub.dart`; pass it to
      `ZstdSimple().decompress(data, maxOutputBytes: maxOutputBytes)` on the
      `zstd` arm.
- [ ] **Pass `kMaxDecodedValueBytes` at both call sites** in `value_codec.decode`
      (encrypted `:246`, plaintext `:266`). Keep `_checkDecodedSize` after each.
- [ ] **Exception handling** (per the open question). If mapping: wrap the
      `decompress` call (or the wrapper's `zstd` arm) to catch
      `ZstdLimitExceededException` and rethrow
      `DecodedValueTooLargeException(decodedSize: e.declaredSize, limit:
      kMaxDecodedValueBytes)`.
- [ ] **Tests** (`packages/kmdb/test/encoding/`): a frame declaring > 1 MiB is
      rejected at `decode` **before** the large allocation — build it the cheap
      way (compress several MiB of a repeating byte, which lands in a few hundred
      bytes, then decode) and assert the resolved exception type + sizes; assert
      it fires on **both** the plaintext and encrypted branches; a normal value
      round-trips unchanged; the uncompressed (`none`) over-limit path still
      throws via `_checkDecodedSize`. Add/extend the sync hostile-input coverage
      if the S-2 corpus (from `plan_0_10_01_sync_trust_boundary`) has a natural
      hook.
- [ ] **Spec.** Update `docs/spec/05_value_encoding.md`'s S-2 paragraph as above.
- [ ] **Roadmap.** Update `docs/roadmap/0_10_01.md`: WI-8 / the S-2 caveat — both
      halves plus the KMDB consumption thread have landed; **mark S-2 fully
      closed** (the caveat's "mark closed only when both halves have landed" is
      satisfied once this merges).

**Final step — QA sign-off and pre-commit:**

- [ ] `make coverage` — ≥ baseline. Touches `kmdb` (production + tests); the
      `kmdb`-scoped `make pre_commit` covers it, but run
      `cd packages/kmdb && dart test` and the web tests
      (`dart test --platform chrome` for the encoding suite) so both `decompress`
      implementations are exercised.
- [ ] Hand off to **`kmdb-qa`** for sign-off.
- [ ] `make pre_commit` — format, analyze, license_check, tests green.
- [ ] Verify licence headers on any new files.

## Summary

_To be completed when the work is done._
