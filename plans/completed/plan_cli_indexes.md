# Add index commands and collection commands to the CLI

**Status**: Implementing

**PR link**: https://github.com/aurochs-kmesh/kmdb/pull/11

## Problem statement

Most of the kmdb functionality is available via the CLI but the ability to
create and delete [secondary indexes](../docs/spec/16_secondary_indexes.md) is
missing. This plan looks to add the ability to create, delete and get info on
indexes in a given collection.

Indexes are created within collections and are used to improve search
(filtering) latency. As no schema is enforced in a collection, indexes may not
align to all documents in a collection as it's reasonable to assume that a user
search for a specific value doesn't want to search for things without a value.
However, a search for documents that have a no/null value is basically a search
for documents not in the index. See also "Missing vs Null Semantics" in the
Filter DSL specification.

There is currently two collection-specific commands and consideration needs to
be made as to if the CLI ergonomics can be improved as part of this work:

- `create-collection`: To create an empty collection
- `collections`

The scope of this plan is focussed on indexing fields to support the filter DSL
for querying. The [Hybrid Text Search Engine](../docs/proposals/text_search.md)
looks at full-text search facilities for improved search within a field - any
design should be mindful of this roadmap item but maintain the scope described
here.

A smaller aspect to this plan is to provide the ability to delete a collection
via the CLI. This deletion would also delete all documents in the collection.
The work is presented in this plan as it can be bundled with the index-based
work as it also operates at the collection level.

## Open questions

All questions resolved — see Investigation section.

## Investigation

### How are indexes synchronized?

**Index definitions and content are intentionally not synchronized.**

The `$meta` namespace (where index state lives, keyed as
`index:{namespace}:{path}`) and the `$index:*` namespaces (where index entries
live) are both system namespaces prefixed with `$`. The sync engine explicitly
filters these out during SSTable upload — only user namespaces are synced (see
`packages/kmdb/lib/src/sync/sync_engine.dart`).

This is by design and clearly stated in spec §12: index data is device-local.
When a device pulls SSTables from a remote, the documents arrive in user
namespaces and are indexed locally on the next query. In practice:

- **Index definitions** (the `IndexDefinition` list at `KmdbDatabase.open()`)
  must be re-supplied on each open. They are not stored in a synced location.
- **Index entries** (`$index:*`) are built locally from the locally-held
  documents. After a sync pull, any indexes in `current` state may transition to
  `stale` (generation mismatch) and will be rebuilt on next query.
- The spec does not currently document this behaviour explicitly in §16 — a spec
  clarification note is worth raising.

### What's the best command line structure?

**A critical architectural constraint shapes this decision:** the CLI currently
opens `KvStoreImpl` directly, bypassing the Query Layer and its `IndexManager`
(see `packages/kmdb_cli/lib/src/database_opener.dart`). Index definitions are
supplied to `KmdbDatabase.open()` as a `List<IndexDefinition>` and are not
persisted by the library itself. The CLI would therefore need to:

1. **Persist index definitions** in a CLI-managed config file (natural fit:
   `local/config.json`, which already stores remote configuration).
2. **Load those definitions** when opening the database so `IndexManager` can
   maintain them across sessions.

Given this, the flat subcommand pattern used by the existing `remote` command is
the recommended approach for collections and indexes:

```
# Collection commands (replacing/extending current commands)
kmdb <db> collections list
kmdb <db> collections create <name>
kmdb <db> collections delete <name>

# Index commands
kmdb <db> index list <collection>
kmdb <db> index create <collection> <path>
kmdb <db> index info <collection> <path>
kmdb <db> index delete <collection> <path>
```

This uses the plural `collections` for collection management (as a top-level
command with subcommands, extending the existing `collections` command) and the
singular `index` for index management. Keeping `index` flat avoids the
"telescoping" problem (`collections <name> indexes ...`) where a user-supplied
collection name could shadow the `indexes` keyword.

**Naming notes:**

- The existing `collections` command becomes a subcommand dispatcher (like
  `remote`). The existing `create-collection` command can be retained as an
  alias or removed.
- Path arguments (dot-notation, e.g. `address.city` or `tags[]`) should be
  clearly distinguished from positional args in usage strings.
- Shell quoting guides should accompany `tags[]` examples since `[]` has special
  meaning in some shells.

### Should composite indexes be supported?

**No — defer to later schema work.**

