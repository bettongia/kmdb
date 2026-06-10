# betto_zstd: Web/WASM support and multi-platform pipeline

**Status**: Open

**PR link**: —

## Problem statement

`betto_zstd` currently works only on native platforms (macOS, Linux, iOS, Android,
Windows) via Dart FFI and `native_toolchain_c`. The web platform is entirely
unsupported.

For KMDB v0.05 this creates two distinct problems of different severity:

1. **Web decompression is non-deferrable.** Native KMDB clients write
   Zstd-compressed SSTable values (flag byte prefix = `0x01`). A web client
   that cannot decompress those values cannot participate in a sync pool with
   native devices — it will silently fail to decode every document written by a
   native device. WASM decompression must land before any web KMDB client can
   sync with native.

2. **Web write-side compression is a go/no-go gate.** Whether web clients can
   *produce* Zstd-compressed values depends on whether the WASM Zstd frames are
   byte-compatible with what native `betto_zstd` decompresses. This must be
   verified empirically. If the frames are incompatible, web writes remain
   uncompressed (the current behaviour) — which is safe and already supported by
   KMDB's 1-byte flag prefix. If they are compatible, web write compression can
   be enabled.

Secondary concerns:

- The `native_toolchain_c` `CBuilder` handles single-platform compilation at
  build time. Multi-platform CI (Linux cross-compilation, Windows MinGW,
  Android, iOS) needs a GitHub Actions pipeline and verification that the hook
  compiles cleanly on each target.
- `publish_to: none` must be removed for the pub.dev beta release (see KMDB
  roadmap review §3.8). Any remaining pub.dev publishing blockers must be
  resolved.

## Open questions

