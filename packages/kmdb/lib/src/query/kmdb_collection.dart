// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import '../encoding/value_codec.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/util/key_codec.dart';
import '../search/search_mode.dart';
import '../search/search_result.dart';
import 'exceptions.dart';
import 'filter/filter.dart';
import 'kmdb_codec.dart';
import 'kmdb_database.dart';
import 'kmdb_query.dart';

/// A typed collection of documents within a [KmdbDatabase].
///
/// Obtained via [KmdbDatabase.collection]. Provides typed read, write, and
/// query operations over a single [namespace] in the underlying LSM store.
///
/// ## Keys
///
/// KMDB uses UUIDv7 identifiers for all records. New documents are
/// automatically assigned a system-generated key when created via [insert].
/// Existing documents already carry a system-assigned key that is preserved
/// during [put] or [replace].
///
/// All keys must be valid UUIDv7 hex strings. Format validation is enforced
/// at the storage boundary.
///
/// ## Conflict Semantics
///
/// All writes use **Last-Write-Wins (LWW)** conflict resolution. When two
/// devices independently write to the same document key and their SSTables are
/// later merged during sync compaction, the entry with the higher HLC timestamp
/// is kept and the other is silently discarded. This applies to every write
/// method — [put], [insert], [replace], [update], [delete] — without
/// exception.
///
/// Applications requiring field-level merge semantics (e.g. incrementing a
/// counter, appending to a list) should use the `MergeOperator` callback on
/// the sync engine (§12), which enables CRDT-style resolution.
///
/// ## Example
///
/// ```dart
/// final tasks = db.collection(name: 'tasks', codec: TaskCodec());
/// await tasks.put(Task(id: newKey, title: 'Buy milk'));
/// final task = await tasks.get(newKey); // Task or null
/// await for (final t in tasks.watchKey(newKey)) { ... }
/// ```
final class KmdbCollection<T> {
  /// Creates a collection. Use [KmdbDatabase.collection] instead.
  KmdbCollection({
    required this.namespace,
    required this.codec,
    required KmdbDatabase database,
    this.keyGenerator = const UuidV7KeyGenerator(),
  }) : _db = database;

  /// The unique storage identifier for this collection in the LSM engine.
  ///
  /// This is the namespace passed as `name` to [KmdbDatabase.collection]. It
  /// serves as the low-level partition key in the storage engine. System
  /// namespaces (e.g. `$meta`, `$index:…`, `$cache`) are internal and are
  /// never surfaced as user collections.
  final String namespace;

  /// The codec used to encode and decode documents.
  final KmdbCodec<T> codec;

  /// The generator used for new document keys in [insert].
  final KeyGenerator keyGenerator;

  final KmdbDatabase _db;

  /// The database this collection belongs to.
  KmdbDatabase get database => _db;

  // ── Point-lookup methods ───────────────────────────────────────────────────

  /// Returns the document with [key], or `null` if it does not exist.
  ///
  /// Uses the Cache Layer for cache-aware reads. The framework injects
  /// `_id: key` into the decoded map before calling [KmdbCodec.decode], so
  /// implementations can read `json['_id']` to reconstruct the typed model's
  /// key field.
  Future<T?> get(String key) async {
    final bytes = await _db.cache.get(namespace, key);
    if (bytes == null) return null;
    // Inject the document key as '_id' before handing the map to the codec.
    // This gives codec.decode() a consistent fromJson-style map that includes
    // the system key without it being persisted in the value bytes.
    final doc = ValueCodec.decode(bytes);
    doc['_id'] = key;
    return codec.decode(doc);
  }

  /// Returns a map of documents for each key in [keys].
  ///
  /// Missing documents are represented as `null` values in the result map.
  Future<Map<String, T?>> getMany(Iterable<String> keys) async {
    final result = <String, T?>{};
    for (final key in keys) {
      result[key] = await get(key);
    }
    return result;
  }

  /// Returns `true` if a document with [key] exists.
  Future<bool> exists(String key) async {
    final bytes = await _db.cache.get(namespace, key);
    return bytes != null;
  }

