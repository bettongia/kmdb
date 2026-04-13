// Copyright 2026 The KMDB Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:math' show min, max;
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../encoding/value_codec.dart';
import '../../engine/kvstore/kv_store.dart';
import '../../engine/kvstore/kv_store_impl.dart';
import '../embedding_model.dart';
import '../search_result.dart';
import '../sync_delta.dart';
import '../vec_index_definition.dart';
import 'vec_index_state.dart';

/// Manages all vector (semantic) search indexes for a [KmdbDatabase] instance.
///
/// [VecManager] intercepts document writes to maintain SQ8-quantised BGE
/// embedding indexes, executes flat-scan cosine similarity queries, and handles
/// post-sync delta application. All vector key writes are included in the same
/// [WriteBatch] as the triggering document write, ensuring atomicity (spec §22).
///
/// ## Storage layout
///
/// For each (collection, field) pair declared in a [VecIndexDefinition]:
///
/// | Namespace | Key | Content |
/// |---|---|---|
/// | `$vec:{ns}:{field}` | `{docId}` (32-char UUID) | 384-byte SQ8 vector |
/// | `$vec:corpus:{ns}:{field}` | corpus sentinel | CBOR map — `{n}` |
/// | `$vec:truncated:{ns}:{field}` | `{docId}` (32-char UUID) | empty bytes |
///
/// ## Index lifecycle
///
/// ```
/// undefined → building → current
///                      ↘ stale → (rebuild) → current
/// current → syncing → current
///         ↘ (crash during sync) → stale → (rebuild) → current
/// ```
///
/// On [KmdbDatabase.open], [checkAndTransitionOnOpen] transitions any index
/// found in `syncing` state to `stale` (crash recovery for interrupted deltas).
///
/// ## SQ8 quantisation
///
/// Embeddings are stored as unsigned 8-bit integers using a fixed symmetric
/// range for L2-normalised vectors:
/// - Encode: `u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)`
/// - Decode: `f = u / 255.0 * 2.0 - 1.0`
///
/// The dot product of two dequantised L2-normalised vectors approximates their
/// cosine similarity. Maximum per-element quantisation error is ≈ 0.004.
///
/// ## Example
///
/// ```dart
/// final manager = VecManager(store, [
///   VecIndexDefinition(collection: 'articles', field: 'body'),
/// ], embeddingModel);
/// await manager.checkAndTransitionOnOpen();
///
/// // On every document write, before committing the batch:
/// final batch = WriteBatch()..put('articles', docId, encodedValue);
/// await manager.interceptWrite(
///   namespace: 'articles', docId: docId,
///   newDoc: encodedMap, oldDoc: null, batch: batch,
/// );
/// await store.writeBatchInternal(batch);
/// ```
final class VecManager {
  /// Creates a [VecManager].
  ///
  /// [store] is the underlying [KvStoreImpl] used for all index reads and
  /// writes. [defs] is the list of vector index definitions configured at
  /// [KmdbDatabase.open] time. [model] is the embedding model used to generate
  /// float32 vectors from text fields.
  VecManager(
    KvStoreImpl store,
    List<VecIndexDefinition> defs,
    EmbeddingModel model,
  ) : _store = store,
      _defs = List.unmodifiable(defs),
      _model = model;

  final KvStoreImpl _store;
  final List<VecIndexDefinition> _defs;
  final EmbeddingModel _model;

  /// In-memory cache of index statuses, keyed by `'{namespace}:{field}'`.
  ///
  /// Populated during [checkAndTransitionOnOpen]. Updated synchronously on
  /// every [_saveState] call so [interceptWrite] can skip unbuilt indexes
  /// without an async meta read on the hot write path.
  final _statusCache = <String, VecIndexStatus>{};

  // ── Startup ─────────────────────────────────────────────────────────────────

  /// Called during [KmdbDatabase.open] to recover from unclean shutdowns.
  ///
  /// Any index found in `syncing` state indicates that [applyDelta] was
  /// interrupted by a crash. The index is transitioned to `stale` so the next
  /// call to [ensureBuilt] triggers a full rebuild.
  Future<void> checkAndTransitionOnOpen() async {
    for (final def in _defs) {
      final state = await _loadState(def.collection, def.field);
      _statusCache[_cacheKey(def.collection, def.field)] = state.status;
      if (state.status == VecIndexStatus.syncing) {
        await _saveState(
          state.copyWith(status: VecIndexStatus.stale),
          def.collection,
          def.field,
        );
      }
    }
  }

