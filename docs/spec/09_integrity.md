# Integrity & Compression

## Checksum Strategy

| Component           | Algorithm | Rationale                                                                                |
| :------------------ | :-------- | :--------------------------------------------------------------------------------------- |
| WAL record header   | XXH64     | Fast, 64-bit output. Computed on every write. Speed matters at high write rates.         |
| SSTable footer      | XXH64     | Verified once on SSTable open and on sync ingestion.                                     |
| SSTable data blocks | XXH64     | Per-block checksum. Verified on read. Detects partial corruption without full-file scan. |
| Sync file transfer  | XXH64     | Verified after download, before ingestion. Catches corrupted transfers.                  |

XXH64 was chosen over CRC32 for three reasons: 64-bit output provides
dramatically better collision resistance (\~10¹⁹ vs \~10⁹), it runs faster on
ARM processors without CRC32C hardware acceleration, and the 4-byte per-record
overhead is negligible at all scales.

## Compression

Compression is applied at the value level, not the block level. This preserves
fixed-size block arithmetic and keeps the compression choice self-describing via
a 1-byte flag stored with each value.

The decompressor reads the per-value flag and dispatches to the correct
algorithm, enabling cross-platform databases where some values were compressed
with Zstd (native) and others with Deflate (web).

The `zstandard` Dart package (v1.5+) provides full cross-platform support: FFI
on native platforms, WASM on web. Dictionary compression is recommended after
accumulating [sufficient documents per namespace](#zstd-dictionary-compression).

## Bloom Filter Migration Path

The current design uses Bloom filters (10 bits/key, double hashing). At 500K
keys, total filter memory is \~625KB. For future optimisation, Xor filters offer
30% less space and 25% faster lookups, at the cost of immutability (must rebuild
on set changes). Since SSTable filters are inherently immutable (built once at
flush time), Xor filters are a natural fit and should be considered for a future
version.
