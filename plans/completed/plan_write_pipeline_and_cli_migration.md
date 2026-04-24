# Write Pipeline Formalisation and CLI Query Layer Migration

**Status**: Completed

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/18

## Problem statement

Two related architectural weaknesses compound each other:

1. **The write pipeline is implicit.** `KmdbCollection._writeDocument()` and
   `_deleteDocument()` contain hardcoded calls to each validator and augmentor
   rather than iterating a registered list. Adding a new write concern (unique
   constraints, authorisation, audit logging) requires modifying the method
   body. The existing augmentor calls also have slightly inconsistent signatures
   across `IndexManager`, `FtsManager`, `VecManager`, and `VaultRefInterceptor`.

2. **The CLI bypasses the Query Layer entirely.** `DatabaseOpener` opens a raw
   `KvStoreImpl`; write commands call `store.put()` directly. This means schema
   enforcement, secondary index maintenance, FTS and vector index updates are
   all silently skipped on CLI writes. `InsertCommand` and `UpdateCommand`
   already carry doc comments documenting this limitation. Each new Query Layer
   feature must be manually re-wired into `CommandContext` or the limitation
   compounds.

The fix is: formalise the write pipeline as three explicit layers, introduce an
untyped `rawCollection` entry point so the CLI can route writes through
`_writeDocument()`, and migrate the CLI's mutation and query commands to use it.

## Open questions

- [x] Storage of schemas and indexes across the migration: unchanged. Schemas
      stay in `$meta`; index definitions stay in `local/config.json` (passed to
      `KmdbDatabase.open()` at startup, as application code does today).
- [x] Commands that remain at the store layer: `dump`, `restore`, `verify`,
      `flush`, `compact`, `sync`, `push`, `pull`, `stats`, `info`, `vault` — all
      operate on engine internals and legitimately bypass write validation (same
      reason database restores bypass constraints in any database system).
- [x] `scan --prefix` stays at the store layer — key-prefix scanning is an
      inherently engine-level operation not expressible in the `Filter` DSL.
- [x] Post-write notification: `KvStore.writeEvents` stream already serves as
      Layer 3. `CacheLayer` and `watch()` already subscribe to it. No new code
      needed for this layer in this plan; it is documented in the spec.
- [x] Schema validation on sync ingestion: incoming SSTables from other devices
      are applied directly to the LSM and are **never** re-validated against the
      local schema (see roadmap §0.01 — Sync behaviour). `WriteValidator` runs
      only in `_writeDocument()`, which is called for local writes only. This is
      intentional: the admission gate cannot be applied retroactively to data
      written on another device before the schema was activated or under a
      looser schema version.

## Investigation

### The three layers in `_writeDocument()` today

```
_validateNoReservedKeys(newDoc)          ← Layer 1: hardcoded validator
_db.schemaManager.validate(...)          ← Layer 1: hardcoded validator
ValueCodec.encode(newDoc)
WriteBatch creation
_db.indexManager.interceptWrite(...)     ← Layer 2: augmentor
_db.ftsManager?.interceptWrite(...)      ← Layer 2: augmentor
_db.vecManager?.interceptWrite(...)      ← Layer 2: augmentor
_db.vaultRefInterceptor?.interceptWrite  ← Layer 2: augmentor
store.writeBatchInternal(batch)          ← atomic commit
// KvStore.writeEvents fires             ← Layer 3: implicit via stream
```

`_deleteDocument()` has the same augmentor calls (with `newDoc: null` signalling
deletion) but no Layer 1 calls — correct, since deletion is never blocked.

### Augmentor signature inconsistency

The four augmentors accept slightly different named parameters:

| Augmentor                            |  `namespace`  | `key/docId` | `newDoc` | `oldDoc` | `batch` |
| :----------------------------------- | :-----------: | :---------: | :------: | :------: | :-----: |
| `IndexManager.interceptWrite`        | ✓ `namespace` | ✓ `docKey`  |    ✓     |    ✓     |    ✓    |
| `FtsManager.interceptWrite`          | ✓ `namespace` |  ✓ `docId`  |    ✓     |    ✓     |    ✓    |
| `VecManager.interceptWrite`          | ✓ `namespace` |  ✓ `docId`  |    ✓     |    ✓     |    ✓    |
| `VaultRefInterceptor.interceptWrite` |       —       |      —      |    ✓     |    ✓     |    ✓    |