  // ── Index queries ─────────────────────────────────────────────────────────

  /// Returns `true` if a vector index is declared for [namespace]/[field].
  bool hasIndex(String namespace, String field) =>
      _find(namespace, field) != null;

  /// Returns `true` if any vector index is declared for [namespace].
  bool hasAnyIndex(String namespace) =>
      _defs.any((d) => d.collection == namespace);

  /// Returns all field names that have vector indexes in [namespace].
  List<String> indexedFieldsFor(String namespace) => _defs
      .where((d) => d.collection == namespace)
      .map((d) => d.field)
      .toList();

  // ── Write interception ─────────────────────────────────────────────────────

  /// Adds vector index writes to [batch] for a document write.
  ///
  /// Call this for every document write before committing the [WriteBatch].
  /// The vector writes and the document write share the same batch, ensuring
  /// atomicity. If embedding inference fails, a [StateError] is thrown and the
  /// batch must not be committed — the document store remains unmodified.
  ///
  /// - [newDoc] is the new document content (`null` for deletes).
  /// - [oldDoc] is the previous document content (`null` for inserts).
  ///
  /// Handles all three cases:
  /// - Insert (`oldDoc == null`, `newDoc != null`) — runs inference, writes vector.
  /// - Update (`oldDoc != null`, `newDoc != null`) — overwrites vector; adjusts
  ///   truncation marker. Corpus `n` is unchanged.
  /// - Delete (`newDoc == null`) — removes vector and truncation marker; decrements `n`.
  Future<void> interceptWrite({
    required String namespace,
    required String docId,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
    required WriteBatch batch,
  }) async {
    final matching = _defsFor(namespace);
    if (matching.isEmpty) return;

    for (final def in matching) {
      // Only intercept when the index is active (building, current, or
      // syncing). Undefined and stale indexes are rebuilt lazily by
      // ensureBuilt; intercepting before the index exists would create entries
      // that ensureBuilt cannot reliably reconcile.
      final status =
          _statusCache[_cacheKey(namespace, def.field)] ??
          VecIndexStatus.undefined;
      if (status == VecIndexStatus.undefined ||
          status == VecIndexStatus.stale) {
        continue;
      }

      if (newDoc == null) {
        await _interceptDelete(def, namespace, docId, batch);
      } else if (oldDoc == null) {
        await _interceptInsert(def, namespace, docId, newDoc, batch);
      } else {
        await _interceptUpdate(def, namespace, docId, newDoc, batch);
      }
    }
  }

  Future<void> _interceptInsert(
    VecIndexDefinition def,
    String namespace,
    String docId,
    Map<String, dynamic> doc,
    WriteBatch batch,
  ) async {
    final fieldValue = _extractFieldValue(doc, def.field);
    if (fieldValue == null) return; // field absent — nothing to index

    final (embedding, truncated) = await _embed(fieldValue);
    final quantised = _quantise(embedding);

    batch.put(
      VecIndexState.vecNamespace(namespace, def.field),
      docId,
      quantised,
    );

    if (truncated) {
      batch.put(
        VecIndexState.truncatedNamespace(namespace, def.field),
        docId,
        Uint8List(0),
      );
    }

    // Increment corpus document count.
    final n = await _readCorpusN(namespace, def.field);
    _writeCorpusN(namespace, def.field, n + 1, batch);
  }

  Future<void> _interceptDelete(
    VecIndexDefinition def,
    String namespace,
    String docId,
    WriteBatch batch,
  ) async {
    batch.delete(VecIndexState.vecNamespace(namespace, def.field), docId);
    // Safe no-op if marker is absent — delete is idempotent.
    batch.delete(VecIndexState.truncatedNamespace(namespace, def.field), docId);

    // Decrement corpus document count (floor at 0).
    final n = await _readCorpusN(namespace, def.field);
    if (n > 0) {
      _writeCorpusN(namespace, def.field, n - 1, batch);
    }
  }

