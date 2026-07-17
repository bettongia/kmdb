# Library Integration Guide + sample Flutter to-do app

**Status**: Investigated

**PR link**: —

## Problem statement

`docs/roadmap/0_09.md`'s "Integration Guide" item calls for a document
teaching a Dart/Flutter application developer how to integrate `kmdb` as a
library — opening/closing a database, managing collections and documents, the
vault, fault handling, etc. — built around a sample Flutter to-do app
(multiple projects, each with tasks carrying title/description/priority/
status/attachments/comments) that demonstrates schema, indexing/search,
vault, and sync mechanics.

This is one of three plans split out of a single combined roadmap item at the
`kmdb-architect` agent's recommendation — see
[plan_0_09_spec_review_and_primer_fold.md](plan_0_09_spec_review_and_primer_fold.md)
for the full split rationale. This plan is the heaviest and riskiest of the
three: unlike the other two (docs-only), it requires real, tested application
code (the sample app) in addition to the guide prose. Because of that weight,
its roadmap item has since moved out to its own roadmap,
[`docs/roadmap/0_10.md`](../roadmap/0_10.md) — it is no longer tracked under
`0_09`, and the plan file itself was renamed from `plan_0_09_integration_guide.md`
to `plan_0_10_integration_guide.md` to match (all cross-references from its
former `0_09` siblings were updated accordingly).

**Dependency: [plan_0_09_spec_review_and_primer_fold.md](plan_0_09_spec_review_and_primer_fold.md)
is now a prerequisite, not just a nice-to-have cross-check.** The guide cites
spec section numbers throughout (§16, §17, §20–23, §24, §25, §31, etc.) — the
spec-review plan is what confirms those sections are correct, complete, and
current before this plan's guide prose is written against them. Implementation
of this plan should not start until the spec-review plan has landed on `main`.

## Open questions

- [x] **Q1 — Guide document placement.** **Decision: `docs/integration_guide/README.md`**,
      mirroring the existing `docs/user_guide/` layout. Lower churn than a
      `docs/guides/` umbrella restructure, and the CLI guide keeps its current
      location.
- [x] **Q2 — Sample app package placement (reframed by review — see Review
      notes below).** The original three-option framing was wrong: a Flutter
      app **cannot** be a pub-workspace member — the root `pubspec.yaml`
      (lines 19–26) explicitly excludes `flutter: sdk: flutter` packages so
      pure-Dart Linux/Windows CI runners keep resolving. **Decision:**
      `packages/kmdb_example_todo/` as a **standalone, non-workspace Flutter
      package**, sited like the existing `packages/kmdb_icloud/example/`
      precedent — path deps on `kmdb`, `dependency_overrides` mirrored from
      root, its own dedicated CI job (modelled on `make cicd_flutter`). The
      native-asset-hook worry is moot since this package was never joining the
      workspace.
- [x] **Q3 — Platform scope for the sample app.** **Decision: desktop only for
      v1 — macOS, Linux, Windows.** No web, no mobile. This simplifies the
      guide considerably: no per-platform caveats needed for semantic search
      (§20 excludes it on web only) or for the sync-demo mechanism (Q4 —
      native-only, fine on all three desktop targets).
- [x] **Q4 — How much of the sync story is demonstrable single-device
      (reframed by review — see Review notes below).** **Decision: use
      `LocalDirectoryAdapter`** (`packages/kmdb/lib/src/sync/local/local_directory_adapter.dart`,
      exported from `kmdb.dart`) — two `KmdbDatabase.open()` instances at
      different local paths sharing one sync folder, no cloud credentials
      needed. It's `dart.library.io` (native-only), which is a non-issue given
      the Q3 desktop-only scope. No "going further" cloud-adapter section is
      required for v1 given this fully in-suite demo covers the mechanic.

## Investigation

Grounded by the `kmdb-architect` agent. Key findings:

### Existing doc registers (informs Q1)

| Doc | Audience | Register |
|---|---|---|
| `docs/spec/` | maintainers/integrators needing on-disk formats & protocol | normative reference |
| `docs/primer.md` (being retired — see sibling plan) | contributors reading the source | narrative "why" |
| `docs/user_guide/README.md` (879 lines, exists) | CLI users | task tutorial (`kmdb` binary) |
| **Integration Guide (this plan)** | Dart/Flutter app devs using `kmdb` as a library | task tutorial ("how do I open/close, collections, vault, faults…") |

