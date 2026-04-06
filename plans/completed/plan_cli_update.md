# CLI: Support updates

**Status**: Complete

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/7

## Problem statement

In the KMDB CLI, updating an existing document is partially supported but not as
a first-class "update" or "patch" command.

Current Support:

1. Full Document Replacement (via import): The import command is currently the
   only way to update an existing document by its ID. It requires the input JSON
   to have an `_id` field and defaults to a replace strategy.

   ```sh
   # Overwrites the document with ID '019...' with the provided fields 2
   echo '{"`_id`": "019...", "title": "Updated Title", "status": "done"}' | kmdb mydb import notes
   ```

1. The `put` command is actually an "Insert": Although named put (which usually
   implies upsert), the current CLI implementation always generates a new UUIDv7
   key and replaces any `_id` provided in the input. Therefore, it cannot be
   used to update existing records.
1. No Partial Updates: There is currently no way to perform a partial update
   (patching specific fields) without providing the entire document.

To provide comprehensive update functionality, the following changes are
proposed:

1. **Rename `put` → `insert`** (with `put` kept as a deprecated alias). The
   command always generates a new UUIDv7 key and ignores any `_id` in the
   payload — this is insert semantics, not upsert. The rename makes the intent
   unambiguous. `put` continues to work but prints a deprecation warning.

1. **Add an `update` command** (partial field merge). Supports three mutually
   exclusive targeting modes:

   ```sh
   # Single document by positional ID (most common case)
   kmdb <db> update <collection> <id> --set '{"status": "done"}'

   # Multiple specific IDs (repeatable flag)
   kmdb <db> update <collection> --id <id> --id <id> --set '{"status": "done"}'

   # Filter-based (all documents matching the filter)
   kmdb <db> update <collection> --filter '{"field":"active","op":"eq","value":false}' --set '{"archived": true}'

   # All documents (explicit opt-in to prevent accidents)
   kmdb <db> update <collection> --all --set '{"archived": true}'
   ```

   - Merge is shallow (top-level key replacement only).
   - `_id` cannot be overwritten by the `--set` payload.
   - Each document is updated independently — no atomicity guarantee across
     multiple documents.
   - Reports `{"updated": N}` on success.

## Open questions

- [x] Is `put` intentionally insert-only, or is this an oversight?
- [x] Does `import --on-conflict replace` fully cover the full-replacement use
  case, making a `put` upsert redundant?
- [x] Does the CLI layer operate at `KvStoreImpl` directly — meaning
  `KmdbCollection.update` is NOT available, and a `patch` must be implemented
  by hand at the KvStore layer?
- [x] Would a query-update command require a full scan + rewrite loop? Does the
  scan API support this safely?
- [x] Should `put` be renamed? If so, what migration strategy?
- [x] Should single-doc and multi-doc update be one command or two?

## Investigation

### Is `put` intentionally insert-only?

Yes. This is a deliberate design choice, not a bug. The doc comment on
`PutCommand` states explicitly: _"Each document receives a system-generated
UUIDv7 identifier in its `_id` field. Any `_id` supplied by the caller is
replaced."_ The existing test at line 263 of `commands_test.dart` is titled
_"ignores user-provided id and generates a new one"_ and asserts this behaviour.
The command's description is "Insert one or more documents." The semantic naming
is intentional: `put` in the CLI is Insert, not Upsert.

Changing `put` to respect a caller-supplied `_id` would be a breaking change
to documented, tested behaviour. It would also silently promote an arbitrary
string (whatever the user typed as `_id`) into a storage key without format
validation — UUIDv7 key format is enforced at the `KvStore` boundary, so an
invalid key would surface only at the storage write, not at parsing time. This
change would be confusing rather than clarifying.

**Recommendation:** Do NOT change `put`. The description "insert" is accurate
and `import` already covers the upsert use case. If the CLI experience is
confusing, a documentation/help-text improvement is sufficient.

### Does `import` cover the full-replacement case?

Yes, completely. `ImportCommand` with `--on-conflict replace` (the default) does
exactly what a `put`-as-upsert would do: it reads a document with an explicit
`_id` field and writes it to the store under that key, replacing any existing
document. The plan's own example demonstrates this:

```sh
echo '{"_id": "019...", "title": "Updated Title", "status": "done"}' | kmdb mydb import notes
```

This is fully functional today. The only quirk is that `import` is NDJSON-only
(one document per line from stdin or `--input <file>`), so single-document
inline usage is slightly awkward compared to a dedicated command. This is a UX
concern, not a missing capability.

### Does the CLI layer have access to `KmdbCollection.update`?

No. The CLI's `CommandContext.store` is typed as `KvStoreImpl` — the raw,
untyped KvStore layer. `KmdbCollection<T>` lives at the Query Layer (one level
above KvStore), requires a `KmdbCodec<T>`, and is not reachable from the CLI
without restructuring the database-open path.

