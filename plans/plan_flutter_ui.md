# Flutter UI — CLI Feature Parity

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

See also:

- [plan_cli_repl.md](completed/plan_cli_repl.md)
- [plan_kmdb_config.md](completed/plan_kmdb_config.md) — prerequisite: Complete. `KmdbConfig` is now in `kmdb`.
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
      [plan_kmdb_config.md](completed/plan_kmdb_config.md) and is a prerequisite for the
      search and index management phases of this plan. **Resolved: `plan_kmdb_config` is complete.**

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
| Scan --explain | **Out of scope** | Developer diagnostic; deferred to a future search/filter enhancement plan |
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
definitions live in `local/config.json`, previously only parsed by `kmdb_cli`.
`KmdbConfig` has been moved to the `kmdb` package (see
[plan_kmdb_config.md](completed/plan_kmdb_config.md)) so the UI can import it directly.
This unblocks Phases 2 and 3.

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

- [x] **Responsive layout scaffold**: Replace the fixed 4-column horizontal scroll
      with an adaptive layout:
  - Wide (>= 900 px): keep the existing multi-column side-by-side layout.
  - Narrow (< 900 px): `Navigator`-based push model (collection list → document
    list → detail).
  - Create `lib/layout/adaptive_layout.dart` with `LayoutBreakpoints` const and
    an `AdaptiveColumnLayout` widget that switches between the two modes.
  - Guard `PlatformMenuBar` behind `defaultTargetPlatform == TargetPlatform.macOS`.

- [x] **Server-side scan in `CollectionProvider`**: Replace full in-memory scan
      with `KmdbCollection.where(filter).get()` (filtered) and
      `KmdbCollection.all().get()` (unfiltered), via a `ScanOptions` value object
      (filter, orderBy, descending, limit, offset).

- [x] **`AppProvider`**: New top-level provider exposing `KmdbDatabase` (not just
      `KvStore`) to downstream consumers. Required for schema, index, and FTS
      operations.
  - Fix the collection-count efficiency problem: `_loadCollections` currently
    streams every document across every collection just to count it. Replace with
    `KmdbCollection.count()` so startup does not materialise all documents.

- [x] **Error handling pattern**: Standardise on a `SnackBarService` or
      `ErrorProvider` for surfacing operation errors as dismissable snackbars.
      Currently errors silently inject `{'error': '...'}` documents into the list.

- [x] **Progress indicator for long-running operations**: All blocking operations
      (`compact`, `verify`, large import/restore, sync push/pull, and any other
      operation that may take more than ~200 ms) must show a modal or inline
      progress indicator and disable the UI to prevent concurrent mutations. Use a
      shared `AsyncOperationOverlay` widget so the pattern is consistent across
      all phases.

- [x] **Reactive document list via `watch()`**: Switch `CollectionProvider` from
      manual `loadDocuments()` refresh to `KmdbCollection.watch()` so mutations
      propagate automatically.
  - Expose a user-controlled "auto-refresh" toggle in the UI (e.g. toolbar
    icon). When disabled, `watch()` is paused and a manual refresh button is
    shown instead.
  - This replaces the current pattern of calling `loadDocuments()` directly
    after each `addDocument` / `deleteDocument`.

- [x] **Widget test infrastructure**: Add widget tests for the two provider
      classes using `MemoryStorageAdapter` from the `kmdb` package. Target ≥ 50%
      test coverage for `kmdb_ui` (lower than the library packages, but every new
      provider state and every dialog's happy/error path must have a corresponding
      widget test throughout all phases).

### Phase 1 — Document CRUD parity

- [x] **Document edit UI**: Add an "Edit" action to `DocumentDetailColumn`.
  - JSON text editor pre-populated with formatted JSON.
  - On save: decode JSON, preserve `_id`, call `store.put(collection, id, ...)`.
  - Surface `SchemaValidationException` as a field-level error list in the dialog.

- [x] **Get document by key**: Add a "Find by ID" search bar to
      `DocumentContentColumn` that calls `store.get(collection, key)`.

- [x] **Scan filtering (server-side)**: Filter bar in `DocumentContentColumn`:
  - Simple mode: field + operator + value → `Filter` object.
  - Advanced mode: raw JSON filter string matching the CLI `--filter` format.
  - Wired through `CollectionProvider.ScanOptions`.

- [x] **Scan ordering and pagination**: Order-by field selector and
      ascending/descending toggle; next/prev page controls using
      `ScanOptions.limit` and `offset`.
  - **Note**: `--explain` (query plan output) is out of scope for this plan.
    It is a developer diagnostic that is better suited to a future search/filter
    enhancement work item.