The Integration Guide is a genuine fourth register: task-oriented "how do
I…" for library consumers, not normative reference. Placing it in
`docs/spec/` would mix registers and dilute the spec's reference identity.
The existing `docs/user_guide/` is the direct precedent for keeping
task-oriented guides outside `docs/spec/`.

### Sample app scope (informs Q2–Q4)

The roadmap's stated sample app shape: a to-do app with multiple projects,
each containing tasks (title, description, priority: high/medium/low,
status: backlog/in-progress/done, file attachments, comments/updates). This
maps cleanly onto `kmdb` primitives the guide needs to demonstrate:
collections & documents (`projects`/`tasks`, typed via `KmdbCodec<T>`),
schema admission (§25), a secondary index (§16) for the project→tasks
listing, search (§20–23), vault (§24), sync (§12), and fault handling (§17,
§31). The concrete pinning of each is in the next section.

### Second investigation pass — pinned design (2026-07-17, `kmdb-architect`)

Grounded against current `main` (file/line references verified, not
invented): `packages/kmdb/lib/src/query/kmdb_database.dart`,
`kmdb_codec.dart`, `kmdb_collection.dart`, `collection_schema.dart`,
`index/index_definition.dart`, `search/fts_index_definition.dart`,
`search/lexical/fts_manager.dart`, `encryption/encryption_config.dart`,
`vault/vault_store.dart`, `vault/vault_ref.dart`,
`vault/vault_ref_interceptor.dart`, `sync/local/local_directory_adapter.dart`,
`packages/kmdb_cli/lib/src/database_opener.dart`,
`packages/kmdb_icloud/example/`, `docs/spec/25_collection_schemas.md`.

**Data model** (`lib/src/models/`):

```dart
class Project {
  final String id;            // 32-char hex UUIDv7 ('' before insert())
  final String name;
  final String description;
  final DateTime createdAt;
}

class Task {
  final String id;
  final String projectId;     // FK -> Project.id
  final String title;
  final String description;
  final String priority;      // 'high' | 'medium' | 'low'
  final String status;        // 'backlog' | 'in-progress' | 'done'
  final List<String> attachmentUris; // 'kmdb-vault://sha256/<64hex>'
  final DateTime createdAt;
  final DateTime updatedAt;
}

class TaskComment {           // sub-collection — see "Comments" below
  final String id;
  final String taskId;        // FK -> Task.id
  final String author;
  final String body;
  final DateTime createdAt;
}
```

`KmdbCodec<T>` contract (verified): `keyOf(T)`, `withKey(T, String)`,
`encode(T) -> Map<String,dynamic>`, `decode(Map)`. Keys are 32-char lowercase
hex UUIDv7; `encode()` must emit no `_`-prefixed field (`ReservedFieldException`
otherwise) and only JSON-compatible scalars — `DateTime` fields serialize via
`toIso8601String()` / parse back in `decode()`. `priority`/`status` are plain
`String`s at the codec level; the enum constraint is enforced by the JSON
Schema (§25), not the codec.

**Comments representation — sub-collection, not a free choice.** Verified
`fts_manager.dart:1483` (`_extractFieldValue`): FTS field extraction walks
`field.split('.')` into Maps only and returns a value only if it is a
non-empty `String` — it does **not** fan out arrays or concatenate array
elements (unlike secondary indexes, which do support `tags[]`-style fan-out).
An embedded `List<Comment>` on `Task` is therefore **not full-text searchable**
with the current engine. Since the roadmap explicitly asks the guide to
demonstrate indexing/search including comments, this forces a **`taskComments`
sub-collection**: `FtsIndexDefinition(collection: 'taskComments', field:
'body')` and `IndexDefinition('taskComments', 'taskId')` work directly, and it
doubles as a second worked example of a one-to-many relationship alongside
project→tasks.

**Secondary indexes**, registered at `KmdbDatabase.open()`:
```dart
indexes: [
  IndexDefinition('tasks', 'projectId'),      // project -> tasks listing
  IndexDefinition('taskComments', 'taskId'),  // task -> comments listing
],
```
The guide cites `tasks.where(Field('projectId').equals(project.id)).get()`,
and uses `explainedGet`/`QueryPlan` to show the index is used once built (§16
lazy build).

