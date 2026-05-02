# Move KmdbConfig into the `kmdb` package

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

**Prerequisite for**: [plan_flutter_ui.md](plan_flutter_ui.md) Phase 2 (search
and index management panels require `KmdbConfig` from a package the UI can
depend on).

See also:

- [plan_flutter_ui.md](plan_flutter_ui.md)
- [plan_flutter_ui_mobile.md](plan_flutter_ui_mobile.md)

## Problem statement

`KmdbConfig` (the reader/writer for `local/config.json`) currently lives in
`kmdb_cli`. It stores per-database, per-device configuration that is not part of
the synced data: named sync remotes, FTS index definitions, and secondary index
definitions.

Because it is CLI-internal, no other client — including the Flutter UI, future
language bindings, or user-written Dart programs — can read or write this config
without depending on the CLI package, which is not intended as a library.

This plan moves `KmdbConfig` (and its associated types) into the `kmdb` package
so that any Dart client can manage per-database configuration without going
through the CLI.

---

## Open questions

- [x] **Public API surface**: A separate `package:kmdb/kmdb_config.dart`
      library, not part of the primary `kmdb.dart` barrel. Clients that do not
      need config management do not pull in the dependency. `kmdb_cli` and
      `kmdb_ui` both import it explicitly.

- [x] **Platform I/O abstraction**: `KmdbConfig` depends on a thin
      `KmdbConfigStore` interface rather than `dart:io` directly:
      `dart     abstract interface class KmdbConfigStore {       Future<String?> read();       Future<void> write(String json);     }     `
      `KmdbConfig` is platform-neutral and handles all JSON parsing. The native
      implementation (`IoKmdbConfigStore`, using `dart:io`) is the only concrete
      class needed now. A future `WebKmdbConfigStore` (IndexedDB / localStorage)
      can be added without touching `KmdbConfig`. `kmdb_config.dart` documents
      clearly that `IoKmdbConfigStore` is not supported on web. A convenience
      factory `KmdbConfig.forDatabase(String dbPath)` wires up
      `IoKmdbConfigStore` for native callers; web callers will eventually pass
      their own store.

- [x] **`local/` directory creation**: `IoKmdbConfigStore` creates the `local/`
      subdirectory lazily on first write, preserving the existing CLI behaviour.

---

## Investigation

### Current location of KmdbConfig

`KmdbConfig` is defined in `packages/kmdb_cli/lib/src/config/kmdb_config.dart`.
It imports `remote_config.dart` from the same directory for the `RemoteConfig`
hierarchy.

It is used by:

- `cli_runner.dart` — calls `KmdbConfig.load(dbPath)` at startup
- `remote_command.dart` — add/list/remove sync remotes
- `search_command.dart` — create/delete FTS index definitions
- `new_device_id_command.dart` — reads config to rewrite the device id
- `sync_helpers.dart` — reads remotes for push/pull
- `database_opener.dart` — passes loaded config into `CommandContext`
- `repl/dot_commands/database_commands.dart` — loads config on `.open`
- `commands/command.dart` — `CommandContext` carries `KmdbConfig config`

### Types to move

| Type                   | Actual Dart form            | Description                                               |
| :--------------------- | :-------------------------- | :-------------------------------------------------------- |
| `KmdbConfig`           | `final class`               | Top-level config object; owns mutation and JSON parsing   |
| `RemoteConfig`         | `sealed class` + subclasses | Named sync remote (in `remote_config.dart`)               |
| `IndexRecord`          | `typedef` (record)          | Secondary index spec `({String collection, String path})` |
| `FtsIndexRecord`       | `typedef` (record)          | FTS index spec with BM25 params                           |
| `EmbeddingModelConfig` | `typedef` (record)          | ONNX model path config                                    |

### Abstraction split

The `dart:io` usage in `KmdbConfig` is confined to exactly two methods:

- `static Future<KmdbConfig> load(String dbDir)` — reads and parses the file.
- `Future<void> save(String dbDir)` — serialises and atomically writes the file
  (write-to-temp-then-rename).

