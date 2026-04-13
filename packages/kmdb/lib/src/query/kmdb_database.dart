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

import '../cache/cache_layer.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/kv_store_impl.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../search/embedding_model.dart';
import '../search/fts_index_definition.dart';
import '../search/lexical/fts_manager.dart';
import '../search/vec_index_definition.dart';
import 'exceptions.dart';
import 'index/index_definition.dart';
import 'index/index_manager.dart';
import 'kmdb_codec.dart';
import 'kmdb_collection.dart';

/// The top-level KMDB database handle.
///
/// [KmdbDatabase] is the entry point for all Query Layer operations. It opens
/// the underlying [KvStore], wraps it with a [CacheLayer], registers index
/// definitions, and vends typed [KmdbCollection] instances.
///
/// ## Opening
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/database',
///   adapter: MemoryStorageAdapter(), // omit to use the platform default
///   indexes: [
///     IndexDefinition('contacts', 'address.city'),
///     IndexDefinition('contacts', 'tags[]'),
///   ],
///   onIndexReady: (ns, path) {
///     print('Index $ns.$path is ready');
///   },
/// );
/// ```
///
/// ## Text Search
///
/// Text search indexes are configured at open time:
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/database',
///   adapter: MemoryStorageAdapter(),
///   ftsIndexes: [FtsIndexDefinition(collection: 'docs', field: 'body')],
///   vecIndexes: [VecIndexDefinition(collection: 'docs', field: 'body')],
///   embeddingModel: await OnnxEmbeddingModel.load(), // required for vecIndexes
/// );
/// ```
///
/// ## Collections
///
/// ```dart
/// final tasks = db.collection(name: 'tasks', codec: TaskCodec());
/// await tasks.put(Task(id: key, title: 'Buy milk'));
/// final task = await tasks.get(key);
/// ```
///
/// ## Lifecycle
///
/// Call [onResume] when the app returns to the foreground (mobile/web).
/// Call [close] before discarding the instance.
final class KmdbDatabase {
  KmdbDatabase._({
    required CacheLayer cache,
    required KvStoreImpl store,
    required IndexManager indexManager,
    required FtsManager? ftsManager,
    required List<FtsIndexDefinition> ftsIndexes,
    required List<VecIndexDefinition> vecIndexes,
    required EmbeddingModel? embeddingModel,
  }) : _cache = cache,
       _store = store,
       _indexManager = indexManager,
       _ftsManager = ftsManager,
       _ftsIndexes = ftsIndexes,
       _vecIndexes = vecIndexes,
       _embeddingModel = embeddingModel;

  final CacheLayer _cache;
  final KvStoreImpl _store;
  final IndexManager _indexManager;
  final FtsManager? _ftsManager;
  final List<FtsIndexDefinition> _ftsIndexes;
  final List<VecIndexDefinition> _vecIndexes;
  final EmbeddingModel? _embeddingModel;

  // ── Factory ─────────────────────────────────────────────────────────────────

