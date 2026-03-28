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

SSTable filenames encode origin device, HLC range, and — for consolidation
output — the coordinator epoch. There are two distinct formats, distinguishable
by segment count (splitting on `-`):

### Regular flush output (3 segments)

Produced by a local memtable flush or by downloading a peer's SSTable:

```
{deviceId}-{minHlc}-{maxHlc}.sst
```

### Consolidation output (4 segments)

Produced by the cross-device compaction coordinator. The epoch is the
coordinator's current epoch from the fencing token, enabling stale partial
output to be identified and deleted without opening any file:

```
{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst
```

### Field encoding

| Field      | Encoding                                      | Width    |
| :--------- | :-------------------------------------------- | :------- |
| `deviceId` | Truncated UUID hex (no hyphens)               | 8 chars  |
| `epoch`    | Decimal integer, no padding                   | Variable |
| `minHlc`   | Regular flush: full 64-bit HLC (physical + logical), uppercase hex | 16 chars |
| `maxHlc`   | Regular flush: full 64-bit HLC (physical + logical), uppercase hex | 16 chars |
| `minHlc`   | Consolidation: 48-bit physical component only, uppercase hex | 12 chars |
| `maxHlc`   | Consolidation: 48-bit physical component only, uppercase hex | 12 chars |

Regular flush files embed the full 64-bit HLC (including the 16-bit logical
counter) to guarantee unique filenames even when multiple flushes occur within
the same physical millisecond. Consolidation files use the 48-bit physical
component only, since cross-device ordering relies solely on wall-clock time.

No field contains a `-`, so splitting on `-` and counting segments is
unambiguous.

### Examples

```
a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst      ← regular flush
f9e8d7c6-017F8B0C00000000-017F8B0C3FFF0000.sst      ← regular flush
a3f2b1c9-7-017F8A090000-017F8A0AFFFF.sst            ← consolidation, epoch 7
```

The device ID is a stable per-installation UUID generated on first launch and
persisted in platform-specific secure storage (Keychain on iOS,
SharedPreferences on Android, localStorage on web). It must not be stored inside
the database itself to avoid circular dependency during bootstrap.

### Stale consolidation output detection

A recovering coordinator scans the sync folder for 4-segment files. Any such
file whose epoch does not match the current fencing token for that `deviceId`
is stale output from a crashed coordinator and must be deleted before a new
consolidation begins. See §12 for the full recovery procedure.

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