All mutation methods (`addRemote`, `removeRemote`, `addIndex`, `removeIndex`,
`addFtsIndex`, `removeFtsIndex`) and JSON parsing are pure Dart with no I/O.
This makes the `KmdbConfigStore` abstraction very clean: `load` becomes
`KmdbConfigStore.read() → Future<String?>` and `save` becomes
`KmdbConfigStore.write(String json) → Future<void>`. `KmdbConfig` itself gains
`KmdbConfig.fromJson(String json)` and `String toJson()` methods and loses its
direct `dart:io` dependency entirely.

### Impact on `kmdb_cli`

Once moved, `kmdb_cli` imports from `package:kmdb/kmdb_config.dart`. All call
sites that use `KmdbConfig.load(dbPath)` are replaced with
`KmdbConfig.forDatabase(dbPath)` (the convenience factory that wires up
`IoKmdbConfigStore`). The CLI behaviour is unchanged; only import paths shift.

### Impact on `kmdb_ui`

`kmdb_ui` gains a direct `KmdbConfig` import. No workaround needed.

---

## Implementation plan

### Step 1 — Audit current `KmdbConfig` code

- [ ] Confirm no types in `kmdb_cli/lib/src/config/` reference CLI-only types
      (`CliCommand`, `CommandContext`, `ArgParser`, etc.) that must stay in
      `kmdb_cli`. The investigation above indicates they do not, but verify
      before moving.

### Step 2 — Create `package:kmdb/kmdb_config.dart`

- [ ] Create `packages/kmdb/lib/src/config/kmdb_config_store.dart` defining the
      `KmdbConfigStore` abstract interface (`read()`, `write(String json)`).
- [ ] Create `packages/kmdb/lib/src/config/io_kmdb_config_store.dart` with
      `IoKmdbConfigStore` — the `dart:io` implementation. Document that it is
      not supported on web. Lazy-create the `local/` subdirectory on first
      write.
- [ ] Create `packages/kmdb/lib/src/config/kmdb_config.dart` with the moved
      types and JSON parsing logic. `KmdbConfig` depends only on
      `KmdbConfigStore`. Add a `KmdbConfig.forDatabase(String dbPath)` factory
      that wires up `IoKmdbConfigStore`.
- [ ] Create `packages/kmdb/lib/kmdb_config.dart` as the public library entry
      point exporting `KmdbConfigStore`, `IoKmdbConfigStore`, `KmdbConfig`, and
      the associated data types.
- [ ] Add doc comments to all public classes, methods, and properties.

### Step 3 — Update `kmdb_cli`

- [ ] Replace all internal imports of the moved types with
      `package:kmdb/kmdb_config.dart`.
- [ ] Remove the now-redundant type definitions from `kmdb_cli`.
- [ ] **Keep `adapterFor` in `kmdb_cli`** — it is a CLI-only convenience that
      maps a `RemoteConfig` subtype to its concrete `SyncStorageAdapter`
      constructor (currently a one-liner: `LocalRemoteConfig` →
      `LocalDirectoryAdapter(path)`). Non-CLI consumers construct adapters
      directly and have no need for this function. Leave it in
      `remote_config.dart` where it lives today; do not move it to `kmdb`.
- [ ] Confirm `CommandContext` continues to carry `KmdbConfig?` and that all
      command tests pass.

### Step 4 — Tests

- [ ] Move any existing `KmdbConfig` unit tests from `kmdb_cli/test/` to
      `kmdb/test/config/`.
- [ ] Add a `FakeKmdbConfigStore` test double (in-memory `String?`) usable
      across all `KmdbConfig` tests — no `dart:io` required in tests.
- [ ] Add tests for the new public library in `kmdb/test/config/`:
  - Read/write round-trip for each config section (remotes, FTS indexes,
    secondary indexes) using `FakeKmdbConfigStore`.
  - Graceful handling of a `null` read (missing config) and corrupt JSON.
  - Unknown keys preserved on round-trip (forward compatibility).
- [ ] Add integration tests for `IoKmdbConfigStore` using a temp directory:
  - Lazy `local/` directory creation on first write.
  - Round-trip survives process restart (write then read from disk).