A formal `WriteAugmentor` interface unifies these.

### Proposed `WriteValidator` interface

```dart
abstract interface class WriteValidator {
  /// Validates [document] before it is written to [collection].
  ///
  /// Throws to abort the write. Called before any I/O — no partial write
  /// can occur if a validator throws.
  void validate(String collection, Map<String, dynamic> document);
}
```

`ReservedKeyValidator` replaces the static `_validateNoReservedKeys()`.
`SchemaManager` adds `implements WriteValidator` — its existing
`validate(collection, doc)` method already matches the interface exactly.

`KmdbDatabase` holds `List<WriteValidator> _validators` and `_writeDocument()`
iterates it instead of calling validators by name.

### Proposed `WriteAugmentor` interface

```dart
abstract interface class WriteAugmentor {
  /// Adds entries to [batch] for this augmentor's concern.
  ///
  /// [newDoc] is `null` for deletes; [oldDoc] is `null` for new inserts.
  /// Runs after all validators pass and before [WriteBatch] is committed.
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  });
}
```

`IndexManager`, `FtsManager`, `VecManager`, and `VaultRefInterceptor` each add
`implements WriteAugmentor` and adopt the unified signature. `KmdbDatabase`
holds `List<WriteAugmentor> _augmentors` and `_writeDocument()` and
`_deleteDocument()` each iterate it.

### `rawCollection` and `RawDocumentCodec`

The CLI does not have a typed model — it works with `Map<String, dynamic>`. A
built-in pass-through codec makes an untyped collection trivial:

```dart
final class RawDocumentCodec implements KmdbCodec<Map<String, dynamic>> {
  const RawDocumentCodec();
  @override String keyOf(Map<String, dynamic> v) => v['_id'] as String;
  @override Map<String, dynamic> withKey(Map<String, dynamic> v, String key) =>
      {...v, '_id': key};
  @override Map<String, dynamic> encode(Map<String, dynamic> v) {
    final m = Map<String, dynamic>.of(v)..remove('_id');
    return m;
  }
  @override Map<String, dynamic> decode(Map<String, dynamic> json) => json;
}
```

`KmdbDatabase.rawCollection(String name)` returns
`collection(name: name, codec: const RawDocumentCodec())`.

### CLI migration: `DatabaseOpener`

`DatabaseOpener.open()` currently returns `(KvStoreImpl, bool created)`. It will
return `(KmdbDatabase, bool created)`. The two-phase device-ID open uses
`db.store.ensureDeviceId()` (the `store` getter is already public on
`KmdbDatabase`) — logic unchanged. After the device-ID phase, config is loaded
from `local/config.json` and passed to the second `KmdbDatabase.open()` call:

```dart
final db = await KmdbDatabase.open(
  path: dbPath,
  adapter: adapter,
  deviceId: deviceId,
  indexes: config.indexDefinitions,
  ftsIndexes: config.ftsIndexDefinitions,
  // schemas loaded automatically from $meta — no parameter needed
);
```

### CLI migration: `CommandContext`

`CommandContext` is restructured around `KmdbDatabase`:

```dart
final class CommandContext {
  CommandContext({required KmdbDatabase db, KmdbConfig? config, ...}) ...

  final KmdbDatabase db;

  // Convenience accessors used by commands that still need store-level access.
  KvStoreImpl get store => db.store;
  IndexManager get indexManager => db.indexManager;
  VaultStore? get vaultStore => db.vaultStore;
}
```

### CLI migration: commands

**Commands migrated to `rawCollection`** — gain schema enforcement and index
maintenance automatically:

