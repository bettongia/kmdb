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

import '../cache/cache_layer.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/kv_store_impl.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../search/embedding_model.dart';
import '../search/fts_index_definition.dart';
import '../search/lexical/fts_manager.dart';
import '../search/semantic/vec_manager.dart';
import '../search/vec_index_definition.dart';
import '../vault/vault_gc.dart';
import '../vault/vault_recovery.dart';
import '../vault/vault_ref_interceptor.dart';
import '../vault/vault_store.dart';
import 'collection_schema.dart';
import 'exceptions.dart';
import 'index/index_definition.dart';
import 'index/index_manager.dart';
import 'kmdb_codec.dart';
import 'kmdb_collection.dart';
import 'raw_document_codec.dart';
import 'reserved_key_validator.dart';
import 'schema/schema_manager.dart';
import 'write_augmentor.dart';
import 'write_validator.dart';

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
/// ## Collection Schemas
///
/// Schemas are optional. When supplied, every document write to that collection
/// is validated before the [WriteBatch] is committed. Writes that violate the
/// schema throw [SchemaValidationException]. Schemas are persisted in `$meta`
/// and synced to other devices (spec §25).
///
/// ```dart
/// final db = await KmdbDatabase.open(
///   path: '/path/to/database',
///   adapter: adapter,
///   schemas: [
///     CollectionSchema(
///       collection: 'contacts',
///       jsonSchema: {
///         'required': ['name', 'email'],
///         'properties': {
///           'name': {'type': 'string', 'minLength': 1},
///           'email': {'type': 'string', 'format': 'email'},
///         },
///       },
///     ),
///   ],
///   onSchemaVersionMismatch: (collection, stored, supported) {
///     // Schema from a newer KMDB build — enforcement disabled for safety.
///   },
/// );
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
    required SchemaManager schemaManager,
    required FtsManager? ftsManager,
    required VecManager? vecManager,
    required List<FtsIndexDefinition> ftsIndexes,
    required List<VecIndexDefinition> vecIndexes,
    required EmbeddingModel? embeddingModel,
    VaultStore? vaultStore,
    VaultGc? vaultGc,
  }) : _cache = cache,
       _store = store,
       _indexManager = indexManager,
       _schemaManager = schemaManager,
       _ftsManager = ftsManager,
       _vecManager = vecManager,
       _ftsIndexes = ftsIndexes,
       _vecIndexes = vecIndexes,
       _embeddingModel = embeddingModel,
       _vaultStore = vaultStore,
       // Build the interceptor only when both a VaultStore and VaultGc are
       // present; if either is absent, vault reference counting is disabled.
       _vaultRefInterceptor = (vaultStore != null && vaultGc != null)
           ? VaultRefInterceptor(kvStore: store, gc: vaultGc)
           : null {
    // ── Layer 1: validators (run before any I/O) ─────────────────────────────
    // Always register the reserved-key validator first so that user fields
    // starting with '_' are rejected before schema validation runs.
    _validators
      ..add(const ReservedKeyValidator())
      ..add(_schemaManager);

    // ── Layer 2: augmentors (add entries to WriteBatch after validators) ──────
    // IndexManager is always present.
    _augmentors.add(_indexManager);

    // FtsManager augmentor — null when no FTS indexes are configured.
    // The local `fts` variable captures the non-null value after the null
    // check so that Dart's flow analysis can prove non-nullability.
    final fts = _ftsManager;
    if (fts != null) _augmentors.add(fts);

    // VecManager augmentor — null when no vector indexes are configured.
    final vec = _vecManager;
    if (vec != null) _augmentors.add(vec);

    // VaultRefInterceptor augmentor — null when vault is disabled.
    final vri = _vaultRefInterceptor;
    if (vri != null) _augmentors.add(vri);
  }

  final CacheLayer _cache;
  final KvStoreImpl _store;
  final IndexManager _indexManager;
  final SchemaManager _schemaManager;
  final FtsManager? _ftsManager;
  final VecManager? _vecManager;
  final List<FtsIndexDefinition> _ftsIndexes;
  final List<VecIndexDefinition> _vecIndexes;
  final EmbeddingModel? _embeddingModel;
  final VaultStore? _vaultStore;
  final VaultRefInterceptor? _vaultRefInterceptor;

  /// Layer 1 validators. Iterated in registration order; first failure aborts
  /// the write before any I/O is performed.
  final List<WriteValidator> _validators = [];

  /// Layer 2 augmentors. Iterated in registration order; each adds entries to
  /// the [WriteBatch] that is atomically committed with the document write.
  final List<WriteAugmentor> _augmentors = [];

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
  /// [vaultStore] is the optional vault content-addressable store. When
  /// supplied, vault reference counting and GC are activated and vault
  /// recovery runs during open. If `null`, vault features are disabled.
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
    VaultStore? vaultStore,
    List<CollectionSchema> schemas = const [],
    void Function(String collection, int storedVersion, int supportedVersion)?
    onSchemaVersionMismatch,
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

    // Initialise VecManager if any vector indexes are configured.
    final vecManager = (vecIndexes.isNotEmpty && embeddingModel != null)
        ? VecManager(store, vecIndexes, embeddingModel)
        : null;

    // Recover from any unclean sync shutdown for vector indexes.
    await vecManager?.checkAndTransitionOnOpen();

    // Run vault recovery if a VaultStore is supplied. This sweeps the staging
    // directory and removes any incomplete or orphaned hash directories left
    // by a prior crash (§24 crash table). Runs after LSM recovery because it
    // uses the already-opened KvStore to validate ref counts.
    VaultGc? vaultGc;
    if (vaultStore != null) {
      final recovery = VaultRecovery(store: vaultStore, kvStore: store);
      await recovery.recover();
      vaultGc = VaultGc(store: vaultStore, kvStore: store);
    }

    // Initialise SchemaManager: register caller-supplied schemas (persisting
    // them via LWW), then load any schemas synced from other devices.
    final schemaManager = SchemaManager(
      onSchemaVersionMismatch: onSchemaVersionMismatch,
    );
    final metaStore = store.meta;
    for (final schema in schemas) {
      await schemaManager.register(schema, metaStore);
    }
    await schemaManager.load(metaStore);

    return KmdbDatabase._(
      cache: cache,
      store: store,
      indexManager: indexManager,
      schemaManager: schemaManager,
      ftsManager: ftsManager,
      vecManager: vecManager,
      ftsIndexes: ftsIndexes,
      vecIndexes: vecIndexes,
      embeddingModel: embeddingModel,
      vaultStore: vaultStore,
      vaultGc: vaultGc,
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

  /// Returns an untyped collection for [name] using the built-in
  /// [RawDocumentCodec].
  ///
  /// This is the entry point for code that works with plain
  /// `Map<String, dynamic>` documents — such as the CLI — and does not have a
  /// typed model. All write pipeline validation and augmentation (schema
  /// enforcement, secondary index maintenance, FTS updates, vault ref counts)
  /// still runs, so writes through [rawCollection] are fully equivalent to
  /// typed writes through [collection].
  ///
  /// ## Example
  ///
  /// ```dart
  /// final col = db.rawCollection('contacts');
  /// await col.insert({'name': 'Alice', 'email': 'alice@example.com'});
  /// final doc = await col.get(key);
  /// ```
  KmdbCollection<Map<String, dynamic>> rawCollection(String name) =>
      collection(name: name, codec: const RawDocumentCodec());

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
  /// If an [embeddingModel] was supplied to [open], its [EmbeddingModel.dispose]
  /// equivalent is called after all other cleanup so that native ORT resources
  /// are released. After [close] returns, this instance must not be used again.
  Future<void> close({bool flush = true}) async {
    await _cache.close(flush: flush);
    // Release native embedding model resources (no-op when embeddingModel is
    // null or when the implementation's dispose() is a no-op).
    _embeddingModel?.dispose();
  }

  // ── Text search ────────────────────────────────────────────────────────────

  /// The full-text search (FTS) manager.
  ///
  /// Non-null when at least one [FtsIndexDefinition] was supplied to [open].
  /// Used by [KmdbCollection.search] to execute lexical (BM25) queries and
  /// to intercept document writes for index maintenance.
  FtsManager? get ftsManager => _ftsManager;

  /// The vector (semantic) search manager.
  ///
  /// Non-null when at least one [VecIndexDefinition] was supplied to [open]
  /// alongside an [embeddingModel]. Used by [KmdbCollection.search] to execute
  /// semantic (cosine similarity) queries and to intercept document writes for
  /// index maintenance.
  VecManager? get vecManager => _vecManager;

  // ── Internal (used by KmdbCollection) ─────────────────────────────────────

  /// The ordered list of write validators (Layer 1 of the write pipeline).
  ///
  /// [KmdbCollection._writeDocument] iterates this list before any I/O. If any
  /// validator throws, the write is aborted with no partial side effects.
  List<WriteValidator> get validators => _validators;

  /// The ordered list of write augmentors (Layer 2 of the write pipeline).
  ///
  /// [KmdbCollection._writeDocument] and [KmdbCollection._deleteDocument]
  /// iterate this list to add extra entries to the [WriteBatch] before it is
  /// committed. All augmentor writes land in the same atomic batch as the
  /// document write.
  List<WriteAugmentor> get augmentors => _augmentors;

  /// The cache-aware read path.
  CacheLayer get cache => _cache;

  /// The raw store for writes that include system namespace entries.
  KvStoreImpl get store => _store;

  /// The index manager for write interception and lazy build.
  IndexManager get indexManager => _indexManager;

  /// The schema manager for admission-gate validation on collection writes.
  SchemaManager get schemaManager => _schemaManager;

  /// Registers [schema] for [collection] and persists it to `$meta`.
  ///
  /// This is a convenience wrapper around [SchemaManager.register] that
  /// supplies the internal [MetaStore] automatically. After a successful call,
  /// every subsequent write to [collection] is validated against [schema].
  ///
  /// Use this method from outside the `kmdb` package (e.g. CLI commands) to
  /// avoid direct access to the package-private [MetaStore].
  ///
  /// Example:
  /// ```dart
  /// await db.registerSchema(CollectionSchema(
  ///   collection: 'contacts',
  ///   jsonSchema: {'required': ['name']},
  /// ));
  /// ```
  Future<void> registerSchema(CollectionSchema schema) =>
      _schemaManager.register(schema, _store.meta);

  /// Removes the schema for [collection] from both `$meta` and the in-memory
  /// cache.
  ///
  /// This is a convenience wrapper around [SchemaManager.deregister] that
  /// supplies the internal [MetaStore] automatically. After a successful call,
  /// writes to [collection] are no longer validated. Deregistering an unknown
  /// collection is a no-op.
  ///
  /// Use this method from outside the `kmdb` package (e.g. CLI commands) to
  /// avoid direct access to the package-private [MetaStore].
  ///
  /// Example:
  /// ```dart
  /// await db.deregisterSchema('contacts');
  /// ```
  Future<void> deregisterSchema(String collection) =>
      _schemaManager.deregister(collection, _store.meta);

  /// The FTS index definitions configured at open time.
  List<FtsIndexDefinition> get ftsIndexes => _ftsIndexes;

  /// The vector index definitions configured at open time.
  List<VecIndexDefinition> get vecIndexes => _vecIndexes;

  /// The embedding model configured at open time (null if no vector indexes).
  EmbeddingModel? get embeddingModel => _embeddingModel;

  /// The vault store configured at open time.
  ///
  /// Non-null when a [VaultStore] was supplied to [open]. Used by
  /// [KmdbCollection] to wire vault URIs in decoded documents to the active
  /// store so that [VaultRef.getBlob] and [VaultRef.getMetadata] work.
  VaultStore? get vaultStore => _vaultStore;

  /// The vault reference count interceptor.
  ///
  /// Non-null when both a [VaultStore] and [VaultGc] are active. Called by
  /// [KmdbCollection] on every document write to maintain `$vault` ref counts
  /// atomically alongside the document write.
  VaultRefInterceptor? get vaultRefInterceptor => _vaultRefInterceptor;
}