  Future<void> _interceptUpdate(
    VecIndexDefinition def,
    String namespace,
    String docId,
    Map<String, dynamic> newDoc,
    WriteBatch batch,
  ) async {
    final fieldValue = _extractFieldValue(newDoc, def.field);
    if (fieldValue == null) {
      // Field removed — treat as delete without changing corpus count.
      batch.delete(VecIndexState.vecNamespace(namespace, def.field), docId);
      batch.delete(
        VecIndexState.truncatedNamespace(namespace, def.field),
        docId,
      );
      return;
    }

    final (embedding, truncated) = await _embed(fieldValue);
    final quantised = _quantise(embedding);

    // Overwrite the vector atomically — no read-before-write needed.
    batch.put(
      VecIndexState.vecNamespace(namespace, def.field),
      docId,
      quantised,
    );

    // Adjust truncation marker: remove stale marker and add new one if needed.
    batch.delete(VecIndexState.truncatedNamespace(namespace, def.field), docId);
    if (truncated) {
      batch.put(
        VecIndexState.truncatedNamespace(namespace, def.field),
        docId,
        Uint8List(0),
      );
    }

    // Corpus n is unchanged for updates.
  }

  // ── Lazy build ────────────────────────────────────────────────────────────

  /// Ensures the vector index for [namespace]/[field] is built and current.
  ///
  /// - If the index is [VecIndexStatus.undefined] or [VecIndexStatus.stale],
  ///   performs a full namespace scan running inference on every document.
  /// - If the index is [VecIndexStatus.building], waits for it to complete
  ///   (no-op — build is synchronous, so this state is transient).
  /// - If the index is [VecIndexStatus.current] or [VecIndexStatus.syncing],
  ///   returns immediately.
  ///
  /// Building the index may take several seconds for large collections.
  Future<void> ensureBuilt(String namespace, String field) async {
    final state = await _loadState(namespace, field);

    if (state.status == VecIndexStatus.current ||
        state.status == VecIndexStatus.syncing) {
      return;
    }

    // Transition to building and persist before scanning, so a crash during
    // build leaves the index in `building` (which transitions to `stale` on
    // next open via checkAndTransitionOnOpen).
    await _saveState(
      state.copyWith(status: VecIndexStatus.building, builtThrough: ''),
      namespace,
      field,
    );

    // Reset the vector and corpus namespaces before rebuilding.
    await _clearVecEntries(namespace, field);

    // Full namespace scan: for each document, run inference and store vector.
    var count = 0;
    String lastDocId = '';

    await for (final entry in _store.scan(namespace)) {
      final docId = entry.key;
      Map<String, dynamic> doc;
      try {
        doc = ValueCodec.decode(entry.value);
      } catch (_) {
        continue; // skip corrupt entries
      }

      final fieldValue = _extractFieldValue(doc, field);
      if (fieldValue == null) continue;

      final (embedding, truncated) = await _embed(fieldValue);
      final quantised = _quantise(embedding);

      final batch = WriteBatch();
      batch.put(VecIndexState.vecNamespace(namespace, field), docId, quantised);
      if (truncated) {
        batch.put(
          VecIndexState.truncatedNamespace(namespace, field),
          docId,
          Uint8List(0),
        );
      }
      await _store.writeBatchInternal(batch);

      count++;
      lastDocId = docId;
    }

    // Write final corpus count and mark index current.
    final corpusBatch = WriteBatch();
    _writeCorpusN(namespace, field, count, corpusBatch);
    await _store.writeBatchInternal(corpusBatch);

    await _saveState(
      state.copyWith(
        status: VecIndexStatus.current,
        builtThrough: lastDocId,
        builtAt: DateTime.now().toUtc().toIso8601String(),
      ),
      namespace,
      field,
    );
  }

  // ── Delta sync ────────────────────────────────────────────────────────────

