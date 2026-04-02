# Move record ID creation to be an internal concern

**Status**: Completed

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

Using the CLI, the user is able to provide their own key in the `put` call. KMDB
relies on the key being a UUIDv7. However, it appears that the user can provide
any value for the key and this can cause issues with the storage structure.

The fix needs to be deeper than the CLI functionality. The kmdb system must
protect against any key that is not a valid UUIDv7.

I'd suggest that the UUIDv7 we use as the record ID be purely an internal
concept. Naturally, the user will be able to `get` the ID but they shouldn't be
able to create or mutate it. In a backup/restore scenario we shouldn't care
about maintaining the ID from the original backup - the new database can just
generate new IDs. However, the choice of a UUIDv7 for an identifier is based on
being time ordered so having the original ID in an export/backup will aid in
ordering a restore.

It is important that the user understands that they should not rely on the UUID
as a long term pointer, especially between database instances.

## Open questions

- [x] Should `KvStore.put()` be changed to generate and return a key (splitting
  the interface into `insert` vs `update`), or should UUIDv7 validation be
  enforced at the `KvStore` boundary while keeping the current signature?
  - **Decision**: Option A (Enforce validation) was chosen for minimal API breakage.
- [x] How should `KmdbCollection.insert()` return the generated key to the
  typed-API caller — as a return value, or by mutating the model via a new codec
  method (e.g., `withKey(T value, String key) → T`)?
  - **Decision**: Added `withKey` to `KmdbCodec` to allow the typed API to return
    an updated model instance with the generated key.
- [x] Should `KmdbCodec.keyOf()` be retained for `replace()`/`update()` lookups
  on existing documents, or redesigned entirely?
  - **Decision**: Retained `keyOf` for updates on existing documents that already
    carry a system-assigned key.
- [x] What is the backup/restore contract? The plan says original UUIDv7s aid
  ordering on restore — should the lower-level `KvStore` keep a back-door for
  trusted internal callers to supply a key?
  - **Decision**: `KvStore.put` remains public and allows supplying a key, but
    enforces UUIDv7 structural validation. This allows `ImportCommand` (and
    restore) to preserve original IDs while ensuring system integrity.

## Investigation

### Current key flow

Keys travel through three distinct layers, with validation only at the bottom:

```
CLI `put` command       → accepts any `id` field from JSON, no validation
KmdbCollection.put()   → calls codec.keyOf(value), no validation
KvStore.put()          → documents requirement, no runtime check
LsmEngine.put()        → KeyCodec.keyToBytes() — FIRST validation
```

### CLI (`packages/kmdb_cli/lib/src/commands/put_command.dart:75-89`)

- Reads `doc['id']` from the user's JSON document (line 76).
- Converts it to string with `'$keyRaw'` — **no UUIDv7 validation whatsoever**.
- Only auto-generates a key when `--autoid` is set AND no `id` field is present
  (lines 80–82).
- Passes the raw user string directly to `ctx.store.put(namespace, key, encoded)`.

A user can therefore write arbitrary 32-hex-char strings (or even shorter/longer
ones) as record IDs, bypassing the UUIDv7 contract entirely.

### Typed API (`packages/kmdb/lib/src/query/kmdb_collection.dart:133-164`)

- `insert()`, `replace()`, and `put()` all call `codec.keyOf(value)` — no
  further validation.
- `KmdbCodec.keyOf()` is user-supplied; the contract (doc comment in
  `kmdb_codec.dart:42-45`) says the key "must be a 32-character lowercase hex
  string (a UUIDv7 binary key encoded as hex)" — **documented, not enforced**.
- The typed API is only as safe as each application's codec implementation.

### `KvStore` interface (`packages/kmdb/lib/src/engine/kvstore/kv_store.dart:38`)

```dart
Future<void> put(String namespace, String key, Uint8List value);
```

Doc comment says `[key] must be a 32-character lowercase hex string (binary
UUIDv7)` — again, documented but not enforced at this boundary.

### `KeyCodec.keyToBytes()` — the actual validation point
(`packages/kmdb/lib/src/engine/util/key_codec.dart:77-89`)

Validates:
- Length is exactly 32 hex chars after stripping hyphens.
- All characters parse as valid hex.