`IndexDefinition` accepts a single `path` string. The entire index entry key
encoding (§16) is designed around one value per entry. Supporting composite
indexes would require a new key encoding scheme (concatenating multiple encoded
values), a new API surface, and coordination with future schema work. The
incremental benefit for the CLI CRUD commands is low. Single-field and array
fan-out indexes (e.g. `tags[]`) cover the common filtering use-cases.

### Should we maintain index stats?

**No additional stats infrastructure is needed for this plan.**

The existing `IndexState` (status, `builtThrough`, `builtAt`) is sufficient to
implement a useful `index info` command. For the small-to-medium databases KMDB
targets, and given that write interception is synchronous and co-located with
the document write, the risk of index degradation is low. Stats can be revisited
when the benchmarking roadmap item is addressed.

### Should we support `unique`, `not null` or filtered indexes?

**No — explicitly out of scope.**

The current write path silently skips null/missing values (no index entry
written) and there is no enforcement mechanism. Unique and `not null`
constraints belong to a future schema layer. The `IndexDefinition` model should
not be extended in this plan.

### Additional open questions

#### How does `index delete` clean up index data?

`IndexManager` needs a new `removeIndex(namespace, path)` method. Removing an
index requires:

1. Removing the definition from the CLI config so it is no longer passed to the
   `IndexManager` on next open.
2. Scanning and deleting all entries in the corresponding `$index:{ns}:{path}`
   namespace.
3. Deleting the `$meta` state entry (`index:{namespace}:{path}`).

This method will be needed by both `index delete` and `collections delete`
(which cascades to all indexes on the collection).

#### Does the CLI need to open `KmdbDatabase` or just `KvStoreImpl`?

Index commands that read or build index state need `IndexManager`, which
requires either:

- Opening via `KmdbDatabase` (adds a `KmdbCodec` dependency — the CLI currently
  avoids typed codecs), or
- Instantiating `IndexManager` directly on top of the `KvStoreImpl` the CLI
  already opens (requires the CLI to persist and load `IndexDefinition`
  objects).

The second approach is more self-contained and avoids changing how the CLI opens
the database. The CLI config (`local/config.json`) should be extended to store
index definitions as `{namespace, path}` pairs.

#### What happens to index definitions when `collections delete` is called?

Deleting a collection will also cascade to delete all associated index
definitions from the CLI config and all `$index:*` and `$meta` entries via the
new `IndexManager.removeIndex` method. Ordering: remove collection documents
first, then remove each index (config + storage entries).

#### What happens on Device B when Device A deletes a collection and syncs?

When `SyncEngine` ingests SSTables on Device B, it calls `ingestSstable`
directly — this bypasses the `KvStore` write path entirely. No `IndexManager`
intercept fires, no generation counters are updated, and Device B's `$meta`
namespace registry and `$index:*` entries are untouched. After the pull:

- All documents in the collection are tombstoned (correct)
- The namespace still appears in `collections list` on Device B (stale registry)
- The `$index:*` entries on Device B now point to tombstoned document keys
  (orphaned)
- The CLI `local/config.json` on Device B still holds the index definitions

There is no collection-level delete signal in the sync protocol, so Device B
cannot automatically detect that a collection was intentionally deleted rather
than having its documents individually removed.

**Fix:** the `pull` and `sync` commands must run a post-ingest check: for each
namespace that has index definitions in the CLI config, scan for live
(non-tombstoned) documents. If zero live documents remain and the namespace was
previously registered, trigger the same cascade as `collections delete` (purge
index entries, remove from config, unregister from `$meta`). This check is
scoped only to namespaces with configured indexes, so it has no impact on
unindexed collections.

## Implementation plan

The work falls into six sequential phases. Later phases depend on earlier ones,
so they must be completed in order.

### Phase 1 — `MetaStore.unregisterNamespace` (kmdb package)

`collections delete` must remove the collection from the namespace registry and
delete its generation counter, otherwise the deleted collection keeps appearing
in `collections list`. `MetaStore` has `registerNamespace` but no inverse.

- [x] Add `unregisterNamespace(String userNamespace)` to `MetaStore`:
  - Read the current namespaces list via `getNamespaces()`
  - Remove the entry, write the updated list back
  - Delete the generation counter entry (`gen:{namespace}`) from `$meta`
- [x] Tests:
  - Unregistering an existing namespace removes it from `getNamespaces()`
  - Unregistering removes the generation counter
  - Unregistering a namespace not in the registry is a no-op (does not throw)
  - Other namespaces are unaffected

### Phase 2 — `IndexManager.removeIndex` (kmdb package)

Needed by both `index delete` and `collections delete` (which cascades). No
equivalent method currently exists.

