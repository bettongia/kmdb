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

/// KMDB — a local-first document database for Dart and Flutter.
///
/// Provides a typed, reactive query API over an LSM storage engine with
/// multi-device sync via commodity cloud storage.
library;

// ── Storage engine (public surface) ──────────────────────────────────────────
export 'src/engine/kvstore/kv_store.dart'
    show
        KvStore,
        KvEntry,
        OpenResult,
        WriteBatch,
        BatchEntry,
        KvStoreConfig,
        StoreStats,
        StoreInfo;
export 'src/engine/kvstore/kv_store_impl.dart' show KvStoreImpl;
export 'src/engine/platform/storage_adapter_interface.dart'
    show StorageAdapter, StorageException, LockException;
export 'src/engine/wal/wal_exceptions.dart' show CorruptedWalException;
export 'src/engine/platform/storage_adapter_memory.dart'
    show MemoryStorageAdapter;
export 'src/engine/platform/storage_adapter_native.dart'
    show StorageAdapterNative;

// ── Sync ──────────────────────────────────────────────────────────────────────
export 'src/sync/sync_engine.dart' show SyncEngine;
export 'src/sync/consolidation_coordinator.dart' show ConsolidationCoordinator;
export 'src/sync/consolidation_config.dart' show ConsolidationConfig;
export 'src/sync/sync_storage_adapter.dart'
    show SyncStorageAdapter, LockConflictException;
export 'src/sync/local/memory_sync_adapter.dart' show MemorySyncAdapter;
export 'src/sync/local/local_directory_adapter_stub.dart'
    if (dart.library.io) 'src/sync/local/local_directory_adapter.dart'
    show LocalDirectoryAdapter;

// ── Value encoding ────────────────────────────────────────────────────────────
export 'src/encoding/value_codec.dart' show ValueCodec;
export 'src/engine/util/key_codec.dart' show KeyGenerator, UuidV7KeyGenerator;

// ── Cache ─────────────────────────────────────────────────────────────────────
export 'src/cache/cache_layer.dart' show CacheLayer;
export 'src/cache/cache_tier.dart' show CacheTier;

// ── Query layer ───────────────────────────────────────────────────────────────
export 'src/query/kmdb_codec.dart' show KmdbCodec;
export 'src/query/kmdb_database.dart' show KmdbDatabase;
export 'src/query/kmdb_collection.dart' show KmdbCollection;
export 'src/query/kmdb_query.dart' show KmdbQuery;
export 'src/query/exceptions.dart'
    show
        DocumentAlreadyExistsException,
        DocumentNotFoundException,
        IndexRebuildEvent,
        ReservedFieldException,
        ReservedIndexPathException,
        StaleIndexException;
export 'src/query/filter/filter.dart' show Filter;
export 'src/query/filter/field_filter.dart' show Field;
export 'src/query/filter/field_path.dart' show FieldPath, missing;
export 'src/query/index/index_definition.dart' show IndexDefinition;
export 'src/query/index/index_manager.dart'
    show IndexManager, IndexState, IndexStatus;

// ── Text search — shared foundations ─────────────────────────────────────────
export 'src/search/search_mode.dart' show SearchMode;
export 'src/search/search_result.dart'
    show SearchResult, SearchMetadata, SearchHit;
export 'src/search/embedding_model.dart' show EmbeddingModel;
export 'src/search/fts_index_definition.dart' show FtsIndexDefinition;
export 'src/search/vec_index_definition.dart' show VecIndexDefinition;
export 'src/search/sync_delta.dart' show SyncDelta, DeltaChangeType, DeltaEntry;

// ── Text search — lexical (BM25) ─────────────────────────────────────────────
export 'src/search/lexical/pipeline.dart'
    show tokeniseAndNormalise, filterStopWords, stem, preprocess;
export 'src/search/lexical/fts_index_state.dart'
    show FtsIndexStatus, FtsIndexState, kFtsTombstone;
export 'src/search/lexical/fts_manager.dart' show FtsManager;

// ── Text search — semantic (vector) ──────────────────────────────────────────
export 'src/search/semantic/vec_index_state.dart'
    show VecIndexStatus, VecIndexState;
export 'src/search/semantic/vec_manager.dart' show VecManager;

// ── Text search — hybrid (RRF) ────────────────────────────────────────────────
export 'src/search/hybrid/hybrid_manager.dart' show rrfScore, mergeWithRrf;

// ── Vault — content-addressable binary object store ───────────────────────────
export 'src/vault/vault_ref.dart' show VaultRef;
export 'src/vault/vault_manifest.dart' show VaultManifest;
export 'src/vault/vault_store.dart'
    show VaultStore, VaultCrcMismatchException, VaultObjectNotFoundException;
export 'src/vault/vault_gc.dart' show VaultGc;
export 'src/vault/vault_ref_interceptor.dart' show VaultRefInterceptor;
export 'src/vault/vault_package.dart'
    show VaultPackage, VaultPackageContents, VaultAttachment;
export 'src/vault/vault_recovery.dart' show kVaultNamespace;
export 'src/vault/vault_storage_adapter.dart' show VaultStorageAdapter;
export 'src/vault/local_directory_vault_adapter_stub.dart'
    if (dart.library.io) 'src/vault/local_directory_vault_adapter.dart'
    show LocalDirectoryVaultAdapter;
