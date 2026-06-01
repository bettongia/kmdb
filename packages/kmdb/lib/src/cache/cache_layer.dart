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

import 'dart:async';
import 'dart:typed_data';

import '../engine/compaction/reclamation_policy.dart'
    show ReclamationPolicyRegistry;
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/meta_store.dart';
import '../engine/util/hlc.dart';
import 'cache_tier.dart';
import 'session_cache.dart';

/// Wraps a [KvStore] with a session object cache and namespace-generation-based
/// invalidation.
///
/// ## Session cache
///
/// [CacheLayer.get] checks the in-memory [SessionCache] before calling the
/// underlying [KvStore.get]. On a cache hit the raw bytes are returned without
/// a disk read. On a miss the bytes are fetched, cached, and returned.
///
/// The session cache capacity is determined by [CacheTier]:
/// - Desktop: 2,000 objects
/// - Mobile / Web: 256 objects
///
/// ## Invalidation
///
/// [CacheLayer] subscribes to [KvStore.writeEvents]. On each emission:
///
/// 1. The current generation counter for the affected namespace is read from
///    `$meta`.
/// 2. All session cache entries for that namespace whose generation does not
///    match the new counter are evicted proactively.
///
/// Because the generation counter is part of the cache key, stale entries that
/// are not evicted proactively will simply never match on the next [get] call
/// and will age out of the LRU naturally.
///
/// ## Lifecycle
///
/// Call [onResume] when the app returns to the foreground (mobile/web) to check
/// whether any namespace generation counters advanced while the app was
/// suspended (e.g. by a background sync). Stale entries are evicted before the
/// first UI read.
///
/// Call [close] to cancel the write-event subscription and close the underlying
/// store.
///
/// ## Example
///
/// ```dart
/// final (store, result) = await KvStoreImpl.open('/db', adapter);
/// final cache = CacheLayer(store: store);
/// final bytes = await cache.get('tasks', keyHex); // fetched + cached
/// final bytes2 = await cache.get('tasks', keyHex); // served from cache
/// await cache.close();
/// ```
final class CacheLayer implements KvStore {
  /// Creates a [CacheLayer] wrapping [_store].
  ///
  /// [tier] defaults to [detectCacheTier]. [maxObjects] overrides the
  /// tier-derived session cache capacity.
  CacheLayer({required this._store, CacheTier? tier, int? maxObjects})
    : _tier = tier ?? detectCacheTier(),
      _cache = SessionCache(
        maxObjects: maxObjects ?? (tier ?? detectCacheTier()).maxSessionObjects,
      ) {
    _writeEventSub = _store.writeEvents.listen(_onWriteEvent);
  }

  final KvStore _store;
  final CacheTier _tier;
  final SessionCache _cache;
  late final StreamSubscription<String> _writeEventSub;

  /// The platform tier used by this cache.
  CacheTier get tier => _tier;

  /// Current session cache size (number of entries held).
  int get cachedObjectCount => _cache.length;

  // ── KvStore — write path (delegates straight through) ─────────────────────

  @override
  Future<void> put(String namespace, String key, Uint8List value) =>
      _store.put(namespace, key, value);

  @override
  Future<void> delete(String namespace, String key) =>
      _store.delete(namespace, key);

  @override
  Future<void> writeBatch(WriteBatch batch) => _store.writeBatch(batch);

  // ── KvStore — read path (cache-aware) ─────────────────────────────────────

  /// Returns the raw bytes for (namespace, key), using the session cache.
  ///
  /// Lookup order:
  /// 1. Read the current generation counter from `$meta`.
  /// 2. Check the session cache — return immediately on a hit.
  /// 3. Fetch from [KvStore].
  /// 4. Cache the result (even `null` is not cached — absence is not tracked).
  /// 5. Return the bytes.
  @override
  Future<Uint8List?> get(String namespace, String key) async {
    final gen = await _readGeneration(namespace);
    final cached = _cache.get(namespace, key, gen);
    if (cached != null) return cached;

    final bytes = await _store.get(namespace, key);
    if (bytes != null) {
      _cache.put(namespace, key, gen, bytes);
    }
    return bytes;
  }

