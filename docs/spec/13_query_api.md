# Query API

The Query Layer is the primary interface for application code. It provides
typed document collections, a composable lazy query pipeline, a filter DSL with
full dot-notation support, and automatic secondary index maintenance. It wraps
the Cache Layer and is the only layer that encodes and decodes CBOR (see §5).

## Opening the Query Layer

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,             // StorageAdapter for the platform
  deviceId: deviceId,          // 8-char hex device identifier
  indexes: [
    IndexDefinition('contacts', 'address.city'),
    IndexDefinition('contacts', 'tags[]'),
    IndexDefinition('notes', 'metadata.createdAt'),
  ],
  onIndexReady: (namespace, path) {
    // Secondary index build complete.
  },
  onIndexRebuildRequired: (List<IndexRebuildEvent> events) async {
    // Interrupted build detected on open — application decides when to rebuild.
  },
  config: KvStoreConfig(),
  // ── Text search (§20–23) ──────────────────────────────────────────────────
  ftsIndexes: [
    FtsIndexDefinition(collection: 'books', field: 'description'),
  ],
  vecIndexes: [
    VecIndexDefinition(collection: 'books', field: 'description'),
  ],
  embeddingModel: model,        // Required when vecIndexes is non-empty
  onSearchIndexReady: () {
    // All search indexes are current — safe to enable search UI.
  },
  // ── Vault (§24) ──────────────────────────────────────────────────────────
  vaultStore: vaultStore,       // null → vault features disabled
  // ── Collection schemas (§25) ─────────────────────────────────────────────
  schemas: [
    CollectionSchema(
      collection: 'contacts',
      jsonSchema: {
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string', 'format': 'email'},
        },
      },
    ),
  ],
  onSchemaVersionMismatch: (collection, storedVersion, supportedVersion) {
    // Schema authored by a newer KMDB build — enforcement disabled.
  },
);
```

`adapter` provides the platform file I/O backend (`StorageAdapter`).
`deviceId` is an 8-character lowercase hex string identifying this device;
production code should call `db.ensureDeviceId()` after `open()` to load or
generate a stable value.

Indexes are **declared, not built**. The `indexes` list registers dot-path
definitions so the write interception path knows which fields to maintain. No
index entries are written at open time. An index that is declared but never
queried incurs zero storage overhead. See §16 for the full index lifecycle.

## `KmdbCodec<T>`

Thin bridge between a typed Dart model and KMDB. Implementors delegate
encode/decode to generated code (`freezed` / `json_serializable`):

```dart
abstract interface class KmdbCodec<T> {
  /// The document's stable, immutable key.
  /// Must not change after a document is written.
  String keyOf(T value);

  /// Returns a new instance of [value] with [key] assigned to its identifier
  /// field. Called by insert() after generating a new system key.
  T withKey(T value, String key);

  /// Encode to a JSON-compatible map. CBOR encoding is applied by the
  /// Query Layer — the codec works with Map<String, dynamic> only.
  ///
  /// MUST NOT include any top-level key starting with '_'. The '_' prefix is
  /// reserved for KMDB system fields. Including '_id' or any other '_'-prefixed
  /// key will cause ReservedFieldException to be thrown before any I/O.
  Map<String, dynamic> encode(T value);

  /// Decode from a JSON-compatible map.
  ///
  /// The framework injects '_id' (the document's UUIDv7 key) into the map
  /// before calling decode(). Implementations should read json['_id'] to
  /// reconstruct the typed model's key field.
  T decode(Map<String, dynamic> json);
}
```

### Vault Fields and `VaultRef`

Where a document field value is a valid `kmdb-vault://` URI, the Query Layer
represents it as a `VaultRef` rather than a raw string. `KmdbCodec<T>` is
responsible for mapping between `VaultRef` and the typed model field.

```dart
// In a codec for a document with a photo attachment:
@override
Map<String, dynamic> encode(Person value) => {
  'name': value.name,
  'photo': value.photo,  // VaultRef — its toString() returns the URI
};

@override
Person decode(Map<String, dynamic> json) => Person(
  id: json['_id'] as String,
  name: json['name'] as String,
  photo: json['photo'] is VaultRef
      ? json['photo'] as VaultRef
      : VaultRef(json['photo'] as String),
);
```

