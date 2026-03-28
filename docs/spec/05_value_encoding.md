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
    ↓  Zstd (preferred) or Deflate (web fallback)   // further 30–50% reduction on typical documents
Uint8List (compressed, if ratio > 1.1×)
    ↓  1-byte compression flag    // prepended: 0x00 = raw, 0x01 = Zstd, 0x02 = Deflate
SSTable slot value
```

## Compression Flag

Each stored value is prefixed with a 1-byte compression flag:

| Flag   | Algorithm | Platform                    | Notes                                                          |
| :----- | :-------- | :-------------------------- | :------------------------------------------------------------- |
| `0x00` | None      | All                         | Used when value is small or already compressed.                |
| `0x01` | Zstd      | Native (FFI) + Web (WASM)   | Level 1 (fastest). Preferred on all platforms via `zstandard`. |
| `0x02` | Deflate   | Web — WASM unavailable only | Pure Dart via `archive` package. ~10% worse ratio. Fallback.  |

The 1.1× threshold means compression is only applied when the compressed form
is at least 9% smaller than the original. Values that do not compress well —
already-compressed images, encrypted blobs — are stored raw with flag `0x00`.

The flag makes the compression choice self-describing. A database can contain a
mix of values compressed by different algorithms, and cross-platform reads are
transparent: a value written with Zstd on a native device is correctly
decompressed by a web client because the flag identifies the algorithm.

## Cross-Platform Transparency

All platforms prefer Zstd. On native, this is `dart:ffi` to libzstd. On web, this
is the `zstandard` WASM module. Both produce identical output for the same input,
so cross-device reads are transparent:

1. Native client writes a value → Zstd (flag `0x01`) → uploaded to sync folder
2. Web client downloads the SSTable
3. Reads the 1-byte flag: `0x01` (Zstd)
4. Decompresses using the WASM Zstd module (identical algorithm, identical output)
5. Decodes the CBOR bytes → passes `Map<String, dynamic>` to `codec.decode()`

The Deflate fallback (`0x02`) is used only on web browsers where WASM is
unavailable. Native clients reading a `0x02` value use `archive`'s Inflate
decompressor. This path should be rare in practice — all modern browsers support
WASM.

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
