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

import 'dart:typed_data';

import '../cache/cache_layer.dart';
import '../encryption/encryption_blob.dart';
import '../encryption/encryption_config.dart';
import '../encryption/encryption_error.dart';
import '../encryption/encryption_provider.dart';
import '../encryption/key_derivation.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/kv_store_impl.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/platform/storage_adapter_native.dart';
import 'package:betto_inferencing/betto_inferencing.dart';
import 'package:betto_zstd/betto_zstd.dart' show ZstdSimple;
import '../search/fts_index_definition.dart';
import '../search/lexical/fts_manager.dart';
import '../search/semantic/vec_manager.dart';
import '../search/vec_index_definition.dart';
import '../sync/consolidation_config.dart';
import '../sync/sync_context.dart';
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
///   embeddingModel: await OnnxEmbeddingModel.load(cacheDir: cacheDir), // required for vecIndexes
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
    EncryptionProvider? encryption,
    VaultStore? vaultStore,
    VaultGc? vaultGc,
    Map<String, VersionConfig>? versionConfigs,
  }) : _store = store,
       _encryption = encryption,
       _vaultStore = vaultStore,
       // Build the interceptor only when both a VaultStore and VaultGc are
       // present; if either is absent, vault reference counting is disabled.
       _vaultRefInterceptor = (vaultStore != null && vaultGc != null)
           ? VaultRefInterceptor(
               kvStore: store,
               gc: vaultGc,
               encryption: encryption,
             )
           : null,
       _versionAugmentor = VersionWriteAugmentor(
         configs: versionConfigs ?? const {},
         encryption: encryption,
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

  /// The active encryption provider, or `null` for plaintext databases.
  ///
  /// Threaded into every [ValueCodec] call site so that all stored values
  /// (documents, `$index:`, `$ver:`, `$vault`, `$cache`) are encrypted
  /// uniformly. Exposed to [KmdbCollection] via the [encryption] getter.
  final EncryptionProvider? _encryption;
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
  /// [wasmUrl] is the URL from which the Zstd WASM module is loaded on the web
  /// platform. On native platforms this parameter is ignored. Defaults to the
  /// standard Flutter asset path (`assets/packages/betto_zstd/assets/zstd.wasm`),
  /// which is correct for Flutter apps that declare `betto_zstd` as a dependency.
  /// Override only when serving the WASM from a custom location (e.g. a pure-Dart
  /// web server that hosts assets at a different path).
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
    String? wasmUrl,
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

    /// Encryption configuration for this database.
    ///
    /// - Pass `null` (default) for a plaintext database.
    /// - Pass `EncryptionConfig(passphrase: '...')` to open an existing
    ///   encrypted database with a passphrase.
    /// - Pass `EncryptionConfig(recoveryCode: '...')` to open with a recovery
    ///   code.
    /// - Pass `(await EncryptionConfig.createResult(passphrase: '...')).config`
    ///   to provision a new encrypted database.
    ///
    /// The bootstrap (reading `enc:blob`, deriving the KEK, unwrapping the DEK,
    /// and constructing the [EncryptionProvider]) runs inside [open] immediately
    /// after the LSM engine opens. The resulting provider is threaded into every
    /// value-decoding collaborator.
    ///
    /// Throws [EncryptionError] with the appropriate code if the 4-state
    /// invariant is violated (e.g. encrypted database opened without config,
    /// or wrong passphrase).
    EncryptionConfig? encryptionConfig,
  }) async {
    // Initialise the Zstd compression module before any I/O begins.
    //
    // On web this loads and instantiates the WASM module (idempotent — safe to
    // call multiple times). On native it is a no-op Future that resolves
    // immediately. Must be the first await in open() so that tryCompress and
    // decompress (called synchronously from ValueCodec.encode/decode) are always
    // backed by an initialised compressor.
    //
    // Ordering rationale: KvStoreImpl.open() and the schema/meta loads that
    // follow do NOT route through ValueCodec (MetaStore uses raw CBOR). The
    // first compressed-value decode paths (KmdbCollection reads, IndexManager
    // lazy build, versioning) are only reachable after open() returns, so
    // placing init() before KvStoreImpl.open() is both sufficient and correct.
    // If a future change causes documents to be decoded during recovery, this
    // comment is the signal that init() must still precede that code.
    await ZstdSimple.init(
      wasmUrl: wasmUrl ?? 'assets/packages/betto_zstd/assets/zstd.wasm',
    );

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

    // ── Encryption bootstrap ─────────────────────────────────────────────────
    // Runs immediately after KvStoreImpl.open() and before any value-decoding
    // collaborator is constructed. Reads the enc:blob (plaintext CBOR) from
    // $meta to determine the 4-state outcome. The resulting EncryptionProvider?
    // is threaded into every collaborator below.
    //
    // The bootstrap never routes through ValueCodec (MetaStore.getRawByName uses
    // raw CBOR), keeping the read path non-circular: the DEK is available before
    // any encrypted value needs to be decoded.
    final encryption = await _runEncryptionBootstrap(
      store,
      encryptionConfig,
      path,
    );

    final cache = CacheLayer(store: store);

    final indexManager = IndexManager(
      store: store,
      definitions: indexes,
      onIndexReady: onIndexReady,
      encryption: encryption,
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
        ? FtsManager(store, ftsIndexes, encryption: encryption)
        : null;

    // Recover from any unclean shutdown during a delta sync (transitions
    // any index left in `syncing` state to `stale`).
    await ftsManager?.checkAndTransitionOnOpen();

    // Initialise VecManager if any vector indexes are configured.
    final vecManager = (vecIndexes.isNotEmpty && embeddingModel != null)
        ? VecManager(store, vecIndexes, embeddingModel, encryption: encryption)
        : null;

    // Recover from any unclean sync shutdown for vector indexes.
    await vecManager?.checkAndTransitionOnOpen();

    // Wire the encryption provider into the VaultStore (if any) so that
    // blobs written after this point are encrypted and reads are decrypted.
    // This must happen before VaultRecovery, because recovery may read blobs
    // to verify SHA-256 content addresses (decryption is required first).
    if (vaultStore != null) {
      vaultStore.encryption = encryption;
    }

    // Run vault recovery if a VaultStore is supplied. This sweeps the staging
    // directory and removes any incomplete or orphaned hash directories left
    // by a prior crash (§24 crash table). Runs after LSM recovery because it
    // uses the already-opened KvStore to validate ref counts.
    // Thread the encryption provider so that encrypted $vault ref count entries
    // are decoded correctly during the recovery sweep and subsequent GC sweeps
    // (Q6 decision: all ValueCodec call sites encrypt uniformly).
    VaultGc? vaultGc;
    if (vaultStore != null) {
      final recovery = VaultRecovery(
        store: vaultStore,
        kvStore: store,
        encryption: encryption,
      );
      await recovery.recover();
      vaultGc = VaultGc(
        store: vaultStore,
        kvStore: store,
        encryption: encryption,
      );
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
      final persisted = await configStore.get(ns, encryption: encryption);
      // Only include explicitly-set configs (skip defaults — they are implicit).
      if (persisted != VersionConfig.defaults) {
        mergedVersionConfigs[ns] = persisted;
      }
    }
    // Caller-supplied configs take precedence and are persisted.
    for (final entry in versionConfigs.entries) {
      await configStore.put(entry.key, entry.value, encryption: encryption);
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
        final cfg = await configStore.get(ns, encryption: encryption);
        if (!cfg.isDisabled) {
          versionPolicies[versionNamespace(ns)] = VersionRetentionPolicy(cfg);
        }
      }
      return ReclamationPolicyRegistry.withVersionPolicies(versionPolicies);
    });

    // Wire the version drop callback into the engine so compaction-time $ver:
    // trims can decrement vault ref counts (RQ5).
    final vaultRefInterceptor = (vaultStore != null && vaultGc != null)
        ? VaultRefInterceptor(
            kvStore: store,
            gc: vaultGc,
            encryption: encryption,
          )
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
                  // VersionEntry.decode is async when encryption is active
                  // because the inner ValueCodec.decode is async.
                  final entry = await VersionEntry.decode(
                    bytes,
                    encryption: encryption,
                  );
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
      encryption: encryption,
      vaultStore: vaultStore,
      vaultGc: vaultGc,
      versionConfigs: mergedVersionConfigs,
    );
  }

  // ── Encryption bootstrap ────────────────────────────────────────────────────

  /// Runs the 4-state encryption bootstrap immediately after [KvStoreImpl.open].
  ///
  /// Reads the `enc:blob` from `$meta` (plaintext CBOR — non-circular) and
  /// applies the following logic:
  ///
  /// | `enc:blob` present? | `encryptionConfig` supplied? | Outcome |
  /// |:-------------------|:-----------------------------|:--------|
  /// | No                 | No                           | Normal unencrypted open. Returns `null`. |
  /// | Yes                | No                           | Throws [EncryptionError.databaseIsEncrypted]. |
  /// | No                 | Yes (unlock)                 | Throws [EncryptionError.databaseIsNotEncrypted]. |
  /// | No                 | Yes (create)                 | Provisions encryption: writes `enc:blob`, returns provider. |
  /// | Yes                | Yes (unlock)                 | Unwraps DEK. Returns provider, or throws [EncryptionError.badCredentials]. |
  ///
  /// Returns the [EncryptionProvider] to thread into all collaborators, or
  /// `null` for an unencrypted database.
  static Future<EncryptionProvider?> _runEncryptionBootstrap(
    KvStoreImpl store,
    EncryptionConfig? encryptionConfig,
    String dbId,
  ) async {
    final blob = await store.meta.getEncryptionBlob();
    final blobPresent = blob != null;

    if (!blobPresent && encryptionConfig == null) {
      // State 1: Unencrypted database, no config — normal open.
      return null;
    }

    if (blobPresent && encryptionConfig == null) {
      // State 2: Encrypted database opened without credentials — fail loudly.
      throw EncryptionError.databaseIsEncrypted();
    }

    if (!blobPresent && encryptionConfig!.isProvisioning) {
      // State 4: Provision a new encrypted database.
      // Check that there is no user data already (cannot retrofit encryption).
      final userNamespaces = (await store.listNamespaces())
          .where((ns) => !ns.startsWith(r'$'))
          .toList();
      if (userNamespaces.isNotEmpty) {
        throw EncryptionError.cannotProvisionNonEmptyDatabase();
      }

      // Wrap the pre-generated DEK under both the passphrase KEK and the
      // recovery KEK, then persist the enc:blob.
      final dek = encryptionConfig.provisioningDek;
      final salt = encryptionConfig.provisioningSalt;
      final recoveryEntropy = encryptionConfig.provisioningRecoveryEntropy;

      final wrappedDekPassphrase = await encryptionConfig.wrapDekWithPassphrase(
        dek,
        salt,
      );
      final wrappedDekRecovery = await encryptionConfig.wrapDekWithRecovery(
        dek,
        recoveryEntropy,
      );

      final newBlob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedDekPassphrase,
        wrappedDekRecovery: wrappedDekRecovery,
      );

      // Write the blob DURABLY before any encrypted user value can be written.
      // putEncryptionBlob uses putRawByName which routes through the WAL and
      // will be fsynced when the first flush occurs. The open() call returns
      // after this point, but the caller cannot write encrypted user values
      // until they call put/collection operations, by which time the WAL will
      // have been fsynced on the write path.
      await store.meta.putEncryptionBlob(newBlob);

      // Cache the DEK for this session so the user is not re-prompted on
      // repeated opens (relevant when a FlutterSecureDekCache is injected).
      await encryptionConfig.dekCache.store(dbId, dek);

      return encryptionConfig.buildProvider(dek);
    }

    if (!blobPresent &&
        encryptionConfig != null &&
        !encryptionConfig.isProvisioning) {
      // State 3: Unlock config supplied but no blob — database is not encrypted.
      throw EncryptionError.databaseIsNotEncrypted();
    }

    // State 5: enc:blob present + unlock config supplied — unwrap the DEK.
    // Try the DEK cache first to avoid re-running Argon2id (Argon2id at the
    // default parameters takes ~200ms, so skipping it on repeated opens is
    // a significant UX improvement when a FlutterSecureDekCache is injected).
    final cachedDek = await encryptionConfig!.dekCache.read(dbId);
    if (cachedDek != null) {
      return encryptionConfig.buildProvider(cachedDek);
    }

    final existingBlob = blob!;

    // Try passphrase unwrap (Argon2id + AES-GCM).
    Uint8List? dek = await encryptionConfig.tryUnwrapWithPassphrase(
      existingBlob.wrappedDekPassphrase,
      existingBlob.argon2Salt,
    );

    // Try recovery-code unwrap if passphrase didn't work.
    dek ??= await encryptionConfig.tryUnwrapWithRecovery(
      existingBlob.wrappedDekRecovery,
    );

    if (dek == null) {
      throw EncryptionError.badCredentials();
    }

    // Cache the DEK and return the provider.
    await encryptionConfig.dekCache.store(dbId, dek);
    return encryptionConfig.buildProvider(dek);
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
  /// defaults to production values. [cancel] is an optional imperative
  /// cancellation signal; [timeout] is an optional maximum duration for the
  /// entire sync run (converted to an absolute deadline inside the engine so
  /// that back-off comparisons are consistent across the full run).
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
  ///
  /// // With cancellation and a 30-second timeout:
  /// final token = CancellationToken();
  /// await db.sync(
  ///   syncAdapter: adapter,
  ///   cancel: token,
  ///   timeout: const Duration(seconds: 30),
  /// );
  /// ```
  Future<void> sync({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
      cancel: cancel,
      timeout: timeout,
    );
    await engine.sync();
  }

  /// Flushes and uploads local SSTables to [syncAdapter].
  ///
  /// See [sync] for full parameter documentation (including [cancel] and
  /// [timeout]).
  ///
  /// **Native-only.** See [sync] for web behaviour.
  Future<void> push({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
      cancel: cancel,
      timeout: timeout,
    );
    await engine.push();
  }

  /// Downloads peer SSTables from [syncAdapter] and ingests them locally.
  ///
  /// See [sync] for full parameter documentation (including [cancel] and
  /// [timeout]).
  ///
  /// **Native-only.** See [sync] for web behaviour.
  Future<void> pull({
    required SyncStorageAdapter syncAdapter,
    String syncRoot = '',
    Set<String>? syncNamespaces,
    StorageAdapter? localAdapter,
    ConsolidationConfig consolidationConfig = const ConsolidationConfig(),
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final engine = await _buildSyncEngine(
      syncAdapter: syncAdapter,
      syncRoot: syncRoot,
      syncNamespaces: syncNamespaces,
      localAdapter: localAdapter,
      consolidationConfig: consolidationConfig,
      cancel: cancel,
      timeout: timeout,
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
  ///
  /// The [cancel] and [timeout] parameters are combined into a single
  /// [SyncContext] and passed to the engine constructor so every adapter call
  /// site has access to the cancellation signal. [timeout] is converted to an
  /// absolute deadline at this point so back-off comparisons are consistent
  /// across the full sync run.
  Future<SyncEngine> _buildSyncEngine({
    required SyncStorageAdapter syncAdapter,
    required String syncRoot,
    required Set<String>? syncNamespaces,
    required StorageAdapter? localAdapter,
    required ConsolidationConfig consolidationConfig,
    CancellationToken? cancel,
    Duration? timeout,
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

    // Build the per-sync-run context. Convert timeout to an absolute deadline
    // once here so all subsequent comparisons use the same reference point.
    final SyncContext? ctx = (cancel != null || timeout != null)
        ? SyncContext(
            cancel: cancel,
            deadline: timeout != null ? DateTime.now().add(timeout) : null,
          )
        : null;

    return SyncEngine(
      store: _store,
      cloudAdapter: syncAdapter,
      localAdapter: resolvedLocalAdapter,
      deviceId: info.deviceId,
      dbDir: info.dbDir,
      syncRoot: syncRoot,
      syncNamespaces: resolvedNamespaces,
      consolidationConfig: consolidationConfig,
      ctx: ctx,
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

  /// Rebuilds all stale or undefined `$vec:` indexes in the foreground.
  ///
  /// Calls [VecManager.reindex] on the underlying vector manager. This is a
  /// foreground operation — it blocks until all stale indexes have been fully
  /// rebuilt from the current document contents. For large collections this
  /// may take several seconds.
  ///
  /// This method is **vec-only** — it does not touch FTS indexes.
  ///
  /// Returns the number of indexes that were (re)built. Returns `0` immediately
  /// when no embedding model is configured (i.e., no vector indexes were
  /// declared at [open] time).
  ///
  /// Use this after a planned model upgrade to force an immediate rebuild
  /// rather than waiting for the next `search()` call:
  ///
  /// ```dart
  /// // After upgrading to a new embedding model:
  /// final model = await OnnxEmbeddingModel.load(
  ///   spec: ModelCatalog.lookup('bge-small-en-v1.5'),
  ///   cacheDir: cacheDir,
  /// );
  /// final db = await KmdbDatabase.open(
  ///   path: '/path/to/db',
  ///   adapter: adapter,
  ///   vecIndexes: [...],
  ///   embeddingModel: model,
  /// );
  /// final rebuilt = await db.reindex();
  /// print('Rebuilt $rebuilt vector index(es).');
  /// ```
  Future<int> reindex() async {
    final vec = _vecManager;
    if (vec == null) return 0;
    return vec.reindex();
  }

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

  /// The active encryption provider, or `null` for plaintext databases.
  ///
  /// [KmdbCollection] uses this to thread encryption through all
  /// [ValueCodec] encode/decode calls. Never expose the raw DEK — only
  /// the provider is accessible here.
  EncryptionProvider? get encryption => _encryption;

  // ── Passphrase management ───────────────────────────────────────────────────

  /// Changes the passphrase for an encrypted database.
  ///
  /// This re-wraps the existing DEK under a new passphrase KEK, then
  /// atomically replaces the `enc:blob` in `$meta` with the updated wrapped
  /// DEK. The DEK itself is unchanged: all existing data remains valid.
  ///
  /// [currentConfig] must successfully unlock the existing `enc:blob`
  /// (passphrase or recovery code). [newPassphrase] is the replacement
  /// passphrase; a new Argon2id salt is generated for it.
  ///
  /// Throws [StateError] if the database is not encrypted.
  /// Throws [EncryptionError.badCredentials] if [currentConfig] does not
  /// unlock the existing blob.
  ///
  /// On success, the in-memory [DekCache] in [currentConfig] is updated with
  /// the DEK (so it can be reused without re-running Argon2id).
  ///
  /// Example:
  /// ```dart
  /// await db.changePassphrase(
  ///   currentConfig: EncryptionConfig(passphrase: 'old-passphrase'),
  ///   newPassphrase: 'new-passphrase',
  /// );
  /// ```
  Future<void> changePassphrase({
    required EncryptionConfig currentConfig,
    required String newPassphrase,
  }) async {
    final existingBlob = await _store.meta.getEncryptionBlob();
    if (existingBlob == null) {
      throw StateError(
        'changePassphrase called on a plaintext (unencrypted) database.',
      );
    }

    // Step 1: Unwrap the DEK using the current credentials.
    Uint8List? dek = await currentConfig.tryUnwrapWithPassphrase(
      existingBlob.wrappedDekPassphrase,
      existingBlob.argon2Salt,
    );
    dek ??= await currentConfig.tryUnwrapWithRecovery(
      existingBlob.wrappedDekRecovery,
    );
    if (dek == null) {
      throw EncryptionError.badCredentials();
    }

    // Step 2: Generate a new Argon2id salt for the new passphrase.
    // The recovery-KEK-wrapped DEK is re-wrapped under the existing recovery
    // entropy (the recovery code stays the same to avoid requiring the user to
    // record a new mnemonic). Only the passphrase is changed.
    final newSalt = await KeyDerivation.generateSalt();
    final newPassphraseConfig = EncryptionConfig(passphrase: newPassphrase);
    final newWrappedDekPassphrase = await newPassphraseConfig
        .wrapDekWithPassphrase(dek, newSalt);

    // Re-wrap under the existing recovery KEK. We cannot derive the original
    // recovery entropy from the blob alone, so we must re-wrap from the current
    // blob's recovery-wrapped DEK using the current credentials.
    // Strategy: unwrap the recovery-wrapped DEK and re-wrap it under the same
    // recovery KEK. Since we already have the DEK, we just re-wrap it with a
    // freshly-derived recovery KEK from the same entropy.
    // The recovery blob is unchanged — we re-wrap the DEK under the same
    // recovery KEK. The existing wrappedDekRecovery has the recovery entropy
    // encoded in it, but we don't need to know the entropy directly: we just
    // keep the existing wrappedDekRecovery as-is (the recovery code hasn't
    // changed, so the same recovery KEK will still unwrap it).
    //
    // The updated blob:
    // - New Argon2id salt (invalidates the old passphrase KEK derivation).
    // - New wrappedDekPassphrase (re-wrapped under the new passphrase + new salt).
    // - Same wrappedDekRecovery (recovery code and entropy unchanged).
    final updatedBlob = EncryptionBlob(
      argon2Salt: newSalt,
      wrappedDekPassphrase: newWrappedDekPassphrase,
      wrappedDekRecovery: existingBlob.wrappedDekRecovery,
      argon2Memory: existingBlob.argon2Memory,
      argon2Iterations: existingBlob.argon2Iterations,
      argon2Parallelism: existingBlob.argon2Parallelism,
    );

    // Step 3: Write the updated blob durably.
    await _store.meta.putEncryptionBlob(updatedBlob);

    // Clear the old cached DEK (it was valid under the old passphrase KEK but
    // the dbId key is unchanged — a FlutterSecureDekCache keyed by dbId would
    // still serve the DEK, but we overwrite it to ensure freshness).
    final info = await _store.storeInfo();
    await currentConfig.dekCache.clear(info.dbDir);
    // Cache the DEK under the new config so future opens don't re-prompt.
    await newPassphraseConfig.dekCache.store(info.dbDir, dek);
  }

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
  /// supplies the internal `MetaStore` automatically. After a successful call,
  /// every subsequent write to [collection] is validated against [schema].
  ///
  /// Use this method from outside the `kmdb` package (e.g. CLI commands) to
  /// avoid direct access to the package-private `MetaStore`.
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
  /// supplies the internal `MetaStore` automatically. After a successful call,
  /// writes to [collection] are no longer validated. Deregistering an unknown
  /// collection is a no-op.
  ///
  /// Use this method from outside the `kmdb` package (e.g. CLI commands) to
  /// avoid direct access to the package-private `MetaStore`.
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
