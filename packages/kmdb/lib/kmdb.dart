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
    show KvStore, KvEntry, OpenResult, WriteBatch, BatchEntry, KvStoreConfig;
export 'src/engine/kvstore/kv_store_impl.dart' show KvStoreImpl;
export 'src/engine/platform/storage_adapter_interface.dart'
    show StorageAdapter, StorageException, LockException;
export 'src/engine/wal/wal_exceptions.dart' show CorruptedWalException;
export 'src/engine/platform/storage_adapter_memory.dart'
    show MemoryStorageAdapter;

// ── Sync ──────────────────────────────────────────────────────────────────────
export 'src/sync/sync_engine.dart' show SyncEngine;
export 'src/sync/consolidation_coordinator.dart' show ConsolidationCoordinator;
export 'src/sync/consolidation_config.dart' show ConsolidationConfig;
export 'src/sync/cloud/cloud_adapter.dart' show CloudAdapter, LockConflictException;
export 'src/sync/local/memory_sync_adapter.dart' show MemorySyncAdapter;

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
        StaleIndexException;
export 'src/query/filter/filter.dart' show Filter;
export 'src/query/filter/field_filter.dart' show Field;
export 'src/query/index/index_definition.dart' show IndexDefinition;
