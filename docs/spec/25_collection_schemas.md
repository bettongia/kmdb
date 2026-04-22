# Collection Schemas

## Overview

KMDB supports optional JSON Schema validation for collections. Schemas are
configured at database open time and act as an admission gate on every document
write. Reads and deletes are never blocked.

Schemas are authored as a JSON Schema subset (see [Supported Keywords](#supported-keywords))
and stored internally as a Dart-native rule tree. The raw JSON map is used only
for authoring and cross-device persistence.

## Configuring Schemas

Schemas are declared via the `schemas` parameter of `KmdbDatabase.open`:

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  schemas: [
    CollectionSchema(
      collection: 'contacts',
      jsonSchema: {
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string', 'format': 'email'},
          'age':  {'type': 'integer', 'minimum': 0},
        },
        'additionalProperties': false,
      },
    ),
  ],
);
```

Collections with no registered schema accept any document. Collections with a
schema reject writes that violate it by throwing `SchemaValidationException`
before the `WriteBatch` is committed — no partial write occurs.

## SchemaValidationException

```dart
try {
  await contacts.insert(contact);
} on SchemaValidationException catch (e) {
  for (final v in e.violations) {
    print('${v.path}: ${v.message}');
  }
}
```

`SchemaValidationException.violations` is a non-empty list of `SchemaViolation`
objects. Each violation has:

| Field     | Description                                    |
| :-------- | :--------------------------------------------- |
| `path`    | Dot-path to the offending field, or `''` (root) |
| `message` | Human-readable description of the violation    |

All violations found in a single write are reported together so UI forms can
surface every error at once.

## Affected Write Operations

Schema validation applies to every document write path:

| Method        | Validated? |
| :------------ | :--------- |
| `put`         | Yes        |
| `insert`      | Yes        |
| `replace`     | Yes        |
| `update`      | Yes — the full merged result is validated, not the patch |
| `delete`      | No         |
| sync ingest   | No (see [Sync Bypass](#sync-bypass)) |

## Supported Keywords

The following JSON Schema keywords are recognised:

| Keyword                | Types        | Notes                                      |
| :--------------------- | :----------- | :----------------------------------------- |
| `type`                 | any          | `string`, `number`, `integer`, `boolean`, `object`, `array`, `null` |
| `required`             | object       | List of required property names            |
| `properties`           | object       | Per-property sub-schemas                   |
| `additionalProperties` | object       | `false` rejects unknown keys; defaults to `true` |
| `enum`                 | any          | Value must equal one of the listed items   |
| `minimum`              | number/integer | Inclusive lower bound                    |
| `maximum`              | number/integer | Inclusive upper bound                    |
| `minLength`            | string       | Minimum character count (Unicode-aware)    |
| `maxLength`            | string       | Maximum character count (Unicode-aware)    |
| `pattern`              | string       | ECMAScript regular expression              |
| `format`               | string       | `email`, `uri`, `date`, `date-time`, `time`, `uuid` (unknown formats silently ignored) |
| `minItems`             | array        | Minimum element count                      |
| `maxItems`             | array        | Maximum element count                      |
| `items`                | array        | Sub-schema applied to every element        |

Unknown keywords are silently ignored. This allows schemas written by a newer
KMDB version to be partially interpreted by an older one.

## Persistence and Sync

Each schema is persisted in `$meta` under the symbolic key
`schema:{collection}` as UTF-8 JSON with the following envelope:

```json
{
  "schemaModelVersion": 1,
  "schema": { ... }
}
```

A registry of schema-holding collections is maintained at
`schema:__registry__` so that schemas synced from other devices are loaded on
the next open.

### Last-Write-Wins

When `schemas` is passed to `KmdbDatabase.open`, each schema is unconditionally
written to `$meta` at open time. Across devices, the most recent open call
that supplies a schema wins (LWW via HLC). This matches the standard KMDB
conflict resolution model.

### Caller-Supplied Schema Wins on Load

`SchemaManager.load()` is called after `register()` during `open()`. If a
schema was supplied by the caller for a collection, any version in `$meta` for
that same collection is skipped — the in-memory declaration takes precedence.
This prevents a stale or older-device schema from overriding an explicit local
declaration.

## Sync Bypass {#sync-bypass}

Documents that arrive via the sync engine (i.e. written via
`KvStore.writeBatchInternal`) bypass schema validation. Sync ingest writes
directly to the storage engine without going through `KmdbCollection`. This
is intentional: schema versions may differ across devices, and rejecting synced
documents would break replication.

## Schema Model Versioning

The `schemaModelVersion` field in the persisted payload allows KMDB to detect
when a schema was authored by a newer build that supports additional keywords.

`SchemaManager.kSchemaModelVersion` is the highest version this build
understands (currently `1`). When a loaded schema has a higher version, the
`onSchemaVersionMismatch` callback is fired and validation is disabled for that
collection — writes are not incorrectly blocked by keywords this build cannot
interpret.

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  onSchemaVersionMismatch: (collection, storedVersion, supportedVersion) {
    // Prompt the user to update the app.
    print('Schema for "$collection" requires KMDB $storedVersion '
          '(this build supports up to $supportedVersion).');
  },
);
```

## Unique Constraints

Unique constraints are not part of the §25 schema model. They are deferred to
a future iteration. The primary challenge is that enforcing uniqueness requires
a secondary index scan inside the write transaction, which conflicts with the
current synchronous write model (see §18). Additionally, LWW conflict
resolution across devices may temporarily violate a uniqueness constraint
during sync catch-up.

Unique indexes will be tracked on the roadmap when the concurrency model is
extended to support them.