URI format is validated eagerly at `VaultRef` construction time.
`VaultRef.getBlob()` and `VaultRef.getMetadata()` trigger on-demand hydration
if the object is a stub. See §24 for the full `VaultRef` API.

### Reserved `_` Field Prefix

The `_` prefix is reserved for KMDB system-managed fields. Currently defined:

| Field | Meaning |
| ----- | ------- |
| `_id` | The document's UUIDv7 key (injected by the framework on read; never stored in value bytes) |

Rules:

1. `encode()` **must not** return any top-level key starting with `_`. The
   framework validates this before every write and throws
   `ReservedFieldException` if violated. This includes `_id` — the framework
   owns it entirely.
2. `decode()` receives the map with `_id` pre-injected. Read `json['_id']` to
   reconstruct the key field in your typed model.
3. `withKey()` stamps the key onto the typed model so that `insert()` can
   return the document with its assigned `_id`.
4. Secondary index paths must not start with `_`. Defining an index on a
   reserved path throws `ReservedIndexPathException` at `KmdbDatabase.open()`
   time.

### Example Codec

```dart
class TaskCodec implements KmdbCodec<Task> {
  @override
  String keyOf(Task value) => value.id;

  @override
  Task withKey(Task value, String key) => Task(
        id: key,
        title: value.title,
        done: value.done,
      );

  // Do NOT include 'id' or any '_'-prefixed key here.
  @override
  Map<String, dynamic> encode(Task value) => {
    'title': value.title,
    'done': value.done,
  };

  // The framework injects '_id' before calling decode().
  @override
  Task decode(Map<String, dynamic> json) => Task(
    id: json['_id'] as String,
    title: json['title'] as String,
    done: json['done'] as bool? ?? false,
  );
}
```

## Write Pipeline

Every document write — whether typed (`collection()`) or untyped (`rawCollection()`)
— passes through a three-layer write pipeline before the `WriteBatch` is committed.

### Layer 1 — Validators (`WriteValidator`)

Validators are called sequentially before any I/O. If any validator throws, the
write is aborted and no partial I/O has occurred. Built-in validators:

| Validator | What it checks |
| --------- | -------------- |
| `ReservedKeyValidator` | Rejects any document whose `encode()` output contains a top-level key beginning with `_`. Always runs first. |
| `SchemaManager` | Validates the encoded document against the collection's registered JSON Schema, if one is defined (§25). |

Application code can supply additional validators via the `WriteValidator`
interface:

```dart
abstract interface class WriteValidator {
  /// Validates [document] before it is written to [collection].
  ///
  /// Throws to abort the write. Called before any I/O — no partial write
  /// can occur if a validator throws.
  void validate(String collection, Map<String, dynamic> document);
}
```

### Layer 2 — Augmentors (`WriteAugmentor`)

Augmentors run after all validators pass. Each augmentor adds entries to the
same `WriteBatch` as the document write so that all writes — document and
side-effects — are committed atomically. Built-in augmentors:

| Augmentor | What it adds to the batch |
| --------- | ------------------------- |
| `IndexManager` | Secondary index entries (`$index:{ns}:{path}:…` namespaces) |
| `FtsManager` | BM25 posting lists (`$fts:…` namespaces) |
| `VecManager` | SQ8 vector entries (`$vec:…` namespaces) |
| `VaultRefInterceptor` | Vault blob reference counts (`$vault` namespace) |

Application code can supply additional augmentors via the `WriteAugmentor`
interface:

```dart
abstract interface class WriteAugmentor {
  /// Adds entries to [batch] for this augmentor's concern.
  ///
  /// [newDoc] is `null` for deletes; [oldDoc] is `null` for new inserts.
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  });
}
```

### Layer 3 — Post-write notifications

`KvStore.writeEvents` fires automatically after `WriteBatch` is committed.
`CacheLayer` subscribes to evict stale cache entries; `watch()` subscribers
re-execute their queries. No additional application code is required.

### Delete path

`delete()` skips Layer 1 (validators) — deletes are never blocked by
admission-gate checks. Layer 2 augmentors still run, receiving `newDoc: null`
to clean up side-effect entries (index postings, vector embeddings, ref counts).

