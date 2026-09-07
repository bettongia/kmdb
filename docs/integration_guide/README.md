---
title: KMDB Integration Guide
subtitle: Using kmdb as a library in your Dart/Flutter application
toc-title: "Contents"
...

# Introduction

This guide is for **Dart/Flutter application developers** integrating `kmdb`
as a library — opening and closing a database, defining collections and
schemas, running queries, using the secondary index, attaching files via the
vault, searching, syncing across devices, and handling faults. It is a
different register from [`docs/spec/`](../spec/00_index.md), which is the
normative reference for on-disk formats and protocol detail aimed at
maintainers; this guide is task-oriented ("how do I…") and assumes you never
need to read the spec to build a working app, though every section links to
the relevant spec number for when you want the full detail.

If you are looking for the `kmdb` **command-line tool** instead, see the
[CLI User Guide](../user_guide/README.md).

## The companion sample app

Every code sample in this guide is lifted from a real, tested, working
application: **`packages/kmdb_example_todo/`**, a desktop Flutter to-do app
with multiple projects, each containing tasks (title, description, priority,
status, file attachments, and comments). It exercises every subsystem this
guide covers — schema admission, the secondary index, both search surfaces,
the vault, authenticated sync, and encryption — end to end, with a full data-
layer test suite. If a snippet below looks incomplete, the full context is in
that package.

```
packages/kmdb_example_todo/
  lib/
    main.dart                    # app entry point (coverage-exempt, see below)
    src/
      models/                    # Project, Task, TaskComment
      codecs/                    # KmdbCodec<T> implementations
      db/
        schemas.dart             # JSON Schema (§25) admission gates
        app_database.dart        # KmdbDatabase.open() wrapper
      repositories/              # thin data-access layer — the unit under test
      ui/                        # the six screens (coverage-exempt)
  test/                          # data-layer tests (repositories/, codecs/, db/schemas.dart)
```

## Platform scope

This guide and its sample app target **desktop only for v1 — macOS, Linux,
and Windows**. There is no mobile or web build. This is a scope choice, not a
hard architectural limit: the barrel (`package:kmdb/kmdb.dart`) compiles for
web, `StorageAdapterSahPool` gives web persistence, and `WebSyncAuthenticator`
exists — so **web is a natural v2 extension** of this guide. The two things
that keep v1 desktop-only are (a) the sync mechanic this guide demonstrates,
`LocalDirectoryAdapter`, is native-only (`dart.library.io`), and (b) semantic
search's ONNX inference is still deferred on web (see §22). Neither of those
is relevant to a first read of this guide.

# Install kmdb

Add `kmdb` to your `pubspec.yaml`:

```yaml
dependencies:
  kmdb: ^0.1.0
```