- [x] **Document count**: Display live document count for the selected collection
      via `KmdbCollection.count()` in the collection header or detail column.

- [x] **Collection delete**: Swipe-to-delete or context menu on collection list
      items; call via `KmdbDatabase` API (not `store.deleteNamespace`) so that
      index and FTS namespace cleanup is handled correctly.

### Phase 2 — Lexical search

- [x] **FTS index management panel**: Accessible from the collection header.
      Requires `KmdbConfig` from `kmdb` (see [plan_kmdb_config.md](plan_kmdb_config.md)).
  - List FTS indexes for the current collection (from `KmdbConfig`).
  - Create: field name input + stopwords toggle + BM25 k1/b sliders.
  - Delete: confirmation dialog.
  - Show index status (current / pending / error).

- [x] **Search panel**: Accessible from a search icon on the collection header.
  - Query text field.
  - Mode selector: auto / lexical / semantic / hybrid. **Gate semantic/hybrid
    modes behind a platform-capability check from day one** (e.g.
    `FtsManager.supportsSemanticSearch()`) — ONNX Runtime is macOS-only in
    practice and not available on iOS. Do not hard-code all four modes; build
    the guard in now rather than leaving it for the mobile plan to undo.
  - Results list: rank, score, document id, field preview.
  - Tapping a result selects that document in the detail column.
  - Wire to `FtsManager.search()` using `FtsIndexDefinition` from `KmdbConfig`.

### Phase 3 — Schema, secondary indexes, and import/export

- [x] **Schema management panel**:
  - List collections with registered schemas.
  - Show schema JSON (read-only collapsible view).
  - Set schema: JSON editor → `KmdbDatabase.registerSchema()`.
  - Remove: confirmation → `KmdbDatabase.deregisterSchema()`.
  - Validate: paste a JSON document; show field-level validation results.

- [x] **Secondary index management panel**:
  - List indexes from `KmdbConfig` for the current collection.
  - Create: field path input; validate no `_` prefix.
  - Delete: confirmation; call index removal via the `kmdb` public API.
  - Show status (status, `builtThrough` generation, `builtAt` timestamp).

- [x] **Export / Import / Dump / Restore**:
  - Export: save file picker → NDJSON line-by-line.
  - Import: file picker → NDJSON → `store.put` per doc with conflict selector
    (ignore / replace / error). The conflict dialog must prominently warn that
    **"Replace" overwrites the document on all synced devices after the next
    sync**, not just locally — each import write gets a fresh HLC timestamp that
    will win against any prior version on peer devices, including versions written
    after the export was taken.
  - Dump: save file picker → multi-collection NDJSON matching the CLI `dump`
    format.
  - Restore: file picker → parse dump format → `store.put` per doc per
    collection.
  - All four operations are long-running; use `AsyncOperationOverlay` (see
    Phase 0) throughout.
  - **macOS sandbox**: save-file pickers (export, dump) require the same
    security-scoped access as directory pickers. Verify that the `file_picker`
    package handles macOS sandbox entitlements correctly for save operations,
    not just open/directory picks.

- [x] **Database info / stats / maintenance panel**: Toolbar or menu entry giving
      access to:
  - Read-only info: `store.storeInfo()` (dbDir, deviceId, HLC) and
    `store.stats()` (SSTable counts, total bytes).
  - Actions: `flush`, `compact`, `verify` — each with a confirmation dialog and
    result snackbar.
  - `new-device-id` — confirmation dialog (destructive action warning). Before
    rotating, call `flush()` and verify no sync is in progress: rotating while a
    sync is running produces orphaned SSTables under the old device ID in the
    cloud.

### Phase 4 — Sync and remote management (desktop only)

- [x] **Remote management UI**: Settings panel for the open database.
  - List named remotes (name, type, path) from `KmdbConfig`.
  - Add remote: name + directory picker + type selector.
  - Remove remote: confirmation.

- [x] **Push / Pull / Sync actions**: Toolbar buttons (or menu items).
  - Use `AsyncOperationOverlay` (see Phase 0) while running.
  - Show result (files pushed/pulled count) or error in a snackbar.
  - Guard with `defaultTargetPlatform == TargetPlatform.macOS`; show "Sync is
    not available on mobile" otherwise.

---

## Summary

