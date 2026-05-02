# Flutter UI — CLI Feature Parity

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

See also:

- [plan_cli_repl.md](completed/plan_cli_repl.md)
- [plan_kmdb_config.md](plan_kmdb_config.md) — prerequisite: `KmdbConfig` must move to `kmdb` before Phase 2
- [plan_flutter_ui_mobile.md](plan_flutter_ui_mobile.md)
- [docs/roadmap/0_02.md](../docs/roadmap/0_02.md)

## Problem statement

The `kmdb_ui` Flutter package is a macOS-only desktop browser in early state. It
covers roughly 5–6 of the ~27 CLI surface-area operations. The roadmap goal
(v0.02) is a UI that works on mobile as well as desktop, as a functional and
integration validation vehicle for the KMDB engine on those platforms.

This plan:

1. Analyses every CLI command against current UI coverage (gap analysis).
2. Assesses mobile (iOS/Android) feasibility given the native FFI stack.
3. Defines a phased implementation roadmap to bring the Flutter UI to full parity
   with the document-focused CLI command set (matching the REPL scope, not the
   batch-only maintenance commands).

---

## Open questions

- [x] **Scope: maintenance commands**: The UI should expose all maintenance
      commands (`flush`, `compact`, `verify`, `stats`, `info`, `new-device-id`).
      `init` maps to "New Database" in the File menu and does not need a separate
      UI entry point.
- [x] **Scope: vault**: The UI shows vault URIs as plain links in the document
      detail view. No file/image rendering.
- [x] **Scope: sync on mobile**: Moved to
      [plan_flutter_ui_mobile.md](plan_flutter_ui_mobile.md). May need to wait
      for cloud-based sync drivers (e.g. Google Drive) before mobile sync is
      practical.
- [x] **`local/config.json` access from UI**: `KmdbConfig` must move from
      `kmdb_cli` into the `kmdb` package (Option A) so that the UI and future
      clients can use it without depending on the CLI. This is tracked in
      [plan_kmdb_config.md](plan_kmdb_config.md) and is a prerequisite for the
      search and index management phases of this plan.

---

## Investigation

### CLI command surface (full)

| Command | Sub-operations | REPL scope |
|:---|:---|:---|
| `get` | get a document by key | yes |
| `insert` | insert a new document (with optional vault import) | yes |
| `update` | partial update: by id / --id / --filter / --all | yes |
| `delete` | delete a document by key | yes |
| `scan` | list docs with --filter, --order-by, --limit, --offset, --select, --explain | yes |
| `count` | count documents in a collection | yes |
| `collections` | list / create / delete collections | yes |
| `export` | export a collection to NDJSON | yes |
| `import` | import NDJSON into a collection | yes |
| `dump` | dump all collections to NDJSON | yes |
| `restore` | restore all collections from an NDJSON dump | yes |
| `schema` | set / show / list / remove / validate | yes |
| `search` | query (lexical/semantic/hybrid) + list/create/delete FTS indexes | yes |
| `index` | list / create / info / delete secondary indexes | yes |
| `vault get` | fetch a vault blob by URI | yes |
| `remote` | add / remove / list sync remotes | yes |
| `push` | push local SSTables to remote | yes |
| `pull` | pull peer SSTables from remote | yes |
| `sync` | push + pull in one step | yes |
| `flush` | force memtable flush | no (maintenance) |
| `compact` | run full compaction | no (maintenance) |
| `verify` | verify data integrity | no (maintenance) |
| `stats` | show storage statistics | no (maintenance) |
| `info` | show device id, HLC, db dir | no (maintenance) |
| `init` | initialise a new database on disk | no (maintenance) |
| `new-device-id` | rotate the device identity | no (maintenance) |

### Gap analysis — current UI coverage

