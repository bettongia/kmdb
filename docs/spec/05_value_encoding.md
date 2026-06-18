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

### Without encryption (plaintext)

```
Dart object (T)
    ↓  codec.encode(value)
Map<String, dynamic>
    ↓  cbor.encode()              // ~20–30% smaller than JSON; native Uint8List support
Uint8List (CBOR bytes)
    ↓  Zstd (native and web)     // further 30–50% reduction on typical documents
Uint8List (compressed, if compressed length < raw length, else original CBOR bytes)
    ↓  2-byte prefix: [EncryptionFlag 0x00][CompressionFlag]
SSTable slot value
```

### With encryption (AES-256-GCM)

```
Dart object (T)
    ↓  codec.encode(value)
Map<String, dynamic>
    ↓  cbor.encode()
Uint8List (CBOR bytes)
    ↓  Zstd (optional)
[CompressionFlag][CBOR or compressed payload]
    ↓  AES-256-GCM encrypt (12-byte nonce, 16-byte tag)
    ↓  EncryptionFlag prefix: [0x01]
[0x01][nonce 12B][ciphertext][tag 16B]
SSTable slot value
```

When encryption is active, the `CompressionFlag` moves **inside** the
ciphertext, hiding algorithm information from observers without the key.

Both native and web platforms compress values with Zstd. On native, `betto_zstd`
uses FFI bindings compiled from source via `native_toolchain_c`. On web,
`betto_zstd` provides a frame-compatible WASM module (self-built Emscripten) —
KMDB calls `ZstdSimple.init()` at `KmdbDatabase.open()` time to load and
initialise the WASM module before any document read or write.

## Wire Format Prefix Bytes

Every stored value starts with an `EncryptionFlag` byte, followed by content
that depends on whether encryption is active:

| EncryptionFlag | Byte   | Meaning | Format of remaining bytes |
| :------------- | :----- | :------ | :------------------------ |
| `none`         | `0x00` | Plaintext | `[CompressionFlag][CBOR payload]` |
| `aesGcm`       | `0x01` | AES-256-GCM encrypted | `[nonce 12B][ciphertext][tag 16B]` |

Any other `EncryptionFlag` byte is rejected with `ArgumentError`.

## Compression Flag

When `EncryptionFlag == 0x00` (plaintext), the second byte is the
`CompressionFlag`:

| Flag   | Algorithm | Platform       | Notes                                                              |
| :----- | :-------- | :------------- | :----------------------------------------------------------------- |
| `0x00` | None      | All            | Used when value is small or already compressed.                    |
| `0x01` | Zstd      | All            | Level 3. Via `betto_zstd` (native: FFI; web: WASM). Published to pub.dev. |

Any other `CompressionFlag` byte is rejected with `ArgumentError` — unknown
flags indicate data written by a future version of KMDB or silent corruption.

Compression is applied only when the compressed form is strictly smaller than the
raw CBOR bytes (`compressed.length < raw.length`). Values that do not compress
well — already-compressed images, encrypted blobs — are stored raw with flag
`0x00`. The minimum document size for compression is 64 bytes (smaller documents
are always stored as `0x00`).

## Cross-Platform Reads

Both native and web clients write Zstd (`0x01`) for compressible documents, and
`0x00` for small or incompressible values. Any platform can read any flag: `0x00`
is passed through as-is, and `0x01` is decompressed using `betto_zstd` (FFI on
native, WASM on web).

Cross-platform reads are fully transparent: `betto_zstd` produces standard Zstd
frames on native and identical frames on web (same C source, Emscripten-compiled).
A database written by a native client can be read by a web client and vice versa.

## CBOR Boundary

CBOR encoding occurs **only at the Query Layer**:

- **On write (plaintext)**: `codec.encode(value)` → `cbor.encode()` → compress
  → prepend `[0x00][CompressionFlag]` → `KvStore.put(namespace, key, bytes)`
- **On write (encrypted)**: `codec.encode(value)` → `cbor.encode()` →
  compress → `AES-GCM encrypt([CompressionFlag][payload])` → prepend `[0x01]`
  → `KvStore.put(namespace, key, bytes)`
- **On read**: `KvStore.get(namespace, key)` → read `EncryptionFlag` → decrypt
  if `0x01`, else read `CompressionFlag` → decompress → `cbor.decode()` →
  `codec.decode(map)`

See §31 for the full encryption bootstrap sequence and key management details.

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
