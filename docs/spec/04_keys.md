# Keys & Identifiers

## UUIDv7 Document Keys

Document keys are UUIDv7 values generated at insert time. KMDB enforces the
UUIDv7 format (version 7, variant 2) for all user namespaces at the
[KvStore] boundary. UUIDv7 embeds a millisecond-precision timestamp in the
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
