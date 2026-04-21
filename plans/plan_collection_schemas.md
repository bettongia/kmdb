# Collection Schemas

**Status**: Investigated

**PR link**: _pending_

## Problem statement

KMDB has no mechanism to enforce document structure within a collection.
Applications that require certain fields to be present, typed correctly, or
formatted to a specific pattern currently must implement their own validation
layer outside the database. This plan adds an optional, per-collection schema
system that acts as an admission gate on writes, using a JSON Schema subset as
the authoring surface and a Dart-native rule tree internally.

Unique constraints (e.g. requiring a field value is unique across documents in a
collection) are deliberately out of scope and tracked separately in the roadmap.
The distributed nature of KMDB's sync model makes strong uniqueness guarantees
non-trivial; the preferred approach (soft local enforcement + post-sync
violation detection) warrants its own implementation plan.

## Open questions

- [x] Schema persistence: in-memory only or persisted/synced? → **Persisted** in
      `$schema:{collection}` so schemas sync to other devices via normal SSTable
      replication.
- [x] Schema version protection for older KMDB clients? →
      **`schemaModelVersion`** field in the stored CBOR payload. Old clients
      that read a `schemaModelVersion` they do not support warn via
      `onSchemaVersionMismatch` callback and disable enforcement for that
      collection. Newer KMDB versions support all prior model versions.
- [x] `update()` validation scope: patch only or merged result? → **Merged
      result**. `update()` already reads the old document before writing;
      validation runs against the merged map.
- [x] `additionalProperties` default → **`true`** (permissive). Disallowing
      extra fields requires explicit `additionalProperties: false`.
- [x] CLI scope → **Library only** for this plan. CLI support deferred.

## Investigation

### Insertion point: `KmdbCollection._writeDocument()`

All collection writes (`insert`, `put`, `replace`, `update`) route through
`_writeDocument()` in
[kmdb_collection.dart](../packages/kmdb/lib/src/query/kmdb_collection.dart). The
write pipeline is:

1. `_validateNoReservedKeys()` — synchronous, before any I/O (existing)
2. `ValueCodec.encode()` — encodes Map to binary
3. `WriteBatch` creation
4. `indexManager.interceptWrite()` — adds `$index:*` entries to batch
5. `ftsManager.interceptWrite()` — adds `$fts:*` entries to batch
6. `vecManager.interceptWrite()` — adds `$vec:*` entries to batch
7. `vaultRefInterceptor.interceptWrite()` — adjusts `$vault` ref counts in batch
8. `store.writeBatchInternal(batch)` — atomic commit

Schema validation slots in **between steps 1 and 2** — synchronous, before the
batch is created, so a validation failure throws before any I/O and leaves no
partial state.

For `update()` specifically, the merged document (old doc + patch) must be
passed to the validator rather than the raw patch.

### Storage: `$schema:{collection}`

Schemas are stored using the existing `MetaStore` pattern in
[meta_store.dart](../packages/kmdb/lib/src/engine/kvstore/meta_store.dart). The
key `schema:{collection}` under `$meta` follows the same convention as
`index:{namespace}:{path}` for secondary index state.

Each stored schema is a CBOR map with:

- `schemaModelVersion` (int) — KMDB schema feature version; starts at `1`
- `schema` (map) — the raw JSON Schema definition as provided by the caller

### `KmdbDatabase.open()` changes

New parameters in
[kmdb_database.dart](../packages/kmdb/lib/src/query/kmdb_database.dart):

```dart
static Future<KmdbDatabase> open({
  ...existing params...
  List<CollectionSchema> schemas = const [],
  void Function(String collection, int storedVersion, int supportedVersion)?
      onSchemaVersionMismatch,
})
```

At open time, for each `CollectionSchema`:

1. Write it to `$meta` under `schema:{collection}` (always; LWW via HLC)
2. Register it with `SchemaManager`

If no schema is provided for a collection but one exists in storage (synced from
another device):

1. Read it from `$meta`
2. Check `schemaModelVersion` against `kSchemaModelVersion`
3. If version is unsupported, call `onSchemaVersionMismatch` and skip
   enforcement
4. Otherwise register it with `SchemaManager`

### New types

**`CollectionSchema`** — caller-facing registration object:

```dart
final class CollectionSchema {
  const CollectionSchema({
    required this.collection,
    required this.jsonSchema,
  });
  final String collection;
  final Map<String, dynamic> jsonSchema;
}
```

**`SchemaRule`** — sealed internal rule tree (one subclass per keyword group):

