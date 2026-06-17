# Wire betto_zstd WASM to KMDB web compression path

**Status**: Investigated

**PR link**: _pending_

## Problem statement

KMDB's web platform currently stores all values **uncompressed** (`CompressionFlag.none = 0x00`).
`tryCompress` is a no-op stub and `decompress` throws `UnsupportedError` for the Zstd flag
(`0x01`). This means:

1. Web documents are larger than their native counterparts.
2. A web client **cannot read** a database written by a native client — the `0x01` flag causes an
   immediate crash, making cross-platform databases impossible.
3. `docs/roadmap/0_05.md` lists "Web decompression non-deferrable" as the motivation for shipping
   `betto_zstd` with WASM support; that work is done on the `betto_zstd` side but KMDB has not
   consumed it.

`betto_zstd ^0.1.0-dev.3` publishes a frame-compatible WASM module behind the same `ZstdSimple`
API that the native path already uses. The fix is to remove the stub, hoist a one-time async init
into `KmdbDatabase.open()`, and let `compression_web.dart` delegate to `ZstdSimple` exactly as
`compression_io.dart` does.

## Open questions

_None — all design questions are resolved in the Investigation below._

## Investigation

### Compression file layout

The conditional-export shim at
`packages/kmdb/lib/src/encoding/compression.dart` selects between:

- `compression_io.dart` — native, uses `ZstdSimple` from `package:betto_zstd/betto_zstd.dart`
- `compression_web.dart` — web stub to be replaced
- `compression_stub.dart` — no-op fallback (not a target of this work)

The two functions the shim exports — and whose signatures must remain unchanged — are:

```dart
(CompressionFlag, Uint8List) tryCompress(Uint8List data);
Uint8List decompress(CompressionFlag flag, Uint8List data);
```

Both are **synchronous**. They are called from `ValueCodec.encode`/`decode`, which are
in turn called from ~30 synchronous call sites across the codebase. Making these async
is not viable.

### betto_zstd WASM API

`package:betto_zstd/betto_zstd.dart` already conditionally exports `zstd_web.dart` when
`dart.library.js_interop` is available — no separate import path is needed. On web:

```dart
class ZstdSimple {
  ZstdSimple({int level = 3});
  static Future<void> init({String wasmUrl = 'assets/packages/betto_zstd/assets/zstd.wasm'});
  Uint8List compress(List<int> data);    // sync; throws StateError if init() not awaited
  Uint8List decompress(List<int> data);  // sync; throws StateError if init() not awaited
}
```

`init()` fetches and instantiates the WASM module. It is **idempotent** — safe to call multiple
times. On **native**, `init()` is a no-op `Future`, so an unconditional `await ZstdSimple.init()`
at `open()` time is safe on all platforms and simpler than a web-only guard.