  /// Scans [namespace] for keys in [[startKey], [endKey]].
  ///
  /// Scan results are not materialised in the session cache at this layer.
  /// Materialised view caching (spec §15.3) — persisting frequent scan results
  /// as CBOR-encoded key lists in the `$cache` system namespace — is handled by
  /// the Query Layer (Phase 7, `KmdbQuery`), which has knowledge of the query
  /// parameters needed to form a stable cache key.
  @override
  Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey}) =>
      _store.scan(namespace, startKey: startKey, endKey: endKey);

  // ── KvStore — misc ─────────────────────────────────────────────────────────

  @override
  Future<void> flush() => _store.flush();

  @override
  Future<void> compactAll() => _store.compactAll();

  @override
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider) =>
      _store.setTombstoneHorizonProvider(provider);

  @override
  void setVersionDropCallback(
    Future<void> Function(List<Uint8List> droppedValues)? callback,
  ) => _store.setVersionDropCallback(callback);

  @override
  void setVersionRegistryProvider(
    Future<ReclamationPolicyRegistry> Function()? provider,
  ) => _store.setVersionRegistryProvider(provider);

  @override
  Stream<VersionHistoryEntry> scanVersionHistory(
    String namespace,
    String docKey,
  ) => _store.scanVersionHistory(namespace, docKey);

  @override
  Future<void> resetTombstoneFloor() => _store.resetTombstoneFloor();

  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) =>
      _store.ingestSstable(filename, bytes);

  @override
  Future<void> dropAllSstables() => _store.dropAllSstables();

  @override
  Future<List<String>> listNamespaces() => _store.listNamespaces();

  @override
  Future<bool> createNamespace(String namespace) =>
      _store.createNamespace(namespace);

  @override
  Future<StoreStats> stats() => _store.stats();

  @override
  Future<StoreInfo> storeInfo() => _store.storeInfo();

  @override
  Stream<String> get writeEvents => _store.writeEvents;

  /// Delegates device ID reassignment to the underlying store.
  ///
  /// The session cache does not embed the device ID, so no cache invalidation
  /// is needed — the rename affects only SSTable filenames and `$meta`.
  @override
  Future<void> reassignDeviceId(String newDeviceId) =>
      _store.reassignDeviceId(newDeviceId);

  /// Cancels the write-event subscription and closes the underlying store.
  @override
  Future<void> close({bool flush = true}) async {
    await _writeEventSub.cancel();
    await _store.close(flush: flush);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Checks all tracked namespaces for stale cache entries (spec §15.4).
  ///
  /// Call this when the app returns to the foreground (mobile / web) to
  /// proactively evict any entries that became stale while the process was
  /// suspended (e.g. by a background sync that incremented generation counters).
  /// On desktop this is a no-op because the process stays alive and receives
  /// write events continuously via [KvStore.writeEvents].
  ///
  /// In Flutter, wire this into `WidgetsBindingObserver.didChangeAppLifecycleState`:
  /// ```dart
  /// if (state == AppLifecycleState.resumed) db.onResume();
  /// ```
  Future<void> onResume() async {
    if (_tier == CacheTier.desktop) return; // in-memory is always fresh

    final namespaces = _trackedNamespaces.toList();
    for (final ns in namespaces) {
      final gen = await _readGeneration(ns);
      _cache.evictNamespace(ns, gen);
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  /// Namespaces that have been accessed via [get] this session.
  ///
  /// Used by [onResume] to know which generation counters to check.
  final _trackedNamespaces = <String>{};

  /// Handles a [KvStore.writeEvents] emission.
  ///
  /// Reads the new generation for the affected namespace and proactively evicts
  /// stale session cache entries.
  void _onWriteEvent(String namespace) {
    // System namespace writes (e.g. '$sync', '$meta') don't have user-facing
    // cached data — skip them.
    if (namespace.startsWith(r'$')) return;

    // Fire-and-forget: we don't await the generation read inside a sync
    // listener. The proactive eviction races with the next get(), but the
    // generation-check in get() ensures correctness regardless of order.
    _readGeneration(namespace).then((gen) {
      _cache.evictNamespace(namespace, gen);
    });
  }

  /// Reads the generation counter for [namespace] from `$meta`.
  ///
  /// Returns 0 if no counter has been written yet (namespace is empty).
  Future<int> _readGeneration(String namespace) async {
    _trackedNamespaces.add(namespace);
    final bytes = await _store.get(
      MetaStore.kNamespace,
      MetaStore.genKey(namespace),
    );
    if (bytes == null || bytes.length < 8) return 0;
    return ByteData.sublistView(bytes).getUint64(0, Endian.big);
  }
}
