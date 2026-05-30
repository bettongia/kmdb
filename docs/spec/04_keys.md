# Keys & Identifiers

## UUIDv7 Document Keys

Document keys are UUIDv7 values generated at insert time by the system. KMDB enforces the
UUIDv7 format (version 7, variant 2) for all user namespaces at the
[KvStore] boundary. This ensures the structural and performance guarantees of the time-ordered
keys are maintained.

UUIDv7 embeds a millisecond-precision timestamp in the
most significant bits, providing:

- **Index locality:** Sequential inserts land at the SSTable tail, avoiding page
  splits. Measurable performance win at 100K+ documents.

- **Implicit insertion order:** A scan over a namespace returns documents
  roughly in creation order without explicit orderBy.

- **No coordination required:** Each device can generate keys independently
  while maintaining global uniqueness.

- **Timestamp extraction:** The creation timestamp can be read directly from the
  key without storing a separate createdAt field.

Keys are stored as 16-byte binary internally, not 36-character strings. The uuid
Dart package (v4.5+) provides UUIDv7 generation. A KeyGenerator interface allows
injection of deterministic generators for testing.

### Cross-Device Monotonicity

If two devices insert in the same millisecond, their UUIDv7s interleave by
random suffix rather than device. "Insertion order within a device" is the
contract. "Global insertion order across devices" would require a coordination
mechanism. Make orderBy('id') the explicit way to get time-order; do not
guarantee ordering from all() with no orderBy.

## Namespace Encoding

### Wire Format

Namespaces are user-supplied collection names that appear in every internal key,
WAL record, and SSTable scan prefix. The on-disk format stores them as a
length-prefixed byte sequence:

```
[nsLen 1B][ns UTF-8 bytes]
```

Because `nsLen` is a single unsigned byte, the namespace is limited to **255
UTF-8 bytes**. `KvStoreImpl` enforces this limit at the public boundary and
throws a descriptive `ArgumentError` if the limit is exceeded.

### UTF-8 Encoding

Namespace bytes are produced by `utf8.encode` (Dart's `dart:convert`). This
correctly encodes every Unicode scalar value. Earlier builds used
`String.codeUnits` (UTF-16 code units), which silently truncated characters
above U+00FF — corrupting any non-ASCII namespace name. The fix is backward-
compatible for ASCII namespaces: for any pure-ASCII string,
`utf8.encode(s) == s.codeUnits`, so existing databases require no migration.

### NFC Normalisation

Two visually identical namespace strings can differ in Unicode normalisation
form. For example, the French "café" can be represented as:

- **NFC** (precomposed): `U+0063 U+0061 U+0066 U+00E9` — 4 code points, 5
  UTF-8 bytes.
- **NFD** (decomposed): `U+0063 U+0061 U+0066 U+0065 U+0301` — 5 code points,
  6 UTF-8 bytes.

Without normalisation, these would encode to different byte sequences and
resolve to different namespaces, causing a "my collection disappeared" bug.

`KvStoreImpl` applies **Unicode NFC normalisation** to every user-supplied
namespace at the public boundary (before the `$`-prefix guard and before any
storage operation). All downstream encoding sees the canonical NFC form, so
callers supplying the same logical name in different normalisation forms always
access the same namespace.

### Single Shared Helper

All three encoding sites (internal keys in `KeyCodec`, WAL records in
`WalRecord`/`WalBatchFrame`, and scan prefix builders in `LsmEngine`) route
through the `namespaceToBytes`/`bytesToNamespace` helpers in
`lib/src/engine/util/namespace_codec.dart`. This ensures the three paths can
never diverge.

### Length Limit Enforcement

The 255-byte limit is enforced on the **UTF-8 byte length** (not the Dart
`String.length` or code-unit count), because the byte count is what lands on
disk. A namespace just at the limit (255 UTF-8 bytes) is accepted; 256 bytes
throws:

```
ArgumentError: Namespace exceeds 255 UTF-8 bytes (got 256): <name>
```

## Device Identity

Each device installation generates a stable UUID on first launch. This ID is
used in SSTable filenames, .hwm filenames, and as the HLC tiebreaker for
conflict resolution. It must be persisted outside the database:

- iOS/macOS: Keychain (survives app reinstall).

- Android: SharedPreferences with backup rules (or Keystore for higher
  security).

- Web: localStorage (per-origin, survives page reload).

- Desktop: Platform-specific app data directory.

### Reassigning a Device Identity

When a database directory is copied (for example, to create a staging environment or
a test fixture from a production snapshot), the copy shares the same device ID as the
original. This breaks the sync protocol because both databases appear to the sync engine
as the same peer.

The CLI `new-device-id` command resolves this by reassigning a fresh 8-character hex
device ID to the copy:

```bash
kmdb <db> new-device-id
# Output: { "oldDeviceId": "a1b2c3d4", "newDeviceId": "9f8e7d6c" }
```

Internally, `KvStore.reassignDeviceId(newId)`:

1. Flushes the active memtable so all in-memory data is persisted in SSTables.
2. Renames every SSTable whose filename starts with `{oldId}-` to `{newId}-`.
   Peer-owned SSTables (those whose filename prefix belongs to another device)
   are **not** renamed.
3. Appends a single `VersionEdit` to the Manifest recording all renames
   atomically. The old entries are removed and the new entries are added in one
   record.
4. Persists the new device ID to `$meta` so subsequent opens and `storeInfo()`
   return the new value.

**Remote highwater marks:** if the database has already synced under the old ID,
the remote sync folder will have an orphaned `highwater/{oldId}.hwm` file. The
`new-device-id` command warns when configured remotes are detected. The operator
must delete the old `.hwm` file from the remote manually. For the primary use case
(renaming a copy *before* the first sync) there is nothing to clean up.
