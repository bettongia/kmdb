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
import '../search/hybrid/hybrid_manager.dart';
import '../search/search_mode.dart';
import '../search/search_result.dart';
import '../vault/vault_ref.dart';
import '../vault/vault_store.dart';
import 'exceptions.dart';
import 'filter/filter.dart';
import 'kmdb_codec.dart';
import 'kmdb_database.dart';
import 'kmdb_query.dart';
import 'query_plan.dart';

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
    return decodeDoc(doc);
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
  /// Throws [SchemaValidationException] if a [CollectionSchema] is registered
  /// for this collection and the document violates it.
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
  /// Throws [SchemaValidationException] if a [CollectionSchema] is registered
  /// for this collection and the replacement document violates it.
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
  /// Throws [SchemaValidationException] if a [CollectionSchema] is registered
  /// for this collection and the document violates it.
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
  /// Throws [SchemaValidationException] if a [CollectionSchema] is registered
  /// for this collection and the result of [updater] violates it.
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

  /// Executes [query] and returns results together with a [QueryPlan] that
  /// describes the execution strategy, index usage, and document counts.
  ///
  /// Equivalent to calling [KmdbQuery.explainedGet] directly on the query.
  /// Useful for diagnostic or EXPLAIN-style display from call sites that hold
  /// a [KmdbCollection] reference rather than a [KmdbQuery] instance.
  Future<(List<T>, QueryPlan)> explainedGet(KmdbQuery<T> query) =>
      query.explainedGet();

  // ── Text search ─────────────────────────────────────────────────────────────

  /// Searches this collection for documents matching [query].
  ///
  /// ## Parameters
  ///
  /// - [query] — the search query string. An empty query returns an empty
  ///   result without error.
  /// - [fields] — the document field names to search. If `null` or empty, all
  ///   FTS-indexed fields for this collection are searched.
  /// - [filter] — an optional [Filter] to restrict the candidate set. The
  ///   candidate set is resolved once before both index legs run; only
  ///   documents that pass the filter are scored.
  /// - [mode] — the [SearchMode] to use. Defaults to [SearchMode.auto], which
  ///   activates lexical search when only an FTS index is available, semantic
  ///   when only a vector index is available, and hybrid (RRF) when both are
  ///   present.
  /// - [candidates] — the maximum candidate documents per index leg. Default:
  ///   100. In hybrid mode, each leg (BM25 and cosine) independently fetches
  ///   up to [candidates] documents, for a pool of up to `2 × candidates`
  ///   before RRF merging.
  /// - [limit] — the maximum number of hits to return. Default: 10.
  /// - [offset] — number of hits to skip (for pagination). Default: 0.
  /// - [rrfK] — the Reciprocal Rank Fusion smoothing constant (default 60).
  ///   Only used in hybrid mode. Must be >= 1. Higher values reduce the
  ///   advantage of top-ranked documents. The default of 60 is from the
  ///   original RRF paper (Cormack et al. 2009). To tune the blending
  ///   between lexical and semantic results, adjust this value per query.
  ///
  /// ## Returns
  ///
  /// A [SearchResult] with [SearchResult.hits] in descending score order.
  /// Fields that could not be searched (no matching index) appear in
  /// [SearchMetadata.skipped].
  ///
  /// ## Hybrid mode fieldScores keys
  ///
  /// In hybrid mode, [SearchHit.fieldScores] contains:
  ///
  /// - `"{field}:bm25"` — raw BM25 score for documents in the lexical results.
  /// - `"{field}:cosine"` — raw cosine similarity for documents in the
  ///   semantic results.
  /// - `"{field}"` — per-field RRF score.
  ///
  /// A document absent from one leg has no key for that leg's component.
  ///
  /// ## Example
  ///
  /// ```dart
  /// // Hybrid search — both FTS and vector indexes are configured.
  /// final results = await articles.search(
  ///   'full text search engine',
  ///   fields: ['title', 'body'],
  ///   filter: Filter.field('published').equals(true),
  ///   limit: 20,
  ///   rrfK: 60,
  /// );
  /// for (final hit in results.hits) {
  ///   print('${hit.rank}. [${hit.score.toStringAsFixed(3)}] ${hit.id}');
  /// }
  /// ```
  Future<SearchResult<T>> search(
    String query, {
    List<String>? fields,
    Filter? filter,
    SearchMode mode = SearchMode.auto,
    int candidates = 100,
    int limit = 10,
    int offset = 0,
    int rrfK = 60,
  }) async {
    final fts = _db.ftsManager;

    // Determine the effective field list.
    // When no explicit fields are given, union the FTS-indexed and vec-indexed
    // field lists so that a vec-only configuration is still auto-discoverable.
    List<String> effectiveFields;
    if (fields == null || fields.isEmpty) {
      final ftsFields = fts?.indexedFieldsFor(namespace) ?? const <String>[];
      final vecFields =
          _db.vecManager?.indexedFieldsFor(namespace) ?? const <String>[];
      // Preserve order: FTS fields first, then any vec-only fields.
      final merged = {...ftsFields, ...vecFields}.toList();
      effectiveFields = merged;
    } else {
      effectiveFields = fields;
    }

    if (effectiveFields.isEmpty || query.isEmpty) {
      return SearchResult<T>(
        metadata: SearchMetadata(
          query: query,
          searched: const [],
          skipped: effectiveFields,
          total: 0,
        ),
        hits: const [],
      );
    }

    // When a filter is provided, resolve candidateIds by scanning the
    // collection and applying the filter. This is the pre-filter step (spec
    // §21.6): only candidate documents are passed to the inverted-index scan,
    // avoiding scoring of irrelevant documents.
    Set<String>? candidateIds;
    if (filter != null) {
      final ids = <String>{};
      await for (final entry in _db.store.scan(namespace)) {
        Map<String, dynamic> doc;
        try {
          doc = ValueCodec.decode(entry.value);
        } catch (_) {
          continue;
        }
        doc['_id'] = entry.key;
        if (filter.evaluate(doc)) {
          ids.add(entry.key);
        }
      }
      candidateIds = ids;
      if (candidateIds.isEmpty) {
        return SearchResult<T>(
          metadata: SearchMetadata(
            query: query,
            searched: const [],
            skipped: effectiveFields,
            total: 0,
          ),
          hits: const [],
        );
      }
    }

    final vec = _db.vecManager;

    // Route based on mode and available indexes.
    if (mode == SearchMode.lexical) {
      // Lexical-only: delegate to FTS if available.
      if (fts != null && fts.hasAnyIndex(namespace)) {
        return fts.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          limit: limit,
          offset: offset,
        );
      }
    } else if (mode == SearchMode.semantic) {
      // Semantic-only: delegate to VecManager if available.
      if (vec != null && vec.hasAnyIndex(namespace)) {
        return vec.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          candidates: candidates,
          limit: limit,
          offset: offset,
        );
      }
    } else {
      // auto: prefer hybrid when both indexes are available; fall back to
      // whichever single index is present.
      final hasFts = fts != null && fts.hasAnyIndex(namespace);
      final hasVec = vec != null && vec.hasAnyIndex(namespace);

      if (hasFts && hasVec) {
        // Hybrid path: run both index legs independently, then merge via RRF.
        // Each leg fetches up to `candidates` results. The merged pool is at
        // most 2×candidates before RRF scoring and pagination (spec §23).
        //
        // candidateIds (pre-filter) is passed to both legs so neither
        // re-scans the collection for filtering — the filter is resolved once.
        final lexResult = await fts.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          limit: candidates,
          offset: 0,
        );

        final vecResult = await vec.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          candidates: candidates,
          limit: candidates,
          offset: 0,
        );

        // Determine the union of searched/skipped across both legs.
        final bothSearched = {
          ...lexResult.metadata.searched,
          ...vecResult.metadata.searched,
        }.toList();
        final bothSkipped = effectiveFields
            .where((f) => !bothSearched.contains(f))
            .toList();

        final hybridMeta = SearchMetadata(
          query: query,
          searched: bothSearched,
          skipped: bothSkipped,
          total: 0, // updated by mergeWithRrf
        );

        return mergeWithRrf<T>(
          lexicalHits: lexResult.hits,
          semanticHits: vecResult.hits,
          limit: limit,
          offset: offset,
          metadata: hybridMeta,
          rrfK: rrfK,
        );
      } else if (hasFts) {
        return fts.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          limit: limit,
          offset: offset,
        );
      } else if (hasVec) {
        return vec.search<T>(
          namespace: namespace,
          query: query,
          fields: effectiveFields,
          fetchDoc: (id) => get(id),
          candidateIds: candidateIds,
          candidates: candidates,
          limit: limit,
          offset: offset,
        );
      }
    }

    // No index available — return empty result with all fields skipped.
    return SearchResult<T>(
      metadata: SearchMetadata(
        query: query,
        searched: const [],
        skipped: effectiveFields,
        total: 0,
      ),
      hits: const [],
    );
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  /// Decodes a document map [doc] to [T], wiring any vault URI strings to the
  /// active [VaultStore] so that [VaultRef.getBlob] and [VaultRef.getMetadata]
  /// work on the decoded objects.
  ///
  /// When no [VaultStore] is configured, vault URI strings are left as plain
  /// strings in the map (the codec is responsible for wrapping them in
  /// [VaultRef] instances with no store — those instances will throw
  /// [StateError] if blob/metadata access is attempted).
  ///
  /// When a [VaultStore] is configured, vault URI strings in [doc] are
  /// replaced with wired [VaultRef] instances before the map is passed to
  /// [KmdbCodec.decode]. This allows codec implementations to call
  /// `json['avatar'] as VaultRef` safely in their `decode` method.
  T decodeDoc(Map<String, dynamic> doc) {
    final vaultStore = _db.vaultStore;
    if (vaultStore != null) {
      _wireVaultRefsInMap(doc, vaultStore);
    }
    return codec.decode(doc);
  }

  /// Recursively replaces vault URI strings in [map] with wired [VaultRef]
  /// instances backed by [store].
  static void _wireVaultRefsInMap(Map<String, dynamic> map, VaultStore store) {
    for (final entry in map.entries.toList()) {
      final value = entry.value;
      if (value is String && VaultRef.isVaultUri(value)) {
        final ref = VaultRef(value)..wire(store);
        map[entry.key] = ref;
      } else if (value is Map<String, dynamic>) {
        _wireVaultRefsInMap(value, store);
      } else if (value is List<dynamic>) {
        _wireVaultRefsInList(value, store);
      }
    }
  }

  /// Recursively replaces vault URI strings in [list] with wired [VaultRef]
  /// instances backed by [store].
  static void _wireVaultRefsInList(List<dynamic> list, VaultStore store) {
    for (var i = 0; i < list.length; i++) {
      final value = list[i];
      if (value is String && VaultRef.isVaultUri(value)) {
        final ref = VaultRef(value)..wire(store);
        list[i] = ref;
      } else if (value is Map<String, dynamic>) {
        _wireVaultRefsInMap(value, store);
      } else if (value is List<dynamic>) {
        _wireVaultRefsInList(value, store);
      }
    }
  }

  /// Encodes and writes [newDoc], updating index entries for [oldDoc].
  ///
  /// Runs all registered [WriteValidator]s (Layer 1) before any I/O so that
  /// a violation aborts the write cleanly. Then runs all [WriteAugmentor]s
  /// (Layer 2) to add side-effect entries to the [WriteBatch] before it is
  /// atomically committed (Layer 3 — `writeEvents` fires automatically).
  Future<void> _writeDocument({
    required String key,
    required Map<String, dynamic> newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    // Layer 1: run validators before any I/O. Any validator may throw to
    // abort the write; no partial I/O occurs if one does.
    for (final validator in _db.validators) {
      validator.validate(namespace, newDoc);
    }

    final encodedValue = ValueCodec.encode(newDoc);
    final batch = WriteBatch()..put(namespace, key, encodedValue);

    // Layer 2: run augmentors to add side-effect entries to the batch.
    // All augmentor writes share the same atomic WriteBatch as the document
    // write, ensuring consistency between document and index state.
    for (final augmentor in _db.augmentors) {
      await augmentor.interceptWrite(
        batch: batch,
        namespace: namespace,
        docKey: key,
        newDoc: newDoc,
        oldDoc: oldDoc,
      );
    }

    // Layer 3: commit the batch — writeEvents fires automatically and the
    // CacheLayer / watch() subscribers are notified via the stream.
    await _db.store.writeBatchInternal(batch);
  }

  /// Removes a document and its index entries (secondary, FTS, and vector).
  ///
  /// Runs all registered [WriteAugmentor]s (Layer 2) with `newDoc: null` to
  /// clean up side-effect entries. Validators are not run — deletes are never
  /// blocked by admission-gate checks.
  Future<void> _deleteDocument({
    required String key,
    required Map<String, dynamic> oldDoc,
  }) async {
    final batch = WriteBatch()..delete(namespace, key);

    // Layer 2: augmentors receive newDoc: null to signal deletion.
    for (final augmentor in _db.augmentors) {
      await augmentor.interceptWrite(
        batch: batch,
        namespace: namespace,
        docKey: key,
        newDoc: null,
        oldDoc: oldDoc,
      );
    }

    await _db.store.writeBatchInternal(batch);
  }
}
