# CLI Schema Management

**Status**: Investigated

**PR link**: —

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

> **Review note:** Add `registeredCollections` unconditionally in Phase 2 — it
> is always cleaner than having the CLI decode raw registry bytes directly, and
> the implementation is a one-liner (`_rules.keys.toList()`). Do not leave this
> as a fallback.

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

- [ ] `schema set <collection>`:
  - Accept `--file <path>` (reads file, `jsonDecode`) or `--schema <json>`
    (inline); exactly one required
  - Validate the decoded value is a `Map<String, dynamic>`
  - Call `ctx.db.schemaManager.register(CollectionSchema(collection: collection,
    jsonSchema: decoded), ctx.db.store.meta)`
  - Print confirmation: `Schema registered for '<collection>'.`
- [ ] `schema show <collection>`:
  - Read raw bytes from `ctx.db.store.meta.getRawByName('schema:$collection')`
  - If absent, error: `No schema registered for '<collection>'.`
  - Decode JSON, extract the `schema` field, pretty-print it
- [ ] `schema list`:
  - Read `ctx.db.store.meta.getRawByName('schema:__registry__')`
  - If absent or empty, print: `No schemas registered.`
  - Print one collection name per line
- [ ] `schema remove <collection>`:
  - Call `ctx.db.schemaManager.deregister(collection, ctx.db.store.meta)`
  - Print: `Schema removed for '<collection>'.`
- [ ] `schema validate <collection> (--doc <json> | --file <path>)`:
  - Read doc JSON from `--doc` inline string or `--file` path
  - Call `ctx.db.schemaManager.validate(collection, doc)` — catch
    `SchemaValidationException` and print violations in the standard error
    format; print `{"valid": true}` when validation passes
  - If no schema is registered for the collection, print
    `No schema registered for '<collection>'. Document not validated.` and
    return `true`
- [ ] Add `SchemaValidationException` formatting helper (shared between
      `schema validate` output and the violation errors surfaced by migrated
      write commands)
- [ ] Register `SchemaCommand` in `cli_runner.dart`
- [ ] Tests for all subcommands covering success, missing arg, missing
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

—
