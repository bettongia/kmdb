# CLI Schema Management

**Status**: Investigated

**PR link**: —

## Problem statement

Users have no way to define, inspect, or remove collection schemas via the CLI.
Schemas are currently configurable only through the `KmdbDatabase.open()` API in
application code, which means anyone managing a KMDB database from the command
line cannot apply or inspect write admission gates without modifying the
application that owns the database.

Additionally, `kmdb_schema` exposes a `SchemaParser` that compiles a JSON Schema
map to a rule tree, but has no standalone validator API — there is no convenient
way for a non-KMDB application to validate a Dart `Map` against a JSON Schema
string without understanding the internal `SchemaRule` hierarchy.

## Open questions

- [x] Storage location: `$meta` only — schemas sync automatically, consistent
      with the library. Not mirrored in `local/config.json`.
- [x] Update semantics: validate the merged document (existing + patch), not
      just the patch — mirrors `KmdbCollection.update()` behaviour.
- [x] `MetaStore.deleteRawByName` exists — `SchemaManager.deregister` is
      implementable without engine changes.

## Investigation

### `kmdb_schema`: current public surface

`SchemaParser.parse(Map<String, dynamic>)` is the only entry point. It compiles
a JSON Schema map to a `SchemaRule` tree; the caller must call
`rule.validate(doc, '')` manually and handle the returned `List<SchemaViolation>`
themselves. There is no convenience type that accepts a JSON string, holds the
rule tree, and exposes a single `validate(doc)` call. Non-KMDB consumers need
exactly that.

### `SchemaManager`: missing `deregister`

`SchemaManager` (`packages/kmdb/lib/src/query/schema/schema_manager.dart`)
supports `register` and `load` but has no removal path. The CLI `schema remove`
subcommand needs:

```dart
Future<void> deregister(String collection, MetaStore meta)
```

Implementation: remove the key `schema:{collection}` via
`meta.deleteRawByName('schema:$collection')`, rewrite the
`schema:__registry__` list without the collection name, and evict the in-memory
cache entry. Deregistering an unknown collection is a no-op.

### `CommandContext` and `DatabaseOpener`

`CommandContext` currently carries `store`, `config`, `indexManager`, and
`vaultStore`. A `SchemaManager` field is added as a required named parameter
with a default of `SchemaManager()` (empty, no schemas — keeps tests
construction-compatible).

`DatabaseOpener.open()` does not need changes. Schema loading happens in
`cli_runner.dart` after the store is opened:

```dart
final schemaManager = SchemaManager();
await schemaManager.load(store.meta);
```

### Write commands requiring enforcement

The CLI has three mutation commands that write document content:

| Command | Write path | Validation input |
| :------ | :--------- | :--------------- |
| `insert` | single doc or batch | the incoming doc |
| `put` | single doc | the incoming doc |
| `update` | shallow merge of `--set` into existing doc | **merged result** (existing + patch) |

`update` is the subtle case. `_updateOne()` currently does:
```
read existing → _merge(existing, setFields) → store.put()
```
Validation must run on the merged map, between `_merge` and `store.put`. The
same applies to the filter-based and `--all` paths that inline the same
read-merge-write loop.

The `--import` path in `update` (vault package replace) follows the same
principle: validate the replacement doc before the `WriteBatch` is written.

`delete` is never validated — consistent with the library.

### `schema set` input

Two input modes, mirroring `insert --value` / `insert --file`:

- `--file <path>` — reads a JSON Schema object from a `.json` file
- `--schema <json>` — accepts an inline JSON Schema string

The file or string contains only the JSON Schema (e.g.
`{"required": ["name"], ...}`). The collection name is the positional argument.

### Error format for schema violations

```
Error: schema validation failed for 'contacts':
  name: required field is missing
  email: must be a valid email
```

One violation per line, indented two spaces, `path: message`.
When `path` is empty (root violation), the message is printed without a prefix.

### `schema:__registry__` key

`SchemaManager` writes and reads this key directly via `putRawByName` /
`getRawByName`. The CLI `schema list` subcommand reads the registry key directly
from `store.meta` (same as `SchemaManager.load()` does internally) rather than
adding a public accessor, unless that proves cumbersome — in which case a
`registeredCollections` getter on `SchemaManager` is the right fix.

## Implementation plan

### Phase 1 — `kmdb_schema`: `JsonSchemaValidator`

- [ ] Add `JsonSchemaValidator` to
      `packages/kmdb_schema/lib/src/json_schema_validator.dart`:
  - `JsonSchemaValidator.fromMap(Map<String, dynamic> schema)` — compiles via
    `SchemaParser().parse(schema)`
  - `JsonSchemaValidator.fromJson(String json)` — calls `jsonDecode(json)` then
    `fromMap`; throws `FormatException` on malformed JSON or non-object root
  - `List<SchemaViolation> validate(Map<String, dynamic> document)` — runs the
    compiled rule tree against `document` at root path `''`
- [ ] Export `JsonSchemaValidator` from `packages/kmdb_schema/lib/schema.dart`
- [ ] Unit tests in `packages/kmdb_schema/test/`:
  - `fromMap` — valid doc passes, missing required field fails
  - `fromJson` — valid JSON schema string compiles and validates
  - `fromJson` — malformed JSON throws `FormatException`
  - `fromJson` — non-object root (array) throws `FormatException`
  - `validate` returns all violations in one pass