If you want vault attachment-content search over HTML or Markdown files (see
["Search: two surfaces"](#search-two-surfaces) below), also add:

```yaml
dependencies:
  kmdb_extractor_html: ^0.1.0
  kmdb_extractor_markdown: ^0.1.0
```

`import 'package:kmdb/kmdb.dart';` gives you the full public API surface used
throughout this guide.

# Define your data model and codecs

`kmdb` stores documents as `Map<String, dynamic>`; your typed model classes
never touch that map directly. A `KmdbCodec<T>` bridges the two.

## The model

The sample app's `Task` model (`lib/src/models/task.dart`) is a plain Dart
class:

```dart
class Task {
  const Task({
    required this.id,
    required this.projectId,
    required this.title,
    required this.description,
    required this.priority,
    required this.status,
    required this.attachmentUris,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;            // 32-char hex UUIDv7, or '' before insert()
  final String projectId;     // FK -> Project.id
  final String title;
  final String description;
  final String priority;      // constrained by JSON Schema, see below
  final String status;        // constrained by JSON Schema, see below
  final List<String> attachmentUris; // 'kmdb-vault://sha256/<64hex>'
  final DateTime createdAt;
  final DateTime updatedAt;
}
```

Note that `priority` and `status` are plain `String` fields here, **not**
Dart enums. `kmdb`'s codec contract only understands JSON-compatible scalars,
so an enum would need to be converted to/from a string somewhere anyway; the
sample app puts the "which values are legal" constraint entirely in the JSON
Schema (below), and exposes the allowed value sets as `String` constants
(`TaskPriority.high`/`.medium`/`.low`, `TaskStatus.backlog`/`.inProgress`/
`.done`) purely for compile-time-checked call sites.

## The codec

```dart
class TaskCodec implements KmdbCodec<Task> {
  const TaskCodec();

  @override
  String? keyOf(Task value) => value.id;

  @override
  Task withKey(Task value, String key) => Task(
    id: key,
    projectId: value.projectId,
    title: value.title,
    description: value.description,
    priority: value.priority,
    status: value.status,
    attachmentUris: value.attachmentUris,
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
  );

  @override
  Map<String, dynamic> encode(Task value) => {
    'projectId': value.projectId,
    'title': value.title,
    'description': value.description,
    'priority': value.priority,
    'status': value.status,
    'attachmentUris': value.attachmentUris,
    'createdAt': value.createdAt.toIso8601String(),
    'updatedAt': value.updatedAt.toIso8601String(),
  };

  @override
  Task decode(Map<String, dynamic> json) => Task(
    id: json['_id'] as String,
    projectId: json['projectId'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    priority: json['priority'] as String,
    status: json['status'] as String,
    attachmentUris: (json['attachmentUris'] as List<dynamic>)
        .map((e) => e is VaultRef ? e.uri : e as String)
        .toList(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
```

Three contract rules to internalise (spec §13):

- **`encode()` must not emit any top-level `_`-prefixed key.** The `_id` field
  is reserved for the framework-managed key; if your `encode()` includes one,
  every write throws `ReservedFieldException`.
- **`decode()` receives `_id` pre-injected.** The framework adds it to the map
  before calling your `decode()` — that is the only way to recover the
  document's key.
- **`DateTime` (and anything else non-JSON-scalar) needs manual
  serialization.** `toIso8601String()`/`DateTime.parse()` is the pattern used
  throughout this guide.

There is a fourth, less obvious rule the `TaskCodec` above demonstrates:
**vault URI strings may arrive as wired `VaultRef` objects, not plain
strings.** `KmdbCollection.decodeDoc` walks the raw document map *before*
calling your `decode()` and replaces every `kmdb-vault://` URI it finds — at
any depth, including inside lists — with a `VaultRef` instance backed by the
database's `VaultStore` (so `VaultRef.getBlob()`/`getMetadata()` work
directly). This only happens when the database was opened with a
`vaultStore` (see ["Vault: attachments"](#vault-attachments) below); a
database opened without one leaves the strings alone. Since `Task
.attachmentUris` is typed `List<String>`, `decode()` must normalise each
element back to its bare URI string regardless of which shape it arrives in
— the `e is VaultRef ? e.uri : e as String` line above is that
normalisation, and it is easy to miss if you only test against a
vault-less database.

# Define collections and schemas

## JSON Schema admission (spec §25)

A `CollectionSchema` is an optional admission gate, checked on every write to
a collection (`put`/`insert`/`replace`/`update` — never on `delete`, and never
on sync ingest, spec §25). The sample app's `tasks` schema
(`lib/src/db/schemas.dart`):

```dart
static final CollectionSchema tasks = CollectionSchema(
  collection: 'tasks',
  jsonSchema: {
    'required': [
      'projectId', 'title', 'description', 'priority', 'status',
      'attachmentUris', 'createdAt', 'updatedAt',
    ],
    'properties': {
      'projectId': {'type': 'string', 'minLength': 1},
      'title': {'type': 'string', 'minLength': 1},
      'description': {'type': 'string'},
      'priority': {'type': 'string', 'enum': TaskPriority.values},
      'status': {'type': 'string', 'enum': TaskStatus.values},
      'attachmentUris': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'createdAt': {'type': 'string', 'format': 'date-time'},
      'updatedAt': {'type': 'string', 'format': 'date-time'},
    },
    'additionalProperties': false,
  },
);
```

`additionalProperties: false` is what makes a typo'd or removed field a loud
`SchemaValidationException` at write time rather than a silently-dropped
field — worth keeping in mind before adding a new field to a model without
also updating its schema. A violating write throws before any I/O:

```dart
try {
  await tasks.insert(task);
} on SchemaValidationException catch (e) {
  for (final v in e.violations) {
    print('${v.path}: ${v.message}'); // every violation, reported together
  }
}
```

## Comments: a sub-collection, not an embedded list

The sample app's task comments (`taskComments`) are their own top-level
collection — **not** an embedded `List<Comment>` field on `Task`. This is
forced, not a style preference: `FtsManager`'s field extractor only walks
`Map`s and only recognises a non-empty `String` leaf value — it does not fan
out arrays or concatenate array elements (unlike secondary indexes, which do
support `tags[]`-style fan-out, spec §16). An embedded `List<Comment>` would
therefore be **invisible to full-text search**. Since searching comment text
is one of the things this guide demonstrates, `taskComments` has to be a
real collection:

```dart
FtsIndexDefinition(collection: 'taskComments', field: 'body'),
IndexDefinition('taskComments', 'taskId'),
```

This also happens to be a second worked example of a one-to-many
relationship, alongside project → tasks.

# Open and close a database

## The basics

```dart
final adapter = StorageAdapterNative();
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  schemas: AppSchemas.all,
  indexes: [
    IndexDefinition('tasks', 'projectId'),
    IndexDefinition('taskComments', 'taskId'),
  ],
  ftsIndexes: [
    FtsIndexDefinition(collection: 'tasks', field: 'title'),
    FtsIndexDefinition(collection: 'tasks', field: 'description'),
    FtsIndexDefinition(collection: 'taskComments', field: 'body'),
  ],
);
// ... use db ...
await db.close();
```

`StorageAdapterNative` is the real filesystem — the adapter you want for a
real desktop app. (`MemoryStorageAdapter` exists too, and is what the sample
app's fast data-layer tests use for CRUD/schema/index coverage; vault and
sync tests keep the real adapter, since those subsystems' crash-safety
depends on genuine filesystem semantics.)

## The stable device ID — a two-phase open

Every SSTable a device flushes is named `{deviceId}-{minHlc}-{maxHlc}.sst`
(spec §8), and that ID is baked in when the underlying storage engine is
constructed — `KmdbDatabase.ensureDeviceId()` **cannot** retroactively change
it once the store is open. If you plan to sync at all (see
["Sync"](#sync-two-instances-one-shared-folder) below), open your database in
two phases, mirroring `kmdb_cli`'s `DatabaseOpener`:

```dart
const defaultDeviceId = '00000000';
var (minimalStore, _) = await KvStoreImpl.open(path, adapter);
final deviceId = await minimalStore.ensureDeviceId();
if (deviceId != defaultDeviceId) {
  await minimalStore.close(flush: false); // no data was written yet
}

final db = await KmdbDatabase.open(
  path: path,
  adapter: adapter,
  deviceId: deviceId, // <-- the stable ID, not the default sentinel
  // ...
);
```

Skipping this — opening once with the default and calling `ensureDeviceId()`
afterwards — leaves the instance permanently on the `'00000000'` sentinel.
That is harmless for a database that never syncs, but **fatal once two
instances try to sync**: they collide on the same per-device high-water-mark
filename and SSTable name prefix. The sample app's `AppDatabase.open()`
(`lib/src/db/app_database.dart`) implements this two-phase pattern once, so
every call site gets it for free.

## Encryption bootstrap (spec §31)

Encryption is opt-in per database. Creating a **new** encrypted database and
opening an **existing** one are different calls:

```dart
// Create — provisioning a brand-new encrypted database.
final setup = await EncryptionConfig.createResult(passphrase: userPassphrase);
final db = await AppDatabase.open(path: dbPath, encryptionConfig: setup.config);
// Show setup.recoveryCode to the user EXACTLY ONCE — it cannot be recovered
// if lost, and this is the only time the API surfaces it.

// Unlock — opening an existing encrypted database.
final db = await AppDatabase.open(
  path: dbPath,
  encryptionConfig: EncryptionConfig(passphrase: userPassphrase),
);

// Unlock via the 16-word recovery code instead of a passphrase.
final db = await AppDatabase.open(
  path: dbPath,
  encryptionConfig: EncryptionConfig(recoveryCode: theRecoveryCode),
);
```

Provisioning a config against a database that already has user data throws
`EncryptionError.cannotProvisionNonEmptyDatabase()` — encryption must be
decided before the first write, not retrofitted.

**There is no DEK cache.** Every unlock — passphrase, recovery code, or
biometric — re-derives and re-verifies credentials; nothing is cached warm
across opens. The cost is one Argon2id derivation per open (~200ms), which is
an acceptable trade for closing a real defect (a warm cache could previously
let a wrong passphrase silently "work"). See the sample app's Unlock/Create
screen (`lib/src/ui/screens/unlock_screen.dart`) for the full create-vs-unlock
branch, including the recovery-code display dialog.

### Fault path: wrong passphrase

```dart
try {
  final db = await AppDatabase.open(
    path: dbPath,
    encryptionConfig: EncryptionConfig(passphrase: userPassphrase),
  );
} on EncryptionError catch (e) {
  switch (e.code) {
    case EncryptionErrorCode.badCredentials:
      // Wrong passphrase or recovery code. The database's lock was already
      // released before this throw — retrying open() with the correct
      // credential is safe, no cleanup needed.
      break;
    case EncryptionErrorCode.databaseIsEncrypted:
      // encryptionConfig was null, but the database IS encrypted.
      break;
    default:
      // See EncryptionErrorCode for the full set.
  }
}
```

# CRUD and queries (spec §13)

`KmdbCollection<T>` gives you `insert`/`get`/`replace`/`put`/`delete`, plus a
composable query builder:

```dart
final projects = db.collection<Project>(name: 'projects', codec: const ProjectCodec());

final created = await projects.insert(newProject);        // strict create — throws if value already has a key
await projects.replace(updatedProject);                    // throws DocumentNotFoundException if the key doesn't exist
await projects.put(upsertedProject);                        // upsert — keyless mints a key, keyed updates in place
final fetched = await projects.get(created.id);             // -> T?
await projects.delete(created.id);                          // no-op if the key doesn't exist

final all = await projects.all().orderBy('createdAt').get();
final proj1Tasks = await tasks
    .where(Field('projectId').equals(project.id))
    .orderBy('createdAt')
    .get();
```

Pick `insert` when you want to *guarantee* a fresh document (it throws
`ArgumentError` if the value already carries a key); pick `put` for a normal
save-this-document call whether it is new or existing; pick `replace` when
you specifically want "this key must already exist."

# The secondary index (spec §16)

`IndexDefinition('tasks', 'projectId')`, registered at `open()` time, is what
makes `tasks.where(Field('projectId').equals(...))` fast instead of a full
collection scan. No index entries are written at open time — the index
builds **lazily** on first query, moving through four states: `undefined` →
`building` → `current` (or `stale` if writes arrived mid-build). Use
`explainedGet()` to see which strategy a query actually used:

```dart
final (results, plan) = await tasks
    .where(Field('projectId').equals(project.id))
    .orderBy('createdAt')
    .explainedGet();

print(plan.strategy);              // ScanStrategy.fullScan or .indexScan
print(plan.filters.first.indexUsed); // true once the index has finished building
```

A freshly-registered index answers its first few queries via a full scan
while it builds in the background; once `current`, subsequent queries use
`ScanStrategy.indexScan`. Both are correct — this is an optimisation, not a
correctness concern — but `explainedGet()` is how you'd verify it in a test,
exactly as the sample app's `TaskRepository.explainListByProject()` does.

# Reactivity: watch() and watchKey() (spec §14)

No third-party state-management dependency is needed to keep a Flutter UI in
sync with the database — `KmdbQuery.watch()` and `KmdbCollection.watchKey()`
are `Stream`s you can hand directly to a `StreamBuilder`:

```dart
Stream<List<Task>> watchByProject(String projectId) => tasks
    .where(Field('projectId').equals(projectId))
    .orderBy('createdAt')
    .watch();

Stream<Task?> watchTask(String id) => tasks.watchKey(id); // emits null if deleted
```

`watch()` re-runs the query on every write to the collection's namespace,
debounced at 50ms so a burst of writes doesn't re-run the query once per
write. `watchKey()` is cheaper for a single-document detail screen: it only
re-fetches that one key, not a full filtered scan. The sample app's six
screens are built entirely on these two primitives plus `StreamBuilder` —
see `lib/src/ui/screens/` for the full pattern.

# Vault: attachments (spec §24)

`VaultStore` is a content-addressable blob store: `ingest()` writes bytes
once (deduplicating identical content across every document that references
it) and returns a `kmdb-vault://sha256/<64hex>` URI you store as a plain
string field on your document.

```dart
final vaultStore = VaultStore(dbDir: dbPath, adapter: adapter);
final db = await KmdbDatabase.open(
  path: dbPath,
  adapter: adapter,
  vaultStore: vaultStore,
  // ...
);

// Ingest, then attach the URI to a document in the SAME write.
final info = await db.store.storeInfo();
final ref = await vaultStore.ingest(
  bytes: fileBytes,
  hlcTimestamp: info.currentHlc,
  originalName: 'report.md',
);
final updated = task.copyWith(attachmentUris: [...task.attachmentUris, ref.uri]);
await tasks.put(updated); // writes the doc AND the ref-count increment atomically
```

## Ref counting is automatic — if you write through KmdbCollection

Supplying `vaultStore` to `open()` activates `VaultRefInterceptor`, which
scans every document write for `kmdb-vault://` URIs and adjusts the object's
reference count in the **same `WriteBatch`** as the document write. This is
why the ingest-then-attach pattern above needs no separate "commit the ref
count" step: as long as you write the updated document through
`KmdbCollection` (not by hand-rolling `WriteBatch` entries), ref counting
just happens. Removing a URI from `attachmentUris` and writing the document
again decrements the count; once it reaches zero and no other document
references the object, it becomes eligible for garbage collection.

Retrieve the bytes back via `VaultStore.getBytes(sha256)`, or — for a
document already decoded through `KmdbCollection` — via the wired `VaultRef`
your codec's `decode()` receives (see
["Define your data model and codecs"](#define-your-data-model-and-codecs)
above for why `decode()` needs to unwrap it back to a plain string for a
`List<String>`-typed field).

## Exporting a document with its attachments (KVLT packaging)

`VaultPackage.write`/`.read` bundle a document and its attachments into a
single portable, Zstandard-compressed archive (the same `.kvlt` format the
CLI's `vault export`/`insert --import` commands use) — useful for "export this
task with its files" or "back up a document" features:

```dart
final archive = VaultPackage.write(
  documentJson: taskCodec.encode(task),
  attachments: [
    for (final uri in task.attachmentUris)
      VaultAttachment(
        subdirName: VaultRef(uri).sha256,
        bytes: await vaultStore.getBytes(VaultRef(uri).sha256),
      ),
  ],
);
await File('task-export.kvlt').writeAsBytes(archive);

// Later, or on another device:
final contents = VaultPackage.read(await File('task-export.kvlt').readAsBytes());
// contents.documentJson and contents.attachments are ready to re-ingest.
```

# Search: two surfaces

`kmdb` has two independent text-search surfaces, both backed by BM25 lexical
scoring for this guide (`SearchMode.lexical` — see
["Going further"](#going-further) for hybrid/semantic mode).

## Field search (spec §20–21)

Searches document *fields* you've registered an `FtsIndexDefinition` for:

```dart
final result = await tasks.search(
  'quarterly revenue',
  fields: ['title', 'description'],
  mode: SearchMode.lexical,
);
for (final hit in result.hits) {
  print('${hit.rank}. [${hit.score.toStringAsFixed(3)}] ${hit.document.title}');
}
```

## Attachment-content search (spec §32)

Searches the **extracted text of attached files** — a completely separate
index from field search above, populated by registering `vaultSearch` at
`open()` time with one or more `VaultTextExtractor`s:

```dart
final db = await KmdbDatabase.open(
  path: dbPath,
  adapter: adapter,
  vaultStore: vaultStore,
  vaultSearch: VaultSearchConfig(
    extractors: [HtmlTextExtractor(), MarkdownTextExtractor()],
  ),
  // ...
);

final result = await tasks.searchVault('revenue', mode: SearchMode.lexical);
for (final hit in result.hits) {
  print('${hit.rank}. ${hit.document.title} — "${hit.chunkContext.snippet}"');
}
```

The sample app registers only pure-Dart extractors (`HtmlTextExtractor`,
`MarkdownTextExtractor`) to keep its native-asset footprint minimal — see
["Going further"](#going-further) for `PdfTextExtractor`. Vault content
extraction and indexing run asynchronously in a background isolate queue, so
a `searchVault()` call immediately after `ingest()` may not yet see the new
content; poll or wait briefly if you need read-your-writes for a test.

# Sync: two instances, one shared folder (spec §12, §34)

## The mechanism

`LocalDirectoryAdapter` is a credential-free `SyncStorageAdapter` backed by
any directory `dart:io` can see — a local test folder, a NAS mount, or a
Dropbox/OneDrive/iCloud-as-local-filesystem folder. Point two
`KmdbDatabase` instances at **different local paths** but the **same** shared
directory, and you have a fully working, no-cloud-credentials-needed sync
demo:

```dart
final result = await dbA.sync(
  syncAdapter: SyncAuthenticatingAdapter(
    LocalDirectoryAdapter(sharedDir),
    DefaultSyncAuthenticator(rootKey),
  ),
);
```

## Authentication is mandatory, not optional

Since 0.10.01 (WI-4), every sync artefact is authenticated: `db.sync()`
expects an adapter already wrapped in `SyncAuthenticatingAdapter`, built from
a `DefaultSyncAuthenticator` sharing the **same 256-bit root key** across
every device in the sync set. Passing a **raw** `LocalDirectoryAdapter` — no
wrapping — no longer converges: the peer rejects every artefact it cannot
authenticate.

**DEMO ONLY — never hard-code a sync root key in production.** The sample
app's two-instance demo (`lib/src/repositories/sync_service.dart`) uses a
fixed 32-byte constant shared by both demo instances, purely so the demo is
self-contained:

```dart
/// DEMO ONLY — never hard-code a sync root key in production.
final Uint8List kDemoSyncRootKey = Uint8List.fromList(
  List<int>.generate(32, (i) => i),
);
```

A real application must never do this. The real enrolment story:

- **At the CLI level**, `kmdb remote add` mints a key automatically for the
  first device; a second device joins via `kmdb remote pair show` on the
  enrolled device (prints a pairing code), then `kmdb remote pair import` on
  the new device.
- **At the app level**, the equivalent is: generate a 32-byte root key once,
  store it in a `SecretStore`, and transfer it to each additional device out
  of band (QR code, paired-device handshake, whatever your app's UX
  supports) — your application owns this key-sharing flow. The demo constant
  stands in for that flow purely because two co-located demo instances have
  no real "out of band" to transfer through anyway.

## Fault handling: quarantine, not a thrown error

A mismatched or unauthenticatable peer artefact does **not** surface as a
thrown exception from `sync()`/`pull()` in the normal case — it is
**quarantined**: rejected, skipped, and logged, while the rest of the sync
proceeds.

```dart
final result = await db.sync(syncAdapter: adapter); // SyncResult
if (result.pull.quarantined.isNotEmpty) {
  // Peer artefacts that failed authentication (or were otherwise corrupt/
  // invalid) this call — permanently rejected, not re-fetched.
}
if (result.pull.deferred.isNotEmpty) {
  // Transiently skipped (e.g. below the local tombstone-GC floor) — retried
  // automatically on a later pull, not a fault.
}

// The durable, device-local record — survives across restarts and missed
// per-call results:
final everQuarantined = await db.quarantinedSstables();
await db.clearQuarantineLog(); // acknowledge; does not un-quarantine the files
```

`sync()` returns `SyncResult` (wrapping the pull half's `PullResult`), and
`pull()` returns `PullResult` directly — neither is `void`. Always inspect
`quarantined`/`deferred` rather than assuming a non-throwing call means
"everything applied." See §34's per-site rejection-policy table for exactly
which sync call sites quarantine versus propagate a `SyncAuthException`.

## Local-only data never leaves the device

All `$$fts:*`, `$$vec:*`, and `$$index:*` system namespaces — the secondary
index and both search indexes this guide covers — are **local-only**: stored
in `.local.sst` files and never uploaded to the sync folder (spec §16, §20).
Every device rebuilds these derived indexes independently from the synced
document data; there is nothing to reconcile.

# Handle faults

A summary of the fault surfaces this guide has already covered, gathered in
one place:

| Fault | Surface | What it means |
| :---- | :------ | :------------ |
| Schema violation | `SchemaValidationException` thrown by `insert`/`put`/`replace`/`update` | The write was rejected before any I/O — inspect `.violations` |
| Wrong passphrase/recovery code | `EncryptionError.badCredentials()` from `open()` | The lock was already released; retry `open()` with the correct credential |
| Opened encrypted DB with no config | `EncryptionError.databaseIsEncrypted()` from `open()` | Supply an `EncryptionConfig` |
| Provisioning a non-empty DB | `EncryptionError.cannotProvisionNonEmptyDatabase()` from `open()` | Encryption must be decided before the first write |
| Unauthenticatable sync peer | `PullResult.quarantined` non-empty (not a thrown error) | The artefact was rejected and logged; sync itself succeeded |
| Missing document on `replace()` | `DocumentNotFoundException` | The key doesn't exist yet — use `put()` to upsert instead |
| Interrupted index build (unclean shutdown) | `onIndexRebuildRequired` callback to `KmdbDatabase.open()` | Decide when to trigger a rebuild; the affected namespaces are listed |

Crash recovery itself (WAL replay, orphan SSTable cleanup, the dirty-open
flag) runs automatically inside `open()` — see spec §17 for the full recovery
sequence. There is nothing an application developer needs to do beyond
handling the faults in the table above.

# Accessibility

The sample app's six screens are not exempt from a basic accessibility bar
just because they are a demo: icon-only controls (attach file, sync-now,
search-mode toggle) carry `Semantics`/`tooltip` labels, status/priority chips
use dark, high-contrast colour pairs with a `Semantics` label so the value is
never conveyed by colour alone, and error states (`badCredentials`, schema
rejections) are wrapped in `Semantics(liveRegion: true)` so they are
announced, not just displayed. Since the target platforms are desktop, full
keyboard navigation matters more than usual — Flutter's default focus
traversal on the standard widgets used here (`TextField`, `FilledButton`,
`SegmentedButton`, `ListTile`) already covers this without extra wiring.

# Going further

Things this guide deliberately does not demonstrate, to keep the sample app
small — each is a real, supported `kmdb` capability:

- **Hybrid/semantic search** (`SearchMode.hybrid`/`.semantic`, spec §22–23) —
  needs an ONNX embedding model (`EmbeddingModel`) and its native-asset
  weight. The default `bge-small-en-v1.5` model is English-only;
  `multilingual-e5-small` (~100 languages) is a registered opt-in.
- **`PdfTextExtractor`** (`kmdb_extractor_pdf`, native, wraps `betto_pdfium`)
  — works on every desktop target this guide covers, but adds native-asset
  weight the sample app doesn't need alongside its pure-Dart HTML/Markdown
  extractors.
- **Biometric unlock and a persistent `SecretStore`** — `KEKSource.biometric`
  plus `kmdb_flutter`'s `BiometricKekProvider` let a Flutter app unlock via
  Face ID/Touch ID/platform biometrics instead of a passphrase, with a
  `ReauthPolicy` governing how long that stays valid before a passphrase is
  required again. See spec §31 for the full model; this guide's desktop
  sample wires neither, using the in-memory `SecretStore` default (which
  costs only a per-launch Argon2id derivation, ~200ms).
- **Web** (see ["Platform scope"](#platform-scope) above) — a natural v2
  extension once `LocalDirectoryAdapter`'s native-only sync mechanic has a
  web equivalent and semantic search's ONNX inference lands on web.
- **Real multi-language content** — lexical search is already multilingual
  (stemming is language-aware, tokenisation covers CJK/Thai/Arabic/
  Cyrillic/Devanagari; only stop-word lists are English-only) and semantic
  search has a multilingual opt-in model. This guide's sample app content is
  English-only purely to keep the guide itself to one language, not because
  of an engine limitation.

# Friction log

If you hit a place where this guide was wrong, unclear, or missing a step,
please record it in a copy of the
[Friction Log template](friction_log_template.md) — copy the template into
`friction_logs/YYYY-MM-DD_your-description.md`, fill it in as you go, and
open an issue or PR with it. This is exactly the mechanism used to validate
this guide before release (a cold-read agent working through it from
scratch, recording every friction point) — real users hitting real friction
is the same signal, and the guide gets better from it.

# Where to go next

- [`docs/spec/00_index.md`](../spec/00_index.md) — the full normative
  specification, if you want the on-disk format or protocol detail behind
  any section above.
- [CLI User Guide](../user_guide/README.md) — if you also want to inspect or
  manipulate a `kmdb` database from the command line (useful for debugging a
  database your app created).
- `packages/kmdb_example_todo/` — the full sample app this guide is built
  around, including its data-layer test suite.