- [ ] Run the full `kmdb_cli` test suite to confirm no regressions.
- [ ] Maintain ≥ 90% test coverage in both packages.

### Step 5 — Documentation

- [ ] Update `packages/kmdb/README.md` to mention `kmdb_config.dart` and its
      purpose.
- [ ] Update any relevant spec files in `docs/spec/` if config management is
      described there.
- [ ] Update `docs/primer.md` as required.

---

## Summary

- Created `package:kmdb/kmdb_config.dart` library with `KmdbConfigStore` (abstract interface), `IoKmdbConfigStore` (dart:io, native-only), and `KmdbConfig` (platform-neutral, all JSON parsing and mutation).
- Moved `KmdbConfig`, `RemoteConfig`/`LocalRemoteConfig`, `IndexRecord`, `FtsIndexRecord`, and `EmbeddingModelConfig` out of `kmdb_cli` into `packages/kmdb/lib/src/config/`.
- `KmdbConfig` now stores unknown top-level JSON keys in `_extra` and round-trips them verbatim, ensuring forward compatibility with newer config versions.
- `adapterFor` left in `kmdb_cli/lib/src/config/remote_config.dart` — it is CLI-only and non-CLI consumers construct adapters directly.
- All `kmdb_cli` call sites updated: `KmdbConfig.load(path)` → `KmdbConfig.forDatabase(path)`, `config.save(path)` → `config.save()`.
- Tests updated throughout `kmdb_cli` to use the new API; one `IndexCommand delete` test fixed to use `forDatabase` so `save()` has a real backing store.
- All 1246 `kmdb` tests and 839 `kmdb_cli` tests pass.

---

## Review

**Reviewed**: 2026-05-02

### Problem Statement Assessment

This is a real and well-motivated problem. `KmdbConfig` is genuinely misplaced
in `kmdb_cli`: the config file format is a database-level concern, not a CLI
concern, and blocking `kmdb_ui` (and any future Dart consumer) on a CLI package
dependency is the wrong coupling. Moving it now, before `kmdb_ui` grows further,
is the right time.

The prerequisite relationship to `plan_flutter_ui.md` Phase 2 is correctly
identified and gives this work clear priority.

### Proposed Solution Assessment

The `KmdbConfigStore` abstraction is the right call. The I/O boundary in the
current `KmdbConfig` really is confined to `load` and `save`, and the plan's
investigation confirms this accurately. Introducing `read()` /
`write(String json)` as the interface surface is minimal and correct — it keeps
the platform-neutral logic testable without `dart:io`, which is exactly what the
test plan exploits with `FakeKmdbConfigStore`.

The `KmdbConfig.forDatabase(String dbPath)` convenience factory is a good
ergonomic addition; it gives native callers a one-liner without exposing
`IoKmdbConfigStore` unnecessarily in the call site.

**One unresolved split: `adapterFor` in `remote_config.dart`**

The current `remote_config.dart` already imports `package:kmdb/kmdb.dart` for
`SyncStorageAdapter` and `LocalDirectoryAdapter`, and exposes the top-level
function `adapterFor(RemoteConfig remote)`. This function is CLI-specific (it
wires a config type to a live sync adapter) and should **not** move to `kmdb`.
The plan does not address where `adapterFor` ends up after the migration.

The cleanest resolution: keep `adapterFor` in `kmdb_cli` as a free function in a
thin `adapter_factory.dart` file (or directly in `sync_helpers.dart`).
`RemoteConfig` itself moves to `kmdb`, but `adapterFor` stays in the CLI because
it bridges `RemoteConfig` (now in `kmdb`) with `LocalDirectoryAdapter` (also in
`kmdb`). The plan's Step 3 should call this out explicitly to avoid the
implementer inadvertently moving it or creating a circular dependency.

**Tests for the forward-compatibility case are listed but the plan's claim needs
verification**

