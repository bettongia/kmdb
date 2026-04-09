# Drop `es_compression` and replace with `kmdb_zstd`

**Status**: Investigated

**PR link**: _pending_

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

- [ ] Add `kmdb_zstd: any` to `dependencies`
- [ ] Remove `es_compression: ^2.0.15` from `dependencies`
- [ ] Remove `archive: ^4.0.9` from `dependencies`

### 2. Rewrite `compression_io.dart`

- [ ] Remove `import 'package:archive/archive.dart'`
- [ ] Remove `import 'package:es_compression/zstd.dart'`
- [ ] Add `import 'package:kmdb_zstd/zstd.dart'`
- [ ] Replace `ZstdCodec(level: 3).encode(data)` with
  `ZstdSimple(level: 3).compress(data)` in `tryCompress`
- [ ] Replace `ZstdCodec().decode(data)` with `ZstdSimple().decompress(data)`
  in `decompress`
- [ ] Remove the `CompressionFlag.deflate` arm from `decompress` (no longer
  needed — clean break)
- [ ] Update the file-level comment to reflect the new dependency

### 3. Rewrite `compression_web.dart`

- [ ] Remove `import 'package:archive/archive.dart'`
- [ ] Change `tryCompress` to return `(CompressionFlag.none, data)` always
  (no compression on web — same as stub)
- [ ] Change `decompress` to handle only `CompressionFlag.none` and
  `CompressionFlag.zstd` (throw `UnsupportedError` for zstd as before); remove
  the `deflate` arm
- [ ] Update the file-level comment

### 4. Simplify `compression_flag.dart`

- [ ] Remove the `deflate(0x02)` variant from the `CompressionFlag` enum
- [ ] Remove the `0x02` case from `CompressionFlag.fromByte`
- [ ] Update doc comments to remove references to Deflate

### 5. Update `compression.dart` doc comment

- [ ] Update the library doc comment to remove the Deflate reference
- [ ] Update the native platform description to reference `kmdb_zstd`

### 6. Update `CONTRIBUTING.md`

- [ ] Remove the section describing the ARM64 `es_compression` blob workaround
- [ ] Remove the `es_compression` references

### 7. Run `dart pub get` from workspace root

- [ ] Verify the dependency graph resolves correctly with `kmdb_zstd` in place

### 8. Tests

- [ ] Run `dart test packages/kmdb` and confirm all tests pass
- [ ] Check compression-specific tests cover: compress round-trip, no-compress
  passthrough, unknown flag rejection
- [ ] Add or update tests if coverage drops below 90%

### 9. Analyse

- [ ] Run `dart analyze packages/kmdb` — zero errors/warnings
- [ ] Run `dart analyze packages/kmdb_cli` — zero errors/warnings

## Summary

_To be filled in on completion._