  /// Returns a stream that emits the document (or `null`) whenever it is
  /// written or deleted.
  ///
  /// Emits the current value immediately on subscription, then re-emits after
  /// every write to [namespace].
  Stream<T?> watchKey(String key) {
    late StreamController<T?> controller;
    late StreamSubscription<String> sub;

    void emitCurrent() {
      get(key).then(controller.add, onError: controller.addError);
    }

    controller = StreamController<T?>(
      onListen: () {
        emitCurrent();
        sub = _db.cache.writeEvents.listen((ns) {
          if (ns == namespace) emitCurrent();
        });
      },
      onCancel: () => sub.cancel(),
    );

    return controller.stream;
  }

  // ── Write methods ──────────────────────────────────────────────────────────

  /// Inserts [value] as a new document.
  ///
  /// Assigns a new system-generated UUIDv7 key to the document via
  /// [KmdbCodec.withKey].
  ///
  /// Returns the updated document with its assigned key.
  ///
  /// Throws [DocumentAlreadyExistsException] if a document with the same key
  /// already exists (rare for UUIDv7).
  Future<T> insert(T value) async {
    final key = keyGenerator.next();
    final existing = await _db.cache.get(namespace, key);
    if (existing != null) {
      throw DocumentAlreadyExistsException(key, namespace);
    }
    final newValue = codec.withKey(value, key);
    await _writeDocument(
      key: key,
      newDoc: codec.encode(newValue),
      oldDoc: null,
    );
    return newValue;
  }

  /// Replaces the document with the same key as [value].
  ///
  /// The key returned by [KmdbCodec.keyOf] must be a valid UUIDv7 hex string.
  /// Throws [DocumentNotFoundException] if no document with that key exists.
  Future<void> replace(T value) async {
    final key = codec.keyOf(value);
    final existingBytes = await _db.cache.get(namespace, key);
    if (existingBytes == null) {
      throw DocumentNotFoundException(key, namespace);
    }
    final oldDoc = ValueCodec.decode(existingBytes);
    await _writeDocument(key: key, newDoc: codec.encode(value), oldDoc: oldDoc);
  }

  /// Upserts [value] — inserts if absent, replaces if present.
  ///
  /// The key returned by [KmdbCodec.keyOf] must be a valid UUIDv7 hex string.
  Future<void> put(T value) async {
    final key = codec.keyOf(value);
    final existingBytes = await _db.cache.get(namespace, key);
    final oldDoc = existingBytes != null
        ? ValueCodec.decode(existingBytes)
        : null;
    await _writeDocument(key: key, newDoc: codec.encode(value), oldDoc: oldDoc);
  }

  /// Upserts each value in [values] as individual atomic writes.
  ///
  /// Each document is written atomically, but the batch as a whole is NOT
  /// guaranteed to be atomic across all keys.
  Future<void> putMany(Iterable<T> values) async {
    for (final value in values) {
      await put(value);
    }
  }

  /// Deletes the document with [key].
  ///
  /// [key] must be a valid UUIDv7 hex string. No-op if the document does not
  /// exist.
  Future<void> delete(String key) async {
    final existingBytes = await _db.cache.get(namespace, key);
    if (existingBytes == null) return; // no-op

    final oldDoc = ValueCodec.decode(existingBytes);
    await _deleteDocument(key: key, oldDoc: oldDoc);
  }

  /// Reads the document with [key], applies [updater], and writes the result.
  ///
  /// Returns the updated document, or `null` if the document does not exist.
  ///
  /// Safe on a single device (the synchronous single-isolate model prevents
  /// interleaving). Subject to LWW conflict resolution during sync — see
  /// the **Conflict Semantics** section above.
  Future<T?> update(String key, T Function(T current) updater) async {
    final current = await get(key);
    if (current == null) return null;
    final updated = updater(current);
    await put(updated);
    return updated;
  }

  // ── Query builder ──────────────────────────────────────────────────────────