**Search — two distinct surfaces, both demonstrated:**
- **`KmdbCollection.search()`** over task fields (`kmdb_collection.dart:470`):
  `tasks.search(query, fields: ['title', 'description'], mode:
  SearchMode.lexical, limit: 20)`, requiring `ftsIndexes:
  [FtsIndexDefinition(collection: 'tasks', field: 'title'),
  FtsIndexDefinition(collection: 'tasks', field: 'description'),
  FtsIndexDefinition(collection: 'taskComments', field: 'body')]` at open.
  **Mode: `SearchMode.lexical` (BM25)** — semantic/hybrid needs an ONNX
  embedding model download plus native-asset setup, extra dependency weight
  the guide doesn't need for v1; mention hybrid/semantic as a "going further"
  callout, not a demoed path.
- **`KmdbCollection.searchVault()`** (`kmdb_collection.dart:707`) — searches
  *extracted text of attached files*, a separate index from field FTS.
  **Decision: include, using pure-Dart extractors only** —
  `vaultSearch: VaultSearchConfig(extractors: [HtmlTextExtractor(),
  MarkdownTextExtractor()])`. `PdfTextExtractor` (native, from
  `kmdb_extractor_pdf`) is deliberately deferred to a "going further" note —
  it works on desktop but adds native-asset weight beyond what a v1 guide
  needs. `packages/kmdb_cli/lib/src/database_opener.dart:185` is the working
  reference for wiring extractors.

**Vault (attachments):** `VaultStore.ingest(bytes: ..., hlcTimestamp: ...,
originalName: ...)` (all **named** parameters, verified `vault_store.dart:202`;
`explicitMediaType` is an optional fourth) returns a `VaultRef`
(`kmdb-vault://sha256/<64hex>`);
`getBlob()` retrieves it. Storing the URI string in `Task.attachmentUris` and
writing the Task in the same batch is what makes ref-counting automatic via
`VaultRefInterceptor` (`kmdb_database.dart:196`).

**Encryption bootstrap** (§31 API, verified `encryption_config.dart` +
`kmdb_database.dart:294-757`):
- **Create:** `EncryptionConfig.createResult(passphrase: ...)` returns
  `EncryptionSetupResult{config, recoveryCode}`; pass `result.config` to
  `KmdbDatabase.open(...)`. Show the 16-word recovery code to the user exactly
  once. Provisioning against a non-empty DB throws
  `EncryptionError.cannotProvisionNonEmptyDatabase()`.
- **Unlock:** `KmdbDatabase.open(..., encryptionConfig:
  EncryptionConfig(passphrase: userPassphrase))`.
- **Fault paths to demonstrate:** wrong passphrase → `EncryptionError.badCredentials()`
  (verified `open()` releases the lock before rethrowing —
  `kmdb_database.dart:628-637` — so retrying `open()` with a corrected
  passphrase is safe); opening an encrypted DB with no `encryptionConfig` →
  `EncryptionError.databaseIsEncrypted()`; recovery via
  `EncryptionConfig(recoveryCode: ...)` as a companion demo to the
  wrong-passphrase path.
- **`kmdb_flutter`/`FlutterSecureDekCache`: NOT needed for v1.** It persists
  the unwrapped DEK across restarts to avoid re-prompting and re-paying the
  ~200ms Argon2id derivation; the default `InMemoryDekCache` (auto-selected
  when `dekCache` is omitted) works on desktop with only that per-launch cost.
  Omit the dependency for v1; mention as an optional enhancement.

**Screen inventory** (minimum set that lets every guide section cite real
code — no third-party state-management dependency, use the collections' own
`watch()`/`watchKey` reactive streams):
1. Unlock/Create — passphrase entry, create-vs-unlock branch, recovery-code
   display, `badCredentials` handling.
2. Project list — list + create.
3. Task list (per project) — `where(projectId)`, status/priority display.
4. Task detail/edit — fields, attach file (vault ingest), list/open
   attachments, add/list comments.
5. Search — task text search vs. attachment-content search toggle.
6. Sync/Settings — "Sync now" against a second local instance (Q4), device-id
   display.