The CLI operates on `Map<String, dynamic>` documents via `ValueCodec.encode` /
`ValueCodec.decode` directly. A `patch` command must therefore implement the
read-merge-write loop itself at the `KvStoreImpl` level — which is exactly what
the plan proposes in its workflow description. This is straightforward and
correct: read via `ctx.store.get`, decode, merge, encode, write via
`ctx.store.put`. No access to `KmdbCollection.update` is needed or expected.

The plan mentions _"leverage the library's `KmdbCollection.update` capability"_
— this is misleading. The CLI cannot and should not open a `KmdbDatabase` just
to patch a field. The equivalent logic is three lines at the `KvStoreImpl`
level and there is no meaningful benefit to going through the Query Layer here.

### Query-update via scan + rewrite

The `scan` API on `KvStoreImpl` already returns `Stream<KvEntry>` with decoded
keys and raw bytes. `FilterParser.parse` is already implemented and used by
`ScanCommand`. An `update` command could:

1. Scan the collection with a `FilterParser.parse` filter (identical to `scan`).
2. For each matching document, merge the `--set` fields.
3. Write each merged document back via `ctx.store.put`.

This is safe in the synchronous, single-isolate model — no concurrent writes
can interleave within a command execution. The plan's proposed filter DSL syntax
matches the already-implemented `FilterParser` JSON format.

One concern: the plan's `update` command name conflicts with a potential future
`KmdbCollection.update` surface or general terminology. A name like `update-all`
or using `patch --filter` instead would avoid confusion.

### Architecture and secondary index concern

The `ScanCommand` and `PutCommand` bypass the Query Layer entirely and write
directly to `KvStoreImpl` without going through `KmdbDatabase._writeDocument`.
This means **secondary indexes are not updated** when the CLI writes or patches
a document. This is a pre-existing limitation of the CLI design — it operates
below the index manager. The plan does not need to solve this, but it should
acknowledge it: documents written or patched via the CLI will have stale indexes
until the next `KmdbDatabase`-level write or index rebuild.

### Is `put` poorly named?

Yes. `put` always generates a new UUIDv7 key — that is HTTP POST / insert
semantics, not PUT / upsert. The command help text already says "Insert one or
more documents", which makes the mismatch obvious. Renaming to `insert` is the
right call.

Migration strategy: keep `put` as a deprecated alias that prints a warning and
delegates to `InsertCommand`. This avoids breaking existing scripts.

### Should patch/update be one command or two?

One. Splitting "patch one doc" from "update many docs" creates an arbitrary
surface boundary. A single `update` command with mutually exclusive targeting
modes (positional `<id>`, repeatable `--id`, `--filter`, or `--all`) is cleaner
and matches user expectations from tools like `mongosh`. The targeting modes are
mutually exclusive; mixing them is an error.

### Summary of findings

| Proposal | Verdict | Rationale |
|---|---|---|
| Fix `put` to be an upsert | **Reject** | Intentional design; `import` already covers this |
| Rename `put` → `insert` (deprecate `put`) | **Accept** | Name is misleading; help text already says "insert"; migration path preserves compatibility |
| Add `update` command (single + multi + filter) | **Accept** | Genuine gap; one command with mutually exclusive targeting modes; KvStore read-merge-write at the right layer |

## Implementation plan

### 1. Rename `put` → `insert` (deprecate `put`)

- [x] Create `packages/kmdb_cli/lib/src/commands/insert_command.dart` as a
  copy/rename of `put_command.dart` with class `InsertCommand`
  - Command name: `insert`; description: "Insert one or more documents."
  - Behaviour identical to current `PutCommand`
- [x] Update `put_command.dart` to become a thin deprecated wrapper:
  - Prints a deprecation warning to stderr: `` `put` is deprecated, use `insert` ``
  - Delegates to `InsertCommand.execute`
- [x] Register both `InsertCommand` (`insert`) and the deprecated `PutCommand`
  (`put`) in `_commands` in `cli_runner.dart`
- [x] Update `_printUsage` to list `insert` under "Data"; show `put` as
  `put (deprecated — use insert)`
- [x] Update existing `put` tests to cover `insert`; add a test confirming
  `put` still works and emits a deprecation warning

### 2. Add `update` command (single, multi-id, filter, and all-docs)