  /// Returns a [KmdbQuery] that will scan the entire collection.
  ///
  /// No I/O occurs until a terminal method is called.
  KmdbQuery<T> all() => KmdbQuery<T>.fromCollection(collection: this);

  /// Shorthand for `all().where(filter)`.
  KmdbQuery<T> where(Filter filter) => all().where(filter);

  // ── Text search ─────────────────────────────────────────────────────────────

  /// Searches this collection for documents matching [query].
  ///
  /// This method is **stubbed** in Phase 1. It returns an empty [SearchResult]
  /// with all requested [fields] listed in [SearchMetadata.skipped]. Plans 2
  /// (lexical) and 3 (semantic) replace this stub with real implementations.
  ///
  /// ## Parameters
  ///
  /// - [query] — the search query string. An empty query returns an empty
  ///   result without error.
  /// - [fields] — the document field names to search. If `null`, all indexed
  ///   fields for this collection are searched.
  /// - [filter] — an optional [Filter] to restrict the candidate set before
  ///   ranking.
  /// - [mode] — the [SearchMode] to use. Defaults to [SearchMode.auto].
  /// - [candidates] — the number of candidate documents to consider during
  ///   ranking. Higher values improve recall at the cost of performance.
  ///   Default: 100.
  /// - [limit] — the maximum number of hits to return. Default: 10.
  /// - [offset] — number of hits to skip (for pagination). Default: 0.
  ///
  /// ## Returns
  ///
  /// A [SearchResult] with [SearchResult.hits] in descending score order.
  /// Fields that could not be searched (no matching index) appear in
  /// [SearchMetadata.skipped].
  Future<SearchResult<T>> search(
    String query, {
    List<String>? fields,
    Filter? filter,
    SearchMode mode = SearchMode.auto,
    int candidates = 100,
    int limit = 10,
    int offset = 0,
  }) async {
    // Phase 1 stub: no indexes exist yet. Return an empty result with all
    // requested fields in `skipped`. Plans 2 and 3 replace this stub.
    final requestedFields = fields ?? const <String>[];
    final metadata = SearchMetadata(
      query: query,
      searched: const [],
      skipped: requestedFields.toList(),
      total: 0,
    );
    return SearchResult<T>(metadata: metadata, hits: const []);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Validates that [doc] contains no top-level keys starting with `_`.
  ///
  /// The `_` prefix is reserved for KMDB system-managed fields (e.g. `_id`).
  /// Throws [ReservedFieldException] listing every offending key if any are
  /// found. Validation runs before any I/O, so no partial writes occur.
  static void _validateNoReservedKeys(Map<String, dynamic> doc) {
    final offending = doc.keys
        .where((k) => k.startsWith('_'))
        .toList(growable: false);
    if (offending.isNotEmpty) {
      throw ReservedFieldException(offending);
    }
  }

  /// Encodes and writes [newDoc], removing old index entries for [oldDoc].
  ///
  /// Validates that [newDoc] contains no `_`-prefixed top-level keys before
  /// any I/O is performed.
  Future<void> _writeDocument({
    required String key,
    required Map<String, dynamic> newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    // Validate before any I/O — throw immediately if the codec emitted
    // reserved fields. This prevents partial writes on error.
    _validateNoReservedKeys(newDoc);
    final encodedValue = ValueCodec.encode(newDoc);
    final batch = WriteBatch()..put(namespace, key, encodedValue);
    await _db.indexManager.interceptWrite(
      batch: batch,
      namespace: namespace,
      docKey: key,
      oldDoc: oldDoc,
      newDoc: newDoc,
    );
    await _db.store.writeBatchInternal(batch);
  }

  /// Removes a document and its index entries.
  Future<void> _deleteDocument({
    required String key,
    required Map<String, dynamic> oldDoc,
  }) async {
    final batch = WriteBatch()..delete(namespace, key);
    await _db.indexManager.interceptWrite(
      batch: batch,
      namespace: namespace,
      docKey: key,
      oldDoc: oldDoc,
      newDoc: null,
    );
    await _db.store.writeBatchInternal(batch);
  }
}
