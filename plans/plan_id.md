# Move record ID creation to be an internal concern

**Status**: Implementing

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
  - **Decision**: Keep the current signature for `KvStore.put()` to support
    backups/restores, but enforce UUIDv7 validation at the boundary for all
    user namespaces.
- [x] How should `KmdbCollection.insert()` return the generated key to the
  typed-API caller — as a return value, or by mutating the model via a new codec
  method (e.g., `withKey(T value, String key) → T`)?
  - **Decision**: Update `KmdbCollection.insert<T>` to return `Future<T>` and
    add a mandatory `withKey(T value, String key)` method to `KmdbCodec`.
- [x] Should `KmdbCodec.keyOf()` be retained for `replace()`/`update()` lookups
  on existing documents, or redesigned entirely?
  - **Decision**: Retain `keyOf` for updates on existing documents that already
    carry an ID.
- [x] What is the backup/restore contract? The plan says original UUIDv7s aid
  ordering on restore — should the lower-level `KvStore` keep a back-door for
  trusted internal callers to supply a key?
  - **Decision**: `KvStore` remains the "back-door" by accepting a key, but it
    will validate that the key is a valid UUIDv7.

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

- [x] Add UUIDv7 structural validation (version 7, variant 2).
- [x] Update `MetaStore` to produce compliant-looking internal keys (ensuring
  XXH64 output has bits 13 and 17 set correctly for validation).
- [x] Update `SequentialKeyGenerator` in `key_codec.dart` to produce compliant
  keys (e.g., `000000000000700080000000000000xx`).

### Step 2 — Remove the user-key path from the CLI

In `put_command.dart`:
- [x] Delete the `keyRaw = doc['id']` extraction block.
- [x] Always generate a key via `UuidV7KeyGenerator().next()`.
- [x] Remove the `--autoid` flag.
- [x] Update `doc['id'] = key` so the assigned ID is returned.

### Step 3 — Refactor `KmdbCollection.insert()` and `KmdbCodec`

- [x] Add `T withKey(T value, String key)` to `KmdbCodec<T>`.
- [x] Update `KmdbCollection.insert(T value)` to:
  - Generate a key.
  - Call `withKey(value, key)`.
  - Persist and return the updated `T`.
- [x] Update all test codecs to implement `withKey`.

### Step 4 — Enforcement in `KvStore`

- [x] Ensure `KvStoreImpl.put()` (and `writeBatch`) validates keys for all
  user namespaces.

### Step 5 — Tests

- [ ] `key_codec_test.dart`: verify structural validation.
- [ ] CLI tests: verify auto-generation and flag removal.
- [ ] `KmdbCollection` tests: verify `insert` returns the model with the key.

### Step 6 — Documentation

- [ ] Update `docs/spec/04_keys.md`.
- [ ] Update API doc comments.

## Summary

{Dot points highlighting the work undertaken}
