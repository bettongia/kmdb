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
    ↓  Zstd (native) or Deflate (web)   // further 30–50% reduction on typical documents
Uint8List (compressed, if ratio > 1.1×)
    ↓  1-byte compression flag    // prepended: 0x00 = raw, 0x01 = Zstd, 0x02 = Deflate
SSTable slot value
```

## Compression Flag

Each stored value is prefixed with a 1-byte compression flag:

| Flag   | Algorithm | Platform       | Notes                                              |
| :----- | :-------- | :------------- | :------------------------------------------------- |
| `0x00` | None      | All            | Used when value is small or already compressed.    |
| `0x01` | Zstd      | Native         | Level 1 (fastest). Via `dart:ffi` to libzstd.      |
| `0x02` | Deflate   | Web / WASM     | Pure Dart via `archive` package. ~10% worse ratio. |

The 1.1× threshold means compression is only applied when the compressed form
is at least 9% smaller than the original. Values that do not compress well —
already-compressed images, encrypted blobs — are stored raw with flag `0x00`.

The flag makes the compression choice self-describing. A database can contain a
mix of values compressed by different algorithms, and cross-platform reads are
transparent: a value written with Zstd on a native device is correctly
decompressed by a web client because the flag identifies the algorithm.

## Cross-Platform Transparency

A value compressed with Zstd on a native device and uploaded to the sync folder
is correctly decompressed by a web client:

1. Web client downloads the SSTable
2. Reads the 1-byte flag: `0x01` (Zstd)
3. Decompresses using the WASM Zstd module
4. Decodes the CBOR bytes
5. Passes the `Map<String, dynamic>` to `codec.decode()`

The web client writes new values with Deflate (`0x02`). A native client reading
those values sees the `0x02` flag and uses libzstd's Deflate decompressor.

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