  /// Applies a post-sync [delta] to the vector index for [namespace].
  ///
  /// Transitions the index through `syncing` while catch-up inference runs.
  /// Queries during `syncing` are served from the pre-delta index entries
  /// (reads are not blocked). Each document is committed in its own
  /// [WriteBatch] so a crash leaves only partial delta state; the index is
  /// recovered to `stale` on next [checkAndTransitionOnOpen].
  ///
  /// This method is intended to run in a background isolate for large deltas —
  /// inference is CPU-bound and should not block the main isolate.
  Future<void> applyDelta(String namespace, SyncDelta delta) async {
    final defsForNs = _defsFor(namespace);
    if (defsForNs.isEmpty) return;

    // Transition each index to syncing.
    for (final def in defsForNs) {
      final state = await _loadState(namespace, def.field);
      if (state.status == VecIndexStatus.current) {
        await _saveState(
          state.copyWith(status: VecIndexStatus.syncing),
          namespace,
          def.field,
        );
      }
    }

    // Process each change in the delta.
    for (final change in delta.changes) {
      for (final def in defsForNs) {
        final batch = WriteBatch();
        await _applyDeltaChange(def, namespace, change, batch);
        if (!batch.isEmpty) {
          await _store.writeBatchInternal(batch);
        }
      }
    }

    // Transition each index back to current.
    for (final def in defsForNs) {
      final state = await _loadState(namespace, def.field);
      if (state.status == VecIndexStatus.syncing) {
        await _saveState(
          state.copyWith(
            status: VecIndexStatus.current,
            builtAt: DateTime.now().toUtc().toIso8601String(),
          ),
          namespace,
          def.field,
        );
      }
    }
  }

  Future<void> _applyDeltaChange(
    VecIndexDefinition def,
    String namespace,
    DeltaEntry change,
    WriteBatch batch,
  ) async {
    final docId = change.docId;

    switch (change.changeType) {
      case DeltaChangeType.added:
        final bytes = await _store.get(namespace, docId);
        if (bytes == null) return; // deleted again before delta was applied
        Map<String, dynamic> doc;
        try {
          doc = ValueCodec.decode(bytes);
        } catch (_) {
          return;
        }
        await _interceptInsert(def, namespace, docId, doc, batch);

      case DeltaChangeType.updated:
        final bytes = await _store.get(namespace, docId);
        if (bytes == null) return;
        Map<String, dynamic> doc;
        try {
          doc = ValueCodec.decode(bytes);
        } catch (_) {
          return;
        }
        await _interceptUpdate(def, namespace, docId, doc, batch);

      case DeltaChangeType.deleted:
        await _interceptDelete(def, namespace, docId, batch);
    }
  }

  // ── Flat-scan cosine similarity search ────────────────────────────────────

  /// Searches [namespace] for documents semantically similar to [query].
  ///
  /// Embeds [query] using the configured [EmbeddingModel], then performs a
  /// brute-force flat scan of the `$vec:{namespace}:{field}` namespaces,
  /// dequantising each stored vector and computing its dot product with the
  /// query vector (dot product of L2-normalised vectors = cosine similarity).
  ///
  /// When [candidateIds] is provided, only those document IDs are scored via
  /// targeted key lookups; the full prefix scan is skipped.
  ///
  /// Returns the top-[candidates] results per field, then merges them across
  /// fields by taking the max per-field cosine score as the document overall
  /// score. [limit] and [offset] control result pagination.
  ///
  /// Fields not indexed appear in [SearchMetadata.skipped].
  Future<SearchResult<T>> search<T>({
    required String namespace,
    required String query,
    required List<String> fields,
    required Future<T?> Function(String docId) fetchDoc,
    Set<String>? candidateIds,
    int candidates = 100,
    int limit = 10,
    int offset = 0,
  }) async {
    if (query.isEmpty) {
      return _emptyResult(query: query, searched: [], skipped: fields);
    }

    // Partition fields into searched (have index) and skipped (no index).
    final searched = <String>[];
    final skipped = <String>[];
    for (final field in fields) {
      if (_find(namespace, field) != null) {
        searched.add(field);
      } else {
        skipped.add(field);
      }
    }

    if (searched.isEmpty) {
      return _emptyResult(query: query, searched: [], skipped: skipped);
    }

    // Ensure all searched indexes are built before querying.
    for (final field in searched) {
      await ensureBuilt(namespace, field);
    }

    // Embed the query string once; reused for all fields.
    final (queryEmbedding, _) = await _embed(query);

    // Per-document per-field cosine scores.
    // Structure: docId → {field: cosine}
    final docFieldScores = <String, Map<String, double>>{};

    for (final field in searched) {
      final fieldScores = await _scoreField(
        namespace: namespace,
        field: field,
        queryEmbedding: queryEmbedding,
        candidateIds: candidateIds,
        candidates: candidates,
      );

      for (final e in fieldScores.entries) {
        (docFieldScores[e.key] ??= {})[field] = e.value;
      }
    }

    if (docFieldScores.isEmpty) {
      return _emptyResult(query: query, searched: searched, skipped: skipped);
    }

    // Overall document score: max cosine across all searched fields.
    final docScores =
        docFieldScores.entries
            .map(
              (e) => (docId: e.key, score: e.value.values.reduce(_maxDouble)),
            )
            .toList()
          ..sort((a, b) {
            final cmp = b.score.compareTo(a.score);
            return cmp != 0 ? cmp : a.docId.compareTo(b.docId);
          });

    final total = docScores.length;
    final page = docScores.skip(offset).take(limit);

    final hits = <SearchHit<T>>[];
    var rank = offset + 1;

    for (final scored in page) {
      final doc = await fetchDoc(scored.docId);
      if (doc == null) {
        rank++;
        continue; // document may have been deleted since the index was read
      }

      final fieldScores = <String, double>{};
      for (final fe in (docFieldScores[scored.docId] ?? {}).entries) {
        fieldScores['${fe.key}:cosine'] = fe.value;
      }

      hits.add(
        SearchHit<T>(
          rank: rank++,
          score: scored.score,
          fieldScores: fieldScores,
          id: scored.docId,
          document: doc,
        ),
      );
    }

    return SearchResult<T>(
      metadata: SearchMetadata(
        query: query,
        searched: searched,
        skipped: skipped,
        total: total,
      ),
      hits: hits,
    );
  }

