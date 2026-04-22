A Local-First Document Database for Dart & Flutter

KMDB is a local-first document database for Dart and Flutter applications
targeting mobile, desktop, and web platforms. It provides a typed, reactive
query API over a key-value storage engine, with multi-device sync via commodity
cloud storage (Google Drive, iCloud) without requiring a central server.

The storage layer is a Log-Structured Merge Tree (LSM) with a write-ahead log
(WAL), in-memory memtable, and immutable Sorted String Table (SSTable) files.
This architecture was chosen specifically because immutable SSTables serve as
the natural sync unit for cloud storage — file creation is atomic in cloud
storage, file mutation is not. This sync-safety property is a first-class
architectural requirement, not an incidental benefit.

The query layer provides a typed collection API with lazy evaluation, a
composable filter DSL supporting nested field paths, and reactive `watch()`
streams with debounced re-execution. Documents are serialized via a thin codec
bridge to `freezed`/`json_serializable`, with UUIDv7 keys providing
time-ordered insertion and index locality.

## Terminology

- **Collection** — a user-facing, typed logical partition of documents. This is
  the primary concept for application code. Collections are obtained via
  `db.collection(name: 'tasks', codec: ...)` and expose a fully-typed read/write
  API.
- **Namespace** — the underlying LSM storage partition. Every collection maps
  1-to-1 to a namespace of the same name. Application developers work with
  collections; the term "namespace" is an implementation detail of the storage
  engine.
- **System namespaces** — internal partitions prefixed with `$` (e.g. `$meta`,
  `$index:…`, `$cache`). These are created and managed by the engine and are
  never surfaced as user collections.

## Features

- **LSM-Tree Storage**: High-performance storage engine using Log-Structured Merge Trees.
- **Zstandard Compression**: Integrated Zstd compression for SSTables and WAL.
- **Reactive Queries**: Watch collections and queries for real-time updates.
- **Typed API**: Fully-typed document collections with JSON serialization.
- **Cloud Sync**: Multi-device synchronization via Google Drive and iCloud.
- **UUIDv7 Keys**: Time-ordered, unique document identifiers.
- **Secondary Indexes**: Lazy-built secondary indexes with dot-path and array fan-out support.
- **Full-Text Search**: BM25 lexical search with a stemming/stopword pipeline.
- **Semantic Search**: BGE Small En v1.5 embeddings with SQ8 quantization for cosine similarity.
- **Hybrid Search**: Reciprocal Rank Fusion over lexical and semantic results.
- **Vault**: Content-addressable blob store with ref-counted GC and distributed sync.
- **Collection Schemas**: Optional JSON Schema validation as an admission gate on writes.

## Getting started

Add `kmdb` to your `pubspec.yaml`:

```yaml
dependencies:
  kmdb: ^0.1.0
```

Run `dart pub get` and import the library:

```dart
import 'package:kmdb/kmdb.dart';
```

## Usage

### Defining a codec

A `KmdbCodec<T>` bridges your model to the document map KMDB stores internally.

```dart
final class Task {
  const Task({required this.id, required this.title, this.done = false});
  final String id;
  final String title;
  final bool done;
}

final class TaskCodec implements KmdbCodec<Task> {
  const TaskCodec();

  @override
  String keyOf(Task v) => v.id;

  @override
  Task withKey(Task v, String key) => Task(id: key, title: v.title, done: v.done);

  @override
  Map<String, dynamic> encode(Task v) => {'title': v.title, 'done': v.done};

  @override
  Task decode(Map<String, dynamic> json) => Task(
    id: json['_id'] as String,
    title: json['title'] as String,
    done: json['done'] as bool? ?? false,
  );
}
```

### Opening a database

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: MemoryStorageAdapter(), // use platform default adapter in production
);
```

### Writing and reading documents

```dart
final tasks = db.collection(name: 'tasks', codec: TaskCodec());

// Write
final id = SequentialKeyGenerator().next();
await tasks.put(Task(id: id, title: 'Buy milk'));

// Read by key
final task = await tasks.get(id);

// Query
final done = await tasks
    .where(Filter.eq('done', true))
    .orderBy('title')
    .get();
```

### Reactive queries

```dart
tasks
    .where(Filter.eq('done', false))
    .watch()
    .listen((results) => print('open tasks: ${results.length}'));
```

### Secondary indexes

Indexes are declared at open time and built lazily on first use.

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  indexes: [
    IndexDefinition('contacts', 'address.city'),
    IndexDefinition('contacts', 'tags[]'), // array fan-out
  ],
  onIndexReady: (ns, path) => print('index ready: $ns.$path'),
);
```

### Text search

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  ftsIndexes: [FtsIndexDefinition(collection: 'docs', field: 'body')],
  vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
  embeddingModel: await OnnxEmbeddingModel.load(),
);

// Lexical (BM25)
final results = await docs.search('open source database', mode: SearchMode.lexical);

// Semantic (cosine similarity)
final results = await docs.search('persistent storage', mode: SearchMode.semantic);

// Hybrid (Reciprocal Rank Fusion)
final results = await docs.search('local first sync', mode: SearchMode.hybrid);
```

### Collection schemas

Schemas enforce document structure on every write. They are optional,
per-collection, and persisted in `$meta` so they sync to other devices
automatically.

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/database',
  adapter: adapter,
  schemas: [
    CollectionSchema(
      collection: 'contacts',
      jsonSchema: {
        'required': ['name', 'email'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'email': {'type': 'string', 'format': 'email'},
          'age':  {'type': 'integer', 'minimum': 0},
        },
        'additionalProperties': false,
      },
    ),
  ],
  onSchemaVersionMismatch: (collection, stored, supported) {
    // Schema arrived from a newer KMDB build — enforcement disabled for safety.
    print('Schema version mismatch for $collection');
  },
);
```

A write that violates the schema throws `SchemaValidationException` before any
I/O is committed. All violations for the document are reported together:

```dart
try {
  await contacts.insert(contact);
} on SchemaValidationException catch (e) {
  for (final v in e.violations) {
    print('${v.path}: ${v.message}');
  }
}
```

Supported JSON Schema keywords: `type`, `required`, `properties`,
`additionalProperties`, `enum`, `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `minLength`, `maxLength`, `pattern`, `format` (`email`,
`uri`, `date`, `date-time`, `uuid`), `minItems`, `maxItems`, `items`.

## Additional information

Refer to [docs](docs/index.md) for the full specification.
