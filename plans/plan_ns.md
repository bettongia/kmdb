# Plan: Namespace vs. Collection Clarification

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

This plan addresses the interchangeable use of "namespace" and "collection"
across the KMDB codebase, CLI, and documentation. The goal is to establish a
clear terminological hierarchy and reflect it in the user-facing surfaces.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

### 1. Terminological Standard

We will adopt the following definitions:

- **Collection**: A high-level, user-facing, typed logical partition of
  documents. This is the primary concept for application developers.
- **Namespace**: A low-level, untyped storage partition in the LSM engine. Every
  collection corresponds to a namespace of the same name.
- **System Namespace**: Internal partitions (prefixed with `$`, e.g., `$meta`,
  `$index`) used by the engine. These are **not** collections.

### 2. API Refinement (`packages/kmdb`)

To align with the high-level Query Layer's intent, we will update the following:

- **`KmdbDatabase.collection`**: Rename the `namespace` parameter to `name`.
  - _Current_: `db.collection(namespace: 'tasks', ...)`
  - _Proposed_: `db.collection(name: 'tasks', ...)`
- **`KmdbCollection`**: Keep the `namespace` property as it refers to the
  underlying storage identifier, but update doc comments to emphasize it as the
  collection's unique name.
- **`IndexDefinition`**: Keep `namespace` as it's a technical link to the
  storage layer, but update doc comments.

### 3. CLI Harmonization (`packages/kmdb_cli`)

The CLI is where the most visible friction exists. We will update all commands
to use `collection` as the primary term for user-facing partitions.

- **Command Usage**: Update positional argument labels from `<namespace>` to
  `<collection>`.
  - `get <collection> <key>`
  - `put <collection> [--value <json>]`
  - `delete <collection> <key>`
  - `scan <collection> [options]`
  - `count <collection> [--filter <json>]`
  - `import <collection> [options]`
  - `export <collection> [--output <file>]`
- **`collections` command**: Keep this name as it's the standard term for
  listing document partitions. Update its description to "List all user
  collections in the database."
- **Help Text**: Update all `--help` descriptions to use "collection"
  consistently.

### 4. Documentation Updates

- **`README.md`**: Add a "Terminology" section explaining the difference between
  Collections and Namespaces.
- **`CLAUDE.md`**: Update the "Query Layer" section to use "collection" as the
  primary term.
- **`docs/spec/13_query_api.md`**: Update the spec to reflect the parameter
  rename in `KmdbDatabase.collection`.

### 5. Verification

- Ensure all tests pass after renaming parameters.
- Verify that `kmdb --help` shows `<collection>` for all data commands.
- Check that system namespaces remain inaccessible via the standard
  `collections` command (already true in `KvStore.listNamespaces`).

---

**Note**: This is a non-breaking change for the storage format, as the string
identifiers themselves do not change. It is a minor breaking change for the
Query Layer API (parameter rename) and the CLI help interface.

## Implementation plan

### 1. `packages/kmdb` — Query Layer API

- [ ] **`kmdb_database.dart`**: Rename the `namespace` parameter to `name` in
  `KmdbCollection<T> collection<T>({required String namespace, ...})`. Update
  the forwarding call to `KmdbCollection<T>(namespace: name, ...)` so the
  internal wiring stays correct. Update the two doc-comment references to
  `[namespace]` on the same method (lines 138 and 141).
- [ ] **`kmdb_collection.dart`**: Keep `final String namespace` as-is. Update
  the class-level doc-comment example (line 57) from
  `db.collection(namespace: 'tasks', ...)` to `db.collection(name: 'tasks', ...)`
  and revise the `namespace` property doc comment (line 71) to clarify it is the
  collection's unique storage identifier, not a user-facing label.
- [ ] **`index_definition.dart`**: Keep `final String namespace` as-is. Update
  its doc comment (line 49) to describe it as the storage-layer identifier for
  the collection this index belongs to.

### 2. `packages/kmdb_cli` — CLI commands

Update each of the following command files to replace every occurrence of
`<namespace>` with `<collection>` in usage strings, description strings, and
error messages (e.g. `'<namespace> argument is required'`):

- [ ] `get_command.dart`
- [ ] `put_command.dart`
- [ ] `delete_command.dart`
- [ ] `scan_command.dart`
- [ ] `count_command.dart`
- [ ] `import_command.dart`
- [ ] `export_command.dart`

- [ ] **`collections_command.dart`**: Update the class doc comment (line 17)
  from "Lists all user-visible namespaces (collections)" to
  "Lists all user collections in the database." Update the `description` getter
  (line 28) from `'List all collections (namespaces) in the database.'` to
  `'List all user collections in the database.'`

### 3. Tests

8 occurrences of `db.collection(namespace:` across 5 test files need updating
to `db.collection(name:`:

- [ ] `test/query/kmdb_query_test.dart` (3 occurrences)
- [ ] `test/query/index_test.dart` (2 occurrences)
- [ ] `test/query/kmdb_collection_test.dart` (1 occurrence)
- [ ] `lib/src/query/kmdb_database.dart` (1 — the call site, handled in step 1)
- [ ] `lib/src/query/kmdb_collection.dart` (1 — the doc example, handled in step 1)

### 4. Documentation

- [ ] **`docs/spec/13_query_api.md`**: Update the `KmdbCollection<T>` section
  heading example (line 55) from `db.collection(namespace: '...', codec: ...)` to
  `db.collection(name: '...', codec: ...)`. The `onIndexReady(namespace, path)`
  callback parameter name can remain `namespace` — it is emitted by the index
  system and refers to the storage identifier.
- [ ] **`README.md`**: Add a "Terminology" section (after the intro, before
  Getting Started) explaining:
  - **Collection** — user-facing typed document partition; the primary concept
    for application code.
  - **Namespace** — the underlying LSM storage partition. Each collection maps
    1-to-1 to a namespace of the same name. System namespaces (`$meta`,
    `$index:…`, `$cache`) are internal and are not surfaced as collections.
- [ ] **`CLAUDE.md`** Query Layer section: replace the reference
  `namespace: '...'` in any code examples with `name: '...'`.

### 5. Verification

- [ ] `dart analyze packages/kmdb` — zero issues
- [ ] `dart analyze packages/kmdb_cli` — zero issues
- [ ] `dart test packages/kmdb` — all tests pass
- [ ] `dart test packages/kmdb_cli` — all tests pass
- [ ] `kmdb --help` shows `<collection>` (not `<namespace>`) for all data
  commands
- [ ] `kmdb <db> collections --help` shows the updated description

## Summary

{Dot points highlighting the work undertaken}