- [ ] **Q1 — `zstandard` pub.dev package in non-Flutter web context.**
  The [`zstandard`](https://pub.dev/packages/zstandard) package claims WASM
  support on web. Does it work in a pure-Dart web context (i.e. compiled with
  `dart compile wasm` / `webdev`, not Flutter Web)? KMDB's web clients are
  Flutter Web, so Flutter dependency may be acceptable — but it must be
  confirmed.

- [ ] **Q2 — Frame compatibility between `zstandard` WASM output and native
  `betto_zstd` output.** Compress a known byte sequence with native
  `betto_zstd` and decompress with the WASM path (and vice versa). Any mismatch
  blocks write-side compression; decompression-only can still land.

- [ ] **Q3 — `native_toolchain_c` cross-compilation for Android and iOS.**
  The `CBuilder` compiles C source for the *target* platform during a Flutter
  build. Does this work out-of-the-box for `arm64-v8a` Android and iOS arm64
  without manual toolchain configuration? Confirm with a test build.

- [ ] **Q4 — Windows MinGW-w64 cross-compilation path.**
  0_05.md specifies MinGW-w64 in a Podman container for Windows builds.
  Does `native_toolchain_c` support MinGW targets, or does a separate
  `hook/build.dart` branch (or a pre-built `.dll`) need to be used?

## Investigation

### Current state

`betto_zstd` is a Dart native-assets package. The `hook/build.dart` calls
`CBuilder.library` to compile `third_party/zstd/src/zstd.c` into a platform
dynamic library (`libzstd.dylib`, `.so`, or `.dll`). The Dart API is a thin
`@Native` wrapper (`ZstdSimple`) with `compress()` and `decompress()` methods,
using `malloc`/`free` for FFI memory management.

The test suite (`test/compression_test.dart`) exercises round-trips, edge cases
(empty, truncated, invalid), and level bounds.

No `.github/` directory exists; there is no CI pipeline.

`pubspec.yaml` has `publish_to: none` — not yet ready for pub.dev.

### Web/WASM approach

`dart:ffi` is unavailable on web. Two approaches exist:

**Option A — Use the `zstandard` pub.dev package as the web implementation.**
`zstandard` bundles a pre-built WASM Zstd binary invoked via `dart:js_interop`.
If frame-compatible with native `betto_zstd` (Q2), it becomes the web back-end.
`betto_zstd` would expose the same `ZstdSimple` API via platform-conditional
exports: `lib/src/zstd_native.dart` (FFI) and `lib/src/zstd_web.dart` (wrapping
`zstandard`), selected via a `lib/zstd.dart` conditional export.

**Option B — Build Zstd to WASM ourselves via Emscripten.**
Build `third_party/zstd/src/zstd.c` with Emscripten to produce a `.wasm`
module, bundle it as an asset, and call it via `dart:js_interop`. Guarantees
frame compatibility (same source, same flags) but adds build complexity and
Emscripten as a build dependency.

**Recommendation:** Start with Option A. If Q2 reveals frame incompatibility,
fall back to Option B for write-side compression only (decompression of native
frames via `zstandard` WASM is safe regardless — it simply needs to correctly
implement the Zstd frame format, which is standardised).

### Conditional export structure

```
lib/
  zstd.dart                   — conditional export (stub)
  src/
    zstd_native.dart          — @Native FFI impl (unchanged from current zstd_base.dart)
    zstd_web.dart             — dart:js_interop wrapper around zstandard WASM
    zstd_unsupported.dart     — throws UnsupportedError (fallback / test stub)
```

`lib/zstd.dart` selects the right implementation using Dart's `platform`
conditional imports:

```dart
export 'src/zstd_native.dart'
    if (dart.library.js_interop) 'src/zstd_web.dart';
```

The public API (`ZstdSimple`, `minCLevel`, `maxCLevel`) must remain unchanged.
On web, `minCLevel` / `maxCLevel` return the constants from the WASM library;
if `zstandard` does not expose them, expose the known Zstd defaults (−131072,
22) as constants.

### Frame compatibility verification test

A dedicated test file (`test/frame_compat_test.dart`) must run on both native
and web (`dart test --platform chrome`) and verify:

1. A fixed byte sequence compressed by the native FFI path decompresses
   correctly via the WASM path (if WASM decompression is available).
2. A fixed byte sequence compressed by the WASM path decompresses correctly via
   the native FFI path (go/no-go gate for write-side compression).
3. Round-trip on web: compress web → decompress web.

The test must use a fixture produced by the *other* platform (golden-file style)
so that any frame format divergence is detected immediately rather than only at
integration test time. Generate the golden fixture file from the native path
and check it into `test/fixtures/`.

### Multi-platform CI

The `native_toolchain_c` `CBuilder` compiles for the target platform at Flutter
/ Dart build time — no pre-built binaries are required. CI verification is
needed to confirm the hook compiles cleanly on each platform:

| Platform | CI runner | Toolchain |
|---|---|---|
| macOS (universal) | `macos-latest` | Xcode clang; `lipo` for universal binary |
| Linux x86_64 | `ubuntu-latest` | gcc |
| Linux arm64 | `ubuntu-latest` (QEMU) or `ubuntu-24.04-arm` | gcc cross |
| iOS | `macos-latest` | Xcode / iOS SDK |
| Android (arm64-v8a) | `ubuntu-latest` | Android NDK via `native_toolchain_c` |
| Windows x64 | `windows-latest` | MSVC or MinGW-w64 |
| Web (WASM) | `ubuntu-latest` | Chrome via `dart test --platform chrome` |

Each job runs `dart test` for the native path (or the WASM path on the web
job). A combined matrix job fails the pipeline if any platform regresses.

### VERSION_ZSTD pinning

A `VERSION_ZSTD` file at the repo root (e.g. `1.5.7`) is the single source of
truth for which Zstd C source version is vendored in `third_party/`. The
`hook/build.dart` reads this file at build time and asserts that it matches the
version string embedded in the compiled library (`ZSTD_VERSION_STRING`). This
prevents silent drift between the vendored source and the stated version.

Note: `third_party/zstd/src/zstd.c` is already the amalgamation file — the
version is encoded in `zstd.h` as `ZSTD_VERSION_STRING`. The build hook
assertion can be a simple string comparison at hook run time.

### pub.dev publishing

To remove `publish_to: none` and publish to pub.dev:

1. Remove `publish_to: none` from `pubspec.yaml`.
2. Add a `homepage` / `repository` field pointing to the GitHub repo.
3. Ensure all public API has doc comments (currently good).
4. Run `dart pub publish --dry-run` and resolve any warnings.
5. Tag a `v0.1.0` release on GitHub.

No `dependency_overrides` using `git:` refs are present in `betto_zstd`'s own
`pubspec.yaml` — this is clean.

## Implementation plan

### Phase 1 — WASM decompression (required; unblocks KMDB web sync)

- [ ] Add `zstandard` as a dependency in `pubspec.yaml`
- [ ] Create `lib/src/zstd_web.dart`: `ZstdSimple` wrapping `zstandard`'s web
  decompress path (and compress if Q2 passes)
- [ ] Refactor `lib/src/zstd_base.dart` → `lib/src/zstd_native.dart` (rename
  only; no API changes)
- [ ] Update `lib/zstd.dart` to use conditional export
  (`if (dart.library.js_interop) 'src/zstd_web.dart'`)
- [ ] Confirm Q1: run `dart test --platform chrome` against existing tests
- [ ] All existing native tests continue to pass

### Phase 2 — Frame compatibility verification

- [ ] Generate golden fixture: compress a fixed payload with native FFI, write
  to `test/fixtures/native_compressed.zst`
- [ ] Write `test/frame_compat_test.dart` with the three scenarios above
- [ ] Run frame compat test on native and on Chrome
- [ ] **Decision point:** if Q2 passes (WASM frames ≡ native frames), enable
  write-side compression in `zstd_web.dart`. If it fails, disable compress on
  web (throw `UnsupportedError`) and document the limitation.
- [ ] Update README with web support status and limitations

### Phase 3 — VERSION_ZSTD pinning

- [ ] Create `VERSION_ZSTD` file at repo root with current vendored version
- [ ] Add version assertion to `hook/build.dart`: read `VERSION_ZSTD`, compare
  with `ZSTD_VERSION_STRING` from `zstd.h`, throw if mismatch
- [ ] Document version-bump procedure in README

### Phase 4 — GitHub Actions CI pipeline

- [ ] Create `.github/workflows/ci.yml` with matrix covering: macOS, Linux
  x86_64, Web (Chrome)
- [ ] Add Android and iOS jobs (require Flutter SDK in the runner; confirm
  `native_toolchain_c` cross-compiles cleanly — resolves Q3)
- [ ] Investigate and resolve Windows MinGW-w64 path (resolves Q4); add Windows
  job or document limitation
- [ ] Pipeline runs `make pre_commit` (license_check + test) on each platform
- [ ] Tag CI as a required status check on the default branch

### Phase 5 — pub.dev publishing preparation

- [ ] Remove `publish_to: none`
- [ ] Run `dart pub publish --dry-run`; resolve any warnings
- [ ] Confirm no remaining `git:` overrides in `pubspec.yaml`
- [ ] Tag `v0.1.0` once Phase 1–4 are complete and CI is green

## Summary

_To be completed after implementation._