### `rawCollection` — untyped access

`KmdbDatabase.rawCollection(String name)` returns a
`KmdbCollection<Map<String, dynamic>>` backed by the built-in
`RawDocumentCodec`. All write pipeline layers run identically to a typed
collection:

```dart
final col = db.rawCollection('contacts');
await col.insert({'name': 'Alice', 'email': 'alice@example.com'});
final doc = await col.get(key); // Map<String, dynamic> with '_id' set
```

This is the recommended entry point for code that works with plain
`Map<String, dynamic>` documents, such as CLI tools, without requiring a typed
model class.

## `KmdbCollection<T>`

Obtained via `db.collection(name: '...', codec: ...)`.

### Conflict Semantics

All writes use **Last-Write-Wins (LWW)** conflict resolution. When two devices
independently write to the same document key and their SSTables are later merged
during sync compaction, the entry with the higher HLC timestamp is kept and the
other is silently discarded. This applies to every write method — `put`,
`insert`, `replace`, `update`, `delete` — without exception.

This is not a limitation of any specific method; it is a property of the sync
model. Any pattern where two devices concurrently write to the same document
field can produce a discarded write. Applications that require field-level merge
semantics (e.g. incrementing a counter, appending to a list) should use the
`MergeOperator` callback on the sync engine (§12), which enables CRDT-style
resolution during compaction.

### Point-Lookup Methods

```dart
// Direct KvStore access via Cache Layer — bypasses the query pipeline.
Future<T?>               get(String key);
Future<Map<String, T?>>  getMany(Iterable<String> keys);
Future<bool>             exists(String key);
Stream<T?>               watchKey(String key);  // re-emits on put or delete
```

### Schema Validation

When a `CollectionSchema` is registered for a collection (see §25), every write
method — `put`, `insert`, `replace`, `update` — validates the encoded document
against the schema before committing. Violations throw
`SchemaValidationException` with a list of all `SchemaViolation` objects found.
`delete` is never blocked. Sync ingest bypasses validation (see §25).

### Write Methods

```dart
// insert: throws DocumentAlreadyExistsException if key exists.
Future<void> insert(T value);

// replace: throws DocumentNotFoundException if key does not exist.
Future<void> replace(T value);

// put: upsert — inserts if absent, replaces if present.
Future<void> put(T value);

// putMany: batch upsert. Atomic per-document; NOT atomic across all keys.
Future<void> putMany(Iterable<T> values);

// delete: no-op if the key does not exist.
Future<void> delete(String key);

// update: read-modify-write. Returns null if the document does not exist.
// Safe on a single device (synchronous single-isolate model prevents
// interleaving). Subject to LWW conflict resolution during sync — see
// Conflict Semantics above.
Future<T?> update(String key, T Function(T current) updater);
```

### Query Builder

```dart
// Start building a query. No I/O occurs until a terminal method is called.
KmdbQuery<T> all();

// Shorthand: all().where(filter)
KmdbQuery<T> where(Filter filter);
```

### Text Search

`search()` is the entry point for all text search modes (§20). It returns a
`Future<SearchResult<T>>` containing ranked hits and query metadata.

```dart
final results = await collection.search(
  'flutter local database',
  fields: ['title', 'description'],   // omit → search all indexed fields
  filter: Filter.eq('status', 'published'),  // optional pre-filter
  mode: SearchMode.auto,              // default; auto-selects best mode
  limit: 10,
  offset: 0,
  candidates: 100,                    // per-index candidate limit for hybrid
);

for (final hit in results.hits) {
  print('${hit.rank}. [${hit.score.toStringAsFixed(4)}] ${hit.id}');
}
```

`SearchMode.auto` selects hybrid (RRF) when both lexical and semantic indexes
exist on the field, lexical-only when only an FTS index is configured, and
semantic-only when only a vector index is configured. If no index is available
for a requested field, the field is listed in `SearchMetadata.skipped` and
the search proceeds over the remaining fields. See §20 for full mode semantics
and §23 for the RRF algorithm.

Search indexes are declared at `KmdbDatabase.open()` time alongside secondary
indexes (see `ftsIndexes` and `vecIndexes` above). See §20–23 for the full
text search specification.

## `KmdbQuery<T>` — Pipeline Methods

