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
import '../engine/platform/storage_adapter_native.dart';
import '../search/embedding_model.dart';
import '../search/fts_index_definition.dart';
import '../search/lexical/fts_manager.dart';
import '../search/semantic/vec_manager.dart';
import '../search/vec_index_definition.dart';
import '../sync/consolidation_config.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_storage_adapter.dart';
import '../vault/vault_gc.dart';
import '../vault/vault_recovery.dart';
import '../vault/vault_ref_interceptor.dart';
import '../vault/vault_store.dart';
import '../engine/compaction/reclamation_policy.dart'
    show ReclamationPolicy, ReclamationPolicyRegistry;
import '../versioning/version_config.dart';
import '../versioning/version_entry.dart';
import '../versioning/version_manager.dart';
import '../versioning/version_retention_policy.dart';
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
    required this._cache,
    required KvStoreImpl store,
    required this._indexManager,
    required this._schemaManager,
    required this._ftsManager,
    required this._vecManager,
    required this._ftsIndexes,
    required this._vecIndexes,
    required this._embeddingModel,
    VaultStore? vaultStore,
    VaultGc? vaultGc,
    Map<String, VersionConfig>? versionConfigs,
  }) : _store = store,
       _vaultStore = vaultStore,
       // Build the interceptor only when both a VaultStore and VaultGc are
       // present; if either is absent, vault reference counting is disabled.
       _vaultRefInterceptor = (vaultStore != null && vaultGc != null)
           ? VaultRefInterceptor(kvStore: store, gc: vaultGc)
           : null,
       _versionAugmentor = VersionWriteAugmentor(
         configs: versionConfigs ?? const {},
       ) {
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
    // Must run BEFORE VersionWriteAugmentor so vault refs are counted
    // before the version entry is written (the version entry references
    // the same vault URIs as the document).
    final vri = _vaultRefInterceptor;
    if (vri != null) _augmentors.add(vri);

    // VersionWriteAugmentor — always present; respects isDisabled per-collection.
    _augmentors.add(_versionAugmentor);
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

  /// The version write augmentor, always registered. Emits `$ver:` entries for
  /// every document write in collections where versioning is enabled.
  final VersionWriteAugmentor _versionAugmentor;

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
  /// `'00000000'`, which is a test sentinel — SSTable files written with this
  /// ID are not meaningful for multi-device sync. Production callers should
  /// call [ensureDeviceId] after opening the database (or use `DatabaseOpener`
  /// in the CLI, which handles this automatically).
  ///
  /// [versionConfigs] declares per-collection versioning configuration. Each
  /// entry maps a collection name to its [VersionConfig] (max versions,
  /// retention window). Configs are persisted to `$meta` and propagate via
  /// sync so all devices use the same policy. Omitting a collection from the
  /// map applies [VersionConfig.defaults] (`maxVersions: 4`,
  /// `retentionDays: 90`). Pass `VersionConfig.disabled` to disable versioning
  /// for a collection entirely.
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
    Map<String, VersionConfig> versionConfigs = const {},
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

    // Persist versioning configs to $meta so they propagate via sync.
    // Load the merged config set: caller-supplied configs override any
    // previously persisted configs from other devices.
    final configStore = VersionConfigStore(metaStore);
    final mergedVersionConfigs = <String, VersionConfig>{};
    // Load any configs persisted from prior opens (including those synced from
    // other devices). We use the registered user namespaces as the scan set.
    final knownNamespaces = await store.listNamespaces();
    for (final ns in knownNamespaces) {
      final persisted = await configStore.get(ns);
      // Only include explicitly-set configs (skip defaults — they are implicit).
      if (persisted != VersionConfig.defaults) {
        mergedVersionConfigs[ns] = persisted;
      }
    }
    // Caller-supplied configs take precedence and are persisted.
    for (final entry in versionConfigs.entries) {
      await configStore.put(entry.key, entry.value);
      mergedVersionConfigs[entry.key] = entry.value;
    }

    // Wire the version registry provider into the engine so _compactAll builds
    // a VersionRetentionPolicy per $ver: prefix (Phase 3, RQ2).
    store.setVersionRegistryProvider(() async {
      // Re-read configs at compaction time: they may have changed via sync
      // since the database was opened. Build a map from $ver:{ns} →
      // VersionRetentionPolicy for all non-disabled collections.
      final versionPolicies = <String, ReclamationPolicy>{};
      for (final ns in await store.listNamespaces()) {
        final cfg = await configStore.get(ns);
        if (!cfg.isDisabled) {
          versionPolicies[versionNamespace(ns)] = VersionRetentionPolicy(cfg);
        }
      }
      return ReclamationPolicyRegistry.withVersionPolicies(versionPolicies);
    });

    // Wire the version drop callback into the engine so compaction-time $ver:
    // trims can decrement vault ref counts (RQ5).
    final vaultRefInterceptor = (vaultStore != null && vaultGc != null)
        ? VaultRefInterceptor(kvStore: store, gc: vaultGc)
        : null;
    store.setVersionDropCallback(
      vaultRefInterceptor != null
          ? (droppedValues) async {
              // Decode each dropped VersionEntry and release vault refs for
              // any vault URIs contained in the stored encodedValue.
              // This mirrors the H4-FU3 tombstonesDropped callback pattern.
              final batch = WriteBatch();
              for (final bytes in droppedValues) {
                try {
                  final entry = VersionEntry.decode(bytes);
                  if (entry.encodedValue != null) {
                    await vaultRefInterceptor.decrementVersionRefs(
                      entry.encodedValue!,
                      batch,
                    );
                  }
                } catch (_) {
                  // Skip undecodable entries; the fail-safe posture (retain on
                  // uncertainty) means a missed decrement over-counts — safe.
                  continue;
                }
              }
              if (!batch.isEmpty) {
                await store.writeBatch(batch);
              }
            }
          : null,
    );

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
      versionConfigs: mergedVersionConfigs,
    );
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Loads or generates a stable device identifier for this database instance.
  ///
  /// Reads the `DEVICE_ID` file in the database directory. If the file does not
  /// exist, a new random 8-character lowercase hex ID is generated and persisted
  /// to `$meta`. Subsequent calls return the same ID without re-reading the
  /// file.
  ///
  /// Call this once after [open] in production code before the first [sync],
  /// [push], or [pull]. Callers that omit this call will use the [deviceId]
  /// supplied at [open] time; the default `'00000000'` is only suitable for
  /// tests and should not be used in production sync scenarios.
  ///
  /// Returns the 8-character lowercase hex device identifier.
  ///
  /// Example:
  /// ```dart
  /// final db = await KmdbDatabase.open(path: '/path/to/db', adapter: adapter);
  /// final deviceId = await db.ensureDeviceId();
  /// await db.sync(syncAdapter: myCloudAdapter);
  /// ```
  Future<String> ensureDeviceId() => _store.ensureDeviceId();

  /// Flushes, pushes local SSTables to [syncAdapter], then pulls peer SSTables.
  ///
  /// [syncAdapter] is the remote sync storage backend. [syncRoot] is a path
  /// prefix within the adapter (empty string means the adapter root, which is
  /// correct for single-database setups). [syncNamespaces] restricts which user
  /// collections participate in sync; when `null`, all registered user
  /// collections (non-`$` namespaces) are included. [localAdapter] overrides
  /// the local [StorageAdapter] used to read local SSTables; when `null`, a
  /// [StorageAdapterNative] is constructed automatically. [consolidationConfig]
  /// controls the peer-file consolidation threshold and lease parameters;
  /// defaults to production values.
  ///
  /// Equivalent to calling [push] then [pull] in sequence.
  ///
  /// **Native-only.** Sync requires direct SSTable file access via [dart:io].
  /// On web this method throws [UnsupportedError] at the point where the
  /// [StorageAdapterNative] is constructed (or immediately if [localAdapter] is
  /// supplied but is itself unsupported on web).
  ///
  /// Example:
  /// ```dart
  /// await db.sync(
  ///   syncAdapter: LocalDirectoryAdapter('/path/to/sync-folder'),
  /// );
  /// ```
  Future<void> sync({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
    );
    await engine.sync();
  }

  /// Flushes and uploads local SSTables to [syncAdapter].
  ///
  /// See [sync] for full parameter documentation.
  ///
  /// **Native-only.** See [sync] for web behaviour.
  Future<void> push({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
    );
    await engine.push();
  }

  /// Downloads peer SSTables from [syncAdapter] and ingests them locally.
  ///
  /// See [sync] for full parameter documentation.
  ///
  /// **Native-only.** See [sync] for web behaviour.
  Future<void> pull({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
    );
    await engine.pull();
  }

  /// Constructs a [SyncEngine] with resolved [syncNamespaces], [dbDir], and
  /// [deviceId] from the store.
  ///
  /// When [syncNamespaces] is `null`, all registered user namespaces (those not
  /// starting with `$`) are resolved via [KvStore.listNamespaces].
  ///
  /// When [localAdapter] is `null`, a [StorageAdapterNative] is constructed.
  /// This construction throws [UnsupportedError] on web, which propagates to
  /// the caller as-is — making [sync], [push], and [pull] effectively
  /// native-only in the same way that [SyncEngine] itself is native-only.
  Future<SyncEngine> _buildSyncEngine({
    required SyncStorageAdapter syncAdapter,
    required String syncRoot,
    required Set<String>? syncNamespaces,
    required StorageAdapter? localAdapter,
    required ConsolidationConfig consolidationConfig,
  }) async {
    // Resolve namespaces: use caller-supplied set or list all user namespaces.
    final resolvedNamespaces =
        syncNamespaces ??
        (await _store.listNamespaces())
            .where((ns) => !ns.startsWith(r'$'))
            .toSet();

    // Retrieve the database directory and stable device ID from the store.
    final info = await _store.storeInfo();

    // Resolve local adapter: default to StorageAdapterNative (native-only).
    // On web, StorageAdapterNative() throws UnsupportedError, which bubbles up
    // to the caller of sync/push/pull — the intended behaviour.
    final resolvedLocalAdapter = localAdapter ?? StorageAdapterNative();

    return SyncEngine(
      store: _store,
      cloudAdapter: syncAdapter,
      localAdapter: resolvedLocalAdapter,
      deviceId: info.deviceId,
      dbDir: info.dbDir,
      syncRoot: syncRoot,
      syncNamespaces: resolvedNamespaces,
      consolidationConfig: consolidationConfig,
    );
  }

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
