# Write-Ahead Log

## WAL Record Format

| Field        | Size | Description                                                                  |
| :----------- | :--- | :--------------------------------------------------------------------------- |
| Checksum     | 8B   | XXH64 of all subsequent fields. Truncation detected by checksum failure.     |
| Record type  | 1B   | 0x01 \= Put, 0x02 \= Delete, 0x03 \= Flush marker.                           |
| Sequence     | 8B   | HLC-encoded: upper 48 bits \= physical ms, lower 16 bits \= logical counter. |
| NS length    | 1B   | Namespace name byte length (max 255).                                        |
| Namespace    | NB   | UTF-8 namespace name.                                                        |
| Key length   | 2B   | Big-endian uint16.                                                           |
| Key          | KB   | Raw key bytes (UUIDv7, 16 bytes binary).                                     |
| Value length | 4B   | Big-endian uint32. Zero for Delete records.                                  |
| Value        | VB   | Zstd-compressed JSON bytes. Absent for Delete.                               |

XXH64 provides 64-bit output (collision probability \~1 in 10¹⁹) and runs faster
than CRC32 on ARM processors lacking CRC32C hardware acceleration. The
additional 4 bytes per record is negligible overhead for dramatically improved
integrity guarantees.

## Sequence Number Layout (HLC)

Sequence number bit layout (64 bits total):

```
┌───────────────────────────────────┬──────────────────┐
│  Physical time (ms since epoch)   │  Logical counter │
│  Upper 48 bits                    │  Lower 16 bits   │
└───────────────────────────────────┴──────────────────┘
```

Higher sequence = newer write, regardless of device of origin. This is the sole
conflict resolution key for LWW semantics.

The HLC combines wall-clock time with a logical counter, preserving
human-readable timestamps while guaranteeing causal ordering across devices. The
maxOffset clamp (60 seconds) prevents a broken device clock from permanently
corrupting the clock state.