  /// Scores all documents in [namespace]/[field] against [queryEmbedding].
  ///
  /// Returns a map of `{docId: cosineScore}` sorted by descending score,
  /// truncated to the top [candidates] results.
  Future<Map<String, double>> _scoreField({
    required String namespace,
    required String field,
    required Float32List queryEmbedding,
    Set<String>? candidateIds,
    required int candidates,
  }) async {
    final scores = <String, double>{};

    if (candidateIds != null) {
      // Pre-filter path: targeted key lookups instead of a full prefix scan.
      for (final docId in candidateIds) {
        final bytes = await _store.get(
          VecIndexState.vecNamespace(namespace, field),
          docId,
        );
        if (bytes == null || bytes.length != 384) continue;
        final deq = _dequantise(bytes);
        scores[docId] = _dotProduct(queryEmbedding, deq);
      }
    } else {
      // Full scan path: iterate every entry in the vector namespace.
      await for (final entry in _store.scan(
        VecIndexState.vecNamespace(namespace, field),
      )) {
        if (entry.value.length != 384) continue; // skip corrupt entries
        final deq = _dequantise(entry.value);
        scores[entry.key] = _dotProduct(queryEmbedding, deq);
      }
    }

    if (scores.isEmpty) return {};

    // Keep only the top-candidates results by descending score.
    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Map.fromEntries(sorted.take(candidates));
  }

  // ── Corpus helpers ────────────────────────────────────────────────────────