- `TypeRule` — `type` constraint
- `RequiredRule` — `required` field list
- `PropertiesRule` — per-field child rules
- `AdditionalPropertiesRule` — `additionalProperties: false`
- `EnumRule` — allowed values
- `NumericRule` — `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`
- `StringRule` — `minLength`, `maxLength`, `pattern`
- `FormatRule` — surface validation: email, uri, date, date-time, uuid
- `ArrayRule` — `minItems`, `maxItems`, `items`

**`SchemaViolation`** — individual violation record:

```dart
final class SchemaViolation {
  const SchemaViolation({required this.path, required this.message});
  final String path;    // dot-path to offending field, or '' for root
  final String message;
}
```

**`SchemaValidationException`** — thrown when validation fails:

```dart
final class SchemaValidationException implements Exception {
  const SchemaValidationException({
    required this.collection,
    required this.violations,
  });
  final String collection;
  final List<SchemaViolation> violations;
}
```

**`SchemaManager`** — owns parse, persist, and validate lifecycle:

- `static const int kSchemaModelVersion = 1`
- `Future<void> load(MetaStore meta)` — reads persisted schemas at open time
- `Future<void> register(CollectionSchema schema, MetaStore meta)` — parses JSON
  Schema to `SchemaRule` tree, persists to `$meta`, caches in memory
- `void validate(String collection, Map<String, dynamic> doc)` — runs rule tree,
  throws `SchemaValidationException` if violations found
- `SchemaRule _parse(Map<String, dynamic> jsonSchema)` — JSON Schema → rule tree

### JSON Schema subset (schemaModelVersion 1)

| Keyword                                 | Behaviour                                                                                                                  |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `type`                                  | Validates Dart type: `string`→String, `number`→num, `integer`→int, `boolean`→bool, `array`→List, `object`→Map, `null`→null |
| `required`                              | Each named field must be present and non-null                                                                              |
| `properties`                            | Recursively validates named fields                                                                                         |
| `additionalProperties: false`           | Rejects fields not listed in `properties`                                                                                  |
| `enum`                                  | Value must be in the list (deep equality)                                                                                  |
| `minimum` / `maximum`                   | Inclusive numeric range                                                                                                    |
| `exclusiveMinimum` / `exclusiveMaximum` | Exclusive numeric range                                                                                                    |
| `minLength` / `maxLength`               | String length in characters                                                                                                |
| `pattern`                               | Dart `RegExp` match on string                                                                                              |
| `format`                                | Regex-only surface check: `email`, `uri`, `date` (ISO 8601), `date-time`, `uuid`                                           |
| `minItems` / `maxItems`                 | List length                                                                                                                |
| `items`                                 | Applies rule to each list element                                                                                          |

Defaults: `additionalProperties: true`, all other constraints absent = no
restriction.

`null` vs absent: a field present with value `null` satisfies `required` (field
exists). A missing field fails `required`.

Out of scope for v1: `$ref`, `allOf`/`anyOf`/`oneOf`/`not`, `if`/`then`/`else`,
nested `$schema` declarations.

### Sync behaviour (documented in spec)

Schema enforcement is a per-device, per-write guarantee. Incoming SSTables from
other devices are applied directly to the LSM without re-validation.
Applications must not treat schema conformance as a database-wide invariant; it
is defence-in-depth on local writes only.

### Existing `kmdb_schema` package

[packages/kmdb_schema/](../packages/kmdb_schema/) already provides primitive
validators that map directly to JSON Schema keywords. These are **already
implemented and tested**:

| Validator | JSON Schema keyword |
|---|---|
| `EnumValidator<T>` | `enum` |
| `ConstValidator<T>` | `const` |
| `Minimum<T>` / `Maximum<T>` | `minimum` / `maximum` |
| `ExclusiveMinimum<T>` / `ExclusiveMaximum<T>` | `exclusiveMinimum` / `exclusiveMaximum` |
| `MultipleOf<T>` | `multipleOf` |
| `MinimumLength` / `MaximumLength` | `minLength` / `maxLength` |
| `PatternValidator` | `pattern` |
| `MinItems<T>` / `MaxItems<T>` | `minItems` / `maxItems` |
| `UniqueItems<T>` | `uniqueItems` |
| `Required` | `required` |
| `MinProperties` / `MaxProperties` | `minProperties` / `maxProperties` |
| `DependentRequired` | `dependentRequired` |

**Bug to fix:** `MinimumLength` uses `input.runes.length` while all other string
validators use `input.characters.length` — make consistent.

**Still to add to `kmdb_schema`** (generic, no KMDB dependency):

- `TypeValidator` — maps JSON Schema `type` strings to Dart runtime type checks
- `FormatValidator` — surface regex checks for `email`, `uri`, `date`,
  `date-time`, `uuid`
- `PropertiesValidator` — applies per-field child validators to a Map
- `AdditionalPropertiesValidator` — rejects keys not declared in a properties set
- `ItemsValidator` — applies a child validator to every element of a List

