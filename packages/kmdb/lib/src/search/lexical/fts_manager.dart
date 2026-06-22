// Copyright 2026 The Authors
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

/// @docImport '../../query/kmdb_collection.dart';
library;

import 'dart:convert' show utf8;
import 'dart:math' show log;
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:intl/locale.dart' show Locale;
import 'package:betto_lexical/betto_lexical.dart'
    show createDefaultTokenizer, getStopWords;
import 'package:meta/meta.dart' show visibleForTesting;

import '../../encoding/value_codec.dart';
import '../../encryption/encryption_provider.dart';
import '../../engine/kvstore/kv_store.dart';
import '../../engine/kvstore/kv_store_impl.dart';
import '../../query/write_augmentor.dart';
import '../fts_index_definition.dart';
import '../search_result.dart';
import '../sync_delta.dart';
import 'fts_index_state.dart';
import 'pipeline.dart';

final defaultStopwords = getStopWords(Locale.fromSubtags(languageCode: 'en'));

/// Manages all full-text search (FTS) indexes for a [KmdbDatabase] instance.
///
/// [FtsManager] intercepts document writes to maintain BM25 inverted indexes,
/// executes lexical search queries, and handles post-sync delta application.
/// All FTS key writes are included in the same [WriteBatch] as the triggering
/// document write, ensuring atomicity (spec §21.4).
///
/// ## Storage layout
///
/// The KvStore requires all keys to be 32-character hex strings (UUIDv7 format).
/// FTS uses a **namespace-per-term** scheme for base entries (mirroring the
/// secondary index namespace-per-value pattern) so that document keys satisfy
/// this constraint.
///
/// For each (collection, field) pair declared in an [FtsIndexDefinition]:
///
/// | Namespace | Key | Content |
/// |---|---|---|
/// | `$$fts:{ns}:{field}:{hexTerm}` | `{docId}` (32-char UUID) | CBOR int — term frequency (tf) |
/// | `$$fts:overlay:{ns}:{field}` | `{docId}` (32-char UUID) | CBOR map (term→tf) or tombstone |
/// | `$$fts:doc:{ns}:{field}` | `{docId}` (32-char UUID) | CBOR map `{n, t}` — token count and terms list |
/// | `$$fts:corpus:{ns}:{field}` | fixed 32-char hex sentinel | CBOR map — `{n, totalTokens}` |
///
/// All `$$fts:*` namespaces are **local-only**: they are never uploaded to the
/// sync folder. Each device rebuilds its FTS index independently from document
/// data that is synced via the regular (non-`$$`) namespaces.
///
/// The hex term encoding uses `utf8.encode(term).map(hex).join()` — the same
/// approach as `IndexWriter` for field values.
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
/// ## Example
///
/// ```dart
/// final manager = FtsManager(store, [
///   FtsIndexDefinition(collection: 'articles', field: 'body'),
/// ]);
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
/// Implements [WriteAugmentor] so it integrates with the formal write pipeline
/// without requiring special-casing in [KmdbCollection].
final class FtsManager implements WriteAugmentor {
  /// Creates an [FtsManager].
  ///
  /// [store] is the underlying [KvStoreImpl] used for all index reads and
  /// Creates an [FtsManager].
  ///
  /// [store] is the underlying [KvStoreImpl]. [defs] is the list of FTS index
  /// definitions. [encryption] is the optional encryption provider; when
  /// non-null, source document values are decrypted before indexing (they were
  /// written through the same encrypted [ValueCodec] path).
  FtsManager(
    KvStoreImpl store,
    List<FtsIndexDefinition> defs, {
    this._encryption,
  }) : _store = store,
       _defs = List.unmodifiable(defs);

  final KvStoreImpl _store;
  final List<FtsIndexDefinition> _defs;

  /// Optional encryption provider threaded through all [ValueCodec] calls.
  final EncryptionProvider? _encryption;

  /// In-memory cache of index statuses, keyed by `'{namespace}:{field}'`.
  ///
  /// Populated during [checkAndTransitionOnOpen] by loading the persisted state
  /// for every declared index. Updated synchronously on every [_saveState] call
  /// so that [interceptWrite] can skip unbuilt indexes without an async meta
  /// read on the hot path.
  final _statusCache = <String, FtsIndexStatus>{};

  // ── Startup ─────────────────────────────────────────────────────────────────

  /// Called during [KmdbDatabase.open] to recover from unclean shutdowns.
  ///
  /// Any index found in `syncing` state indicates that [applyDelta] was
  /// interrupted by a crash. The index is transitioned to `stale` so the next
  /// call to [ensureBuilt] triggers a full rebuild.
  Future<void> checkAndTransitionOnOpen() async {
    for (final def in _defs) {
      final state = await _loadState(def.collection, def.field);
      // Populate the status cache so interceptWrite can make decisions without
      // an async meta read on the hot write path.
      _statusCache[_statusCacheKey(def.collection, def.field)] = state.status;
      if (state.status == FtsIndexStatus.syncing) {
        await _saveState(
          state.copyWith(status: FtsIndexStatus.stale),
          def.collection,
          def.field,
        );
      }
    }
  }

  /// Cache key for the status cache.
  static String _statusCacheKey(String namespace, String field) =>
      '$namespace:$field';