**Package file layout** (`packages/kmdb_example_todo/`, non-workspace,
mirrors `packages/kmdb_icloud/example/`'s pattern of `publish_to: none` +
path dep on `kmdb` + a `dependency_overrides` block mirrored from root —
**this mirroring must be kept in sync as root overrides change, a known
footgun already present for `kmdb_flutter`/`kmdb_icloud/example`**):

```
packages/kmdb_example_todo/
  pubspec.yaml        # flutter + kmdb (path) + kmdb_extractor_html/_markdown
                      # (path); dependency_overrides mirrored from root
  macos/ linux/ windows/   # desktop runners only
  lib/
    main.dart
    src/
      db/app_database.dart     # open()/close(): indexes, ftsIndexes,
                                # schemas, vaultStore, vaultSearch,
                                # encryptionConfig, ensureDeviceId
      db/schemas.dart          # Project/Task/TaskComment CollectionSchemas
      models/{project,task,task_comment}.dart
      codecs/{project,task,task_comment}_codec.dart
      repositories/            # thin data-layer = the unit under test
        {project,task,comment,attachment}_repository.dart
        sync_service.dart      # wraps db.sync against LocalDirectoryAdapter
      ui/                      # screens above — coverage-exempt, see below
  test/                        # data-layer tests only, see list below
```

