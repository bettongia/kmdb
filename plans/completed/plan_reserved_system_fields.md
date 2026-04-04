# Reserve `_` field prefix for system use; introduce `_id` as the document key

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/5

## Problem statement

Currently, `KmdbCodec.encode()` is expected to include the document key inside
the serialised map (typically as `"id"`). This creates two problems:

1. **Name collision.** `id` is a common field in application models (e.g. an
   integer ID from a backend API). There is no way for the developer to keep
   their own `id` field separate from KMDB's key.
2. **Redundant storage.** The key is stored twice — once as the LSM storage key
   and again inside the encoded value bytes.

The fix adopts the MongoDB convention: reserve the `_` prefix for system-managed
fields, use `_id` as the authoritative document key field, and have the
framework own it entirely (strip before write, inject before decode). Any
attempt by user code to include a top-level field whose name starts with `_`
is rejected with a clear exception before any write occurs.

## Investigation

### How the key reaches the stored value today

1. `KmdbCollection.insert(value)` generates a UUIDv7 key, calls
   `codec.withKey(value, key)` to stamp it onto the typed model, then calls
   `codec.encode(newValue)` which serialises the whole model including the `id`
   field.
2. `KmdbCollection.put(value)` calls `codec.encode(value)` directly — if the
   application model carries `id`, it ends up in the map.
3. The encoded map is passed to `ValueCodec.encode()` (CBOR + compression) and
   written to the LSM store.

On the read path, `ValueCodec.decode()` restores the map and `codec.decode()`
is called on it as-is. The presence of `id` in the map is relied upon by every
test codec today.

### Files that require changes

**Core library (`packages/kmdb/`)**

| File | Change |
|---|---|
| `lib/src/query/exceptions.dart` | Add `ReservedFieldException` |
| `lib/src/query/kmdb_codec.dart` | Update interface contract: `encode()` must not return `_`-prefixed keys; `decode()` will receive the map with `_id` pre-injected; update doc comments and example |
| `lib/src/query/kmdb_collection.dart` | Validate no `_` keys in `_writeDocument`; inject `_id: key` into decoded map before calling `codec.decode()` in `get()` |
| `lib/src/query/kmdb_query.dart` | Inject `_id: key` before `codec.decode()` in `_execute()`; update `orderBy` doc comment (`'id'` → `'_id'`) |

**Tests (`packages/kmdb/test/`)**

| File | Change |
|---|---|
| `test/query/kmdb_collection_test.dart` | Update `_TaskCodec`: remove `id` from `encode()`, read `_id` in `decode()` |
| `test/query/kmdb_query_test.dart` | Update `_ItemCodec`: remove `id` from `encode()`, read `_id` in `decode()` |
| `test/query/index_test.dart` | Update `_ContactCodec`: remove `id` from `encode()`, read `_id` in `decode()` |
| `test/query/kmdb_collection_test.dart` | Add new tests for `ReservedFieldException` |

**CLI (`packages/kmdb_cli/`)**

| File | Change |
|---|---|
| `lib/src/commands/put_command.dart:78` | `doc['id'] = key` → `doc['_id'] = key` |
| `lib/src/commands/restore_command.dart:94` | `doc['id']` → `doc['_id']` and update error message |
| `lib/src/commands/import_command.dart:98` | `doc['id']` → `doc['_id']` and update error message |
| `test/e2e/cli_session_test.dart` | Update all `['id']` key references to `['_id']` |
| Other CLI test files | Update any `'id'` document field references to `'_id'` |

**Spec docs**

| File | Change |
|---|---|
| `docs/spec/13_query_api.md` | Update `KmdbCodec` example: remove `id` from `encode()`, show `_id` in `decode()`, document the reserved prefix rule |

### Design decisions

**`_id` is not stored in the value bytes.** The LSM key is the authoritative
source. On write, the framework validates the encoded map has no `_`-prefixed
keys and stores it clean. On read, the framework injects `_id: key` into the
decoded map before calling `codec.decode()`. This eliminates the redundancy and
gives the framework full ownership of all `_`-prefixed fields.

**Validation happens after `codec.encode()`, before any I/O.** If any top-level
key in the encoded map starts with `_`, a `ReservedFieldException` is thrown
immediately. No partial writes occur. The exception carries the offending field
names so the developer can fix their codec.

**`withKey` stays.** It is still needed by `insert()` to return the document
with its newly assigned `_id` to the caller. The codec implementation stamps the
key onto its typed model — it just must not include it in `encode()`.

**`codec.decode()` receives `_id` in the map.** This makes the codec a natural
`fromJson`-style deserialiser. Implementations read `json['_id']` to reconstruct
the model's key field, just as they would with any other field. No additional
codec interface method is needed.

### Edge cases

- **`_id` in user `encode()` output.** Caught by the new validation — thrown as
  `ReservedFieldException` with a clear message listing the offending keys.
- **Future system fields (e.g. `_rev`, `_ts`).** The reserved prefix gives room
  to add these without a new convention.
- **Filter DSL on `_id`.** `FieldPath.resolve('_id', doc)` will work naturally
  once `_id` is injected before decode. No changes needed in the filter layer.
- **`orderBy('_id')`.** The existing `orderBy` doc comment references `'id'` as
  the natural-order shortcut — update to `'_id'`. The underlying LSM scan order
  is key-based regardless; the doc comment is informational only.
- **Index paths starting with `_`.** Secondary index definitions use dot-path
  field names. The framework should reject index definitions whose path starts
  with `_` at `KmdbDatabase.open()` time, since those fields are system-managed
  and not user-queryable. Add validation in `IndexManager` or `IndexDefinition`.

## Implementation plan

- [ ] Add `ReservedFieldException` to `packages/kmdb/lib/src/query/exceptions.dart`
- [ ] Update `KmdbCodec` interface: revise contract, doc comments, and example
      in `packages/kmdb/lib/src/query/kmdb_codec.dart`
- [ ] Add `_` prefix validation to `KmdbCollection._writeDocument` in
      `packages/kmdb/lib/src/query/kmdb_collection.dart`
- [ ] Inject `_id: key` before `codec.decode()` in `KmdbCollection.get()` in
      `packages/kmdb/lib/src/query/kmdb_collection.dart`
- [ ] Inject `_id: key` before `codec.decode()` in `KmdbQuery._execute()` in
      `packages/kmdb/lib/src/query/kmdb_query.dart`; update `orderBy` doc comment
- [ ] Add validation in `IndexDefinition` (or `IndexManager`) rejecting index
      paths that start with `_`
- [ ] Update test codecs in `kmdb_collection_test.dart`, `kmdb_query_test.dart`,
      and `index_test.dart` to remove `id` from `encode()` and read `_id` in
      `decode()`
- [ ] Add new `ReservedFieldException` tests to `kmdb_collection_test.dart`
      covering: single `_`-prefixed key, multiple offending keys, `_id`
      specifically, and a nested field with `_` prefix (should be allowed — only
      top-level is reserved)
- [ ] Update CLI commands: `put_command.dart`, `restore_command.dart`,
      `import_command.dart`
- [ ] Update CLI tests: all `['id']` references to `['_id']`
- [ ] Update `docs/spec/13_query_api.md`
- [ ] Run full test suite (`dart test packages/kmdb` and
      `dart test packages/kmdb_cli`) and confirm all pass at ≥90% coverage

## Summary

_To be completed after implementation._