  Future<int> _readCorpusN(String namespace, String field) async {
    final bytes = await _store.get(
      VecIndexState.corpusNamespace(namespace, field),
      VecIndexState.corpusSentinelKey,
    );
    if (bytes == null || bytes.isEmpty) return 0;
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is CborMap) {
        final map = decoded.toObject() as Map<dynamic, dynamic>;
        return (map['n'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  void _writeCorpusN(String namespace, String field, int n, WriteBatch batch) {
    final encoded = Uint8List.fromList(
      cbor.encode(CborMap({CborString('n'): CborSmallInt(n)})),
    );
    batch.put(
      VecIndexState.corpusNamespace(namespace, field),
      VecIndexState.corpusSentinelKey,
      encoded,
    );
  }

  // ── Clear helpers ─────────────────────────────────────────────────────────

  /// Removes all stored vector entries for [namespace]/[field] before a
  /// full rebuild. Corpus stats are reset via a subsequent [_writeCorpusN]
  /// call at the end of the build scan.
  Future<void> _clearVecEntries(String namespace, String field) async {
    final vecNs = VecIndexState.vecNamespace(namespace, field);
    final truncatedNs = VecIndexState.truncatedNamespace(namespace, field);
    final corpusNs = VecIndexState.corpusNamespace(namespace, field);

    // Collect keys before deleting to avoid scan-while-mutating.
    final vecKeys = <String>[];
    await for (final entry in _store.scan(vecNs)) {
      vecKeys.add(entry.key);
    }
    final truncatedKeys = <String>[];
    await for (final entry in _store.scan(truncatedNs)) {
      truncatedKeys.add(entry.key);
    }

    if (vecKeys.isNotEmpty || truncatedKeys.isNotEmpty) {
      final batch = WriteBatch();
      for (final k in vecKeys) {
        batch.delete(vecNs, k);
      }
      for (final k in truncatedKeys) {
        batch.delete(truncatedNs, k);
      }
      batch.delete(corpusNs, VecIndexState.corpusSentinelKey);
      await _store.writeBatchInternal(batch);
    }
  }

  // ── State persistence ─────────────────────────────────────────────────────

  Future<VecIndexState> _loadState(String namespace, String field) async {
    final bytes = await _store.meta.getRawByName(
      VecIndexState.metaKey(namespace, field),
    );
    return VecIndexState.fromBytes(namespace, field, bytes);
  }

  Future<void> _saveState(
    VecIndexState state,
    String namespace,
    String field,
  ) async {
    _statusCache[_cacheKey(namespace, field)] = state.status;
    await _store.meta.putRawByName(
      VecIndexState.metaKey(namespace, field),
      state.toBytes(),
    );
  }

  // ── SQ8 quantisation ──────────────────────────────────────────────────────
  //
  // These helpers duplicate the public quantise/dequantise functions from
  // kmdb_inferencing to avoid a circular package dependency (kmdb_inferencing
  // depends on kmdb, not the other way around).
  //
  // Formula:
  //   encode: u = clamp(round((f + 1.0) / 2.0 * 255), 0, 255)
  //   decode: f = u / 255.0 * 2.0 - 1.0
  //
  // This maps the L2-normalised range [-1, 1] → [0, 255] with ≤0.004 error.

  static Uint8List _quantise(Float32List vector) {
    final out = Uint8List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      final u = ((vector[i] + 1.0) / 2.0 * 255.0).roundToDouble();
      out[i] = min(255, max(0, u.toInt()));
    }
    return out;
  }

  static Float32List _dequantise(Uint8List vector) {
    final out = Float32List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      out[i] = vector[i] / 255.0 * 2.0 - 1.0;
    }
    return out;
  }

  // ── Dot product ───────────────────────────────────────────────────────────

  /// Computes the dot product of two float32 vectors.
  ///
  /// For L2-normalised vectors this equals cosine similarity. Both vectors must
  /// have the same length.
  static double _dotProduct(Float32List a, Float32List b) {
    assert(
      a.length == b.length,
      'Vector length mismatch: ${a.length} vs ${b.length}',
    );
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  // ── Embedding helper ──────────────────────────────────────────────────────

  /// Calls [_model.embed] and wraps inference failures as [StateError].
  ///
  /// Wrapping as [StateError] ensures the calling [interceptWrite] propagates
  /// an error that prevents the WriteBatch from being committed.
  Future<(Float32List, bool)> _embed(String text) async {
    try {
      return await _model.embed(text);
    } catch (e) {
      throw StateError('Embedding inference failed: $e');
    }
  }

  // ── Field extraction ──────────────────────────────────────────────────────

  /// Extracts the string value of [field] from [doc] using dot-notation.
  ///
  /// Returns `null` if the field is absent, not a string, or empty.
  static String? _extractFieldValue(Map<String, dynamic> doc, String field) {
    final parts = field.split('.');
    dynamic current = doc;
    for (final part in parts) {
      if (current is! Map) return null;
      current = current[part];
    }
    if (current is! String || current.isEmpty) return null;
    return current;
  }

  // ── Utility helpers ───────────────────────────────────────────────────────

  static String _cacheKey(String namespace, String field) =>
      '$namespace:$field';

  VecIndexDefinition? _find(String namespace, String field) {
    for (final def in _defs) {
      if (def.collection == namespace && def.field == field) return def;
    }
    return null;
  }

  List<VecIndexDefinition> _defsFor(String namespace) =>
      _defs.where((d) => d.collection == namespace).toList();

  static double _maxDouble(double a, double b) => a > b ? a : b;

  static SearchResult<T> _emptyResult<T>({
    required String query,
    required List<String> searched,
    required List<String> skipped,
  }) => SearchResult<T>(
    metadata: SearchMetadata(
      query: query,
      searched: searched,
      skipped: skipped,
      total: 0,
    ),
    hits: const [],
  );
}