  // ── Index queries ─────────────────────────────────────────────────────────

  /// Returns `true` if an FTS index is declared for [namespace]/[field].
  bool hasIndex(String namespace, String field) =>
      _find(namespace, field) != null;

  /// Returns `true` if any FTS index is declared for [namespace].
  bool hasAnyIndex(String namespace) =>
      _defs.any((d) => d.collection == namespace);

  /// Returns all field names that have FTS indexes in [namespace].
  List<String> indexedFieldsFor(String namespace) => _defs
      .where((d) => d.collection == namespace)
      .map((d) => d.field)
      .toList();

  // ── Write interception ───────────────────────────────────────────────────

  /// Adds FTS index writes to [batch] for a document write.
  ///
  /// Call this for every document write before committing the [WriteBatch].
  /// The FTS writes and the document write share the same batch, ensuring
  /// atomicity.
  ///
  /// - [newDoc] is the new document content (`null` for deletes).
  /// - [oldDoc] is the previous document content (`null` for inserts).
  ///
  /// Handles all three cases:
  /// - Insert (`oldDoc == null`, `newDoc != null`) — writes base index entries.
  /// - Update (`oldDoc != null`, `newDoc != null`) — writes overlay entry
  ///   (or promotes to insert if field was not previously indexed).
  /// - Delete (`newDoc == null`) — writes TOMBSTONE overlay, decrements stats.
  @override
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    final matching = _defsFor(namespace);
    if (matching.isEmpty) return;