| CLI feature | UI status | Notes |
|:---|:---|:---|
| Open/create database | Implemented | File picker + NewDatabaseDialog |
| Recent databases list | Implemented | Persisted via shared_preferences |
| List collections (with count) | Implemented | CollectionListColumn |
| Create collection | Implemented | NewCollectionDialog |
| Delete collection | **Missing** | CLI: `collections delete` |
| Scan/browse documents | Partial | In-memory string filter only; no server-side filter, no order-by, no pagination |
| Document detail view (read-only JSON) | Implemented | flutter_json_view, collapsible |
| Insert document | Implemented | AddDocumentDialog (raw JSON textarea) |
| Delete document | Implemented | Confirmation dialog |
| Update/edit document | **Missing** | No edit UI |
| Get document by key | **Missing** | No direct key lookup |
| Scan --filter (server-side) | **Missing** | CollectionProvider does full scan + in-memory filter |
| Scan --order-by, --limit, --offset | **Missing** | |
| Scan --explain | **Missing** | |
| Export collection to NDJSON | **Missing** | |
| Import NDJSON into collection | **Missing** | |
| Dump all collections | **Missing** | |
| Restore from dump | **Missing** | |
| Schema management (set/show/list/remove/validate) | **Missing** | |
| Secondary index management | **Missing** | |
| FTS search (lexical) | **Missing** | Only in-memory string filter |
| Semantic / hybrid search | **Missing** | |
| Vault (get, import) | **Missing** | |
| Sync (push/pull/sync) | **Missing** | |
| Remote management | **Missing** | |
| Database info / stats panel | **Missing** | |
| Theme switching (light/dark/system) | Implemented | |
| macOS security-scoped bookmarks | Implemented | AppDelegate.swift |

### Architecture notes

**State management**: The current app uses `Provider` with `DatabaseProvider`
(database/collection/document selection) and `CollectionProvider` (document list
for selected collection). This is adequate for desktop but needs extension for
new features.

**`local/config.json` dependency**: FTS index definitions and secondary index
definitions live in `local/config.json`, currently only parsed by `kmdb_cli`.
`KmdbConfig` will be moved to the `kmdb` package (see
[plan_kmdb_config.md](plan_kmdb_config.md)) so the UI can import it directly.

**Scan filtering**: `CollectionProvider.loadDocuments` currently calls
`store.scan(collectionName)` and filters in-memory. Server-side filtering should
use `KmdbDatabase.rawCollection()` → `KmdbCollection.where(filter)`, which is
available via the public `kmdb` API.

**Document editing**: The UI stores raw `Map<String, dynamic>` as the selected
document. An edit flow needs an intermediate editing state and a save action that
calls `store.put(collection, key, ValueCodec.encode(updated))`.

**Responsive layout**: `_HomePageState` uses a horizontal `SingleChildScrollView`
with four resizable columns. This must be replaced with a navigator-based layout
that degrades to a single-column stack on narrow (mobile) screens.

Mobile feasibility is covered in [plan_flutter_ui_mobile.md](plan_flutter_ui_mobile.md),
which depends on this plan as a prerequisite.

---

## Implementation plan

### Phase 0 — Foundation (prerequisites for all later phases)

- [ ] **Responsive layout scaffold**: Replace the fixed 4-column horizontal scroll
      with an adaptive layout:
  - Wide (>= 900 px): keep the existing multi-column side-by-side layout.
  - Narrow (< 900 px): `Navigator`-based push model (collection list → document
    list → detail).
  - Create `lib/layout/adaptive_layout.dart` with `LayoutBreakpoints` const and
    an `AdaptiveColumnLayout` widget that switches between the two modes.
  - Guard `PlatformMenuBar` behind `defaultTargetPlatform == TargetPlatform.macOS`.

- [ ] **Server-side scan in `CollectionProvider`**: Replace full in-memory scan
      with `KmdbCollection.where(filter).get()` (filtered) and
      `KmdbCollection.all().get()` (unfiltered), via a `ScanOptions` value object
      (filter, orderBy, descending, limit, offset).

- [ ] **`AppProvider`**: New top-level provider exposing `KmdbDatabase` (not just
      `KvStore`) to downstream consumers. Required for schema, index, and FTS
      operations.

- [ ] **Error handling pattern**: Standardise on a `SnackBarService` or
      `ErrorProvider` for surfacing operation errors as dismissable snackbars.
      Currently errors silently inject `{'error': '...'}` documents into the list.

