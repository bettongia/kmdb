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

/// End-to-end integration tests for the [TableCache] wired into [LsmEngine].
///
/// These tests verify that:
///
/// 1. **Reader reuse**: repeated reads of the same SSTable pay the whole-file
///    hash cost at most once per process lifetime (file is opened once, then
///    served from the cache).
///
/// 2. **Post-compaction correctness**: after compaction removes files from the
///    level map and introduces replacements, reads correctly return values from
///    the new (post-compaction) files, not stale cached readers from old files.
///
/// 3. **Bound respected**: with [KvStoreConfig.tableCacheSize] set below the
///    number of SSTable files, LRU eviction kicks in and reads remain correct
///    (no data loss, no incorrect values).
///
/// 4. **Correctness preserved**: all existing read/scan semantics hold with the
///    table cache enabled.
///
/// Because [LsmEngine] is internal to `package:kmdb`, these tests use
/// [KvStoreImpl] (which wraps [LsmEngine]) and a [_CountingAdapter] to count
/// the number of [fileSize] calls that reach the adapter, which is the first
/// I/O call [SstableReader.open] makes.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A [StorageAdapter] that wraps another adapter and counts [fileSize] calls.
///
/// [SstableReader.open] always calls [fileSize] first (to validate the file
/// is large enough for a footer). Counting these tells us how many fresh reader
/// opens reached the adapter versus how many were served from the [TableCache].
final class _CountingAdapter implements StorageAdapter {
  _CountingAdapter(this._inner);

  final StorageAdapter _inner;

  /// Number of [fileSize] calls received from the SSTable layer.
  int fileSizeCalls = 0;

  /// [fileSize] calls on paths ending in `.sst` — isolates SSTable opens from
  /// WAL, Manifest, and LOCK file sizing that the engine also performs.
  int get sstOpenAttempts => _sstSizeCalls;
  int _sstSizeCalls = 0;

  @override
  Future<int> fileSize(String path) {
    fileSizeCalls++;
    if (path.endsWith('.sst')) _sstSizeCalls++;
    return _inner.fileSize(path);
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      _inner.readFileRange(path, offset, length);

  @override
  Future<void> writeFile(String path, Uint8List bytes) =>
      _inner.writeFile(path, bytes);

  @override
  Future<void> appendFile(String path, Uint8List bytes) =>
      _inner.appendFile(path, bytes);

  @override
  Future<void> deleteFile(String path) => _inner.deleteFile(path);

  @override
  Future<bool> fileExists(String path) => _inner.fileExists(path);

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) =>
      _inner.listFiles(dirPath, extension: extension);

  @override
  Future<Uint8List> readFile(String path) => _inner.readFile(path);

  @override
  Future<void> createDirectory(String dirPath) =>
      _inner.createDirectory(dirPath);

  @override
  Future<void> acquireLock(String path) => _inner.acquireLock(path);

  @override
  Future<void> releaseLock(String path) => _inner.releaseLock(path);

  @override
  Future<void> syncFile(String path) => _inner.syncFile(path);

  @override
  Future<void> syncDir(String path) => _inner.syncDir(path);

  @override
  Future<void> renameFile(String from, String to) =>
      _inner.renameFile(from, to);
}

const _dbDir = '/db';