### Phase 2 — `SchemaManager.deregister()` in `kmdb`

- [ ] Add to `SchemaManager`:
  ```dart
  Future<void> deregister(String collection, MetaStore meta)
  ```
  - Delete `schema:{collection}` via `meta.deleteRawByName`
  - Read, filter, and rewrite the `schema:__registry__` list
  - Remove the in-memory cache entry; no-op if collection was never registered
- [ ] Unit tests in `packages/kmdb/test/query/schema_manager_test.dart`:
  - Deregister stops enforcement for that collection
  - Deregister of unknown collection is a no-op (does not throw)
  - Registry updated correctly after deregister (persists across `load()`)
  - Other registered collections unaffected by deregister

### Phase 3 — Wire `SchemaManager` into `CommandContext`

- [ ] Add `SchemaManager schemaManager` to `CommandContext` constructor
      (required named param, defaulting to `SchemaManager()` for test
      construction without a live store)
- [ ] Load schemas in `cli_runner.dart` after `DatabaseOpener.open()`:
  ```dart
  final schemaManager = SchemaManager();
  await schemaManager.load(store.meta);
  ```
- [ ] Pass `schemaManager` to `CommandContext(...)` in the runner

### Phase 4 — CLI `schema` command

New file:
`packages/kmdb_cli/lib/src/commands/schema_command.dart`

Subcommands:

```
kmdb <db> schema set <collection> (--file <path> | --schema <json>)
kmdb <db> schema show <collection>
kmdb <db> schema list
kmdb <db> schema remove <collection>
kmdb <db> schema validate <collection> (--doc <json> | --file <path>)
```

- [ ] `schema set <collection>`:
  - Accept `--file <path>` (reads file, `jsonDecode`) or `--schema <json>`
    (inline); exactly one required
  - Validate the decoded value is a `Map<String, dynamic>`
  - Call `ctx.schemaManager.register(CollectionSchema(collection: collection,
    jsonSchema: decoded), ctx.store.meta)`
  - Print confirmation: `Schema registered for '<collection>'.`
- [ ] `schema show <collection>`:
  - Read raw bytes from `ctx.store.meta.getRawByName('schema:$collection')`
  - If absent, error: `No schema registered for '<collection>'.`
  - Decode JSON, extract the `schema` field, pretty-print it
- [ ] `schema list`:
  - Read `ctx.store.meta.getRawByName('schema:__registry__')`
  - If absent or empty, print: `No schemas registered.`
  - Print one collection name per line
- [ ] `schema remove <collection>`:
  - Call `ctx.schemaManager.deregister(collection, ctx.store.meta)`
  - Print: `Schema removed for '<collection>'.`
- [ ] `schema validate <collection> (--doc <json> | --file <path>)`:
  - Read doc JSON from `--doc` inline string or `--file` path
  - Call `ctx.schemaManager.validate(collection, doc)` — catch
    `SchemaValidationException` and print violations in the standard error
    format; print `{"valid": true}` when validation passes
  - If no schema is registered for the collection, print
    `No schema registered for '<collection>'. Document not validated.` and
    return `true`
- [ ] Register `SchemaCommand` in `cli_runner.dart`
- [ ] Tests for all subcommands covering success, missing arg, missing
      collection, and no-schema cases

### Phase 5 — Enforcement in write commands

- [ ] `insert_command.dart`:
  - After decoding each incoming doc, call
    `ctx.schemaManager.validate(collection, doc)` before `store.put`
  - On `SchemaValidationException`, write formatted violations to `ctx.err` and
    return `false` (abort the entire batch — do not partially insert)
- [ ] `put_command.dart`:
  - Same pattern: validate before `store.put`
- [ ] `update_command.dart`:
  - In `_updateOne()`: validate `merged` (result of `_merge`) before `store.put`
  - In the filter-based loop: validate each `merged` doc before `store.put`;
    abort on first violation (report key in error message)
  - In the `--all` loop: same
  - In `_executeImport`: validate the replacement `doc` before writing the
    `WriteBatch`
- [ ] Tests for enforcement in each write command:
  - Valid doc accepted; invalid doc rejected with correct error message
  - `update` with `--set` that produces an invalid merged doc is rejected
  - `update --all` aborts on the first violation and reports the document key
  - Collections without a schema are unaffected
  - `delete` is never blocked regardless of schema

## Coverage targets

| Area | Tests to include |
| :--- | :--- |
| `JsonSchemaValidator` | `fromMap`, `fromJson`, malformed JSON, non-object root, all violations returned |
| `deregister` | stops enforcement, no-op on unknown, registry updated, other collections unaffected |
| `schema set` | valid file, valid inline, missing collection arg, non-object JSON |
| `schema show` | present schema displayed, missing collection error |
| `schema list` | none, one, multiple collections |
| `schema remove` | removes enforcement, unknown collection no-op |
| `schema validate` | violations reported, valid doc passes, no-schema no-op |
| `insert` enforcement | valid accepted, invalid rejected |
| `put` enforcement | valid accepted, invalid rejected |
| `update` enforcement | merged valid, merged invalid, filter-based abort on violation, `--all` abort on violation, `--import` replacement validated |
| Cross-collection isolation | schema only enforced for its named collection |

All tests must pass with ≥ 90% coverage.

## Summary

—