- [ ] **Widget test infrastructure**: Add widget test stubs for the two provider
      classes using `MemoryStorageAdapter` from the `kmdb` package.

### Phase 1 — Document CRUD parity

- [ ] **Document edit UI**: Add an "Edit" action to `DocumentDetailColumn`.
  - JSON text editor pre-populated with formatted JSON.
  - On save: decode JSON, preserve `_id`, call `store.put(collection, id, ...)`.
  - Surface `SchemaValidationException` as a field-level error list in the dialog.

- [ ] **Get document by key**: Add a "Find by ID" search bar to
      `DocumentContentColumn` that calls `store.get(collection, key)`.

- [ ] **Scan filtering (server-side)**: Filter bar in `DocumentContentColumn`:
  - Simple mode: field + operator + value → `Filter` object.
  - Advanced mode: raw JSON filter string matching the CLI `--filter` format.
  - Wired through `CollectionProvider.ScanOptions`.

- [ ] **Scan ordering and pagination**: Order-by field selector and
      ascending/descending toggle; next/prev page controls using
      `ScanOptions.limit` and `offset`.

- [ ] **Collection delete**: Swipe-to-delete or context menu on collection list
      items; calls `store.deleteNamespace(name)` after confirmation.

### Phase 2 — Lexical search

- [ ] **FTS index management panel**: Accessible from the collection header.
      Requires `KmdbConfig` from `kmdb` (see [plan_kmdb_config.md](plan_kmdb_config.md)).
  - List FTS indexes for the current collection (from `KmdbConfig`).
  - Create: field name input + stopwords toggle + BM25 k1/b sliders.
  - Delete: confirmation dialog.
  - Show index status (current / pending / error).

- [ ] **Search panel**: Accessible from a search icon on the collection header.
  - Query text field.
  - Mode selector: auto / lexical / semantic / hybrid.
  - Results list: rank, score, document id, field preview.
  - Tapping a result selects that document in the detail column.
  - Wire to `FtsManager.search()` using `FtsIndexDefinition` from `KmdbConfig`.

### Phase 3 — Schema, secondary indexes, and import/export

- [ ] **Schema management panel**:
  - List collections with registered schemas.
  - Show schema JSON (read-only collapsible view).
  - Set schema: JSON editor → `KmdbDatabase.registerSchema()`.
  - Remove: confirmation → `KmdbDatabase.deregisterSchema()`.
  - Validate: paste a JSON document; show field-level validation results.

- [ ] **Secondary index management panel**:
  - List indexes from `KmdbConfig` for the current collection.
  - Create: field path input; validate no `_` prefix.
  - Delete: confirmation; call index removal via the `kmdb` public API.
  - Show status (status, `builtThrough` generation, `builtAt` timestamp).

- [ ] **Export / Import / Dump / Restore**:
  - Export: save file picker → NDJSON line-by-line.
  - Import: file picker → NDJSON → `store.put` per doc with conflict selector
    (ignore / replace / error).
  - Dump: save file picker → multi-collection NDJSON matching the CLI `dump`
    format.
  - Restore: file picker → parse dump format → `store.put` per doc per
    collection.

- [ ] **Database info / stats / maintenance panel**: Toolbar or menu entry giving
      access to:
  - Read-only info: `store.storeInfo()` (dbDir, deviceId, HLC) and
    `store.stats()` (SSTable counts, total bytes).
  - Actions: `flush`, `compact`, `verify` — each with a confirmation dialog and
    result snackbar.
  - `new-device-id` — confirmation dialog (destructive action warning).

### Phase 4 — Sync and remote management (desktop only)

- [ ] **Remote management UI**: Settings panel for the open database.
  - List named remotes (name, type, path) from `KmdbConfig`.
  - Add remote: name + directory picker + type selector.
  - Remove remote: confirmation.

- [ ] **Push / Pull / Sync actions**: Toolbar buttons (or menu items).
  - Show progress indicator while running.
  - Show result (files pushed/pulled count) or error in a snackbar.
  - Guard with `defaultTargetPlatform == TargetPlatform.macOS`; show "Sync is
    not available on mobile" otherwise.

---

## Summary

{Dot points highlighting the work undertaken — to be filled in after implementation}