/// Opens a [KvStoreImpl] against [adapter] with [config].
Future<KvStoreImpl> _open(
  StorageAdapter adapter, {
  KvStoreConfig? config,
}) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: config ?? KvStoreConfig.forTesting(),
    deviceId: 'testdev1',
  );
  return store;
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);
String _key(int n) => SequentialKeyGenerator(start: n).next();

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('TableCache integration — reader reuse', () {
    test(
      'repeated point reads of SSTable data do not re-open the file',
      () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        final store = await _open(adapter);

        // Write enough data to flush into an SSTable. The forTesting() config
        // has a 4 KiB memtable threshold.
        final k = _key(1);
        await store.put('ns', k, _bytes('hello'));
        await store.flush(); // forces data to L0 SSTable

        // Clear the counter after setup so we only measure reads.
        adapter._sstSizeCalls = 0;

        // First read: cold cache — opens the SSTable.
        await store.get('ns', k);
        final firstReadOpens = adapter.sstOpenAttempts;
        expect(firstReadOpens, equals(1));

        // Second and third reads: warm cache — no new fileSize calls.
        await store.get('ns', k);
        await store.get('ns', k);
        expect(adapter.sstOpenAttempts, equals(1));

        await store.close();
      },
    );

    test('repeated scan reads do not re-open the same SSTable file', () async {
      final adapter = _CountingAdapter(MemoryStorageAdapter());
      final store = await _open(adapter);

      for (var i = 1; i <= 3; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      await store.flush();

      adapter._sstSizeCalls = 0;

      // First scan: opens the SSTable.
      await store.scan('ns').toList();
      final firstScanOpens = adapter.sstOpenAttempts;
      expect(firstScanOpens, greaterThan(0));

      // Second scan: warm cache — same number of opens as first scan.
      await store.scan('ns').toList();
      expect(adapter.sstOpenAttempts, equals(firstScanOpens));

      await store.close();
    });
  });

  group('TableCache integration — post-compaction correctness', () {
    test('reads after compaction return values from the new SSTable', () async {
      // Use a config that forces compaction quickly.
      const config = KvStoreConfig(
        memtableSizeBytes: 4096,
        l0CompactionTrigger: 2,
        l1MaxBytes: 16 * 1024,
        l2MaxBytes: 64 * 1024,
        singleFileThresholdBytes: 8 * 1024,
        fsyncOnWrite: false,
        tableCacheSize: 16,
      );
      final adapter = _CountingAdapter(MemoryStorageAdapter());
      final store = await _open(adapter, config: config);

      // Write enough data for L0 → L1 compaction.
      final k1 = _key(1);
      final k2 = _key(2);
      await store.put('ns', k1, _bytes('v1-initial'));
      await store.flush();
      await store.put('ns', k2, _bytes('v2-initial'));
      await store.flush(); // triggers L0 compaction
      await store.compactAll();

      // Delete k1 — it ends up in a fresh L0 SSTable.
      await store.delete('ns', k1);
      await store.flush();

      // Overwrite k2 — also in a fresh L0 SSTable.
      await store.put('ns', k2, _bytes('v2-updated'));
      await store.flush();
      await store.compactAll();

      // Post-compaction reads must reflect the latest state.
      final r1 = await store.get('ns', k1);
      final r2 = await store.get('ns', k2);

      expect(r1, isNull, reason: 'k1 was deleted');
      expect(r2, equals(_bytes('v2-updated')));

      await store.close();
    });

    test(
      'after reassignDeviceId, reads succeed from renamed SSTables',
      () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        final store = await _open(adapter);

        final k = _key(1);
        await store.put('ns', k, _bytes('hello'));
        await store.flush();

        // Rename device — this should evict old-path cache entries.
        // Device ID must be exactly 8 lowercase hex characters.
        await store.reassignDeviceId('a1b2c3d4');

        adapter._sstSizeCalls = 0;

        // Read should open the renamed file (new path, not in cache).
        final result = await store.get('ns', k);
        expect(result, equals(_bytes('hello')));
        // The renamed file was re-opened (cache miss for the new path).
        expect(adapter.sstOpenAttempts, greaterThan(0));

        await store.close();
      },
    );

    test(
      'compaction that overwrites a file in-place evicts the stale cached reader',
      () async {
        // Regression test for the bug where an input file whose name is reused
        // as the compaction output was not evicted from the cache. This caused
        // reads to serve stale index/filter from the old file while the data
        // blocks on disk belonged to the new file — resulting in
        // CorruptedSstableException: Data block checksum mismatch.
        //
        // In-place overwrite happens when the compaction output's HLC range
        // exactly equals an input's range (same min/max HLC → same filename).
        // This is most reliably triggered via dropAllSstables + ingestSstable,
        // but the underlying invariant is tested here via normal put/compact.
        //
        // The correctness property: reads after any compaction must return
        // the value from the post-compaction state, never a corrupted value.
        const config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tableCacheSize: 64,
        );
        final store = await _open(MemoryStorageAdapter(), config: config);

        // Write several keys; force flush + compaction so the cache gets
        // populated with readers before the compaction runs again.
        final keys = List.generate(5, (i) => _key(i + 1));
        for (var i = 0; i < keys.length; i++) {
          await store.put('ns', keys[i], _bytes('v${i + 1}'));
        }
        await store.flush();
        await store.compactAll();

        // Verify correct values before the second round of compaction.
        for (var i = 0; i < keys.length; i++) {
          final r = await store.get('ns', keys[i]);
          expect(r, equals(_bytes('v${i + 1}')));
        }

        // Write more data and compact again. This may produce a compaction
        // output whose filename matches the existing L2 file (in-place overwrite).
        for (var i = 0; i < keys.length; i++) {
          await store.put('ns', keys[i], _bytes('updated-${i + 1}'));
        }
        await store.flush();
        await store.compactAll();

        // After the second compaction the in-place-updated values must be
        // returned correctly. If the stale cached reader was served this would
        // produce a CorruptedSstableException or wrong values.
        for (var i = 0; i < keys.length; i++) {
          final r = await store.get('ns', keys[i]);
          expect(
            r,
            equals(_bytes('updated-${i + 1}')),
            reason: 'key ${keys[i]} should have updated value',
          );
        }

        await store.close();
      },
    );
  });

  group('TableCache integration — LRU bound respected', () {
    test(
      'with tableCacheSize < number of SSTable files, reads remain correct',
      () async {
        // Very small cache: only 1 reader held at once.
        const config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 100, // disable auto-compaction
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tableCacheSize: 1,
        );
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        final store = await _open(adapter, config: config);

        // Write 3 separate flushes → 3 L0 SSTables.
        final keys = [_key(1), _key(2), _key(3)];
        for (var i = 0; i < 3; i++) {
          await store.put('ns', keys[i], _bytes('v${i + 1}'));
          await store.flush();
        }

        // With a cache of 1, reading all 3 must still yield correct values.
        // The LRU eviction replaces the cached reader each time, but reads
        // remain correct because a miss simply re-opens the file from disk.
        for (var i = 0; i < 3; i++) {
          final result = await store.get('ns', keys[i]);
          expect(
            result,
            equals(_bytes('v${i + 1}')),
            reason: 'Key ${keys[i]} should have value v${i + 1}',
          );
        }

        await store.close();
      },
    );
  });

  group('TableCache integration — config', () {
    test('tableCacheSize = 1 is accepted and functional', () async {
      const config = KvStoreConfig(
        memtableSizeBytes: 4096,
        l0CompactionTrigger: 2,
        l1MaxBytes: 16 * 1024,
        l2MaxBytes: 64 * 1024,
        singleFileThresholdBytes: 8 * 1024,
        fsyncOnWrite: false,
        tableCacheSize: 1,
      );
      final adapter = _CountingAdapter(MemoryStorageAdapter());
      final store = await _open(adapter, config: config);

      final k = _key(1);
      await store.put('ns', k, _bytes('ok'));
      await store.flush();
      expect(await store.get('ns', k), equals(_bytes('ok')));

      await store.close();
    });

    test('forTesting() defaults to tableCacheSize = 16', () {
      // Regression guard: forTesting() must not inadvertently get a giant
      // cache or a zero cache (which would panic).
      // ignore: prefer_const_constructors — factory cannot be const
      final config = KvStoreConfig.forTesting();
      expect(config.tableCacheSize, equals(16));
    });

    test('default config tableCacheSize is 256', () {
      const config = KvStoreConfig();
      expect(config.tableCacheSize, equals(256));
    });
  });
}
