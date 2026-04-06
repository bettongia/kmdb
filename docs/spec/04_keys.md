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
