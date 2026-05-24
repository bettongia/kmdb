# ZStandard Planning

As per docs/spec/05_value_encoding.md, ZStandard will be used for compressing.
See also docs/spec/09_integrity.md

The `zstandard` pub package is a Flutter plugin (platform channels) and cannot
be used in a plain Dart package with `dart test`. `zstandard_native` was
evaluated but requires the caller to load the native `DynamicLibrary` manually
and has no prebuilt binaries — making a `hook/build.dart` necessary.

**Selected approach: `es_compression` v2.0.15**

- No Flutter dependency (pure Dart + `dart:ffi`)
- Synchronous `Codec<List<int>, List<int>>` API — `ValueCodec` stays sync
- Prebuilt binaries bundled for macOS / Linux / Windows — no build hook needed
- Works with `dart test` out of the box
- Dart SDK `>=3.2.0` (KMDB requires `^3.10.8` ✓)

Web stays on Deflate (flag `0x02`). Zstd-on-web (WASM) is deferred.

## Status

✅ Native Zstd implemented (flag `0x01`) — 598/599 tests pass (1 pre-existing
Phase 7 failure unrelated to compression).

⚠️ **Apple Silicon (ARM64 macOS) caveat:** `es_compression` v2.0.15 ships only
an x86_64 macOS blob (`eszstd-mac64.dylib`). On ARM64 machines the blob must be
compiled from source using the package's blob-builder tool:

```bash
# Prerequisites: cmake
cd /path/to/es_compression/tool/blob_builder
cmake -B build && cmake --build build
cp build/bin/eszstd-mac64.dylib \
  ~/.pub-cache/hosted/pub.dev/es_compression-2.0.15/lib/src/zstd/blobs/
```

This is a known upstream gap. An issue/PR should be raised with the
`es_compression` maintainers to ship a universal (arm64 + x86_64) macOS blob.
Until then, ARM64 developers must run the blob-builder once after
`dart pub get`.

The issue has previously been raised at
https://github.com/instantiations/es_compression/issues/49.

---

## Implementation (complete)

### Files changed

- `pubspec.yaml` — replaced `zstandard: ^1.5.0` with `es_compression: ^2.0.15`
- `lib/src/encoding/compression.dart` — conditional export (io/web/stub)
- `lib/src/encoding/compression_io.dart` — Zstd encode+decode via `ZstdCodec`
- `lib/src/encoding/compression_web.dart` — Deflate encode+decode (unchanged
  logic)
- `lib/src/encoding/compression_stub.dart` — no-op fallback (neither io nor web)
- `lib/src/encoding/value_codec.dart` — delegates to `tryCompress`/`decompress`
- `hook/build.dart` — removed (no longer needed; `es_compression` bundles
  binaries)
- `test/encoding/value_codec_test.dart` — Zstd round-trip, cross-flag, threshold
  tests

### Compression behaviour by platform

| Platform                | Encode flag    | Decode handles                           |
| ----------------------- | -------------- | ---------------------------------------- |
| Native (`dart:io`)      | `0x01` Zstd    | `0x00` none, `0x01` Zstd, `0x02` Deflate |
| Web (`dart:js_interop`) | `0x02` Deflate | `0x00` none, `0x02` Deflate              |
| Stub (neither)          | `0x00` none    | `0x00` none only                         |

---

## Web / WASM (deferred)

Deflate remains the correct web fallback per spec. `compression_web.dart` is
unchanged. WASM Zstd is a separate future work item.
