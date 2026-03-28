# SSTable Format

SSTables are immutable files containing sorted key-value entries with
prefix-compressed keys, a Bloom/Xor filter block, and a footer for metadata.
Once written, an SSTable is never modified — this immutability is the foundation
of both crash safety and sync safety.

## File Structure

| Block        | Description                                                                                  |
| :----------- | :------------------------------------------------------------------------------------------- |
| Data blocks  | Sorted key-value entries with prefix compression and restart points. Block size: 4KB.        |
| Filter block | Bloom filter (current) or Xor filter (planned migration) for all keys in the file.           |
| Index block  | One entry per data block: (last key, block offset, block size).                              |
| Footer (48B) | Filter block offset/size, index block offset/size, entry count, min/max key, XXH64 checksum. |

## SSTable Naming Convention

Each SSTable filename encodes its origin device and HLC range for sync
identification:

```
{deviceId}-{minHlc}-{maxHlc}.sst
```

Examples:

```
a1b2c3d4-017F8A0B1C00-017F8A0B2FFF.sst
f9e8d7c6-017F8B0C0000-017F8B0C3FFF.sst
```

The device ID is a stable per-installation UUID generated on first launch and
persisted in platform-specific secure storage (Keychain on iOS,
SharedPreferences on Android, localStorage on web). It must not be stored inside
the database itself to avoid circular dependency during bootstrap.

## Value-Level Compression

| Flag | Algorithm | Platform | Notes                                        |
| :--- | :-------- | :------- | :------------------------------------------- |
| 0x00 | None      | All      | When value is small or already compressed.   |
| 0x01 | Zstd      | Native   | Level 1 (fastest). Via dart:ffi to libzstd.  |
| 0x02 | Deflate   | Web      | Fallback for WASM builds. \~10% worse ratio. |

## Recommendations

### Zstd Dictionary Compression

Without a dictionary, Zstd achieves only 10–30% reduction on individual 1–10KB
JSON documents. With a trained dictionary, compression improves to 70–90%
reduction, and decompression runs 2–2.4x faster due to pre-seeded FSE tables.
Strategy: compress without dictionary initially, train a dictionary after
accumulating \~100 documents per namespace, recompress during idle. Store the
64–100KB dictionary alongside namespace metadata.
