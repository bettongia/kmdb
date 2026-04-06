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
import 'dart:typed_data';

import 'package:kmdb/src/cache/cache_layer.dart';
import 'package:kmdb/src/cache/cache_tier.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:test/test.dart';

// ── Counting KvStore wrapper ──────────────────────────────────────────────────

/// Wraps a [KvStore] and records how many times [get] is called.
final class _CountingStore implements KvStore {
  _CountingStore(this._inner);
  final KvStore _inner;
  int getCalls = 0;

  @override
  Future<void> put(String ns, String key, Uint8List value) =>
      _inner.put(ns, key, value);
  @override
  Future<void> delete(String ns, String key) => _inner.delete(ns, key);
  @override
  Future<void> writeBatch(WriteBatch batch) => _inner.writeBatch(batch);
  @override
  Future<Uint8List?> get(String ns, String key) {
    getCalls++;
    return _inner.get(ns, key);
  }

  @override
  Stream<KvEntry> scan(String ns, {String? startKey, String? endKey}) =>
      _inner.scan(ns, startKey: startKey, endKey: endKey);
  @override
  Future<void> flush() => _inner.flush();
  @override
  Future<void> compactAll() => _inner.compactAll();
  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) =>
      _inner.ingestSstable(filename, bytes);
  @override
  Future<List<String>> listNamespaces() => _inner.listNamespaces();
  @override
  Future<StoreStats> stats() => _inner.stats();
  @override
  Future<StoreInfo> storeInfo() => _inner.storeInfo();
  @override
  Stream<String> get writeEvents => _inner.writeEvents;
  @override
  Future<void> reassignDeviceId(String newDeviceId) =>
      _inner.reassignDeviceId(newDeviceId);
  @override
  Future<void> close({bool flush = true}) => _inner.close(flush: flush);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _b(int v) => Uint8List.fromList([v]);

int _dbCounter = 0;

