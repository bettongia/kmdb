# CLI Schema Management

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/commit/77b6dd0

**Prerequisite**: `plan_write_pipeline_and_cli_migration.md` must be complete
before this plan is implemented. Once the CLI routes writes through
`KmdbCollection`, schema enforcement on `insert`, `put`, and `update` is
automatic — no manual wiring in write commands is needed here.

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
      just the patch — this is now handled automatically because `update` routes
      through `KmdbCollection.update()` after the prerequisite migration.
- [x] `MetaStore.deleteRawByName` exists — `SchemaManager.deregister` is
      implementable without engine changes.
- [x] `CommandContext` / `DatabaseOpener` wiring: handled by the prerequisite
      plan. `ctx.db.schemaManager` and `ctx.db.store.meta` are available after
      the migration; no further wiring needed here.

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

### `schema set` input

Two input modes, mirroring `insert --value` / `insert --file`:

- `--file <path>` — reads a JSON Schema object from a `.json` file
- `--schema <json>` — accepts an inline JSON Schema string

The file or string contains only the JSON Schema (e.g.
`{"required": ["name"], ...}`). The collection name is the positional argument.

### Error format for schema violations

The `schema validate` subcommand (dry-run validation against a registered
schema) formats violations as:

```
Error: schema validation failed for 'contacts':
  name: required field is missing
  email: must be a valid email
```

One violation per line, indented two spaces, `path: message`. When `path` is
empty (root violation), the message is printed without a prefix.

For enforcement errors arising from `insert`, `put`, and `update` after the
prerequisite migration, these commands receive a `SchemaValidationException` from
`KmdbCollection` and should format it using the same layout.

### `schema:__registry__` key

`SchemaManager` writes and reads this key directly via `putRawByName` /
`getRawByName`. The CLI `schema list` subcommand reads the registry key from
`ctx.db.store.meta`. If accessing the raw bytes proves cumbersome, a
`registeredCollections` getter on `SchemaManager` is the right fix.


## Implementation plan

### Phase 1 — `kmdb_schema`: `JsonSchemaValidator`

- [x] Add `JsonSchemaValidator` to
      `packages/kmdb_schema/lib/src/json_schema_validator.dart`:
  - `JsonSchemaValidator.fromMap(Map<String, dynamic> schema)` — compiles via
    `SchemaParser().parse(schema)`
  - `JsonSchemaValidator.fromJson(String json)` — calls `jsonDecode(json)` then
    `fromMap`; throws `FormatException` on malformed JSON or non-object root
  - `List<SchemaViolation> validate(Map<String, dynamic> document)` — runs the
    compiled rule tree against `document` at root path `''`
- [x] Export `JsonSchemaValidator` from `packages/kmdb_schema/lib/schema.dart`
- [x] Unit tests in `packages/kmdb_schema/test/`:
  - `fromMap` — valid doc passes, missing required field fails
  - `fromJson` — valid JSON schema string compiles and validates
  - `fromJson` — malformed JSON throws `FormatException`
  - `fromJson` — non-object root (array) throws `FormatException`
  - `validate` returns all violations in one pass

### Phase 2 — `SchemaManager` additions in `kmdb`

- [x] Add `registeredCollections` getter to `SchemaManager`
- [x] Add `getSchema(String collection)` getter to `SchemaManager` — stores raw
      schema map alongside compiled rule tree so it survives round-trips
- [x] Add `deregister` to `SchemaManager`
- [x] Add `registerSchema()` / `deregisterSchema()` convenience wrappers on
      `KmdbDatabase` to avoid exposing `@internal MetaStore` outside the package
- [x] Export `SchemaManager` from `kmdb.dart`
- [x] Unit tests in `packages/kmdb/test/query/schema_manager_test.dart`:
  - `registeredCollections` returns correct list after register/deregister
  - `getSchema` returns the schema map for a registered collection; `null` for unknown
  - Deregister stops enforcement for that collection
  - Deregister of unknown collection is a no-op (does not throw)
  - Registry updated correctly after deregister (persists across `load()`)
  - Other registered collections unaffected by deregister

### Phase 3 — CLI `schema` command

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

- [x] `schema set <collection>`
- [x] `schema show <collection>`
- [x] `schema list`
- [x] `schema remove <collection>`
- [x] `schema validate <collection> (--doc <json> | --file <path>)`
- [x] `SchemaValidationException` formatting helper (`formatViolations`)
- [x] Register `SchemaCommand` in `cli_runner.dart`
- [x] Tests for all subcommands covering success, missing arg, missing
      collection, and no-schema cases

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
| Cross-collection isolation | schema only enforced for its named collection |

All tests must pass with ≥ 90% coverage.

## Summary

- Added `JsonSchemaValidator` to `kmdb_schema` — a standalone convenience type
  with `fromMap`, `fromJson`, and `validate` that wraps `SchemaParser` for
  non-KMDB consumers who want JSON Schema validation without the internal rule
  hierarchy. 19 new tests.

- Extended `SchemaManager` in `kmdb` with `registeredCollections`, `getSchema`,
  and `deregister`. The raw JSON Schema map is now stored alongside the compiled
  rule tree so `getSchema` can return the original map after a round-trip through
  `$meta`. Added `registerSchema`/`deregisterSchema` convenience wrappers on
  `KmdbDatabase` to provide a public API that doesn't require callers outside
  the `kmdb` package to touch the `@internal MetaStore`. Exported `SchemaManager`
  from `kmdb.dart`. 15 new tests.

- Added `SchemaCommand` to `kmdb_cli` with `set`, `show`, `list`, `remove`, and
  `validate` subcommands. All subcommands use the new `KmdbDatabase` wrappers.
  The `formatViolations` static helper provides a consistent error format for
  schema violations from any write command. 34 new tests.

- Total new tests: 68 (19 kmdb_schema + 15 kmdb + 34 kmdb_cli). All 1,537
  tests across the workspace continue to pass.