Coverage mechanism: mark `lib/src/ui/**` and `main.dart` with
`// coverage:ignore-file` (the repo's established mechanism, e.g.
`kmdb_cli`'s `vault_import_helper.dart`), so the non-workspace package's own
`flutter test --coverage` gate measures only `repositories/`, `codecs/`, and
`db/schemas.dart`.

**Sync demo** (Q4, confirmed viable for desktop-only scope): `SyncService`
opens two `KmdbDatabase` instances at different local paths, each calling
`ensureDeviceId()` (required before sync — `kmdb_database.dart:781`) then
`db.sync(syncAdapter: LocalDirectoryAdapter(sharedDir))`.

**Enumerated data-layer test list** (model on `packages/kmdb/test/`
conventions — `MemoryStorageAdapter` where fast, `StorageAdapterNative` +
temp dirs where native file behaviour matters, i.e. vault and sync):

- *CRUD:* insert assigns/round-trips a 32-char hex key; `replace()` on a
  missing key throws `DocumentNotFoundException`; `delete()` then `get()`
  returns null; codec round-trips `DateTime` via ISO-8601; codec emits no
  `_`-prefixed keys.
- *Schema admission:* valid Task admitted; `priority`/`status` outside their
  enum rejected; missing required field rejected; unknown field rejected
  (`additionalProperties: false`).
- *Secondary index:* `where(projectId)` returns only that project's tasks;
  `QueryPlan` shows index use once built; comment listing by `taskId`.
- *Vault round-trip (native adapter):* ingest returns a
  `kmdb-vault://sha256/<64hex>` URI and `getBlob()` round-trips identical
  bytes; attaching increments the `$vault` ref count; removing/deleting
  decrements it; duplicate ingest of identical bytes dedupes; attachment
  search (`searchVault`) finds the hosting doc after ingesting text/markdown.
- *Sync convergence (native adapter, two instances + shared dir):* A writes,
  `A.sync()` then `B.sync()`, B reads A's task (LWW); concurrent edits to the
  same task resolve by HLC; `$$fts:`/`$$vec:`/`$$index:` local-only
  namespaces are absent from the shared sync dir.
- *Encryption bootstrap:* `createResult` provisions and reopens correctly;
  wrong passphrase throws `badCredentials` and a subsequent correct-passphrase
  open still succeeds (lock was released); opening with no `encryptionConfig`
  throws `databaseIsEncrypted`; `recoveryCode` unlock succeeds; provisioning
  against a non-empty DB throws `cannotProvisionNonEmptyDatabase`.

## Implementation plan

- [ ] Scaffold `packages/kmdb_example_todo/` per the pinned file layout:
      `pubspec.yaml` (`publish_to: none`, `flutter` + path deps on `kmdb`,
      `kmdb_extractor_html`, `kmdb_extractor_markdown`,
      `dependency_overrides` mirrored from root), `macos/`/`linux/`/`windows/`
      runners only, `analysis_options.yaml`.
- [ ] Add the data model + codecs: `Project`, `Task`, `TaskComment` classes
      and their `KmdbCodec<T>` implementations per the pinned field lists
      (`DateTime` fields via ISO-8601).
- [ ] Add `db/schemas.dart`: JSON Schema (§25) definitions for `projects`,
      `tasks` (with `priority`/`status` enums, `additionalProperties: false`),
      and `taskComments`.
- [ ] Add `db/app_database.dart`: `KmdbDatabase.open()` wrapper wiring
      `indexes` (`tasks.projectId`, `taskComments.taskId`), `ftsIndexes`
      (`tasks.title`, `tasks.description`, `taskComments.body`),
      `vaultSearch` (`HtmlTextExtractor`, `MarkdownTextExtractor`),
      `encryptionConfig` (create-vs-unlock branch), and `ensureDeviceId()`.
- [ ] Add `repositories/`: `project_repository.dart`, `task_repository.dart`
      (incl. the `where(projectId)` query), `comment_repository.dart`,
      `attachment_repository.dart` (wraps `VaultStore.ingest`/`getBlob` and
      `attachmentUris` bookkeeping), `sync_service.dart` (wraps
      `ensureDeviceId()` + `db.sync(syncAdapter: LocalDirectoryAdapter(...))`).
- [ ] Add the six screens from the pinned screen inventory (Unlock/Create,
      Project list, Task list, Task detail/edit, Search, Sync/Settings),
      using `KmdbCollection.watch()`/`watchKey` for reactivity — no
      third-party state-management dependency. Mark `lib/src/ui/**` and
      `main.dart` with `// coverage:ignore-file`.
- [ ] Write the enumerated data-layer tests (CRUD, schema admission, index,
      vault round-trip, sync convergence via two `LocalDirectoryAdapter`
      instances, encryption bootstrap incl. wrong-passphrase and recovery-code
      paths) per the pinned list above.
- [ ] Add a dedicated CI job for the package (analyze/format/test on the
      macOS runner at minimum, per the desktop-only Q3 scope — confirm
      whether Linux/Windows runners are also needed for the full
      macOS/Linux/Windows target), modelled on the existing `make
      cicd_flutter`/iCloud jobs in `.github/workflows/cicd.yml`.
- [ ] Write the Integration Guide at `docs/integration_guide/README.md`,
      structured around the sample app: open/close a database (incl.
      encryption bootstrap), define collections and schemas, CRUD + queries,
      the secondary index, vault ingest/get/export, both search surfaces
      (field FTS and `searchVault`), sync via `LocalDirectoryAdapter`, and
      fault handling (`OpenResult`, wrong-passphrase, recovery code) — each
      section cross-referencing the relevant spec section number against the
      **post-spec-review** state of `docs/spec/` (per the prerequisite noted
      in the Problem statement —
      [plan_0_09_spec_review_and_primer_fold.md](plan_0_09_spec_review_and_primer_fold.md)
      must have landed on `main` before this step). Note hybrid/semantic
      search and `PdfTextExtractor` as "going further" callouts, not demoed
      paths.
- [ ] Cross-link the guide from `docs/spec/00_index.md` and the repo root
      `README.md`.
- [ ] Add an explicit note (in the guide's README or the package's own
      README) flagging the `dependency_overrides`-mirroring maintenance
      liability, so future root-override changes don't silently drift this
      package out of sync.

**Final step — QA sign-off and pre-commit:**

- [ ] Run the package's own `flutter test --coverage` — confirm
      `repositories/`, `codecs/`, and `db/schemas.dart` meet the project's
      coverage bar (UI is excluded via `coverage:ignore-file`, not measured).
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green
      (note: this package is non-workspace, so confirm its own analyze/format
      run separately, per CLAUDE.md's note that `make pre_commit`'s test step
      is `kmdb`-only).
- [ ] Verify licence headers on all new files (2026).

## Review notes (kmdb-plan-reviewer, 2026-07-17)

**Status set to `Questions`.** Open questions remain, and — importantly — even
once Q1–Q4 are answered this plan will need a second investigation pass before
it can reach `Investigated`: the implementation checklist is not yet mechanical
(see "Implementation readiness" below). Two of the four questions are also
mis-framed against existing repo conventions and should be corrected, not just
answered.

### Problem statement — sound, but the app is a means, not the deliverable

The roadmap item is real and worth doing. The one framing correction: the
**guide prose is the deliverable; the sample app is a vehicle** for it to quote
real, compiling code. Every scoping decision below should be driven by "what is
the minimum app that lets each guide section cite working code," not by "what
makes a good to-do app." The plan already shows the right instinct (UI is
smoke-tested only) — carry that discipline into the scope definition itself.