| Command               | Current call                         | Migrated call                           |
| :-------------------- | :----------------------------------- | :-------------------------------------- |
| `insert`              | `store.put(ns, key, encode(doc))`    | `col.insert(doc)`                       |
| `put`                 | `store.put(ns, key, encode(doc))`    | `col.put(doc)`                          |
| `update` (single)     | `store.put(ns, key, encode(merged))` | `col.update(key, (_) => merged)`        |
| `update` (filter/all) | scan → merge → `store.put`           | scan → `col.update(key, (_) => merged)` |
| `get`                 | `store.get(ns, key)`                 | `col.get(key)`                          |
| `scan` (field filter) | scan all → evaluate                  | `col.where(filter).limit(n).get()`      |
| `scan` (no filter)    | `store.scan(ns)`                     | `col.where().limit(n).get()`            |
| `count`               | `store.scan(ns)` count               | `col.where(filter).count()`             |
| `delete` (single)     | `store.delete(ns, key)`              | `col.delete(key)`                       |
| `delete` (filter/all) | scan → `store.delete`                | scan → `col.delete(key)`                |
| `collections list`    | enumerate via store scan             | unchanged (store-level)                 |

`scan --prefix` remains at the store layer (`db.store.scan(ns, prefix: p)`) —
key-prefix scanning has no `Filter` DSL equivalent.

**Commands that stay at the store layer** (bypass is intentional): `dump`,
`restore`, `verify`, `flush`, `compact`, `sync`, `push`, `pull`, `stats`,
`info`, `new-device-id`, `vault`, `collections create/delete`, `index`,
`remote`, `import`, `export`.

`update --import` (vault package replace) builds a `WriteBatch` directly; it
should validate the replacement document via `col.put(doc)` before the batch
write, or use `col.replace(doc)` if replace semantics are added.

### The `update` command and merge semantics

`UpdateCommand._updateOne()` reads the existing doc, shallow-merges `--set`
fields, then writes. With `rawCollection`:

```dart
await col.update(key, (old) {
  final merged = Map<String, dynamic>.of(old)..addAll(setFields);
  merged['_id'] = old['_id']; // preserve key
  return merged;
});
```

`KmdbCollection.update()` reads the existing doc, calls the updater, and passes
the merged result through `_writeDocument()`. Schema validation therefore sees
the full merged document — correct behaviour, consistent with the library.

## Implementation plan

### Phase 1 — Formalise the write pipeline

- [x] Add `WriteValidator` interface to
      `packages/kmdb/lib/src/query/write_validator.dart`
- [x] Add `WriteAugmentor` interface to
      `packages/kmdb/lib/src/query/write_augmentor.dart`
- [x] Add `ReservedKeyValidator implements WriteValidator` (replaces
      `_validateNoReservedKeys` static method)
- [x] Add `implements WriteValidator` to `SchemaManager` (method signature
      already matches)
- [x] Add `implements WriteAugmentor` to `IndexManager`, `FtsManager`,
      `VecManager`, `VaultRefInterceptor` — unify to the common named-parameter
      signature
- [x] Refactor `KmdbDatabase` to build `List<WriteValidator> _validators` and
      `List<WriteAugmentor> _augmentors` during `open()`
- [x] Refactor `_writeDocument()` to iterate `_validators` then `_augmentors`
- [x] Refactor `_deleteDocument()` to iterate `_augmentors` only (no validators
      — delete is never blocked)
- [x] Export `WriteValidator` and `WriteAugmentor` from `kmdb.dart`
- [x] Update spec §13 with the 3-layer model; note Layer 3 (`writeEvents`) is
      the existing notification mechanism
- [x] All existing tests must still pass — this is a refactor, not a behaviour
      change

### Phase 2 — `rawCollection`

- [x] Add `RawDocumentCodec` to
      `packages/kmdb/lib/src/query/raw_document_codec.dart`
- [x] Add `KmdbDatabase.rawCollection(String name)` — returns
      `collection(name: name, codec: const RawDocumentCodec())`
- [x] Export `RawDocumentCodec` from `kmdb.dart`
- [x] Unit tests: insert/put/get/update/delete via `rawCollection` round-trip;
      schema enforcement and index writes fire correctly via `rawCollection`

### Phase 3 — CLI migration

- [x] Refactor `DatabaseOpener.open()` to return `(KmdbDatabase, bool created)`:
  - Keep two-phase device-ID open using `db.store.ensureDeviceId()`
  - Pass config-derived `indexes` and `ftsIndexes` on the second open
  - Schemas loaded automatically from `$meta` (no change to `open()` signature
    needed)