Future<(KvStoreImpl, MemoryStorageAdapter)> _openStore() async {
  final adapter = MemoryStorageAdapter();
  final dir = '/db${_dbCounter++}';
  final (store, _) = await KvStoreImpl.open(dir, adapter);
  return (store, adapter);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('CacheLayer', () {
    late KvStoreImpl store;
    late _CountingStore counting;
    late CacheLayer cache;

    setUp(() async {
      final (s, _) = await _openStore();
      store = s;
      counting = _CountingStore(store);
      cache = CacheLayer(store: counting, tier: CacheTier.desktop);
    });

    tearDown(() => cache.close());

    // ── Cache hit / miss ────────────────────────────────────────────────────

    test('get returns null for absent key', () async {
      expect(
        await cache.get('tasks', '0000000000007000800000000000000a'),
        isNull,
      );
    });

    test('second get is served from cache without a KvStore call', () async {
      final key = '0000000000007000800000000000000a';
      await store.put('tasks', key, _b(1));

      counting.getCalls = 0;
      final first = await cache.get('tasks', key);
      expect(first, equals(_b(1)));
      final callsAfterFirst = counting.getCalls;

      counting.getCalls = 0;
      final second = await cache.get('tasks', key);
      expect(second, equals(_b(1)));

      // First call hits KvStore (and $meta for gen counter); second should
      // hit the session cache for the document itself — the only $meta reads
      // are for the generation counter.
      expect(callsAfterFirst, greaterThan(0)); // at least one $meta + one doc
      // After caching, the document get is skipped; only $meta gen is re-read.
      // getCalls for second = 1 ($meta gen read). For first = 2 ($meta + doc).
      expect(counting.getCalls, lessThan(callsAfterFirst));
    });

    test('write invalidates cache entry via generation counter', () async {
      final key = '0000000000007000800000000000000a';
      await store.put('tasks', key, _b(1));
      await cache.get('tasks', key); // prime cache

      // Write new value — generation increments, triggering write event
      await cache.put('tasks', key, _b(2));

      // Allow the async write-event handler to run
      await Future<void>.delayed(Duration.zero);

      final result = await cache.get('tasks', key);
      expect(result, equals(_b(2)));
    });

    test('cache stores value after first get', () async {
      final key = '0000000000007000800000000000000b';
      await store.put('notes', key, _b(7));

      expect(cache.cachedObjectCount, 0);
      await cache.get('notes', key);
      expect(cache.cachedObjectCount, greaterThan(0));
    });

    // ── Generation counter invalidation ─────────────────────────────────────

    test(
      'generation counter advances after put, stale entry not served',
      () async {
        final key = '0000000000007000800000000000000c';
        await store.put('ns', key, _b(1));
        await cache.get('ns', key); // gen=1 entry cached

        await cache.put('ns', key, _b(99)); // gen increments to 2
        await Future<void>.delayed(Duration.zero); // let write-event run

        final result = await cache.get('ns', key);
        expect(result, equals(_b(99)));
      },
    );

    test('delete removes value; cache returns null after delete', () async {
      final key = '0000000000007000800000000000000d';
      await cache.put('ns', key, _b(5));
      await Future<void>.delayed(Duration.zero);

      await cache.get('ns', key);
      await cache.delete('ns', key);
      await Future<void>.delayed(Duration.zero);

      expect(await cache.get('ns', key), isNull);
    });

    // ── LRU eviction ────────────────────────────────────────────────────────

    test('LRU eviction occurs when maxObjects is exceeded', () async {
      // Use its own store so closing tinyCache does not interfere with setUp.
      final (ownStore, _) = await _openStore();
      final ownCounting = _CountingStore(ownStore);
      final tinyCache = CacheLayer(
        store: ownCounting,
        tier: CacheTier.desktop,
        maxObjects: 2,
      );

      final k1 = '00000000000070008000000000000001';
      final k2 = '00000000000070008000000000000002';
      final k3 = '00000000000070008000000000000003';
      await ownStore.put('ns', k1, _b(1));
      await ownStore.put('ns', k2, _b(2));
      await ownStore.put('ns', k3, _b(3));

      await tinyCache.get('ns', k1); // cache: [k1]
      await tinyCache.get('ns', k2); // cache: [k1, k2] — full
      await tinyCache.get('ns', k3); // cache: [k2, k3] — k1 evicted

      // k1 should have been evicted — get() will re-fetch from KvStore
      ownCounting.getCalls = 0;
      await tinyCache.get('ns', k1);
      // getCalls > 1: $meta gen + doc (both needed because k1 not in cache)
      expect(ownCounting.getCalls, greaterThan(1));

      await tinyCache.close();
    });

    // ── Platform tier selection ─────────────────────────────────────────────

    test('desktop tier has maxSessionObjects=2000', () {
      expect(CacheTier.desktop.maxSessionObjects, 2000);
      expect(CacheTier.desktop.requiresPersistentCache, isFalse);
    });

    test('mobile tier has maxSessionObjects=256', () {
      expect(CacheTier.mobile.maxSessionObjects, 256);
      expect(CacheTier.mobile.requiresPersistentCache, isTrue);
    });

    test('web tier has maxSessionObjects=256', () {
      expect(CacheTier.web.maxSessionObjects, 256);
      expect(CacheTier.web.requiresPersistentCache, isTrue);
    });

    test('detectCacheTier returns desktop in test environment', () {
      expect(detectCacheTier(), CacheTier.desktop);
    });

    // ── onResume ─────────────────────────────────────────────────────────────

    test('onResume is no-op on desktop', () async {
      final key = '0000000000007000800000000000000e';
      await store.put('ns', key, _b(1));
      await cache.get('ns', key); // prime cache
      final countBefore = cache.cachedObjectCount;

      await cache.onResume(); // desktop — does nothing
      expect(cache.cachedObjectCount, countBefore);
    });

    test('onResume evicts stale entries on mobile tier', () async {
      // Use its own store so closing mobileCache does not interfere with setUp.
      final (ownStore, _) = await _openStore();
      final mobileCache = CacheLayer(store: ownStore, tier: CacheTier.mobile);

      final key = '0000000000007000800000000000000f';
      await ownStore.put('ns', key, _b(1));
      await mobileCache.get('ns', key); // prime cache at gen=1
      expect(mobileCache.cachedObjectCount, greaterThan(0));

      // Simulate a write that increments the generation (goes through ownStore
      // directly, so mobileCache's write-event listener fires).
      await ownStore.put('ns', key, _b(2));

      // Let the write event propagate
      await Future<void>.delayed(Duration.zero);

      // onResume re-checks generation and evicts stale entries
      await mobileCache.onResume();
      expect(mobileCache.cachedObjectCount, 0);

      final result = await mobileCache.get('ns', key);
      expect(result, equals(_b(2)));

      await mobileCache.close();
    });

    // ── scan pass-through ─────────────────────────────────────────────────────

    test('scan delegates to underlying KvStore', () async {
      final k1 = '0000000000007000800000000000000a';
      final k2 = '0000000000007000800000000000000b';
      await store.put('ns', k1, _b(1));
      await store.put('ns', k2, _b(2));

      final entries = await cache.scan('ns').toList();
      expect(entries.length, 2);
      expect(entries.map((e) => e.key), containsAll([k1, k2]));
    });

    // ── writeBatch ────────────────────────────────────────────────────────────

    test('writeBatch delegates to underlying store', () async {
      final k1 = '00000000000070008000000000000001';
      final k2 = '00000000000070008000000000000002';
      await cache.writeBatch(
        WriteBatch()
          ..put('ns', k1, _b(10))
          ..put('ns', k2, _b(20)),
      );

      await Future<void>.delayed(Duration.zero);
      expect(await cache.get('ns', k1), equals(_b(10)));
      expect(await cache.get('ns', k2), equals(_b(20)));
    });
  });
}