### Q2 is mis-framed — a Flutter sample app cannot be a workspace member

Q2 option 1 ("`packages/kmdb_example_todo/` as a full pub-workspace package …
gets melos/CI/analyze/format coverage") is **incompatible with a documented,
enforced repo policy**, and the architect's lean toward it (and the coverage
claim) is factually wrong here:

- The root `pubspec.yaml` (lines 19–26) explicitly excludes Flutter packages
  from the workspace, because they depend on `flutter: sdk: flutter` and would
  break `dart pub get` / `dart test` on the pure-Dart Linux/Windows CI runners.
- `kmdb_flutter` and `kmdb_icloud` are both non-workspace packages for exactly
  this reason, and **`packages/kmdb_icloud/example/` is the existing precedent
  for a Flutter app living in this repo**: not a workspace member, path deps on
  `kmdb`, `dependency_overrides` mirrored from root, its own dedicated CI job
  (`.github/workflows/cicd.yml`, the `test-flutter` / iCloud jobs on the macOS
  runner via `make cicd_*`).

So the real choice is *not* "workspace package vs. standalone." A Flutter app is
**necessarily** standalone-with-its-own-CI-job. That collapses options 1 and 2
into one answer and makes the native-asset-hook worry largely moot (the app was
never going to join the workspace regardless). **Reframe Q2 as:** where does the
non-workspace Flutter package live (`packages/kmdb_example_todo/` alongside the
other non-workspace Flutter packages is the natural fit, mirroring
`kmdb_icloud/example`), and what dedicated CI job (`make cicd_example` +
workflow step) covers analyze/format/test — modelled on `make cicd_flutter`.
Option 3 (extend `packages/kmdb/example/`) should be dropped: that dir is a
pure-Dart, no-Flutter snippet and must stay that way to remain in the workspace.

### Q4 — option (a) is fully real; name the adapter and note the web caveat

The "two `open()` calls sharing a sync folder, no real cloud adapter needed"
idea is not hypothetical: **`LocalDirectoryAdapter`**
(`packages/kmdb/lib/src/sync/local/local_directory_adapter.dart`, exported from
`kmdb.dart`, `SyncStorageAdapter`-conformant) is exactly this — its own doc
comment lists "locally-synced cloud folders" as a use case. Point two db
instances at one directory and you have a credential-free, fully in-suite sync
demo. The plan should name it rather than hand-wave "no real cloud adapter."

**Caveat that ties Q4 to Q3:** `LocalDirectoryAdapter` is `dart.library.io`
(native-only) — it does **not** exist on web. So if Q3 includes web, the sync
section of the guide cannot use this adapter on that platform. Resolve Q3 first,
then Q4's demo mechanism per-platform.

### Q1 and Q3 — genuine, but low-cost

- **Q1** (guide placement) is a cheap preference call; option 1
  (`docs/integration_guide/`) is the low-churn default and I'd take it unless
  the user wants the `docs/guides/` umbrella restructure now.
- **Q3** (platform scope) is a genuine user/CI-cost decision and correctly left
  open. Note its downstream reach: it gates Q4's sync mechanism (above), and
  web additionally changes the search story (ONNX/`betto_inferencing` semantic
  search is excluded on web per §20) and the native-asset build path. macOS is
  the natural minimum (the existing Flutter CI job already runs there).

### Implementation readiness — NOT yet mechanical (blocks `Investigated`)

Even setting the open questions aside, the checklist hides large design work
behind one-line steps and would force a Sonnet implementer to invent
architecture:

- **No data model is specified.** The Dart model classes, their `KmdbCodec<T>`
  implementations, the JSON Schemas (§25) for projects/tasks, and the
  `SecondaryIndexDefinition` for `projectId` (§16) are all undefined. These are
  the load-bearing parts the guide quotes — they must be pinned down in the
  plan, with field types and enum value sets, not left to implementation.