All pipeline methods return a new `KmdbQuery` — the original is unchanged.
No I/O occurs until a terminal method is called.

```dart
KmdbQuery<T> where(Filter filter);           // AND-ed with existing filters
KmdbQuery<T> orderBy(String path, {bool descending = false});
KmdbQuery<T> limit(int count);
KmdbQuery<T> offset(int count);              // stable pagination with orderBy
KmdbQuery<T> keyPrefix(String prefix);       // narrows the underlying LSM scan
```

## `KmdbQuery<T>` — Terminal Methods

```dart
Future<List<T>>              get();           // eager; LSM snapshot closed immediately
Stream<T>                    stream();        // lazy; holds LSM snapshot for stream lifetime
Stream<List<T>>              watch();         // reactive; re-runs on namespace writes (debounced 50ms)
Future<T?>                   first();
Future<int>                  count();         // avoids decoding documents
Future<bool>                 any();
Future<(List<T>, QueryPlan)> explainedGet();  // get() plus execution metadata
```

### `explainedGet()` and `QueryPlan`

`explainedGet()` executes the query and returns results alongside a `QueryPlan`
value that describes the execution strategy chosen:

```dart
final (results, plan) = await collection
    .where(Field('city').equals('London'))
    .orderBy('name')
    .explainedGet();

print(plan.strategy);          // ScanStrategy.indexScan or .fullScan
print(plan.documentsScanned);  // documents examined before in-memory filters
print(plan.documentsMatched);  // documents that passed all filters
print(plan.documentsReturned); // documents returned after offset/limit
print(plan.sorted);            // true when in-memory sort was applied
for (final f in plan.filters) {
  print('${f.fieldPath} ${f.operator} — index: ${f.indexUsed}');
}
```

`QueryPlan` is a pure value type — it is not persisted or synced. See §16 for
the full index selection algorithm and the semantics of each `QueryPlan` field.

`KmdbCollection` also exposes a convenience wrapper:

```dart
final (results, plan) = await collection.explainedGet(
  collection.where(Field('city').equals('London')),
);

**`stream()` implementation:** `stream()` is eagerly evaluated — identical to
`get()` internally, but the result is emitted as a `Stream<T>` rather than
returned as a `Future<List<T>>`. No LSM snapshot is held open. This is
sufficient at KMDB's target scale (≤100K documents); a lazy cursor with
ref-counted SSTable retention can be introduced if larger scale demands it.
Prefer `watch()` for reactive UI lists.

**`orderBy('_id')`** maps directly to `KvStore.scan(descending:)` and avoids
an in-memory sort — the only `orderBy` with this optimisation. All other fields
require a full in-memory sort after scan.

## Field Path Syntax

KMDB supports an ergonomic subset of RFC 9535 (JSONPath) for field selectors.
The same path syntax is used in the Filter DSL, secondary index definitions
(`IndexDefinition`), and the CLI `--select` flag.

| Syntax              | Example               | Meaning                                  |
| ------------------- | --------------------- | ---------------------------------------- |
| Identifier          | `name`                | Top-level field                          |
| Dot child           | `address.city`        | Nested object field                      |
| Optional root sigil | `$.address.city`      | Same as `address.city`                   |
| Array wildcard      | `tags[*]` or `tags[]` | All elements (fan-out) — returns a List  |
| Positional index    | `tags[0]`             | Element at index 0                       |
| Negative index      | `tags[-1]`            | Last element (`length - 1`)              |
| Deeply nested       | `meta.stats.views`    | Three levels deep                        |

### Notes

- The `$` root sigil is **optional**. `$.address.city` and `address.city` are
  equivalent. A bare `$` with no child path is rejected with `ArgumentError`.
- `[*]` is a synonym for `[]` (array fan-out). Both are normalised to `[]`
  internally before any processing.
- Negative indices are resolved as `list[list.length + index]`. An
  out-of-range negative index returns the `missing` sentinel.
- `$$foo` is **not** normalised — only a single leading `$` is treated as a
  root sigil. Double-`$` paths will not resolve.

### Missing vs Null Semantics (field path resolution)

`FieldPath.resolve()` returns the `missing` sentinel (a distinct constant, not
`null`) when:

- A path segment names a key that is absent from the document.
- An intermediate segment is not a `Map` (for dot-child paths) or not a `List`
  (for array access).
- An array index is out of range (including out-of-range negative indices).

`null` is returned only when the field is explicitly present with a `null` value.

### Deferred features

The following RFC 9535 features are intentionally not yet implemented:

- **Filter expressions** (`$.policies[?(@.expired == true)]`) — overlap with the
  Filter DSL and require a unified expression layer design.
- **Recursive descent** (`$..name`) — useful but adds traversal cost with
  non-obvious semantics for index fan-out.
- **Cross-collection references** — deferred until cross-collection query design.

## Filter DSL

Filters are composed via `and` / `or` / `not` and use dot-notation field paths.
All filters are evaluated in memory after the LSM scan (or after an index
lookup narrows the candidate set — see §16).

```dart
// Equality & comparison
Field('status').equals('active')
Field('status').notEquals('archived')
Field('priority').isGreaterThan(3)
Field('priority').isLessThan(10)
Field('priority').isGreaterThanOrEqualTo(3)
Field('priority').isLessThanOrEqualTo(10)
Field('score').isBetween(0.5, 0.9)        // inclusive on both ends