The sealed `SchemaRule` hierarchy and `SchemaParser` also live in `kmdb_schema`
(generic; no KMDB storage concepts). `SchemaManager` (persistence, MetaStore
integration, version checking) lives in `kmdb`.

### New spec document

`docs/spec/25_collection_schemas.md` — covers schema registration, JSON Schema
subset, `schemaModelVersion` versioning, sync behaviour, and the
`onSchemaVersionMismatch` callback.

## Implementation plan

### Phase 1 — Complete `kmdb_schema` primitives

- [ ] Fix `MinimumLength` — change `input.runes.length` to
      `input.characters.length`
- [ ] Add `TypeValidator` to `validation.dart`
- [ ] Add `FormatValidator` to `validation.dart` (email, uri, date, date-time,
      uuid)
- [ ] Add `PropertiesValidator` to `validation.dart`
- [ ] Add `AdditionalPropertiesValidator` to `validation.dart`
- [ ] Add `ItemsValidator` to `validation.dart`
- [ ] Update `validation_test.dart` with tests for all new validators
- [ ] Export new validators from `schema.dart`

### Phase 2 — `SchemaRule` tree and parser in `kmdb_schema`

- [ ] Add sealed `SchemaRule` hierarchy to
      `packages/kmdb_schema/lib/src/schema_rule.dart`
- [ ] Implement `SchemaParser` —
      `SchemaRule parse(Map<String, dynamic> jsonSchema)` using Phase 1
      validators
- [ ] Add `SchemaViolation` type (path + message) to `kmdb_schema`
- [ ] Unit-test `SchemaParser` for every supported keyword including nested
      `properties`

### Phase 3 — KMDB integration types

- [ ] Add `CollectionSchema` to `packages/kmdb/lib/src/query/`
- [ ] Add `SchemaValidationException` to
      `packages/kmdb/lib/src/query/exceptions.dart`
- [ ] Implement `SchemaManager` in `packages/kmdb/lib/src/query/schema/`:
  - `static const int kSchemaModelVersion = 1`
  - `Future<void> load(MetaStore meta)` — reads `schema:*` keys at open time
  - `Future<void> register(CollectionSchema, MetaStore)` — parses, persists,
    caches
  - `void validate(String collection, Map<String, dynamic> doc)` — throws on
    violation
- [ ] Unit-test `SchemaManager`: persistence round-trip, version mismatch
      callback, no-op when collection has no schema

### Phase 4 — Wire into `KmdbDatabase` and `KmdbCollection`

- [ ] Add `schemas` and `onSchemaVersionMismatch` parameters to
      `KmdbDatabase.open()`
- [ ] Instantiate and wire `SchemaManager` in `open()`
- [ ] Insert `schemaManager.validate(namespace, mergedDoc)` into
      `_writeDocument()` after `_validateNoReservedKeys()` and before encoding
- [ ] Ensure `update()` passes the merged document (old + patch) to the
      validator
- [ ] Integration tests: schema enforced on insert/put/replace/update; not on
      delete; not on synced data arriving via `writeBatchInternal` directly

### Phase 5 — Spec and docs

- [ ] Write `docs/spec/25_collection_schemas.md`
- [ ] Update `docs/spec/13_query_api.md` — note schema parameter on `open()`
- [ ] Update `packages/kmdb/lib/src/query/kmdb_database.dart` doc comment with
      schema example
- [ ] Update `packages/kmdb/lib/src/query/kmdb_collection.dart` doc comment
      noting `SchemaValidationException`

### Coverage targets

| Area             | Tests to include                                                                   |
| ---------------- | ---------------------------------------------------------------------------------- |
| `type`           | Each of the 7 types; null value with non-null type; wrong Dart type                |
| `required`       | Present+non-null passes; absent fails; null value with required                    |
| `properties`     | Nested object validation; unknown field with `additionalProperties: false`         |
| `enum`           | Matching value passes; non-matching fails; null in enum list                       |
| Numeric          | Boundary values for min/max (inclusive and exclusive)                              |
| String           | Length boundaries; pattern match and non-match                                     |
| `format`         | Valid and invalid examples for each format token                                   |
| Array            | Length boundaries; `items` type mismatch                                           |
| `update()`       | Patch that produces valid merged doc; patch that produces invalid merged doc       |
| Persistence      | Schema written at open, read back, survives restart                                |
| Version mismatch | `schemaModelVersion > kSchemaModelVersion` triggers callback, disables enforcement |
| Sync bypass      | Document written directly via `writeBatchInternal` bypasses validation             |
| Multiple schemas | Two collections each with independent schemas; violations isolated                 |

All tests must pass with ≥ 90% coverage.

## Summary

_To be completed on implementation._
