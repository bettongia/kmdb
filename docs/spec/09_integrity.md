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

## Durability Ordering (hard invariant)

Checksums detect corruption; they do **not** make data durable. Durability
depends on a strict ordering of `fsync` (file content) and `syncDir` (directory
entries) around every operation that replaces durable state. The engine MUST
uphold this order:

```
1. Write the new file(s)        writeFile + syncFile(newFile)
2. Link the new file(s)         syncDir(dir containing the new file)
3. Record in the Manifest       ManifestWriter.append (appends + fsyncs)
   (when the append creates a NEW manifest file, also syncDir(dbDir))
4. Publish (rotation/fresh)     durable CURRENT swap:
                                writeFile + syncFile(CURRENT.tmp) → rename →
                                syncDir(dbDir)
5. Delete obsolete file(s)      deleteFile(old WAL / compaction inputs / old
                                manifest) — only after steps 1–4
```

Two properties make this correct:

- **`fsync` does not persist a new name.** On Linux a freshly created file whose
  content was `fsync`'d can still vanish after power loss unless its parent
  directory is `syncDir`'d (step 2). `syncDir` is a no-op on macOS/Windows/web,
  but the ordering is written for the strictest platform.
- **Record-before-delete must be durable-before-delete.** Appending a
  `VersionEdit` that references a new file before deleting the data it replaces is
  only safe if the append is *durable* first. `ManifestWriter.append` therefore
  fsyncs the manifest itself, so no call site can delete a WAL or compaction input
  before the manifest entry that supersedes it is on disk.

Violating this order opens a crash window in which the only durable copy of data
is deleted while its durable replacement is not yet recorded — the class of bugs
tracked as review findings **C2** (manifest fsync), **H1** (`syncDir` never
called), and **M3** (`CURRENT` swap not fsynced). The ordering is verified
deterministically in CI by a fault-injecting storage adapter that models
content- and directory-entry durability separately; real-Linux power-loss
verification is tracked as release check **RC-4** (§28).

## Compression

Compression is applied at the value level, not the block level. This preserves
fixed-size block arithmetic and keeps the compression choice self-describing via
a 1-byte flag stored with each value.

The decompressor reads the per-value flag and dispatches to the correct
algorithm. Both native and web devices write Zstd (`0x01`) for compressible
documents. Deflate (`0x02`) was removed as a pre-release clean break and is
rejected by `CompressionFlag.fromByte`.

Compression is provided by `betto_zstd` (published to pub.dev): FFI to
libzstd on native platforms, and a frame-compatible self-built WASM module for
web (wired in via `ZstdSimple.init()` at `KmdbDatabase.open()` time). Frames
produced by the native and web paths are identical by construction (same C
source). Dictionary compression is recommended after accumulating
[sufficient documents per namespace](#zstd-dictionary-compression).

## Bloom Filter Migration Path

The current design uses Bloom filters (10 bits/key, double hashing). At 500K
keys, total filter memory is \~625KB. For future optimisation, Xor filters offer
30% less space and 25% faster lookups, at the cost of immutability (must rebuild
on set changes). Since SSTable filters are inherently immutable (built once at
flush time), Xor filters are a natural fit and should be considered for a future
version.