Does **not** validate:
- UUIDv7 version bits (nibble 13 of the hex string must be `7`).
- RFC 4122 variant bits (most-significant bits of octet 8 must be `10`).

So any 32-character hex string — including `00000000000000000000000000000000`
or a random non-time-ordered value — passes storage-layer validation.

### UUIDv7 generation (`packages/kmdb/lib/src/engine/util/key_codec.dart:62-66`)

```dart
static String generate() => _uuid.v7().replaceAll('-', '');
```

`UuidV7KeyGenerator` (lines 206–211) is the public wrapper used by the CLI
`--autoid` path. Both are correct but opt-in, not enforced.

## Implementation plan

The plan is structured from the deepest layer outward.

### Step 1 — Strengthen validation in `KeyCodec.keyToBytes()`

Add proper UUIDv7 structural validation:
- Version nibble: hex character at index 12 (0-based) must be `'7'`.
- Variant bits: the byte at offset 8 must have its top two bits set to `10`
  (i.e., `(byte & 0xC0) == 0x80`).

This is a safe incremental guard even before other changes land.

### Step 2 — Remove the user-key path from the CLI

In `put_command.dart`:
- Delete the `keyRaw = doc['id']` extraction block (lines 76–86).
- Always generate a key via `UuidV7KeyGenerator().next()`.
- Remove the `--autoid` flag (it becomes the only behaviour).
- Set `doc['id'] = key` so the generated ID appears in the returned JSON.
- Update the command's doc comment and `usage` string.

The user sees the assigned ID in the output and can use it for subsequent `get`
calls, but cannot influence what value is assigned.

### Step 3 — Generate keys internally in `KmdbCollection.insert()`

Change `insert(T value) → Future<void>` to
`insert(T value) → Future<String>`:
- Generate the key using the collection's `KeyGenerator`.
- Return the generated key so the caller can attach it to the model.
- Keep `codec.keyOf()` for `put()` and `replace()` — those operate on existing
  documents that already carry a system-assigned key.

The typed API therefore distinguishes:
- **First write**: `insert()` — key generated by the system, returned to caller.
- **Subsequent writes**: `put()` / `replace()` — key read from the model via
  `codec.keyOf()`.

### Step 4 — Decide `KvStore` interface changes (after resolving open question)

Option A — Validation only (minimal change):
- Add UUIDv7 structural validation at the `KvStore` boundary (before calling
  `LsmEngine.put()`). Reject any key that doesn't pass.
- Keeps the same signature; makes the enforcement contractual.

Option B — Split insert/update:
- Add `Future<String> insert(String namespace, Uint8List value)` that generates
  a key internally.
- Rename existing `put` to `update` (or keep `put` for internal/restore use).
- `WriteBatch` gains a corresponding `insert` entry type.

Option A is lower risk for this iteration.

### Step 5 — Tests

- `key_codec_test.dart`: add tests that assert version and variant bit
  validation rejects non-UUIDv7 hex strings.
- CLI command tests: remove `--autoid` test cases; add a test confirming that a
  document without an `id` field now auto-generates one (not an error).
- `KmdbCollection` tests: add tests asserting `insert()` returns a valid
  UUIDv7-format key.

### Step 6 — Documentation

- Update `docs/spec/04_keys.md` to explain that the UUIDv7 is a system-assigned
  identifier, not a user-supplied field.
- Update `KvStore`, `KmdbCodec`, and `KmdbCollection` doc comments to reflect
  the new contract.

## Summary

- **Enforced UUIDv7 Integrity**: `KeyCodec` now strictly validates the version
  (7) and variant (2) bits of all hex keys.
- **System-Assigned CLI IDs**: The `put` command now always generates a new
  UUIDv7 and ignores any user-provided `id` field. The `--autoid` flag has been
  removed as it is now the default and only behavior.
- **Typed API Internalization**: `KmdbCollection.insert` now handles key
  generation internally using a `KeyGenerator`. `KmdbCodec` gained a `withKey`
  method to allow the collection to return a typed model with the assigned key.
- **Public API Guards**: `KvStoreImpl` now validates all user-provided keys
  before they reach the storage engine, ensuring system-wide structural
  integrity.
- **Comprehensive Verification**: All layers (codec, storage, query, CLI) have
  been verified with new and updated tests, ensuring 100% pass rate.