Step 4 lists "unknown keys preserved on round-trip" as a test case. The current
`KmdbConfig.load` implementation does not preserve unknown keys — the JSON is
parsed into strongly-typed fields and the raw map is discarded. There is no
"pass-through unknown keys" logic in the current code. After the refactor to
`fromJson`/`toJson` on `KmdbConfig` itself, this either needs to be newly
implemented (storing unknown keys in a `Map<String, dynamic> _extra`) or the
test requirement should be removed. This is the single most significant gap
between the stated test plan and what the code currently does. The plan should
explicitly decide which it is.

### Architecture Fit

This fits cleanly into the existing 6-layer architecture. `KmdbConfig` is purely
a local-only, non-synced concern — it lives outside the LSM/sync/cache stack
entirely, reading from `local/config.json`, which is already documented as
per-machine state that is never uploaded. Moving it into `kmdb` as a separate
library entry point (`kmdb_config.dart`, not part of the primary `kmdb.dart`
barrel) keeps the split clean: apps that do not need config management don't pay
for the import, and there is no risk of this touching the storage engine or sync
protocol.

`RemoteConfig` currently imports `package:kmdb/kmdb.dart` only because
`adapterFor` lives in the same file. Once `adapterFor` is moved to `kmdb_cli`,
`RemoteConfig` itself has no `kmdb` dependency and the move is clean.

### Risk and Edge Cases

1. **`adapterFor` placement** — described above. Must be explicitly decided in
   the implementation plan before coding begins.

2. **Unknown key round-trip** — the test plan promises forward-compatibility
   behaviour that the code does not currently implement. Decide: implement it or
   drop the test case.

3. **`IoKmdbConfigStore` write atomicity** — the current `save()` uses
   write-to-temp-then-rename, which is correct and must be preserved in
   `IoKmdbConfigStore`. The plan mentions this (lazy `local/` creation) but does
   not explicitly call out the atomic rename. The implementer should be
   reminded: the temp-file-then-rename strategy must survive into the new
   implementation.

4. **`localDir` and `configPath` static helpers** — the current `KmdbConfig`
   exposes `static String localDir(String dbDir)` and
   `static String configPath(String dbDir)` as public methods (used by CLI
   callers to construct paths). These must migrate with `KmdbConfig` or the CLI
   will break silently. Step 3's "confirm `CommandContext` continues to carry
   `KmdbConfig?`" is not sufficient — a grep for callers of
   `KmdbConfig.localDir` and `KmdbConfig.configPath` should be added to the
   audit in Step 1.

5. **Existing tests use `dart:io` directly** — the current
   `kmdb_config_test.dart` creates temp dirs and writes files manually. These
   should be replaced with `FakeKmdbConfigStore` tests in `kmdb/test/config/`,
   and integration-level tests with real I/O should be kept but clearly
   separated. The plan already describes this correctly; just note that the
   existing tests are quite comprehensive and must all be ported.

6. **`kmdb` package now gains a `dart:io` conditional dependency** —
   `IoKmdbConfigStore` uses `dart:io`. The `kmdb` package already uses `dart:io`
   (it has a platform abstraction layer) so this is not new territory, but the
   implementer must ensure `kmdb_config.dart` uses a conditional import or is
   clearly documented as not supported on web, consistent with how the rest of
   the package handles the web/native split.

### Recommendations

The plan is well-investigated and the implementation steps are clear and
correct. Two things must be resolved before implementation begins:

1. **Explicitly state the fate of `adapterFor`**: add a note to Step 3
   specifying that `adapterFor` stays in `kmdb_cli` and must not move to `kmdb`.
   Suggested location: a new `adapter_factory.dart` in
   `packages/kmdb_cli/lib/src/config/` or inline in `sync_helpers.dart`.

2. **Decide on unknown-key preservation**: either add an `_extra` field to
   `KmdbConfig` and implement round-trip preservation, or remove the test case
   from Step 4. Do not leave it as an implicit promise.

With those two points clarified in the plan text, this is ready to implement.

#### Response

1. I think we've covered this and it is now called out in Step 3.

2. For the unknown key round trip (Step 4 testing), let's add the `_extra` field
   (and associated handling) as part of the implementation work. This will help
   with 2 key cases:
   1. When the user runs an older version of the CLI (for example), we don't
      want to just delete config out from under them
   2. 3rd party apps could use this for their own configuration.
