# Plan: Namespace vs. Collection Clarification

This plan addresses the interchangeable use of "namespace" and "collection" across the KMDB codebase, CLI, and documentation. The goal is to establish a clear terminological hierarchy and reflect it in the user-facing surfaces.

## 1. Terminological Standard

We will adopt the following definitions:

- **Collection**: A high-level, user-facing, typed logical partition of documents. This is the primary concept for application developers.
- **Namespace**: A low-level, untyped storage partition in the LSM engine. Every collection corresponds to a namespace of the same name.
- **System Namespace**: Internal partitions (prefixed with `$`, e.g., `$meta`, `$index`) used by the engine. These are **not** collections.

## 2. API Refinement (`packages/kmdb`)

To align with the high-level Query Layer's intent, we will update the following:

- **`KmdbDatabase.collection`**: Rename the `namespace` parameter to `name`.
  - *Current*: `db.collection(namespace: 'tasks', ...)`
  - *Proposed*: `db.collection(name: 'tasks', ...)`
- **`KmdbCollection`**: Keep the `namespace` property as it refers to the underlying storage identifier, but update doc comments to emphasize it as the collection's unique name.
- **`IndexDefinition`**: Keep `namespace` as it's a technical link to the storage layer, but update doc comments.

## 3. CLI Harmonization (`packages/kmdb_cli`)

The CLI is where the most visible friction exists. We will update all commands to use `collection` as the primary term for user-facing partitions.

- **Command Usage**: Update positional argument labels from `<namespace>` to `<collection>`.
  - `get <collection> <key>`
  - `put <collection> [--value <json>]`
  - `delete <collection> <key>`
  - `scan <collection> [options]`
  - `count <collection> [--filter <json>]`
  - `import <collection> [options]`
  - `export <collection> [--output <file>]`
- **`collections` command**: Keep this name as it's the standard term for listing document partitions. Update its description to "List all user collections in the database."
- **Help Text**: Update all `--help` descriptions to use "collection" consistently.

## 4. Documentation Updates

- **`README.md`**: Add a "Terminology" section explaining the difference between Collections and Namespaces.
- **`CLAUDE.md`**: Update the "Query Layer" section to use "collection" as the primary term.
- **`docs/spec/13_query_api.md`**: Update the spec to reflect the parameter rename in `KmdbDatabase.collection`.

## 5. Verification

- Ensure all tests pass after renaming parameters.
- Verify that `kmdb --help` shows `<collection>` for all data commands.
- Check that system namespaces remain inaccessible via the standard `collections` command (already true in `KvStore.listNamespaces`).

---

**Note**: This is a non-breaking change for the storage format, as the string identifiers themselves do not change. It is a minor breaking change for the Query Layer API (parameter rename) and the CLI help interface.