- [x] Create `packages/kmdb_cli/lib/src/commands/update_command.dart`
  - Signature: `update <collection> [<id>] [--id <id>]... [--filter <json>] [--all] --set <json>`
  - Targeting modes (mutually exclusive — error if more than one is given):
    - Positional `<id>`: update a single document by key
    - `--id <id>` (comma-separated list): update a specific set of documents by key
      (note: the CLI parser only stores one flag value per name; comma-separated
      list is used as a pragmatic alternative to truly repeatable flags)
    - `--filter <json>`: update all documents matching the filter (reuse
      `FilterParser.parse`, same as `ScanCommand`)
    - `--all`: update every document in the collection (explicit opt-in)
  - `--set <json>` is always required; must be a JSON object (reject arrays
    and non-objects)
  - For each targeted document: `ctx.store.get` → `ValueCodec.decode` →
    shallow-merge `--set` fields → `ValueCodec.encode` → `ctx.store.put`
  - `_id` is preserved from the existing document; any `_id` in `--set` is
    silently ignored
  - Merge is shallow (top-level key replacement only; deep/nested merge is
    out of scope)
  - Each document write is independent — no atomicity guarantee across
    multiple documents
  - Report `{"updated": N}` on success
  - Error cases:
    - Missing collection arg
    - No targeting mode given (positional, `--id`, `--filter`, or `--all`
      required)
    - More than one targeting mode given
    - Document not found (positional or `--id` modes) — error with key
    - Missing or invalid `--set` (not a JSON object)
    - Invalid `--filter` JSON
- [x] Register `UpdateCommand` in `_commands` in `cli_runner.dart`
- [x] Add `update` to `_printUsage` under "Data"
- [x] Add tests to `commands_test.dart`:
  - **Single-id mode**: updates one field, adds a new field, preserves
    untouched fields, does not overwrite `_id`, returns false for missing doc
  - **Multi-id mode (`--id`)**: updates all listed docs, returns count,
    errors on any missing key
  - **Filter mode**: updates matching docs only, no-op when nothing matches
    (returns `{"updated": 0}`), does not touch non-matching docs
  - **All-docs mode**: updates every document in the collection
  - **Mutual exclusion**: returns false when two targeting modes are combined
  - **`--set` validation**: returns false when missing, invalid JSON, or a
    JSON array
  - **`--filter` validation**: returns false on invalid JSON
  - **Empty collection**: all-docs and filter modes return `{"updated": 0}`

### 3. Documentation and help text

- [x] Update `_printUsage` in `cli_runner.dart` with `insert` and `update`
  under the "Data" section; mark `put` deprecated
- [x] Check `docs/spec/` for a CLI command reference — no spec file exists for
  CLI commands; no changes required
- [x] Update `packages/kmdb_cli/README.md`:
  - Rename the `put` section to `insert`; add a deprecation note under `put`
    pointing to `insert`
  - Add an `update` section under Data commands documenting all four targeting
    modes (positional `<id>`, `--id`, `--filter`, `--all`) and the `--set` flag,
    with a flags table and usage examples for each mode
  - Update the quick-start example block at the top to use `insert` instead
    of `put`
  - Update the Script files example (uses `put`) to use `insert`

### Notes

- All commands operate at `KvStoreImpl` level. Secondary indexes defined via
  `KmdbDatabase.collection` will not be updated — consistent with `put` /
  `import`. Note this in command doc comments.
- Merge strategy is shallow (top-level key replacement). This should be stated
  clearly in the `update` command doc comment so callers are not surprised when
  patching a nested object replaces the whole nested object.
- No atomicity across multi-document updates. Each `put` is independent.
  Callers requiring atomicity must use the library API directly.

## Summary

- Created `InsertCommand` (`insert_command.dart`) with identical behaviour to
  the original `PutCommand`: generates a fresh UUIDv7 key, ignores any
  caller-supplied `_id`, and accepts JSON/array/NDJSON input from `--value`,
  `--file`, or stdin.
- Replaced `PutCommand` with a thin deprecated wrapper that prints
  `Warning: 'put' is deprecated, use 'insert' instead.` to stderr and delegates
  to `InsertCommand`. The `put` command continues to work for backward
  compatibility.
- Both commands registered in `cli_runner.dart`; help text updated to list
  `insert` and `update` prominently and mark `put` as deprecated.
- Created `UpdateCommand` (`update_command.dart`) supporting four mutually
  exclusive targeting modes:
  - Positional `<id>` — single document
  - `--id <id1,id2,...>` — comma-separated list of IDs (pragmatic alternative
    to repeatable flags, given the CLI parser stores only one value per flag name)
  - `--filter <json>` — filter-based scan using the existing `FilterParser`
  - `--all` — every document in the collection
- `UpdateCommand` performs a shallow merge (top-level key replacement only),
  always preserves `_id`, reports `{"updated": N}` on success, and operates at
  the `KvStoreImpl` layer (consistent with `insert` and `import`; secondary
  indexes are not updated).
- Added 38 new tests covering all targeting modes, mutual exclusion, `--set`
  validation, `--filter` validation, missing documents, empty collections, and
  shallow-merge semantics. All 102 tests in `commands_test.dart` pass.
- Updated `packages/kmdb_cli/README.md`: new `insert` and `update` sections with
  flags tables and examples; deprecated `put` section; updated quick-start and
  script-file examples to use `insert`.