// Set membership
Field('priority').isIn([1, 2, 3])
Field('priority').isNotIn([4, 5])

// Null / existence
Field('deletedAt').isNull()               // field absent OR field == null
Field('assignee').isNotNull()             // field present AND field != null

// Boolean
Field('isActive').isTrue()
Field('isDeleted').isFalse()

// String
Field('title').startsWith('Project')
Field('title').endsWith('2026')
Field('body').contains('urgent')          // substring match

// Array
Field('tags').contains('flutter')         // array contains element
Field('tags').containsAll(['dart', 'flutter'])
Field('tags').containsAny(['mobile', 'web'])

// Nested fields (dot notation)
Field('address.city').equals('London')
Field('meta.stats.views').isGreaterThan(100)

// Composition
Filter.and([
  Field('status').equals('active'),
  Filter.or([
    Field('priority').isGreaterThan(3),
    Field('dueDate').isNotNull(),
  ]),
])
Filter.not(Field('status').equals('archived'))
```

### Missing vs Null Semantics

Field path resolution returns a `Missing` sentinel for fields that do not exist
on a document. `isNull()` matches both `null` values and missing fields.
`isNotNull()` requires the field to be present and non-null. This distinction
is preserved through all filter composition.

## Sync Methods

Sync is a first-class feature of `KmdbDatabase`. See §12 for the full sync
protocol. The public API surface:

| Method | Signature | Description |
| ------ | --------- | ----------- |
| `ensureDeviceId` | `Future<String> ensureDeviceId()` | Load or generate the stable device identifier. Call once after `open()` on production devices before the first `push()`. |
| `sync` | `Future<void> sync({required SyncStorageAdapter syncAdapter, String syncRoot, Set<String>? syncNamespaces, StorageAdapter? localAdapter, ConsolidationConfig consolidationConfig, CancellationToken? cancel, Duration? timeout})` | Flush, push, then pull in one step. **Native-only.** |
| `push` | `Future<void> push({required SyncStorageAdapter syncAdapter, String syncRoot, Set<String>? syncNamespaces, StorageAdapter? localAdapter, ConsolidationConfig consolidationConfig, CancellationToken? cancel, Duration? timeout})` | Flush and upload local SSTables. **Native-only.** |
| `pull` | `Future<void> pull({required SyncStorageAdapter syncAdapter, String syncRoot, Set<String>? syncNamespaces, StorageAdapter? localAdapter, ConsolidationConfig consolidationConfig, CancellationToken? cancel, Duration? timeout})` | Download and ingest peer SSTables. **Native-only.** |

All three sync methods default `syncNamespaces` to all registered user (non-`$`)
collections when omitted. System namespaces are always excluded from sync
regardless of this parameter.

The `cancel` and `timeout` parameters are combined into a `SyncContext` once
at the entry point and threaded to every adapter call site for the duration of
the sync run. If either signal is active when an adapter boundary is reached,
`SyncCancelledException` is thrown and propagates to the caller. See §12 —
Cancellation and Timeout for the full contract.