- [x] Restructure `CommandContext`:
  - Replace `KvStoreImpl store` field with `KmdbDatabase db`
  - Add `KvStoreImpl get store => db.store` convenience getter for commands that
    still need engine access
  - Remove explicit `IndexManager indexManager` field — expose via
    `db.indexManager`
  - Remove explicit `VaultStore? vaultStore` field — expose via `db.vaultStore`
- [x] Migrate write commands: `insert`, `put`, `update` (all targeting modes
      including `--import`)
- [x] Migrate read commands: `get`, `scan` (field-filter and no-filter paths),
      `count`, `delete`
- [x] Keep `scan --prefix` using `db.store.scan()` directly
- [x] Update `cli_runner.dart` to open `KmdbDatabase` and construct the updated
      `CommandContext`
- [x] Remove the doc-comment warnings about stale secondary indexes from
      `InsertCommand` and `UpdateCommand`
- [x] Update all CLI tests: replace `CommandContext(store: ...)` construction
      with `CommandContext(db: ...)`

### Phase 4 — Update dependent plan

- [x] Update `plans/plan_cli_schemas.md`:
  - Add this plan as a prerequisite
  - Remove Phase 3 (enforcement in write commands) — enforcement is now free via
    the Query Layer migration
  - Remove Phase 3 (wire `SchemaManager` into `CommandContext`) — already
    available as `ctx.db.schemaManager`
  - Retain Phase 1 (`JsonSchemaValidator`), Phase 2
    (`SchemaManager.deregister`), and the `schema` command group (Phase 4 in the
    schema plan)

## Coverage targets

| Area                                           | Tests                                                      |
| :--------------------------------------------- | :--------------------------------------------------------- |
| `WriteValidator` / `WriteAugmentor` interfaces | existing tests pass unchanged                              |
| `ReservedKeyValidator`                         | reserved-key rejection (migrated from existing test)       |
| Augmentor unified signature                    | all four augmentors called correctly via list              |
| `rawCollection` round-trip                     | insert, put, get, update, delete                           |
| `rawCollection` + schema                       | violation thrown; valid doc accepted                       |
| `rawCollection` + index                        | index entry written on put; removed on delete              |
| `DatabaseOpener`                               | returns `KmdbDatabase`; device-ID two-phase open preserved |
| CLI `insert`                                   | single doc, batch, NDJSON — schema enforced                |
| CLI `put`                                      | schema enforced                                            |
| CLI `update` (single)                          | merged result validated                                    |
| CLI `update` (filter/all)                      | merged result validated for each match                     |
| CLI `get`                                      | existing doc returned; missing returns null                |
| CLI `scan`                                     | field filter; no filter; `--prefix` still at store layer   |
| CLI `count`                                    | with filter; without filter                                |
| CLI `delete`                                   | single; filter; all                                        |
| Low-level commands                             | unchanged behaviour (dump, restore, sync, etc.)            |

All tests must pass with ≥ 90% coverage.

## Review notes

- **Verify `_validateNoReservedKeys` exists.** The investigation confirmed
  `_db.schemaManager.validate()` at line 615 of `kmdb_collection.dart` but did
  not surface a separate `_validateNoReservedKeys` call. Grep for it before
  starting Phase 1 — if it is absent the `ReservedKeyValidator` step is a no-op
  and can be dropped.

- **Augmentor signature unification confirmed necessary.** `IndexManager` uses
  `docKey`; `FtsManager` and `VecManager` use `docId`; `VaultRefInterceptor` has
  neither parameter. The proposed unified `docKey` name is correct — all four
  implementations will need updating, including `VaultRefInterceptor` which will
  receive but ignore `namespace` and `docKey`.

- **CLI schema plan dependency on `CommandContext.db`.** Phase 3 of
  `plan_cli_schemas.md` calls `ctx.db.schemaManager` and `ctx.db.store.meta`.
  These are only available after this plan's Phase 3 completes. The CLI schema
  plan must not start its Phase 3 until `CommandContext` holds `KmdbDatabase`.

## Summary

—
