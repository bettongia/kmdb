# Value Encoding

## Overview

Document values are encoded as CBOR before being passed to the storage engine.
The engine stores and retrieves opaque `Uint8List` — it has no knowledge of
document structure at any point. Encoding and decoding is performed exclusively
at the Query Layer boundary.

## Why CBOR, Not JSON

CBOR (Concise Binary Object Representation, RFC 8949) encodes the same dynamic
map/list/scalar model as JSON but produces bytes directly:

- **~20–30% smaller** than equivalent JSON text before compression
- **Native binary fields** (`Uint8List`) without base64 encoding — important for
  documents containing thumbnails, encrypted blobs, or other binary attachments
- **No schema required** — self-describing, like JSON
- **Direct `Map<String, dynamic>` interop** via the Dart `cbor` package — no
  hand-written serialisation

The `KmdbCodec<T>` interface works with `Map<String, dynamic>` only. The Query
Layer applies CBOR encoding after `codec.encode(value)` and CBOR decoding before
`codec.decode(json)`. The codec never sees raw bytes.

## Encoding Pipeline

```
Dart object (T)
    ↓  codec.encode(value)
Map<String, dynamic>
    ↓  cbor.encode()              // ~20–30% smaller than JSON; native Uint8List support
Uint8List (CBOR bytes)
    ↓  Zstd (native only)        // further 30–50% reduction on typical documents
Uint8List (compressed, if ratio > 1.1×, else original CBOR bytes)
    ↓  1-byte compression flag    // prepended: 0x00 = raw, 0x01 = Zstd
SSTable slot value
```

Web clients always use flag `0x00` (uncompressed). `betto_zstd` ships a WASM
build (self-built Emscripten, frame-compatible with the native path by
construction), but KMDB has **not yet wired the web compression path to it** —
`tryCompress` on web is a no-op that returns `(0x00, data)`, and `decompress`
throws `UnsupportedError` for `0x01`. Wiring the published WASM build into the
web path is tracked in the roadmap (see §Cross-Platform Reads and §Zstd
Dictionary Compression below).

## Compression Flag

Each stored value is prefixed with a 1-byte compression flag:

| Flag   | Algorithm | Platform       | Notes                                                              |
| :----- | :-------- | :------------- | :----------------------------------------------------------------- |
| `0x00` | None      | All            | Used when value is small, already compressed, or written on web.   |
| `0x01` | Zstd      | Native (FFI)   | Level 3. Via `betto_zstd` (compiles libzstd from source via `native_toolchain_c`; published to pub.dev). |

Any other flag byte is rejected with `ArgumentError` — unknown flags indicate
data written by a future version of KMDB or silent corruption.

The 1.1× threshold means compression is only applied when the compressed form
is at least 9% smaller than the original. Values that do not compress well —
already-compressed images, encrypted blobs — are stored raw with flag `0x00`.

## Cross-Platform Reads

Native clients write Zstd (`0x01`); web clients write uncompressed (`0x00`).
Both can read `0x00` values transparently. Web clients receiving an SSTable
written by a native client will encounter `0x01` values; attempting to decode
these throws `UnsupportedError`. Although `betto_zstd` now provides a
frame-compatible WASM decompressor, KMDB's web `decompress` is not yet wired to
it (tracked in the roadmap). For the current release, sync between native and
web clients requires the web client to operate in a native-primary setup where
it only reads documents it wrote itself.

Cross-native reads are fully transparent: any native device can decompress any
other native device's Zstd values because `betto_zstd` produces standard Zstd
frames.

## CBOR Boundary

CBOR encoding occurs **only at the Query Layer**:

- **On write**: `codec.encode(value)` → `cbor.encode()` → compress → prepend
  flag → `KvStore.put(namespace, key, bytes)`
- **On read**: `KvStore.get(namespace, key)` → read flag → decompress →
  `cbor.decode()` → `codec.decode(map)`

The Cache Layer stores decoded `Map<String, dynamic>` objects in the session
cache — it does not re-encode to CBOR for caching. The `$cache` materialised
view namespace stores CBOR-encoded key lists (not full documents).

## Zstd Dictionary Compression (Future)

Without a dictionary, Zstd achieves only 10–30% reduction on individual 1–10KB
CBOR documents. With a trained dictionary, compression improves to 70–90%
reduction. Strategy for a future version:

1. Compress without dictionary initially.
2. After accumulating ~100 documents per namespace, train a dictionary using
   the Zstd dictionary trainer API.
3. Recompress existing values during idle compaction.
4. Store the 64–100KB dictionary alongside namespace metadata in `$meta`.