- **Phase 0** laid the foundation: replaced the fixed 4-column layout with an `AdaptiveColumnLayout` that switches to a navigator-push stack on narrow screens; replaced full-scan-then-filter in `CollectionProvider` with server-side `KmdbCollection.where()` via a `ScanOptions` value object; introduced `AppProvider` wrapping `KmdbDatabase`; added `ErrorProvider` + `ErrorListener` for snackbar-based error surfacing; added `AsyncOperationOverlay` for blocking operation progress; switched the document list to `KmdbCollection.watch()` for reactive updates; and set up widget-test infrastructure using `MemoryStorageAdapter`.
- **Phase 1** completed document CRUD parity: document edit dialog, get-by-ID search bar, server-side scan filtering (simple + advanced JSON modes), order-by + pagination controls, live document count, and collection delete with confirmation.
- **Phase 2** added lexical search: FTS index management panel (create/delete with status display), and a full search panel with mode selector (lexical/semantic/hybrid gated behind platform-capability checks), results list, and document selection integration.
- **Phase 3** added schema management (view/set/remove/validate), secondary index management (list/create/delete with status), export/import/dump/restore dialogs using `file_picker` with NDJSON format and conflict-mode selection (ignore/replace/error), and a database info/stats/maintenance panel exposing `storeInfo()`, `stats()`, flush, compact, verify, and device ID rotation.
- **Phase 4** added sync and remote management: `sync_sheet.dart` bottom sheet with remote listing, add-remote dialog (name + directory picker), remove-remote with confirmation, and Push/Pull/Sync buttons per remote wired through `AppProvider.runBusy()`; macOS-only guard shows an informational message on other platforms; macOS native menu bar gained a "Sync" menu entry and a toolbar sync button in `DatabaseHistoryColumn`; 111 tests pass.

---

## Review

**Reviewer**: Plan Reviewer Agent  
**Date**: 2026-05-02  
**Verdict**: Ready to implement — advancing to `Investigated`.

### Problem Statement Assessment

The problem is real and well-scoped. The gap analysis is thorough and grounded
in actual code inspection: the `CollectionProvider` full-scan-then-filter
pattern is a genuine scalability hazard, and the silent error injection
(`{'error': '...'}` into the document list) is a legitimate quality issue worth
fixing before adding more features on top of it. The framing as a "validation
vehicle for the KMDB engine on mobile platforms" accurately reflects the v0.02
roadmap goal.

One stale reference: `plan_kmdb_config.md` is listed as a prerequisite for
Phase 2 but that plan is already **Complete** and has been updated accordingly.
Phase 2 is unblocked from the start.

### Proposed Solution Assessment

**Strengths:**

- The four-phase progression is well ordered. Phase 0 fixes the two most
  dangerous technical debts (full-scan provider, silent error swallowing) before
  adding any new UI surface. Phases are appropriately sequenced on real
  dependencies — the `AppProvider` upgrade in Phase 0 is the right prerequisite
  before schema and index management in Phase 3.
- The `ScanOptions` value object is a clean abstraction that avoids polluting
  `CollectionProvider` with a growing parameter list.
- The plan correctly identifies that the `KvStore`-typed provider must be
  upgraded to `KmdbDatabase` to unlock the query layer. This is the right
  architectural move — the current app bypasses the query layer entirely.
- Sync and remote management being desktop-only (Phase 4) is the right call
  given mobile OS sandboxing constraints, and the platform guard approach is
  consistent with the existing `PlatformMenuBar` pattern.
- Vault shown as plain URIs is an appropriate deferral for v0.02.

**Weaknesses / gaps:**

1. **`count` is missing from the document CRUD phase.** The CLI table shows
   `count` as REPL-scope. It is not listed in either the gap analysis or any
   implementation phase. It is trivially implemented via `KmdbCollection.count()`
   once `AppProvider` is in place; it should be included in Phase 1 alongside
   the other document query operations.

2. **Phase 2 search-panel mode selector is too broad.** The plan lists
   `auto / lexical / semantic / hybrid` as search modes. Semantic search
   requires `kmdb_inferencing` (ONNX Runtime), which is unsupported on iOS and
   currently macOS-only in practice. The plan defers the iOS suppression to
   `plan_flutter_ui_mobile.md`, which is fine, but the Phase 2 implementation
   should be written from the start with a platform-capability guard
   (`FtsManager.supportsSemanticSearch()` or similar) rather than baking in
   all four modes and hoping the mobile plan remembers to hide them. This is
   not a blocker but is worth noting up-front so the implementation does not
   create tech debt that the mobile plan then has to undo.