- [x] Add `Future<void> removeIndex(String namespace, String path)` to
      `IndexManager`:
  - Scan the `$index:{namespace}:{path}` system namespace and collect all keys
  - Delete all index entries in a `WriteBatch` (batch in groups of 200 to avoid
    oversized write batches on large indexes)
  - Delete the `$meta` state entry (`index:{namespace}:{path}`) via
    `MetaStore.indexKey`
- [x] Tests:
  - All `$index:*` entries for the index are gone after removal
  - The `$meta` state entry is gone after removal
  - No-op if the index was never built (undefined state)
  - Other indexes on the same collection are unaffected
  - Other collections are unaffected

### Phase 3 — `KmdbConfig` index storage (kmdb_cli package)

Index definitions must survive across CLI sessions. `local/config.json` is the
natural home — it already stores per-machine, non-synced state (remotes).

- [x] Extend `KmdbConfig` to hold a list of index records using "collection" as
      the user-facing term (the kmdb library uses "namespace" internally, but
      the CLI config speaks the user's language):
  ```json
  {
    "remotes": { ... },
    "indexes": [
      { "collection": "contacts", "path": "address.city" },
      { "collection": "contacts", "path": "tags[]" }
    ]
  }
  ```
- [x] Update `KmdbConfig.load` to parse the `indexes` array (missing key → empty
      list; invalid entry → `FormatException`)
- [x] Update `KmdbConfig.save` to serialise the `indexes` array
- [x] Add `addIndex(String collection, String path)`:
  - Throws `ArgumentError` if an identical definition already exists
- [x] Add `removeIndex(String collection, String path)`:
  - Throws `ArgumentError` if the definition does not exist
- [x] Add `indexesForCollection(String collection)` returning
      `List<({String collection, String path})>`
- [x] Add `get indexes` returning an unmodifiable view of all index records
- [x] When constructing `IndexDefinition` objects from config entries, map
      `collection` → `namespace` at the boundary in `cli_runner.dart`
- [x] Tests:
  - Round-trip serialisation (write then load)
  - Load with no `indexes` key (backwards compatibility)
  - `addIndex` / `removeIndex` mutation and error cases
  - `indexesForCollection` filtering

### Phase 4 — `CommandContext` wiring (kmdb_cli package)

`IndexManager` and `KmdbConfig` need to be accessible to commands. The cleanest
approach is to add them to `CommandContext` so commands remain easily testable.

- [x] Add `config` (`KmdbConfig`) and `indexManager` (`IndexManager`) fields to
      `CommandContext`
- [x] In `cli_runner.dart`, after opening the store:
  - Load `KmdbConfig` from `{dbDir}/local/config.json`
  - Construct `IndexManager` from `config.indexes` mapped to `IndexDefinition`
    objects
  - Pass both into `CommandContext`
- [x] Update `CommandContext` constructor and all existing tests that build a
      `CommandContext` (supply a default empty config and empty-definition
      `IndexManager`)

### Phase 5 — Refactor `CollectionsCommand` (kmdb_cli package)

Convert the existing flat command into a subcommand dispatcher, following the
`RemoteCommand` pattern. Add `delete` with index cascade.

- [x] Rewrite `CollectionsCommand` as a subcommand dispatcher with three
      subcommands:
  - `list` — existing behaviour: call `ctx.store.listNamespaces()` and print
  - `create <name>` — existing `create-collection` behaviour: call
    `ctx.store.createNamespace(name)` and print result
  - `delete <name>` — new:
    1. Scan the collection (namespace) via `ctx.store.scan(name)` and delete all
       keys in batches of 200 via `WriteBatch`
    2. For each index in `ctx.config.indexesForCollection(name)`: call
       `ctx.indexManager.removeIndex(name, path)`
    3. Remove index definitions for the collection from `ctx.config` and save
    4. Call `MetaStore.unregisterNamespace(name)` (via `ctx.store`) to remove
       the collection from `$meta`
- [x] Update `CollectionsCommand.usage` and `description`
- [x] Add a deprecation notice to `CreateCollectionCommand` — print a one-line
      stderr warning on every execution:
      `"create-collection is deprecated; use 'collections create <name>' instead."`
- [x] Tests:
  - `collections list` returns registered namespaces
  - `collections create` creates a namespace (idempotent)
  - `collections delete` removes all documents in the namespace
  - `collections delete` cascades to remove index entries and config entries
  - `collections delete` unregisters the namespace from `$meta`
  - `collections delete` on an unknown namespace returns a clear error
  - All subcommand error paths (missing args, etc.)

### Phase 6 — New `IndexCommand` (kmdb_cli package)

A new top-level `index` command with four subcommands.

- [x] Create `packages/kmdb_cli/lib/src/commands/index_command.dart`
      implementing `IndexCommand` as a subcommand dispatcher:
  - `index list <collection>` — load
    `ctx.config.indexesForCollection(collection)`; for each, call
    `ctx.indexManager.getState(collection, path)` and print a row with path and
    status
  - `index create <collection> <path>` — validate `path` does not start with
    `_`; call `ctx.config.addIndex(collection, path)`; save config; print
    confirmation
  - `index info <collection> <path>` — call
    `ctx.indexManager.getState(collection, path)`; print path, status,
    `builtThrough`, `builtAt`
  - `index delete <collection> <path>` — call
    `ctx.indexManager.removeIndex(collection, path)`; call
    `ctx.config.removeIndex(collection, path)`; save config; print confirmation
- [x] Register `IndexCommand` in `_commands` map in `cli_runner.dart`
- [x] Tests:
  - `index list` with no indexes defined returns empty output
  - `index list` shows defined indexes and their status
  - `index create` adds definition to config; is idempotent-error on duplicate
  - `index create` rejects paths starting with `_`
  - `index info` shows correct status for undefined/built indexes
  - `index delete` removes entries and config definition
  - `index delete` on a non-existent index returns a clear error
  - All subcommand error paths (missing args, unknown collection, etc.)

### Phase 7 — Post-sync index cleanup (kmdb_cli package)

When Device B pulls SSTables that contain tombstones for all documents in a
collection, its local index entries and config become orphaned. The `pull` and
`sync` commands must detect this and cascade the same cleanup as
`collections delete`.

- [x] Extract a helper `_purgeOrphanedIndexes(CommandContext ctx)`:
  - For each collection that has index definitions in `ctx.config`:
    - Scan the collection for any live document — stop at the first hit
    - If zero live documents exist and the collection is registered in `$meta`:
      cascade cleanup exactly as `collections delete` does (purge index entries
      via `IndexManager.removeIndex`, remove definitions from config, save,
      unregister collection from `$meta`)
- [x] Call `_purgeOrphanedIndexes` at the end of `PullCommand.execute` and
      `SyncCommand.execute`, after the ingest completes
- [x] Tests:
  - After a pull that tombstones all documents in an indexed collection, index
    entries are gone, config is updated, collection is unregistered
  - A collection with at least one live document after pull is unaffected
  - A collection with no configured indexes is unaffected (no scan performed)
  - Cleanup runs correctly when multiple collections are affected in one pull

### Phase 8 — Spec update

- [x] Add a note to `docs/spec/16_secondary_indexes.md` clarifying that index
      state (`$meta`) and index entries (`$index:*`) are system namespaces
      excluded from sync. After a pull, `current` indexes may become `stale` and
      will rebuild on next query.

## Summary

- Added `MetaStore.unregisterNamespace` to remove a collection from the
  namespace registry and delete its generation counter when a collection is
  deleted.
- Added `IndexManager.removeIndex(namespace, path)` to atomically purge all
  `$index:*` entries and the `$meta` index state entry for a given index.
- Extended `KmdbConfig` (`local/config.json`) to persist index definitions using
  "collection" as the user-facing term; added `addIndex`, `removeIndex`,
  `indexesForCollection`, and an `indexes` accessor.
- Exported `IndexManager`, `IndexState`, and `IndexStatus` from `kmdb.dart` so
  CLI code can use them without internal `src/` imports.
- Wired `KmdbConfig` and `IndexManager` into `CommandContext`; both are loaded
  from the persisted config on every CLI open.
- Refactored `CollectionsCommand` into a subcommand dispatcher (`list`,
  `create`, `delete`); `delete` cascades to remove all index entries and config
  definitions, then unregisters the collection from `$meta`.
- Added a deprecation warning to `create-collection`, directing users to
  `collections create`.
- Added a new `IndexCommand` with four subcommands: `list`, `create`, `info`,
  and `delete`.
- Added post-sync orphan cleanup to `PullCommand` and `SyncCommand`: after
  ingesting SSTables, any indexed collection with zero live documents is
  automatically cleaned up (index entries purged, config updated, namespace
  unregistered).
- Updated spec §16 to document that index state and index entries are
  device-local and excluded from sync.
- Added 248 new tests across both packages (960 total; 31 pre-existing Zstd FFI
  environment failures unchanged).