Frame compatibility with native Zstd is guaranteed by construction (same C source; verified by
`betto_zstd`'s own `test/frame_compat_test.dart`). KMDB does not need to re-prove frame format.

### Async init placement — the critical constraint

`ValueCodec.encode`/`decode` (and therefore `tryCompress`/`decompress`) are synchronous. The
WASM module must be initialised **before the first codec call**. The natural hook is
`KmdbDatabase.open()`, which is already `async` and already awaits `KvStoreImpl.open()`.

Adding `await ZstdSimple.init()` as the **first line** of `open()` satisfies this everywhere
downstream databases are used. It also means the native path gets a harmless extra `await` of a
pre-resolved `Future` (negligible cost).

**The invariant:** _No `ValueCodec.encode` or `decode` call may execute before
`KmdbDatabase.open()` completes._ This must hold for:
- All production paths (satisfied by the existing API design — callers can't get a
  `KmdbCollection` before `open()` returns).
- Tests that call `ValueCodec` directly (several in `value_codec_test.dart`) — these run on
  the VM and don't exercise the web path, so the invariant is trivially satisfied; but the
  test file should be annotated to make this clear.
- CLI tooling (`kmdb_cli`) — CLI commands open a database via `KmdbDatabase.open()` before
  any reads/writes, so the invariant holds.

### WASM asset delivery

The `zstd.wasm` asset is declared in `betto_zstd`'s pubspec `flutter: assets:` and is served at
`assets/packages/betto_zstd/assets/zstd.wasm` in Flutter apps. The downstream consumer
(`kmdb_ui`, separate repo) inherits this automatically.

Pure-Dart web hosts or custom servers must serve the WASM and may need to override the URL. A
`wasmUrl` parameter will be added to `KmdbDatabase.open()` (web-only, ignored on native) and
forwarded to `ZstdSimple.init()`. Default: the standard Flutter asset path.

### Compression threshold discrepancy

The native `tryCompress` uses a strict `<` guard (keep compressed only if `compressed.length < data.length`).
`docs/spec/05_value_encoding.md` describes a "1.1× / 9% smaller" threshold — this is a
pre-existing spec/code divergence, not introduced by this work. This plan will **align the spec
to the code** (strict `<`) and document the rationale: the overhead of a few bytes of Zstd
framing is negligible relative to the minimum compression threshold size
(`_kCompressionThreshold = 64` bytes), so a strict `<` guard is correct and simple.

### Existing tests and coverage

`packages/kmdb/test/encoding/value_codec_test.dart` has:
- A native-only assertion that large docs compress to flag `0x01` (will still pass on native;
  no annotation exists — add a comment confirming web will also pass after this work).
- A `'throws on truncated zstd payload'` test feeding `0x01` + garbage — must now also pass on
  web; error type from `betto_zstd` WASM should be confirmed.

`compression_web.dart` currently carries `// coverage:ignore-file` because the stub is
untestable. **Remove this annotation** — the real implementation must be covered.

VM coverage (`dart test`) does not exercise `dart.library.js_interop` conditional exports.
Coverage for the web path requires `dart test -p chrome`. This is a new CI requirement.

### CI and release checklist

`make pre_commit` runs `dart test` on the VM only. A web compression test lane must be added.

**Approach confirmed from `bettongia/zstd` CI.** `betto_zstd` runs an identical lane (`test-web`
CI job) using `browser-actions/setup-chrome@v2` with `CHROME_EXECUTABLE: chrome` and
`dart test --platform chrome` — no custom WASM URL, no special asset serving setup. Their CI is
green. The `dart test` browser runner serves package files under `assets/packages/X/` matching
the default URL baked into `ZstdSimple.init()`, so the default URL will resolve correctly in
KMDB's Chrome tests too.

The implementation should:
1. Add `packages/kmdb/dart_test.yaml` with Chrome `--no-sandbox` (required in CI Linux
   environments — exactly as `bettongia/zstd` does):
   ```yaml
   override_platforms:
     chrome:
       settings:
         arguments: --no-sandbox
   ```
2. Add a `web_test` target to KMDB's `Makefile`:
   ```makefile
   web_test:
       cd packages/kmdb && dart test --platform chrome test/encoding/value_codec_test.dart
   .PHONY: web_test
   ```
3. Add a `test-web` CI job to `.github/workflows/cicd.yml` mirroring `bettongia/zstd`:
   ```yaml
   test-web:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@v6
       - uses: dart-lang/setup-dart@v1
         with:
           sdk: stable
       - uses: browser-actions/setup-chrome@v2
       - run: make web_test
         env:
           CHROME_EXECUTABLE: chrome
   ```

### Spec sections requiring update on completion

- `docs/spec/05_value_encoding.md` — pipeline overview, compression flag table platform column,
  Cross-Platform Reads section (currently states web stores `0x00` only and throws on `0x01`)
- `docs/spec/08_sstable.md` — any "native only" web compression caveat
- `docs/spec/09_integrity.md` — any "web not wired" note
- `docs/spec/19_platform.md` — web compression matrix row
- `docs/roadmap/0_05.md` — mark "Web decompression non-deferrable" as complete
- `CLAUDE.md` — two spots: Architecture summary and Value-encoding bullet (both say
  "compression (native only — web stores uncompressed)")

## Implementation plan

### 1. Preparation
- [ ] Read `compression_web.dart`, `compression_io.dart`, `compression.dart`, `compression_flag.dart`, and `value_codec.dart` in full to confirm the investigation is current.
- [ ] Read `packages/kmdb/lib/src/query/kmdb_database.dart` around `open()` (line ~260) to identify the exact insertion point for `await ZstdSimple.init()`.
- [ ] Read `packages/kmdb/test/encoding/value_codec_test.dart` in full.

### 2. Core implementation — `compression_web.dart`
- [ ] Remove `// coverage:ignore-file` annotation.
- [ ] Add `import 'package:betto_zstd/betto_zstd.dart' show ZstdSimple;`
- [ ] Implement `tryCompress` mirroring `compression_io.dart` exactly:
  - `ZstdSimple(level: 3).compress(data)`
  - Keep-if-smaller guard: `if (compressed.length < data.length)` → return `(CompressionFlag.zstd, compressed)`, else return `(CompressionFlag.none, data)`
- [ ] Implement `decompress` mirroring `compression_io.dart` exactly:
  - `none` → return `data`
  - `zstd` → `ZstdSimple().decompress(data)`
- [ ] Update the stale `// kmdb_zstd` doc comment in `compression.dart` to `betto_zstd`.

### 3. Async init — `KmdbDatabase.open()`
- [ ] Add optional `String? wasmUrl` parameter to `KmdbDatabase.open()` (nullable; web uses it, native ignores it).
- [ ] At the top of `open()`, add:
  ```dart
  await ZstdSimple.init(wasmUrl: wasmUrl ?? 'assets/packages/betto_zstd/assets/zstd.wasm');
  ```
  (On native this is a no-op; the conditional `wasmUrl` default matches the Flutter asset path.)
- [ ] Verify no call site passes arguments that would conflict (check all `KmdbDatabase.open(` usages across the workspace).

### 4. Spec alignment — compression threshold
- [ ] In `docs/spec/05_value_encoding.md`, replace the "1.1× / 9% smaller" threshold description with the correct "compressed length < raw length" rule.
- [ ] Confirm `compression_io.dart` uses strict `<` (not `<=`) and leave code unchanged if so.

### 5. Tests
- [ ] In `value_codec_test.dart`, add a `test('large doc round-trips correctly on web (zstd flag)', ...)` test that:
  - Creates a large doc (> 64 bytes) and encodes then decodes it.
  - Asserts the first byte of the wire encoding is `CompressionFlag.zstd.byte`.
  - This test should pass on both native and web (no platform guard needed after this work).
- [ ] Confirm the existing `'throws on truncated zstd payload'` test covers the error path correctly — check what `ZstdSimple.decompress` throws for garbage input on web (likely `Exception` or `StateError`; update the test matcher if needed).
- [ ] Add a comment to the native-compression assertion test clarifying that post-this-work both native and web will compress.
- [ ] Run `dart test` (VM) from `packages/kmdb/` to confirm all existing tests still pass.
- [ ] Run `dart test -p chrome test/encoding/value_codec_test.dart` to exercise the web path. Document the command in the CI workflow or release checklist if needed.

### 6. CI integration
_Pattern confirmed from `bettongia/zstd` — copy it directly._
- [ ] Create `packages/kmdb/dart_test.yaml` with `--no-sandbox` Chrome override (see Investigation §CI).
- [ ] Add `web_test` make target to `Makefile` (see Investigation §CI).
- [ ] Add `test-web` CI job to `.github/workflows/cicd.yml` using `browser-actions/setup-chrome@v2` and `CHROME_EXECUTABLE: chrome` (see Investigation §CI).

### 7. Spec and doc updates (post-implementation)
- [ ] Update `docs/spec/05_value_encoding.md` — remove the "web stores uncompressed" / "web not yet wired" caveats; update the Compression Flag table and Cross-Platform Reads section to reflect symmetric Zstd support.
- [ ] Update `docs/spec/08_sstable.md` — remove any "native only" compression caveats.
- [ ] Update `docs/spec/09_integrity.md` — remove the "web not wired" note.
- [ ] Update `docs/spec/19_platform.md` — update the web compression matrix row.
- [ ] Mark the "WASM decompression non-deferrable" item in `docs/roadmap/0_05.md` as fully resolved.
- [ ] Update `CLAUDE.md` — Architecture summary and Value-encoding bullet (both reference "native only — web stores uncompressed").
- [ ] Run `make site` to regenerate HTML docs.

### 8. Pre-commit gate
- [ ] Run `make pre_commit` (format_check, analyze, license_check, scoped tests) — all must pass.

### 9. PR
- [ ] Open a pull request. Update this plan's **PR link** field.
- [ ] Move this plan to `docs/plans/completed/` once the PR is merged.

## Reviewer notes (kmdb-plan-reviewer, 2026-06-17)

**Status decision: Investigated.** Every checklist step is mechanically
executable, and the one genuinely risky item (Chrome CI lane) already has a
defined fallback. All load-bearing factual claims in the investigation were
verified against the code and the resolved `betto_zstd 0.1.0-dev.3` in pub-cache.
Findings below are refinements for the implementer, not blockers.

### Verified correct
- `compression_web.dart` / `compression_io.dart` / `compression.dart` match the
  plan's descriptions exactly (stub, strict `<` guard, conditional export).
- `betto_zstd 0.1.0-dev.3` `ZstdSimple` API is as described: web `init()` is
  idempotent (`if (_exports != null) return;`); native `init({String? wasmUrl})`
  is a genuine no-op `Future`; `compress`/`decompress` are synchronous and throw
  `StateError` before init, `ZstdException` on bad data. Default `wasmUrl` is
  `assets/packages/betto_zstd/assets/zstd.wasm`.
- `KmdbDatabase.open()` is at line 260, is `async`, and awaits
  `KvStoreImpl.open()` at line 287 — the init insertion point is valid.
- Spec/code threshold divergence is real (spec §05 lines 35, 60–61 describe
  1.1×/9%; code uses strict `<`). Roadmap `0_05.md` line 21 carries the "Web
  decompression non-deferrable" item. The CLAUDE.md "native only" statements
  exist. CI workflow is `.github/workflows/cicd.yml` (runs `make cicd` on
  ubuntu-latest); the plan can stop saying "locate the workflow" — it is known.

### Refinement 1 — strengthen the init-ordering rationale (correct, under-explained)
The invariant "no `ValueCodec.encode/decode` before `open()` completes" is
satisfied, but the plan should state *why* `init()` must be the first line and
not merely somewhere in `open()`: `KvStoreImpl.open()` (awaited at line 287) and
the schema/meta loads that follow do **not** route through `ValueCodec`
(`MetaStore` uses raw `cbor`, confirmed). The only compressed-value decode paths
(`KmdbCollection`, `IndexManager` lazy build at `index_manager.dart:414`,
versioning) are reachable only *after* `open()` returns. So placing `init()`
before the `KvStoreImpl.open()` await is sufficient and correct. Record this so a
future change that starts decoding documents during recovery doesn't silently
break the ordering. **Action: add this paragraph to the investigation; no code
impact.**

### Refinement 2 — the truncated-payload test worry is moot
The existing `'throws on truncated zstd payload'` test uses
`throwsA(anything)` (line 256), so the `ZstdException`-vs-`StateError` question
the plan raises in §5/§Existing-tests does not affect it. Web will throw
`ZstdException` for garbage; `anything` already accepts it. **Action: simplify
the checklist item to "confirm the matcher is `throwsA(anything)` — no change
needed"; drop the "update the test matcher if needed" hedge.**

### Refinement 3 — Chrome CI lane: approach confirmed (2026-06-17 update)
_Updated after reviewing `bettongia/zstd` Makefile and CI workflow._

`bettongia/zstd` runs a `test-web` CI job (`browser-actions/setup-chrome@v2`,
`CHROME_EXECUTABLE: chrome`, `dart test --platform chrome`) and its tests call
`ZstdSimple.init()` with **no custom `wasmUrl`**. That CI is green, confirming
that `dart test`'s browser runner does serve `assets/packages/betto_zstd/...`
correctly. The default URL will resolve in KMDB's Chrome tests too (betto_zstd is
a pub dep; its `lib/assets/zstd.wasm` is reachable under that URL scheme).
The spike is no longer needed. **Action: use the exact CI job structure from
`bettongia/zstd` — see §CI in the Investigation.**