3. **Import conflict selector UX.** Phase 3 specifies a conflict selector
   (ignore / replace / error) for import. This is good, but the plan does not
   call out that LWW via HLC timestamps applies here: if the imported document
   has an older HLC timestamp than the stored one, a "replace" might still lose
   to the existing document after sync. The import implementation should either
   strip and regenerate `_id` timestamps or document this limitation clearly.

4. **`new-device-id` risk.** The plan lists this as a destructive action with
   a confirmation dialog, which is correct. However it should also note that
   rotating the device ID while a sync is in progress will produce orphaned
   SSTables under the old device ID in the cloud. The UI should close the
   database (or at least call `flush()` and confirm no sync is running) before
   allowing the rotation.

5. **Test coverage strategy is thin.** The plan mentions "widget test stubs" in
   Phase 0 but does not set expectations for Phase 1–4 coverage. Given the 90%
   minimum requirement and the fact that the UI currently has only four test
   files, this needs to be stated explicitly. At minimum each new Provider state
   and each dialog's happy/error path should have a widget test using
   `MemoryStorageAdapter`. The implementation checklist items should each carry
   an implicit "and corresponding widget test" requirement.

6. **`store.deleteNamespace` vs collection delete.** Phase 1 says collection
   delete "calls `store.deleteNamespace(name)`". This is the KvStore-level API.
   Once `AppProvider` exposes `KmdbDatabase`, the correct call is through the
   database API (which will also handle index and FTS namespace cleanup). The
   implementation should not bypass the database layer for this operation.

7. **Scan `--explain` is listed in the gap analysis as missing but does not
   appear in any implementation phase.** This is fine if it is intentionally
   out of scope (it's a developer diagnostic, not a user feature), but the plan
   should say so explicitly rather than leaving it silently unaddressed.

8. **`DatabaseProvider` opens `KvStoreImpl` directly.** The Phase 0 `AppProvider`
   task correctly plans to switch to `KmdbDatabase`, but `DatabaseProvider`
   currently holds a `KvStore` reference and calls `store.scan()` to count
   collections. After the switch, `_loadCollections` should use
   `KmdbDatabase.listCollections()` (if that API exists) or
   `KmdbDatabase.rawCollection().count()` rather than streaming every document
   just to count it. The plan should call this efficiency problem out explicitly
   in the `AppProvider` task.

### Architecture Fit

The plan fits the 6-layer stack correctly. Moving the provider from `KvStore`
to `KmdbDatabase` is the right architectural decision — it positions the UI
at the Query Layer boundary rather than bypassing it, which is how all other
clients are intended to interact with the engine. The plan does not touch the
storage engine, sync protocol, or cache layer, which is appropriate.

The one structural concern is that `CollectionProvider` currently holds a
direct reference to `KvStore`. The Phase 0 `AppProvider` task must ensure the
refactor is complete before any Phase 1 or later work begins, because all
subsequent phases depend on query-layer APIs that are only reachable through
`KmdbDatabase`.

### Risk and Edge Cases

- **Progress indication for long-running operations**: `compact`, `verify`, and
  large import/restore jobs can run for seconds. The plan mentions a "progress
  indicator while running" for sync but not for these other operations. All
  blocking operations should show a progress indicator and disable the UI to
  prevent concurrent mutations.

- **File picker on macOS sandbox**: The plan inherits the existing
  security-scoped bookmark machinery for opening databases. Import/export file
  pickers for NDJSON files will also need sandbox-safe access. The implementation
  should verify that the `file_picker` package correctly handles macOS sandboxing
  for save-file operations (not just directory picks).

- **Reactive refresh after mutations**: The current `CollectionProvider.addDocument`
  and `deleteDocument` call `loadDocuments()` directly. Once the provider
  switches to `KmdbCollection.watch()`, mutations should automatically propagate
  via the reactive stream rather than requiring manual refresh calls. The plan
  should note whether Phase 0 adopts `watch()` or defers it.

### Recommendations

1. Add `count` to Phase 1.
2. Add an explicit note to the Phase 2 search panel task about platform-gating
   the mode selector from the start.
3. Clarify the expected test coverage approach in Phase 0 and state it as a
   requirement for all subsequent phases.
4. Change the Phase 1 collection delete task to call the `KmdbDatabase` API
   rather than the raw `store.deleteNamespace`.
5. Add a note to the `new-device-id` maintenance action about flushing before
   rotation.
6. Explicitly exclude `--explain` from scope (or include it — but decide).
7. Address the collection count efficiency problem in the `AppProvider` task.

None of these are blocking. The plan is well-reasoned, properly phased, and
grounded in the actual codebase state. It is ready to implement.
