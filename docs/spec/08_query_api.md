# Query API

## `KmdbDatabase`

```dart
final class KmdbDatabase {
  final KvStore _store;
  final KeyGenerator _keyGenerator;
  final Duration watchDebounce;
  KmdbDatabase({
    required KvStore store,
    KeyGenerator? keyGenerator, // defaults to UUIDv7
    this.watchDebounce = const Duration(milliseconds: 50),
  });
  KmdbCollection<T> collection<T>({
    required String namespace,
    required KmdbCodec<T> codec,
  });
  Future<void> close();
}

```

## `KmdbCodec<T>`

Thin bridge between a freezed/json_serializable type and KMDB. Implementors
delegate encode/decode to generated code:

```dart
abstract interface class KmdbCodec<T> {
  /// Read the key from a persisted document.
  /// Key was generated at insert() time.
  String keyOf(T value);
  Map<String, dynamic> encode(T value);
  T decode(Map<String, dynamic> json);
}
```

No key parameter on decode — the key is already inside the JSON document (via id
or equivalent), so passing it separately would be redundant and create a
consistency hazard.

## `KmdbCollection<T>`

```dart
 final class KmdbCollection<T> {
  /// Generate a new UUIDv7 key for a new document.
  String generateKey();

  /// Insert a new document. Throws if key already exists.
  Future<void> insert(T value);

  /// Replace an existing document. Throws if key does not exist.
  Future<void> replace(T value);

  /// Upsert — insert or replace regardless.
  Future<void> put(T value);

  /// Batch upsert.
  Future<void> putMany(List<T> values);

  /// Delete by key. Returns true if the key existed.
  Future<bool> delete(String key);

  /// Read-modify-write. NOT SAFE ACROSS DEVICE SYNC.
  Future<void> update(String key, T Function(T current) updater);

  /// Get a single document by key.
  Future<T?> get(String key);

  /// Start building a query.
  KmdbQuery<T> all();

  /// Reactive stream of query results.
  Stream<List<T>> watch();
}

```

## `KmdbQuery<T>` (Lazy Builder)

```dart
final class KmdbQuery<T> {
  KmdbQuery<T> where(Filter filter);
  KmdbQuery<T> orderBy(String field, {bool descending = false});
  KmdbQuery<T> limit(int count);
  KmdbQuery<T> offset(int count);

  /// Terminal: execute and return results.
  Future<List<T>> get();

  /// Terminal: count matching documents.
  Future<int> count();

  /// Terminal: reactive stream, re-emits on relevant writes.
  Stream<List<T>> watch();
}
```

## Filter DSL

Filters compose via and/or/not and support nested field paths with dot notation:

```dart
// Comparison
filter.eq('status', 'active');
filter.gt('createdAt', cutoffDate);
filter.inList('priority', [1, 2, 3]);

// Nested fields
filter.eq('address.city', 'London');

// String operations
filter.startsWith('title', 'Project');
filter.containsSubstring('body', 'urgent'); // string only
filter.containsElement('tags', 'flutter'); // array only

// Null / existence
filter.isNull('deletedAt');
filter.isNotNull('assignee');

// Composition
filter.and([
  filter.eq('status', 'active'),
  filter.or([filter.gt('priority', 3), filter.isNotNull('dueDate')]),
]);
```

### Missing vs Null Semantics

FieldPath resolution returns a Missing sentinel for fields that do not exist on
a document. This allows `isNull()` and `isNotNull()` to distinguish between
`{ archived: null }` (field present, value null) and `{ }` (field absent).
Without this sentinel, the two cases are indistinguishable, breaking filter
correctness.