- **"comments/updates … resolve during implementation" is an explicit deferral
  of a data-model design decision** (sub-collection vs. embedded array). That is
  precisely the kind of on-the-fly architecture call the `Investigated` bar
  forbids. Decide it in the plan — it changes the schema, the write path, and
  what the guide teaches.
- **The UI is completely unspecified.** "basic UI to create/list/update" hides
  the entire screen inventory, navigation, and state-management approach. Define
  the minimum screen set (and pick a state approach) or the implementer is
  designing an app. Keep it as small as the guide's citations allow.
- **No named files/classes and no test list.** Contrast the sibling
  spec-review plan, which names exact files and line numbers. This plan needs
  the same: the concrete file layout of the sample package and an enumerated
  list of the data-layer tests (collections, schema admission/rejection,
  queries, index, vault ingest/get/export round-trip, sync convergence via the
  two-instance `LocalDirectoryAdapter` setup).
- **"Fault handling" is under-specified.** The guide requirement maps to more
  than "document `OpenResult`/§17" — decide whether the app actually
  demonstrates handling an `OpenResult` with issues (and, if encryption is in
  scope, a bootstrap failure). Which leads to:
- **Encryption in/out of scope is an undecided fork** ("if the sample app opts
  into encryption"). Decide it; it changes the open/bootstrap flow the guide
  shows and the DEK-cache dependency (`kmdb_flutter`).

### Risks / edge cases to capture

- **Maintenance liability.** An in-repo sample app must keep compiling against
  `kmdb` as core evolves, and its dedicated Flutter CI job adds macOS-runner
  cost and a new failure surface. Worth an explicit line acknowledging this is
  ongoing cost, not a write-once artifact.
- **`dependency_overrides` drift.** Like `kmdb_flutter`/`kmdb_icloud/example`,
  the sample app must mirror the root overrides and keep them in sync — a known
  footgun in this repo. Call it out in the checklist.
- **Coverage bar.** The final step says data-layer code must meet the coverage
  bar while UI is exempt — but a non-workspace Flutter package runs its own
  `flutter test --coverage` gate (see the `test-flutter` job's ≥90% enforcement)
  and coverage cannot selectively exempt UI unless UI is excluded via
  `coverage:ignore` or kept out of the measured library. Specify the mechanism.

### Recommendation

Proceed with the plan, but it is **two steps away from implementable**:

1. Take the reframed answers to Q1–Q4 (Q2 collapses to "non-workspace Flutter
   package with its own CI job, sited like `kmdb_icloud/example`"; Q4 names
   `LocalDirectoryAdapter` and is gated on the Q3 platform decision).
2. Then do a second investigation pass that pins the data model, schemas, index
   definitions, comments representation, screen inventory, encryption
   in/out-of-scope, the sample-package file layout, and the enumerated test
   list — at which point it can move to `Investigated`.

Do not promote to `Investigated` on the strength of answering the four
questions alone.

## Confirmed decisions (2026-07-17)

Q1–Q4 above are resolved as recorded. One further design fork the reviewer
flagged under "Implementation readiness" is also now decided:

- [x] **Encryption in scope.** The sample app demonstrates encryption
      end-to-end: passphrase bootstrap on create/open, and a wrong-passphrase
      fault path in the guide's fault-handling section. This is a deliberate
      choice over the simpler unencrypted-only option — it makes the "handle
      faults" requirement in the roadmap item concrete rather than limited to
      `OpenResult`/crash-recovery alone, and encryption is a core `kmdb`
      feature worth showing a library consumer how to wire up correctly.
      Downstream effect: the second investigation pass (below) must pin the
      concrete open/bootstrap flow with encryption enabled, and confirm
      whether `kmdb_flutter`'s `FlutterSecureDekCache` is needed for a
      desktop-only app or is mobile/session-cache-specific and skippable here.

The second investigation pass (data model, schemas, index definitions,
comments representation, search surfaces, encryption bootstrap flow, screen
inventory, package file layout, enumerated test list) has landed — see
"Second investigation pass — pinned design" above. Two further calls made
during that pass, recorded here rather than left as open questions since they
were forced or low-risk:

- [x] **Comments representation: sub-collection, not embedded.** Not a
      preference — forced by `fts_manager.dart`'s Map-only/String-only field
      extraction, which cannot search an embedded array. Since the roadmap
      asks the guide to demonstrate search including comments, the
      sub-collection is the only representation that satisfies that
      requirement.
- [x] **Attachment-content search (`searchVault`) scope: include, pure-Dart
      extractors only.** `HtmlTextExtractor`/`MarkdownTextExtractor` for v1;
      `PdfTextExtractor` (native) deferred to a "going further" callout to
      keep the sample package's native-asset surface minimal.

This plan is ready for a final pass by `kmdb-plan-reviewer` to confirm it now
clears the `Investigated` bar.

## Review notes — second pass (kmdb-plan-reviewer, 2026-07-17)

**Status promoted to `Investigated`.** The four open questions plus the
encryption fork are all decided and recorded, and the second investigation pass
pins the data model, codecs, schemas, indexes, both search surfaces, the
encryption bootstrap, the screen inventory, the non-workspace package layout,
and an enumerated test list concretely enough for mechanical execution.

**API shapes spot-checked against current `main` — all confirmed accurate:**

- `KmdbCodec<T>`: `keyOf` / `withKey` / `encode` / `decode` present as described;
  `encode()` must emit no `_`-prefixed key, `decode()` reads the injected `_id`
  (`kmdb_codec.dart:69-108`). Matches the plan's model↔codec design.
- `IndexDefinition('ns', 'path')` — positional, as cited
  (`query/index/index_definition.dart:74`; the investigation's file list drops
  the `query/` prefix, cosmetic).
- `FtsIndexDefinition({required collection, required field, ...})` — named, as
  cited (`fts_index_definition.dart:64`).
- `search(query, {fields, mode, limit, ...})` and `searchVault(query, {mode,
  limit, offset})` — both match (`kmdb_collection.dart:470,707`).
- `EncryptionConfig.createResult(passphrase:)` → `EncryptionSetupResult{config,
  recoveryCode}`; `EncryptionConfig(passphrase:)` / `(recoveryCode:)`;
  `EncryptionError.databaseIsEncrypted()` / `.badCredentials()` /
  `.cannotProvisionNonEmptyDatabase()` — all present as factories
  (`encryption_config.dart`, `encryption_error.dart`).
- `VaultSearchConfig({extractors, chunkSize, chunkOverlap})` with
  `HtmlTextExtractor()` / `MarkdownTextExtractor()` — all real; the
  `database_opener.dart:185` wiring reference is accurate.
- `LocalDirectoryAdapter(rootPath, {atomicCas})`, native-only, exported;
  `ensureDeviceId()` → `Future<String>`, required before sync
  (`kmdb_database.dart:781`). Consistent with the desktop-only Q3/Q4 decisions.
- The comments-as-sub-collection forcing function is real: `fts_manager.dart`'s
  `_extractFieldValue` (line 1483) walks `field.split('.')` through Maps only and
  returns only a non-empty `String` — no array fan-out. An embedded
  `List<Comment>` genuinely cannot be FTS-indexed, so the sub-collection is
  forced, not a preference. Well grounded.

**One misquote corrected in this pass:** the investigation prose wrote
`VaultStore.ingest` positionally; the real method takes **named** parameters
(`ingest(bytes:, hlcTimestamp:, originalName:, explicitMediaType:)`,
`vault_store.dart:202`). Fixed inline so `attachment_repository.dart` is written
against the correct signature.

**No new inconsistency introduced by the pinned design.** Platform scope
(desktop-only), the `LocalDirectoryAdapter` two-instance sync mechanism, and the
non-workspace package placement are coherent across the questions, the pinned
design, and the checklist. The package is correctly kept out of the root
`workspace:` list (Flutter packages are excluded there — root `pubspec.yaml`, and
`kmdb_flutter`/`kmdb_icloud` set the precedent). The plan's "lines 19–26"
citation is a few lines off from the actual comment block but the substance holds.

**One residual soft spot (non-blocking).** Checklist step 7 (CI job) still
embeds "confirm whether Linux/Windows runners are also needed." Given Q3 fixed
the target at macOS/Linux/Windows, whether CI exercises all three or macOS-only
is a small operational call, not architecture — acceptable latitude for the
implementer. The macOS runner is the stated minimum, matching the existing
Flutter CI precedent.

## Summary

{To be completed once implemented.}
