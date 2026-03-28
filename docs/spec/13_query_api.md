# Query API

The Query Layer is the primary interface for application code. It provides
typed document collections, a composable lazy query pipeline, a filter DSL with
full dot-notation support, and automatic secondary index maintenance. It wraps
the Cache Layer and is the only layer that encodes and decodes CBOR (see §5).

## Opening the Query Layer

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  indexes: [
    IndexDefinition('contacts', 'address.city'),
    IndexDefinition('contacts', 'tags[]'),
    IndexDefinition('notes', 'metadata.createdAt'),
  ],
  onIndexReady: (namespace, path) {
    // Index build complete — re-run any queries that fell back to full scan.
  },
  onIndexRebuildRequired: (List<IndexRebuildEvent> events) async {
    // Interrupted build detected on open — application decides when to rebuild.
  },
  config: KvStoreConfig.defaults(),
);
```

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

  /// Encode to a JSON-compatible map. CBOR encoding is applied by the
  /// Query Layer — the codec works with Map<String, dynamic> only.
  Map<String, dynamic> encode(T value);

  /// Decode from a JSON-compatible map.
  T decode(Map<String, dynamic> json);
}
```

## `KmdbCollection<T>`

Obtained via `db.collection(namespace: '...', codec: ...)`.

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
Future<List<T>>   get();     // eager; LSM snapshot closed immediately
Stream<T>         stream();  // lazy; holds LSM snapshot for stream lifetime
Stream<List<T>>   watch();   // reactive; re-runs on namespace writes (debounced 50ms)
Future<T?>        first();
Future<int>       count();   // avoids decoding documents
Future<bool>      any();
```

**`stream()` implementation:** `stream()` is eagerly evaluated — identical to
`get()` internally, but the result is emitted as a `Stream<T>` rather than
returned as a `Future<List<T>>`. No LSM snapshot is held open. This is
sufficient at KMDB's target scale (≤100K documents); a lazy cursor with
ref-counted SSTable retention can be introduced if larger scale demands it.
Prefer `watch()` for reactive UI lists.

**`orderBy('id')`** maps directly to `KvStore.scan(descending:)` and avoids an
in-memory sort — the only `orderBy` with this optimisation. All other fields
require a full in-memory sort after scan.

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
