# Drop `es_compression` and replace with `kmdb_zstd`

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/9

## Problem statement

The `kmdb` package currently depends on `es_compression` for Zstd compression
on native platforms. This dependency has caused ongoing friction: it ships
prebuilt x86_64-only macOS blobs (requiring a manual ARM64 rebuild step on
Apple Silicon), is a third-party package with its own release cadence, and
introduces a non-trivial setup burden documented in `CONTRIBUTING.md`.

The workspace now contains `kmdb_zstd` — a first-party package that compiles
Zstd from source via `native_toolchain_c` and exposes a minimal
`ZstdSimple.compress` / `ZstdSimple.decompress` API over FFI. This covers
everything `kmdb` needs.

The goal of this plan is to:
1. Replace `es_compression` with `kmdb_zstd` in `packages/kmdb`.
2. Drop Deflate as a write-path compression option (clean break — the project
   is pre-release).
3. Remove the `archive` package dependency from `kmdb` (no longer needed once
   Deflate is gone from both read and write paths).
4. Simplify `CompressionFlag` by removing the `deflate` variant.

## Open questions

_None — the clean-break approach was confirmed by the project owner._

## Investigation

### Current compression wiring

| File | Role |
|---|---|
| `packages/kmdb/lib/src/encoding/compression.dart` | Conditional export dispatcher |
| `packages/kmdb/lib/src/encoding/compression_io.dart` | Native impl — uses `ZstdCodec` from `es_compression` |
| `packages/kmdb/lib/src/encoding/compression_web.dart` | Web impl — uses `ZLibEncoder`/`ZLibDecoder` from `archive` (Deflate) |
| `packages/kmdb/lib/src/encoding/compression_stub.dart` | Stub impl — no-op uncompressed |
| `packages/kmdb/lib/src/encoding/compression_flag.dart` | `CompressionFlag` enum with `none(0x00)`, `zstd(0x01)`, `deflate(0x02)` |

### What `kmdb_zstd` provides

`ZstdSimple` (in `packages/kmdb_zstd/lib/src/zstd_base.dart`) exposes:
- `compress(List<int> data) → Uint8List` — level configurable, defaults to
  `ZSTD_CLEVEL_DEFAULT`
- `decompress(List<int> data) → Uint8List` — reads frame size from header

This is a clean drop-in for `ZstdCodec(level: 3).encode()` / `.decode()`.

The `hook/build.dart` in `kmdb_zstd` compiles `zstd.c` via `native_toolchain_c`,
so no prebuilt blobs are needed.

### Web path decision

Dropping Deflate on web means the web platform stores values **uncompressed**
(`CompressionFlag.none`). The stub behaviour already does this. The web
implementation becomes identical to the stub. The two can be merged or the web
file can simply delegate to `CompressionFlag.none` on compress and a passthrough
on decompress.

### `archive` package

`archive` is currently used in two places:
- `compression_io.dart` — `ZLibDecoder` for reading legacy Deflate values
- `compression_web.dart` — `ZLibEncoder`/`ZLibDecoder` for write+read

Removing Deflate from both paths allows `archive` to be dropped entirely from
`packages/kmdb/pubspec.yaml`.

### `CompressionFlag` cleanup

`deflate(0x02)` can be removed. `fromByte` will throw `ArgumentError` for
`0x02` (unknown byte), which is the right behaviour for a clean break.

### ffigen config gap in `kmdb_zstd` (housekeeping, not a blocker)

The `ffigen` section of `packages/kmdb_zstd/pubspec.yaml` only lists 4
functions, but `zstd_base.dart` uses 6 additional symbols via `@Native`
annotations. This is harmless but should be noted as technical debt.

## Implementation plan

### 1. Update `packages/kmdb/pubspec.yaml`

- [x] Add `kmdb_zstd: any` to `dependencies`
- [x] Remove `es_compression: ^2.0.15` from `dependencies`
- [x] Remove `archive: ^4.0.9` from `dependencies`

### 2. Rewrite `compression_io.dart`

- [x] Remove `import 'package:archive/archive.dart'`
- [x] Remove `import 'package:es_compression/zstd.dart'`
- [x] Add `import 'package:kmdb_zstd/zstd.dart'`
- [x] Replace `ZstdCodec(level: 3).encode(data)` with
  `ZstdSimple(level: 3).compress(data)` in `tryCompress`
- [x] Replace `ZstdCodec().decode(data)` with `ZstdSimple().decompress(data)`
  in `decompress`
- [x] Remove the `CompressionFlag.deflate` arm from `decompress` (no longer
  needed — clean break)
- [x] Update the file-level comment to reflect the new dependency

### 3. Rewrite `compression_web.dart`

- [x] Remove `import 'package:archive/archive.dart'`
- [x] Change `tryCompress` to return `(CompressionFlag.none, data)` always
  (no compression on web — same as stub)
- [x] Change `decompress` to handle only `CompressionFlag.none` and
  `CompressionFlag.zstd` (throw `UnsupportedError` for zstd as before); remove
  the `deflate` arm
- [x] Update the file-level comment

### 4. Simplify `compression_flag.dart`

- [x] Remove the `deflate(0x02)` variant from the `CompressionFlag` enum
- [x] Remove the `0x02` case from `CompressionFlag.fromByte`
- [x] Update doc comments to remove references to Deflate

### 5. Update `compression.dart` doc comment

- [x] Update the library doc comment to remove the Deflate reference
- [x] Update the native platform description to reference `kmdb_zstd`

### 6. Update `CONTRIBUTING.md`

- [x] Remove the section describing the ARM64 `es_compression` blob workaround
- [x] Remove the `es_compression` references

### 7. Run `dart pub get` from workspace root

- [x] Verify the dependency graph resolves correctly with `kmdb_zstd` in place

### 8. Tests

- [x] Run `dart test packages/kmdb` and confirm all tests pass (662 tests pass)
- [x] Check compression-specific tests cover: compress round-trip, no-compress
  passthrough, unknown flag rejection
- [x] Add or update tests if coverage drops below 90%

### 9. Analyse

- [x] Run `dart analyze packages/kmdb` — zero errors/warnings
- [x] Run `dart analyze packages/kmdb_cli` — zero errors/warnings (pre-existing
  infos only, no new issues)

## Summary

- Replaced `es_compression` with the first-party `kmdb_zstd` package in
  `packages/kmdb/pubspec.yaml`; also removed `archive` which was only needed
  for Deflate support.
- Rewrote `compression_io.dart` to use `ZstdSimple.compress` /
  `ZstdSimple.decompress` from `kmdb_zstd` instead of `ZstdCodec` from
  `es_compression`. Dropped the Deflate decode arm (clean break).
- Collapsed `compression_web.dart` to a no-op: `tryCompress` always returns
  `(CompressionFlag.none, data)`; Zstd decode still throws `UnsupportedError`
  as before.
- Removed `CompressionFlag.deflate(0x02)` from the enum and its `fromByte`
  case. Byte `0x02` now throws `ArgumentError`, surfacing legacy data clearly.
- Updated doc comments in `compression.dart` and `compression_flag.dart` to
  remove Deflate references and credit `kmdb_zstd`.
- Removed the `es_compression` ARM64 workaround section from `CONTRIBUTING.md`.
- Updated `value_codec_test.dart`: removed `archive` import, updated
  `CompressionFlag` tests to reflect the two-value enum, replaced the
  cross-flag Deflate round-trip test with a test verifying that flag `0x02`
  now throws `ArgumentError`.
- All 662 `kmdb` tests and 270 `kmdb_cli` tests pass. Zero analyzer
  errors/warnings introduced. License headers verified clean.