### Refinement 4 — the spec threshold change is a decision, flag it for the architect
"Align the spec to the code (strict `<`)" (§Investigation, §4) is a reasonable
call and I agree with the reasoning (Zstd framing overhead is negligible above
the 64-byte floor). But it is a **spec-semantics decision**, and spec wording is
the `kmdb-architect`'s domain, not something to settle inside an
unrelated-feature plan. The mechanical edit is fine for the implementer to make;
just have the architect confirm the 1.1×/9× language isn't load-bearing
elsewhere (e.g. referenced by a benchmark or §05's compression-ratio prose at
lines 15/94 which discuss *typical* ratios, a different claim). **Action: before
editing §05, the implementer should get a one-line confirmation from the
architect; otherwise the change stands.** Not a blocker — the edit is low-risk
and reversible.

### Refinement 5 — minor
- The stale doc comments say `kmdb_zstd` in `compression.dart` (line 19) and
  `compression_io.dart` (line 16). The plan catches `compression.dart` (§2) but
  not the `compression_io.dart` header comment. **Add it to the §2 checklist.**
- `KmdbDatabase.open()` has 18 named params already; adding `wasmUrl` is fine,
  but place it logically (near `config`/platform params, not at the end after
  `versionConfigs`) and give it a doc comment noting it is web-only and ignored
  on native.

### Bottom line
Strong, well-investigated plan with accurate grounding. Proceed to
implementation. Treat Refinement 3 (Chrome CI spike) as the first real action
and Refinement 4 (architect sign-off on the §05 threshold wording) as a quick
checkpoint. Neither rises to an open question that should hold the plan in
`Questions`.

## Summary

_To be filled in after implementation._