    for (final def in matching) {
      // Only intercept when the index is active (building, current, or
      // syncing). Undefined and stale indexes are rebuilt lazily by
      // ensureBuilt; intercepting writes before the index exists would create
      // entries that _buildIndex cannot reliably reconcile.
      final status =
          _statusCache[_statusCacheKey(namespace, def.field)] ??
          FtsIndexStatus.undefined;
      if (status == FtsIndexStatus.undefined ||
          status == FtsIndexStatus.stale) {
        continue;
      }
      if (newDoc == null) {
        await _interceptDelete(def, namespace, docKey, batch);
      } else if (oldDoc == null) {
        await _interceptInsert(def, namespace, docKey, newDoc, batch);
      } else {
        await _interceptUpdate(def, namespace, docKey, newDoc, batch);
      }
    }
  }

  Future<void> _interceptInsert(
    FtsIndexDefinition def,
    String namespace,
    String docId,
    Map<String, dynamic> doc,
    WriteBatch batch,
  ) async {
    final fieldValue = _extractFieldValue(doc, def.field);
    if (fieldValue == null) return; // field absent — nothing to index

    final stopWords = def.stopWords
        ? defaultStopwords.listing
        : const <String>{};
    final tokens = preprocess(
      fieldValue,
      createDefaultTokenizer(),
      stopWords: stopWords,
    );
    if (tokens.isEmpty) return;

    final tf = _termFrequencies(tokens);
    final tokenCount = tokens.length;

    final terms = tf.keys.toList();

    // Write base index entries (one per unique term).
    _writeBaseEntries(def, namespace, docId, tf, batch);

    // Write per-document info (token count + terms list for compaction).
    _writeDocInfo(namespace, def.field, docId, tokenCount, terms, batch);

    // Read current corpus stats and increment.
    final stats = await _readCorpusStats(namespace, def.field);
    _writeCorpusStats(
      namespace,
      def.field,
      n: stats.n + 1,
      totalTokens: stats.totalTokens + tokenCount,
      batch: batch,
    );
  }

  Future<void> _interceptUpdate(
    FtsIndexDefinition def,
    String namespace,
    String docId,
    Map<String, dynamic> newDoc,
    WriteBatch batch,
  ) async {
    final oldDocInfo = await _readDocInfo(namespace, def.field, docId);
    final oldTokenCount = oldDocInfo.count;

    if (oldTokenCount == 0) {
      // The field was not previously indexed (field was absent or empty in the
      // old version). Treat the update as a fresh insert.
      await _interceptInsert(def, namespace, docId, newDoc, batch);
      return;
    }

    final newFieldValue = _extractFieldValue(newDoc, def.field);
    final stopWords = def.stopWords
        ? defaultStopwords.listing
        : const <String>{};

    if (newFieldValue == null) {
      // Field was removed in the update — treat as a delete of the FTS entry.
      _writeTombstone(namespace, def.field, docId, batch);
      batch.delete(_docNamespace(namespace, def.field), docId);
      final stats = await _readCorpusStats(namespace, def.field);
      _writeCorpusStats(
        namespace,
        def.field,
        n: (stats.n - 1).clamp(0, _maxInt),
        totalTokens: (stats.totalTokens - oldTokenCount).clamp(0, _maxInt),
        batch: batch,
      );
      return;
    }

    final newTokens = preprocess(
      newFieldValue,
      createDefaultTokenizer(),
      stopWords: stopWords,
    );
    final newTf = _termFrequencies(newTokens);
    final newTokenCount = newTokens.length;

    // Write overlay entry with current term frequencies. This supersedes the
    // stale base entries during queries until compaction reconciles them.
    _writeOverlayEntry(namespace, def.field, docId, newTf, batch);

    // Update doc info with the new token count but KEEP the old terms list.
    // Compaction uses the old terms to enumerate which base namespaces
    // (`$$fts:{ns}:{field}:{hexTerm}`) need stale entries removed. After
    // compaction rewrites the base entries, it updates the terms list.
    _writeDocInfo(
      namespace,
      def.field,
      docId,
      newTokenCount,
      oldDocInfo.terms, // preserve old terms until compact updates them
      batch,
    );

    // Adjust corpus stats by the token count delta.
    final stats = await _readCorpusStats(namespace, def.field);
    final delta = newTokenCount - oldTokenCount;
    _writeCorpusStats(
      namespace,
      def.field,
      n: stats.n,
      totalTokens: (stats.totalTokens + delta).clamp(0, _maxInt),
      batch: batch,
    );
  }

  Future<void> _interceptDelete(
    FtsIndexDefinition def,
    String namespace,
    String docId,
    WriteBatch batch,
  ) async {
    final oldTokenCount = await _readDocTokenCount(namespace, def.field, docId);
    if (oldTokenCount == 0) return; // never indexed — nothing to do

    // Write TOMBSTONE to overlay so the query path excludes this document.
    _writeTombstone(namespace, def.field, docId, batch);

    // Delete the per-document token count.
    batch.delete(_docNamespace(namespace, def.field), docId);

    // Decrement corpus stats.
    final stats = await _readCorpusStats(namespace, def.field);
    _writeCorpusStats(
      namespace,
      def.field,
      n: (stats.n - 1).clamp(0, _maxInt),
      totalTokens: (stats.totalTokens - oldTokenCount).clamp(0, _maxInt),
      batch: batch,
    );
  }

  // ── Initial build ─────────────────────────────────────────────────────────

  /// Ensures the FTS index for [namespace]/[field] is built.
  ///
  /// When the index is `undefined` or `stale`, performs a full namespace scan
  /// to build the index from existing documents. Transitions status to
  /// `current` on success.
  ///
  /// When the index is already `building`, `current`, or `syncing`, returns
  /// immediately.
  Future<void> ensureBuilt(String namespace, String field) async {
    final def = _find(namespace, field);
    if (def == null) return;

    final state = await _loadState(namespace, field);
    switch (state.status) {
      case FtsIndexStatus.undefined:
      case FtsIndexStatus.stale:
        await _buildIndex(def);
      case FtsIndexStatus.building:
      case FtsIndexStatus.current:
      // Syncing state is set by applyDelta; reaching ensureBuilt concurrently
      // during an active sync delta is a benign no-op (nothing to do).
      case FtsIndexStatus.syncing: // coverage:ignore-line
        break; // Nothing to do.
    }
  }

  Future<void> _buildIndex(FtsIndexDefinition def) async {
    final ns = def.collection;
    final field = def.field;

    // 1. Mark as building. Write interception is active during the scan
    //    (activeDefinitionsFor includes `building` indexes).
    await _saveState(
      FtsIndexState(
        namespace: ns,
        field: field,
        status: FtsIndexStatus.building,
      ),
      ns,
      field,
    );

    // 2. Initialise corpus stats to zero before the scan so that write
    //    interception during the scan has a valid starting point.
    final initBatch = WriteBatch();
    _writeCorpusStats(ns, field, n: 0, totalTokens: 0, batch: initBatch);
    await _store.writeBatchInternal(initBatch);

    // 3. Scan the namespace and write base index entries.
    //
    //    For each document, check for a pending overlay:
    //    - Tombstone overlay → document was deleted; skip entirely.
    //    - Map overlay → use overlay terms as the authoritative content,
    //      remove stale base entries for old terms, and clear the overlay.
    //      This performs an inline compact for pre-existing overlay entries,
    //      ensuring buildIndex always produces a consistent base index.
    //    - No overlay → read and index the current document content normally.
    final stopWords = def.stopWords
        ? defaultStopwords.listing
        : const <String>{};
    const batchSize = 200;
    var writeBatch = WriteBatch();
    var batchCount = 0;

    await for (final entry in _store.scan(ns)) {
      Map<String, dynamic> doc;
      try {
        doc = await ValueCodec.decode(entry.value, encryption: _encryption);
      } catch (_) {
        continue;
      }

      final docId = entry.key;

      // Check for a pending overlay for this document.
      final overlayBytes = await _store.get(
        _overlayNamespace(ns, field),
        docId,
      );
      final overlay = overlayBytes != null
          ? _decodeOverlayBytes(overlayBytes)
          : null;

      if (overlay is String && overlay == kFtsTombstone) {
        // Document was deleted — skip; the overlay and doc info will remain
        // as stale entries that a subsequent compact() will clean up.
        continue;
      }

      final Map<String, int> tf;
      final int tokenCount;

      if (overlay is Map) {
        // Use overlay as the authoritative term→tf map. This supersedes any
        // stale content we might have read from the document store.
        final overlayMap = overlay.map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        );

        // Remove stale base entries for terms that are no longer present.
        final oldDocInfo = await _readDocInfo(ns, field, docId);
        for (final oldTerm in oldDocInfo.terms) {
          if (!overlayMap.containsKey(oldTerm)) {
            writeBatch.delete(_termNamespace(ns, field, oldTerm), docId);
          }
        }

        // Clear the overlay — the base now reflects current document content.
        writeBatch.delete(_overlayNamespace(ns, field), docId);

        tf = overlayMap;
        tokenCount = tf.values.fold(0, (a, b) => a + b);
      } else {
        // No overlay — read and index the current document content.
        final fieldValue = _extractFieldValue(doc, field);
        if (fieldValue == null) continue;

        final tokens = preprocess(
          fieldValue,
          createDefaultTokenizer(),
          stopWords: stopWords,
        );
        if (tokens.isEmpty) continue;

        tf = _termFrequencies(tokens);
        tokenCount = tokens.length;
      }

      _writeBaseEntries(def, ns, docId, tf, writeBatch);
      _writeDocInfo(ns, field, docId, tokenCount, tf.keys.toList(), writeBatch);
      batchCount++;

      if (batchCount >= batchSize) {
        await _store.writeBatchInternal(writeBatch);
        writeBatch = WriteBatch();
        batchCount = 0;
      }
    }

    if (!writeBatch.isEmpty) {
      await _store.writeBatchInternal(writeBatch);
    }

    // 4. Re-compute corpus stats from the doc namespace. This correctly
    //    accounts for any documents indexed during the scan via write
    //    interception (e.g. inserts that arrived while the scan was in
    //    progress).
    var finalDocCount = 0;
    var finalTotalTokens = 0;
    await for (final docEntry in _store.scan(_docNamespace(ns, field))) {
      finalDocCount++;
      // Doc namespace values are now CBOR maps {n, t}; extract the count.
      final info = _readDocInfoFromBytes(docEntry.value);
      finalTotalTokens += info.count;
    }

    final statsBatch = WriteBatch();
    _writeCorpusStats(
      ns,
      field,
      n: finalDocCount,
      totalTokens: finalTotalTokens,
      batch: statsBatch,
    );
    await _store.writeBatchInternal(statsBatch);

    // 5. Mark current.
    final now = DateTime.now().toUtc().toIso8601String();
    await _saveState(
      FtsIndexState(
        namespace: ns,
        field: field,
        status: FtsIndexStatus.current,
        builtAt: now,
      ),
      ns,
      field,
    );
  }

  // ── BM25 search ──────────────────────────────────────────────────────────

  /// Executes a BM25 search over [fields] in [namespace].
  ///
  /// Returns a [SearchResult] with ranked hits in descending score order.
  ///
  /// An empty [query] or a query whose every term is a stop word returns an
  /// empty result without error. Fields that have no FTS index are listed in
  /// [SearchMetadata.skipped].
  ///
  /// [candidateIds] restricts scoring to a pre-filtered document set. When
  /// `null`, all documents in the inverted index are scored.
  ///
  /// [fetchDoc] is called for each hit to retrieve the decoded document. Use
  /// the collection's cache-aware [KmdbCollection.get] as the implementation.
  ///
  /// ## Example
  ///
  /// ```dart
  /// final result = await ftsManager.search<Article>(
  ///   namespace: 'articles',
  ///   query: 'full text search',
  ///   fields: ['title', 'body'],
  ///   fetchDoc: (id) => articleCollection.get(id),
  ///   limit: 10,
  /// );
  /// ```
  Future<SearchResult<T>> search<T>({
    required String namespace,
    required String query,
    required List<String> fields,
    required Future<T?> Function(String docId) fetchDoc,
    Set<String>? candidateIds,
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

    // Pre-process the query string. Use stop-word settings from the first
    // matched definition (all defs for the same ns share stop-word config).
    final firstDef = _find(namespace, searched.first)!;
    final stopWords = firstDef.stopWords
        ? defaultStopwords.listing
        : const <String>{};
    final queryTerms = preprocess(
      query,
      createDefaultTokenizer(),
      stopWords: stopWords,
    ).toSet().toList();

    if (queryTerms.isEmpty) {
      return _emptyResult(query: query, searched: searched, skipped: skipped);
    }

    // Score each document per field. Structure: docId → {field: score}.
    final docFieldScores = <String, Map<String, double>>{};

    for (final field in searched) {
      final def = _find(namespace, field)!;
      final fieldScores = await _scoreField(
        def: def,
        namespace: namespace,
        field: field,
        queryTerms: queryTerms,
        candidateIds: candidateIds,
      );

      for (final e in fieldScores.entries) {
        (docFieldScores[e.key] ??= {})[field] = e.value;
      }
    }

    if (docFieldScores.isEmpty) {
      return _emptyResult(query: query, searched: searched, skipped: skipped);
    }

    // Overall document score: max across all searched fields (spec §21).
    final docScores =
        docFieldScores.entries
            .map(
              (e) =>
                  (docId: e.key, score: e.value.values.fold(0.0, _maxDouble)),
            )
            .toList()
          ..sort((a, b) {
            final cmp = b.score.compareTo(a.score);
            return cmp != 0
                ? cmp
                : a.docId.compareTo(b.docId); // stable tiebreak
          });

    final total = docScores.length;
    final page = docScores.skip(offset).take(limit);

    // Fetch documents and build ranked hits.
    final hits = <SearchHit<T>>[];
    var rank = offset + 1;

    for (final scored in page) {
      final doc = await fetchDoc(scored.docId);
      if (doc == null) {
        rank++;
        continue; // document may have been deleted since the index was read
      }

      // Build fieldScores with ':bm25' suffix convention (hybrid mode adds
      // ':cosine' entries alongside these).
      final fieldScores = <String, double>{};
      for (final fe in (docFieldScores[scored.docId] ?? {}).entries) {
        fieldScores['${fe.key}:bm25'] = fe.value;
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

  /// Scores documents for [field] against [queryTerms] using BM25.
  ///
  /// Returns a map of `{docId: bm25Score}` for documents that match at least
  /// one query term. Documents excluded by the overlay (tombstones or term
  /// removal) are not included.
  Future<Map<String, double>> _scoreField({
    required FtsIndexDefinition def,
    required String namespace,
    required String field,
    required List<String> queryTerms,
    Set<String>? candidateIds,
  }) async {
    final k1 = def.k1;
    final b = def.b;

    final corpus = await _readCorpusStats(namespace, field);
    final n = corpus.n;
    if (n == 0) return {};

    final avgdl = corpus.totalTokens / n;

    // Phase 1: collect per-document per-term tf, respecting the overlay.
    // Structure: docId → {term: tf}
    final docTermTf = <String, Map<String, int>>{};
    // Document frequency per query term (approximate from base scan).
    final termDf = <String, int>{};

    for (final term in queryTerms) {
      // Scan the per-term namespace: `$$fts:{ns}:{field}:{hexTerm}`.
      // All entries in this namespace have docId as the key (32-char UUID),
      // so no startKey/endKey constraints are needed.
      await for (final entry in _store.scan(
        _termNamespace(namespace, field, term),
      )) {
        final docId = entry.key;

        if (candidateIds != null && !candidateIds.contains(docId)) continue;

        // Check overlay for this document.
        final overlay = await _readOverlay(namespace, field, docId);

        final int effectiveTf;

        if (overlay == null) {
          // No overlay — document not updated since last base write.
          effectiveTf = _decodeCborInt(entry.value);
        } else if (overlay is String && overlay == kFtsTombstone) {
          // Tombstone — document deleted; skip.
          continue;
        } else if (overlay is Map) {
          // Updated document — use overlay tf for this term.
          final rawTf = overlay[term];
          if (rawTf == null) continue; // term removed in update
          effectiveTf = (rawTf as num).toInt();
        } else {
          continue; // corrupt overlay
        }

        if (effectiveTf <= 0) continue;
        (docTermTf[docId] ??= {})[term] = effectiveTf;
        termDf[term] = (termDf[term] ?? 0) + 1;
      }
    }

    if (docTermTf.isEmpty) return {};

    // Phase 2: BM25 scoring.
    final scores = <String, double>{};

    for (final docEntry in docTermTf.entries) {
      final docId = docEntry.key;
      final termTf = docEntry.value;
      final docLen = await _readDocTokenCount(namespace, field, docId);

      var score = 0.0;
      for (final termEntry in termTf.entries) {
        final df = termDf[termEntry.key] ?? 1;
        score += _bm25Score(
          tf: termEntry.value,
          df: df,
          n: n,
          docLen: docLen,
          avgdl: avgdl,
          k1: k1,
          b: b,
        );
      }
      if (score > 0) scores[docId] = score;
    }

    return scores;
  }

  // ── Compaction ────────────────────────────────────────────────────────────

  /// Reconciles the overlay with the base index for [namespace]/[field].
  ///
  /// Processes each document in the overlay:
  /// - **Tombstone** — removes all base entries and the overlay entry.
  /// - **Overlay map** — removes stale base entries (terms no longer in the
  ///   document), writes current base entries from the overlay, removes the
  ///   overlay entry.
  ///
  /// Each document is processed in its own [WriteBatch]. This method is
  /// provided for future use and is not called automatically in Phase 2.
  Future<void> compact(String namespace, String field) async {
    final overlayNs = _overlayNamespace(namespace, field);
    final docNs = _docNamespace(namespace, field);

    // Collect all overlay entries first (avoids scan-while-mutating).
    final overlayEntries = <({String docId, Uint8List value})>[];
    await for (final entry in _store.scan(overlayNs)) {
      overlayEntries.add((docId: entry.key, value: entry.value));
    }

    for (final overlayEntry in overlayEntries) {
      final docId = overlayEntry.docId;
      final decoded = _decodeOverlayBytes(overlayEntry.value);
      final batch = WriteBatch();

      if (decoded is String && decoded == kFtsTombstone) {
        // Remove base entries for this document by looking up the stored terms
        // from the doc info namespace. Base entries use namespace-per-term:
        // each term has its own namespace `$$fts:{ns}:{field}:{hexTerm}`.
        final docInfo = await _readDocInfo(namespace, field, docId);
        for (final term in docInfo.terms) {
          batch.delete(_termNamespace(namespace, field, term), docId);
        }
        batch.delete(overlayNs, docId);
        batch.delete(docNs, docId);
      } else if (decoded is Map) {
        // Current terms from the overlay map.
        final currentTerms = decoded.map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        );

        // Read the old terms list to find stale base entries.
        final oldDocInfo = await _readDocInfo(namespace, field, docId);
        for (final oldTerm in oldDocInfo.terms) {
          if (!currentTerms.containsKey(oldTerm)) {
            // Term was removed in the update — delete stale base entry.
            batch.delete(_termNamespace(namespace, field, oldTerm), docId);
          }
        }

        // Write current base entries from the overlay, replacing stale ones.
        for (final t in currentTerms.entries) {
          batch.put(
            _termNamespace(namespace, field, t.key),
            docId,
            _encodeCborInt(t.value),
          );
        }

        // Update doc info to reflect the current terms (post-compaction).
        _writeDocInfo(
          namespace,
          field,
          docId,
          currentTerms.values.fold(0, (a, b) => a + b),
          currentTerms.keys.toList(),
          batch,
        );

        // Remove the overlay entry; the base is now current.
        batch.delete(overlayNs, docId);
      }

      if (!batch.isEmpty) {
        await _store.writeBatchInternal(batch);
      }
    }
  }

  // ── Post-sync delta application ───────────────────────────────────────────

  /// Applies a post-sync [delta] to all FTS indexes in [namespace].
  ///
  /// Transitions the index to `syncing` before processing, then back to
  /// `current` on success. If the process is killed during [applyDelta], the
  /// `syncing` state is detected on next [checkAndTransitionOnOpen] and the
  /// index is marked `stale` for a full rebuild.
  ///
  /// Searches issued while [applyDelta] is in progress are served from the
  /// pre-sync index (the `syncing` → `current` transition happens at the end).
  Future<void> applyDelta(String namespace, SyncDelta delta) async {
    final matching = _defsFor(namespace);
    if (matching.isEmpty) return;

    for (final def in matching) {
      final state = await _loadState(namespace, def.field);
      // Only apply delta to fully built indexes; undefined/stale are rebuilt lazily.
      if (state.status != FtsIndexStatus.current) continue;

      // Transition to syncing — queries serve from the pre-sync base.
      await _saveState(
        state.copyWith(status: FtsIndexStatus.syncing),
        namespace,
        def.field,
      );

      try {
        for (final change in delta.changes) {
          await _applyDeltaChange(def, namespace, change);
        }

        // All changes applied — transition back to current.
        await _saveState(
          state.copyWith(
            status: FtsIndexStatus.current,
            builtAt: DateTime.now().toUtc().toIso8601String(),
          ),
          namespace,
          def.field,
        );
      } catch (_) {
        // Leave index in `syncing`; crash recovery transitions to `stale` on
        // next open, triggering a full rebuild.
        rethrow;
      }
    }
  }

  Future<void> _applyDeltaChange(
    FtsIndexDefinition def,
    String namespace,
    DeltaEntry change,
  ) async {
    final docId = change.docId;
    final batch = WriteBatch();

    switch (change.changeType) {
      case DeltaChangeType.added:
        final bytes = await _store.get(namespace, docId);
        if (bytes == null) return; // deleted again before delta was applied
        Map<String, dynamic> doc;
        try {
          doc = await ValueCodec.decode(bytes, encryption: _encryption);
        } catch (_) {
          return;
        }
        await _interceptInsert(def, namespace, docId, doc, batch);

      case DeltaChangeType.updated:
        final bytes = await _store.get(namespace, docId);
        if (bytes == null) return;
        Map<String, dynamic> doc;
        try {
          doc = await ValueCodec.decode(bytes, encryption: _encryption);
        } catch (_) {
          return;
        }
        // _interceptUpdate reads oldTokenCount internally from the store.
        await _interceptUpdate(def, namespace, docId, doc, batch);

      case DeltaChangeType.deleted:
        await _interceptDelete(def, namespace, docId, batch);
    }

    if (!batch.isEmpty) {
      await _store.writeBatchInternal(batch);
    }
  }

  // ── BM25 formula ─────────────────────────────────────────────────────────

  /// Computes the BM25 relevance score for a single term in a document.
  ///
  /// Formula (Okapi BM25):
  /// ```
  /// IDF(t) = ln((N − df(t) + 0.5) / (df(t) + 0.5) + 1)
  /// TF_norm = tf × (k1 + 1) / (tf + k1 × (1 − b + b × |d| / avgdl))
  /// BM25(t, d) = IDF(t) × TF_norm
  /// ```
  static double _bm25Score({
    required int tf,
    required int df,
    required int n,
    required int docLen,
    required double avgdl,
    required double k1,
    required double b,
  }) {
    if (df <= 0 || n <= 0 || docLen <= 0 || avgdl <= 0) return 0.0;
    final idf = log((n - df + 0.5) / (df + 0.5) + 1);
    if (idf <= 0) return 0.0;
    final tfNorm = tf * (k1 + 1) / (tf + k1 * (1 - b + b * docLen / avgdl));
    return idf * tfNorm;
  }

  // ── Namespace helpers ─────────────────────────────────────────────────────

  /// Per-term namespace: `$$fts:{ns}:{field}:{hexTerm}`.
  ///
  /// The `$$` prefix marks this as a local-only namespace — its contents are
  /// never uploaded to the sync folder. Each device rebuilds its FTS index
  /// independently from document data.
  ///
  /// The term is UTF-8 encoded and hex-stringified (same approach as
  /// `IndexWriter` for field values). Within this namespace, the key is the
  /// 32-character UUIDv7 docId and the value is a CBOR-encoded term frequency.
  ///
  /// Using a separate namespace per term keeps all keys as 32-char hex UUIDs,
  /// satisfying the KvStore key constraint.
  static String _termNamespace(String ns, String field, String term) {
    final hexTerm = _termToHex(term);
    return r'$$fts:'
        '$ns:$field:$hexTerm';
  }

  /// Encodes [term] as a lowercase hex string of its UTF-8 bytes.
  static String _termToHex(String term) {
    final bytes = utf8.encode(term);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Overlay namespace: `$$fts:overlay:{ns}:{field}`.
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// Keys are document IDs (32-char UUID). Values are CBOR-encoded term→tf
  /// maps (updates) or the [kFtsTombstone] string (deletes).
  static String _overlayNamespace(String ns, String field) =>
      r'$$fts:overlay:'
      '$ns:$field';

  /// Per-document info namespace: `$$fts:doc:{ns}:{field}`.
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// Keys are document IDs (32-char UUID). Values are CBOR maps:
  /// `{"n": tokenCount, "t": ["term1", "term2", ...]}`.
  /// The terms list enables [compact] to enumerate base namespaces for cleanup.
  static String _docNamespace(String ns, String field) =>
      r'$$fts:doc:'
      '$ns:$field';

  /// Corpus statistics namespace: `$$fts:corpus:{ns}:{field}`.
  ///
  /// The `$$` prefix marks this namespace as local-only (never synced).
  /// Contains a single entry keyed by [_corpusKey] with the CBOR-encoded
  /// corpus statistics map `{n, totalTokens}`.
  static String _corpusNamespace(String ns, String field) =>
      r'$$fts:corpus:'
      '$ns:$field';

  /// Fixed 32-char hex key within [_corpusNamespace] for the corpus stats entry.
  ///
  /// UUIDv7 keys begin with a 48-bit millisecond timestamp in the high bits,
  /// so they never start with all-zero bytes. This sentinel is therefore safe
  /// to use as a fixed, non-colliding key for the single corpus stats record.
  static const String _corpusKey = '01900000000070009000000000000000';

  // ── Write helpers ─────────────────────────────────────────────────────────

  /// Writes one base entry per unique term into its own term namespace.
  ///
  /// Each base entry: namespace = `$$fts:{ns}:{field}:{hexTerm}`, key = docId.
  void _writeBaseEntries(
    FtsIndexDefinition def,
    String namespace,
    String docId,
    Map<String, int> tf,
    WriteBatch batch,
  ) {
    for (final entry in tf.entries) {
      batch.put(
        _termNamespace(namespace, def.field, entry.key),
        docId,
        _encodeCborInt(entry.value),
      );
    }
  }

  /// Writes the per-document info: token count and terms list.
  ///
  /// The terms list is required by [compact] to enumerate which term
  /// namespaces must be cleaned up when processing tombstone overlays.
  void _writeDocInfo(
    String namespace,
    String field,
    String docId,
    int count,
    List<String> terms,
    WriteBatch batch,
  ) {
    final encoded = Uint8List.fromList(
      cbor.encode(
        CborMap({
          CborString('n'): CborSmallInt(count),
          CborString('t'): CborList(terms.map(CborString.new).toList()),
        }),
      ),
    );
    batch.put(_docNamespace(namespace, field), docId, encoded);
  }

  void _writeCorpusStats(
    String namespace,
    String field, {
    required int n,
    required int totalTokens,
    required WriteBatch batch,
  }) {
    final encoded = Uint8List.fromList(
      cbor.encode(
        CborMap({
          CborString('n'): CborSmallInt(n),
          CborString('totalTokens'): CborSmallInt(totalTokens),
        }),
      ),
    );
    batch.put(_corpusNamespace(namespace, field), _corpusKey, encoded);
  }

  void _writeOverlayEntry(
    String namespace,
    String field,
    String docId,
    Map<String, int> tf,
    WriteBatch batch,
  ) {
    final encoded = Uint8List.fromList(
      cbor.encode(
        CborMap(tf.map((k, v) => MapEntry(CborString(k), CborSmallInt(v)))),
      ),
    );
    batch.put(_overlayNamespace(namespace, field), docId, encoded);
  }

  void _writeTombstone(
    String namespace,
    String field,
    String docId,
    WriteBatch batch,
  ) {
    batch.put(
      _overlayNamespace(namespace, field),
      docId,
      Uint8List.fromList(cbor.encode(CborString(kFtsTombstone))),
    );
  }

  // ── Read helpers ──────────────────────────────────────────────────────────

  Future<({int n, int totalTokens})> _readCorpusStats(
    String namespace,
    String field,
  ) async {
    final bytes = await _store.get(
      _corpusNamespace(namespace, field),
      _corpusKey,
    );
    if (bytes == null || bytes.isEmpty) return (n: 0, totalTokens: 0);
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) return (n: 0, totalTokens: 0);
      final map = decoded.toObject() as Map<dynamic, dynamic>;
      return (
        n: (map['n'] as num?)?.toInt() ?? 0,
        totalTokens: (map['totalTokens'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (n: 0, totalTokens: 0);
    }
  }

  /// Reads the token count for [docId] from the doc info namespace.
  ///
  /// Returns 0 if the document was never indexed (field absent or empty).
  Future<int> _readDocTokenCount(
    String namespace,
    String field,
    String docId,
  ) async {
    final info = await _readDocInfo(namespace, field, docId);
    return info.count;
  }

  /// Reads the full doc info (token count + terms list) for [docId].
  ///
  /// Returns `(count: 0, terms: [])` if the document was never indexed.
  Future<({int count, List<String> terms})> _readDocInfo(
    String namespace,
    String field,
    String docId,
  ) async {
    final bytes = await _store.get(_docNamespace(namespace, field), docId);
    if (bytes == null || bytes.isEmpty) {
      return (count: 0, terms: const <String>[]);
    }
    return _readDocInfoFromBytes(bytes);
  }

  /// Decodes doc info from raw [bytes] (synchronous helper for batch scanning).
  static ({int count, List<String> terms}) _readDocInfoFromBytes(
    Uint8List bytes,
  ) {
    if (bytes.isEmpty) return (count: 0, terms: const <String>[]);
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is CborMap) {
        final map = decoded.toObject() as Map<dynamic, dynamic>;
        final count = (map['n'] as num?)?.toInt() ?? 0;
        final rawTerms = map['t'];
        final terms = rawTerms is List
            ? rawTerms.whereType<String>().toList()
            : const <String>[];
        return (count: count, terms: terms);
      }
      // Fallback: legacy format stored token count as a plain integer.
      return (count: _decodeCborInt(bytes), terms: const <String>[]);
    } catch (_) {
      return (count: 0, terms: const <String>[]);
    }
  }

  /// Reads the overlay for [docId]. Returns:
  /// - `null` if no overlay entry exists.
  /// - A [String] equal to [kFtsTombstone] for a deleted document.
  /// - A `Map` of term→tf for an updated document.
  Future<Object?> _readOverlay(
    String namespace,
    String field,
    String docId,
  ) async {
    final bytes = await _store.get(_overlayNamespace(namespace, field), docId);
    if (bytes == null || bytes.isEmpty) return null;
    return _decodeOverlayBytes(bytes);
  }

  static Object? _decodeOverlayBytes(Uint8List bytes) {
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is CborString) return decoded.toString();
      if (decoded is CborMap) return decoded.toObject();
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── State persistence ─────────────────────────────────────────────────────

  Future<FtsIndexState> _loadState(String namespace, String field) async {
    final bytes = await _store.meta.getRawByName(
      FtsIndexState.metaKey(namespace, field),
    );
    return FtsIndexState.fromBytes(namespace, field, bytes);
  }

  Future<void> _saveState(
    FtsIndexState state,
    String namespace,
    String field,
  ) async {
    _statusCache[_statusCacheKey(namespace, field)] = state.status;
    await _store.meta.putRawByName(
      FtsIndexState.metaKey(namespace, field),
      state.toBytes(),
    );
  }

  // ── CBOR helpers ──────────────────────────────────────────────────────────

  static Uint8List _encodeCborInt(int value) =>
      Uint8List.fromList(cbor.encode(CborSmallInt(value)));

  static int _decodeCborInt(Uint8List bytes) {
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is CborSmallInt) return decoded.toInt();
      if (decoded is CborInt) return decoded.toBigInt().toInt();
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ── Misc helpers ──────────────────────────────────────────────────────────

  List<FtsIndexDefinition> _defsFor(String namespace) =>
      _defs.where((d) => d.collection == namespace).toList();

  FtsIndexDefinition? _find(String namespace, String field) {
    for (final def in _defs) {
      if (def.collection == namespace && def.field == field) return def;
    }
    return null;
  }

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

  /// Computes term frequencies from a list of tokens.
  ///
  /// Returns a map from each unique token to its occurrence count.
  static Map<String, int> _termFrequencies(List<String> tokens) {
    final tf = <String, int>{};
    for (final token in tokens) {
      tf[token] = (tf[token] ?? 0) + 1;
    }
    return tf;
  }

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

  static double _maxDouble(double a, double b) => a > b ? a : b;

  /// Upper bound for corpus stat integers (prevents overflow in clamp).
  static const int _maxInt = 0x7fffffffffffffff;

  // ── Test / inspection helpers ─────────────────────────────────────────────

  /// Returns the current [FtsIndexState] for [namespace]/[field], or `null`
  /// if no index is defined for that pair.
  ///
  /// Useful for inspecting index status in tests and diagnostic tooling.
  Future<FtsIndexState?> stateFor(String namespace, String field) async {
    if (_find(namespace, field) == null) return null;
    return _loadState(namespace, field);
  }

  /// Directly overwrites the persisted [FtsIndexStatus] for [namespace]/[field].
  ///
  /// **For testing only.** Allows tests to simulate crash scenarios by forcing
  /// a specific status (e.g. `FtsIndexStatus.syncing`) without going through
  /// the full [applyDelta] code path.
  @visibleForTesting
  Future<void> forceStateForTesting(
    String namespace,
    String field,
    FtsIndexStatus status,
  ) async {
    final current = await _loadState(namespace, field);
    await _saveState(current.copyWith(status: status), namespace, field);
  }
}