  /// Opens the database at [path] and performs crash recovery.
  ///
  /// [adapter] is the [StorageAdapter] to use. On native platforms the default
  /// adapter uses `dart:io`; for tests pass a [MemoryStorageAdapter].
  ///
  /// [indexes] declares secondary indexes. No index entries are written at open
  /// time — each index is built lazily on first query (spec §16).
  ///
  /// [onIndexReady] is called when an index transitions from `building` to
  /// `current`. Use this to re-run queries that fell back to a full scan.
  ///
  /// [onIndexRebuildRequired] is called when the dirty-open flag indicates an
  /// index build was interrupted by an unclean shutdown. The application
  /// decides when to trigger a rebuild.
  ///
  /// [ftsIndexes] declares full-text search (BM25) indexes. These are built
  /// lazily by `FtsManager` (implemented in plan 2). Defaults to empty.
  ///
  /// [vecIndexes] declares vector (semantic) search indexes. These are built
  /// lazily by `VecManager` (implemented in plan 3). Requires [embeddingModel]
  /// to be non-null when this list is non-empty. Defaults to empty.
  ///
  /// [embeddingModel] is the text-to-vector embedding model used by
  /// `VecManager`. Must be supplied when [vecIndexes] is non-empty.
  /// Throws [ArgumentError] if [vecIndexes] is non-empty and this is null.
  ///
  /// [onSearchIndexReady] is called when all text search indexes (FTS and
  /// vector) have transitioned out of `syncing` or `building` state to
  /// `current`. Intended for Flutter apps to re-enable search UI after a sync
  /// delta has been fully applied.
  ///
  /// [deviceId] must be an 8-character lowercase hex string. Defaults to
  /// `'00000000'` for tests; production code should supply a stable per-device
  /// identifier via `DeviceId.load`.
  ///
  /// Throws [LockException] if another process holds the database lock.
  static Future<KmdbDatabase> open({
    required String path,
    required StorageAdapter adapter,
    List<IndexDefinition> indexes = const [],
    void Function(String namespace, String path)? onIndexReady,
    Future<void> Function(List<IndexRebuildEvent> events)?
    onIndexRebuildRequired,
    KvStoreConfig config = const KvStoreConfig(),
    String deviceId = '00000000',
    List<FtsIndexDefinition> ftsIndexes = const [],
    List<VecIndexDefinition> vecIndexes = const [],
    EmbeddingModel? embeddingModel,
    void Function()? onSearchIndexReady,
  }) async {
    // Validate that an embedding model is provided when vector indexes are
    // requested. We check this before any I/O so the error is immediate.
    if (vecIndexes.isNotEmpty && embeddingModel == null) {
      throw ArgumentError(
        'embeddingModel is required when vecIndexes is non-empty',
      );
    }

    final (store, openResult) = await KvStoreImpl.open(
      path,
      adapter,
      config: config,
      deviceId: deviceId,
    );
    final cache = CacheLayer(store: store);

    final indexManager = IndexManager(
      store: store,
      definitions: indexes,
      onIndexReady: onIndexReady,
    );

    // Report any indexes whose build was interrupted by an unclean shutdown.
    if (openResult.hadUnclosedSession && onIndexRebuildRequired != null) {
      final interrupted = await indexManager.checkInterruptedBuilds();
      if (interrupted.isNotEmpty) {
        final events = interrupted
            .map((e) => IndexRebuildEvent(namespace: e.namespace, path: e.path))
            .toList();
        await onIndexRebuildRequired(events);
      }
    }

    // Initialise FTS manager if any FTS indexes are configured.
    final ftsManager = ftsIndexes.isNotEmpty
        ? FtsManager(store, ftsIndexes)
        : null;

    // Recover from any unclean shutdown during a delta sync (transitions
    // any index left in `syncing` state to `stale`).
    await ftsManager?.checkAndTransitionOnOpen();

    return KmdbDatabase._(
      cache: cache,
      store: store,
      indexManager: indexManager,
      ftsManager: ftsManager,
      ftsIndexes: ftsIndexes,
      vecIndexes: vecIndexes,
      embeddingModel: embeddingModel,
    );
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns a typed collection for [name] using [codec] for encode/decode.
  ///
  /// Multiple calls with the same [name] return independent [KmdbCollection]
  /// instances that share the same underlying store. The [name] is used as the
  /// storage namespace identifier in the LSM engine.
  KmdbCollection<T> collection<T>({
    required String name,
    required KmdbCodec<T> codec,
  }) => KmdbCollection<T>(namespace: name, codec: codec, database: this);

  /// Checks all tracked namespaces for stale cache entries.
  ///
  /// Call this when the app returns to the foreground (mobile/web) to evict
  /// entries that may have become stale during a background sync. On desktop
  /// this is a no-op because the process stays alive and receives write events
  /// continuously.
  ///
  /// In Flutter, wire this into `WidgetsBindingObserver.didChangeAppLifecycleState`:
  /// ```dart
  /// if (state == AppLifecycleState.resumed) await db.onResume();
  /// ```
  Future<void> onResume() => _cache.onResume();

  /// Closes the database, optionally flushing the active memtable and
  /// releasing the lock.
  ///
  /// After [close] returns, this instance must not be used again.
  Future<void> close({bool flush = true}) => _cache.close(flush: flush);

  // ── Text search ────────────────────────────────────────────────────────────

  /// The full-text search (FTS) manager.
  ///
  /// Non-null when at least one [FtsIndexDefinition] was supplied to [open].
  /// Used by [KmdbCollection.search] to execute lexical (BM25) queries and
  /// to intercept document writes for index maintenance.
  FtsManager? get ftsManager => _ftsManager;

  /// The vector (semantic) search manager.
  ///
  /// Returns `null` in this stub implementation. Will be populated by plan 3
  /// (semantic search) with a `VecManager` instance.
  dynamic get vecManager => null;

  // ── Internal (used by KmdbCollection) ─────────────────────────────────────

  /// The cache-aware read path.
  CacheLayer get cache => _cache;

  /// The raw store for writes that include system namespace entries.
  KvStoreImpl get store => _store;

  /// The index manager for write interception and lazy build.
  IndexManager get indexManager => _indexManager;

  /// The FTS index definitions configured at open time.
  List<FtsIndexDefinition> get ftsIndexes => _ftsIndexes;

  /// The vector index definitions configured at open time.
  List<VecIndexDefinition> get vecIndexes => _vecIndexes;

  /// The embedding model configured at open time (null if no vector indexes).
  EmbeddingModel? get embeddingModel => _embeddingModel;
}
