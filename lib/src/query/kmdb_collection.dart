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
/// final tasks = db.collection(namespace: 'tasks', codec: TaskCodec());
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
  }) : _db = database;

  /// The namespace this collection operates in.
  final String namespace;

  /// The codec used to encode and decode documents.
  final KmdbCodec<T> codec;

  final KmdbDatabase _db;

  /// The database this collection belongs to.
  KmdbDatabase get database => _db;

  // ── Point-lookup methods ───────────────────────────────────────────────────

  /// Returns the document with [key], or `null` if it does not exist.
  ///
  /// Uses the Cache Layer for cache-aware reads.
  Future<T?> get(String key) async {
    final bytes = await _db.cache.get(namespace, key);
    if (bytes == null) return null;
    return codec.decode(ValueCodec.decode(bytes));
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
      get(key).then(
        controller.add,
        onError: controller.addError,
      );
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
  /// Throws [DocumentAlreadyExistsException] if a document with the same key
  /// already exists.
  Future<void> insert(T value) async {
    final key = codec.keyOf(value);
    final existing = await _db.cache.get(namespace, key);
    if (existing != null) {
      throw DocumentAlreadyExistsException(key, namespace);
    }
    await _writeDocument(key: key, newDoc: codec.encode(value), oldDoc: null);
  }

  /// Replaces the document with the same key as [value].
  ///
  /// Throws [DocumentNotFoundException] if no document with that key exists.
  Future<void> replace(T value) async {
    final key = codec.keyOf(value);
    final existingBytes = await _db.cache.get(namespace, key);
    if (existingBytes == null) {
      throw DocumentNotFoundException(key, namespace);
    }
    final oldDoc = ValueCodec.decode(existingBytes);
    await _writeDocument(
        key: key, newDoc: codec.encode(value), oldDoc: oldDoc);
  }

  /// Upserts [value] — inserts if absent, replaces if present.
  Future<void> put(T value) async {
    final key = codec.keyOf(value);
    final existingBytes = await _db.cache.get(namespace, key);
    final oldDoc =
        existingBytes != null ? ValueCodec.decode(existingBytes) : null;
    await _writeDocument(
        key: key, newDoc: codec.encode(value), oldDoc: oldDoc);
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
  /// No-op if the document does not exist.
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

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Encodes and writes [newDoc], removing old index entries for [oldDoc].
  Future<void> _writeDocument({
    required String key,
    required Map<String, dynamic> newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
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
