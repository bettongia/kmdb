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

/// Tests for [TableCache].
///
/// Verifies:
///   - Reader reuse: N reads of the same file open it exactly once.
///   - Invalidation: [TableCache.evict] forces a re-open on the next call.
///   - Clear: [TableCache.clear] drops all entries.
///   - LRU bound: with more files than capacity the LRU entry is evicted and
///     reads remain correct.
///   - Prefix eviction: [TableCache.evictByPrefix] evicts all matching paths.
///   - Error propagation: a missing file throws [StorageException] and is not
///     cached.
///   - Corruption propagation: a corrupt SSTable throws
///     [CorruptedSstableException] and is not cached.
///
/// End-to-end cache integration (reader reuse through LsmEngine._openReader)
/// is covered by [table_cache_integration_test.dart].
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/sstable/table_cache.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// A [StorageAdapter] wrapper that counts the number of [fileSize] calls,
/// which is the first I/O call [SstableReader.open] makes. By counting these
/// we can verify that the cache avoids repeated opens of the same file.
final class _CountingAdapter implements StorageAdapter {
  _CountingAdapter(this._inner);

  final StorageAdapter _inner;

  /// Number of times [fileSize] has been called on any path.
  ///
  /// [SstableReader.open] always calls [fileSize] first, so this equals the
  /// number of fresh open attempts.
  int openAttempts = 0;

  @override
  Future<int> fileSize(String path) {
    openAttempts++;
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

/// Builds a minimal valid SSTable with [count] entries at [path] on [adapter].
Future<void> _writeSst(
  StorageAdapter adapter,
  String path, {
  int count = 2,
  int basePhysical = 1000,
}) async {
  final writer = SstableWriter();
  for (var i = 0; i < count; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    // Construct a valid internal key for namespace 'ns' with a unique user key.
    final hexKey =
        '${i.toRadixString(16).padLeft(12, '0')}70008${i.toRadixString(16).padLeft(15, '0')}';
    final keyBytes = KeyCodec.keyToBytes(hexKey);
    final internalKey = KeyCodec.encodeInternalKey(
      'ns',
      keyBytes,
      hlc,
      RecordType.put,
    );
    writer.add(internalKey, Uint8List.fromList([i + 1]));
  }
  await adapter.writeFile(path, writer.finish());
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('TableCache', () {
    group('reader reuse', () {
      test(
        'opening the same path twice returns the identical reader',
        () async {
          final adapter = _CountingAdapter(MemoryStorageAdapter());
          const path = '/sst/test.sst';
          await _writeSst(adapter, path);

          final cache = TableCache(capacity: 8);

          final r1 = await cache.open(path, adapter);
          final r2 = await cache.open(path, adapter);

          // The same reader instance is returned on the second call.
          expect(identical(r1, r2), isTrue);
          // The underlying adapter was only contacted once (on the first open).
          expect(adapter.openAttempts, equals(1));
        },
      );

      test(
        'N reads of the same file open the underlying file exactly once',
        () async {
          final adapter = _CountingAdapter(MemoryStorageAdapter());
          const path = '/sst/file.sst';
          await _writeSst(adapter, path);

          final cache = TableCache(capacity: 8);

          // Open the same file 10 times.
          for (var i = 0; i < 10; i++) {
            await cache.open(path, adapter);
          }

          expect(adapter.openAttempts, equals(1));
        },
      );

      test('different paths each open their file once', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        const p1 = '/sst/a.sst';
        const p2 = '/sst/b.sst';
        await _writeSst(adapter, p1, basePhysical: 100);
        await _writeSst(adapter, p2, basePhysical: 200);

        final cache = TableCache(capacity: 8);

        // Open each file twice.
        await cache.open(p1, adapter);
        await cache.open(p2, adapter);
        await cache.open(p1, adapter);
        await cache.open(p2, adapter);

        // Two files, each opened once.
        expect(adapter.openAttempts, equals(2));
      });
    });

    group('invalidation', () {
      test('evict forces a re-open on the next call', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        const path = '/sst/file.sst';
        await _writeSst(adapter, path);

        final cache = TableCache(capacity: 8);

        await cache.open(path, adapter); // open #1
        cache.evict(path);
        await cache.open(path, adapter); // open #2 (cache miss after evict)

        expect(adapter.openAttempts, equals(2));
      });

      test('evict of an absent path is a no-op', () {
        final cache = TableCache(capacity: 8);
        // Should not throw.
        expect(() => cache.evict('/sst/nonexistent.sst'), returnsNormally);
      });

      test('clear removes all entries', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        const p1 = '/sst/a.sst';
        const p2 = '/sst/b.sst';
        await _writeSst(adapter, p1, basePhysical: 100);
        await _writeSst(adapter, p2, basePhysical: 200);

        final cache = TableCache(capacity: 8);

        await cache.open(p1, adapter);
        await cache.open(p2, adapter);
        expect(cache.length, equals(2));

        cache.clear();
        expect(cache.length, equals(0));

        // Re-opening after clear re-reads from disk.
        await cache.open(p1, adapter);
        await cache.open(p2, adapter);
        expect(adapter.openAttempts, equals(4)); // 2 + 2 after clear
      });

      test('evictByPrefix evicts all matching paths', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        const p1 = '/db/sst/dev1-100-200.sst';
        const p2 = '/db/sst/dev1-201-300.sst';
        const p3 = '/db/sst/dev2-100-200.sst';
        await _writeSst(adapter, p1, basePhysical: 100);
        await _writeSst(adapter, p2, basePhysical: 200);
        await _writeSst(adapter, p3, basePhysical: 300);

        final cache = TableCache(capacity: 8);
        await cache.open(p1, adapter);
        await cache.open(p2, adapter);
        await cache.open(p3, adapter);
        expect(cache.length, equals(3));

        // Evict all dev1 files.
        cache.evictByPrefix('/db/sst/dev1-');
        expect(cache.length, equals(1));

        // Re-opening dev1 files hits the adapter; dev2 is still cached.
        await cache.open(p1, adapter);
        await cache.open(p2, adapter);
        await cache.open(p3, adapter);
        // 3 original opens + 2 re-opens (p1, p2).
        expect(adapter.openAttempts, equals(5));
      });
    });

    group('LRU bound', () {
      test('LRU entry is evicted when capacity is exceeded', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());

        // Build 3 unique SSTable files.
        const paths = ['/sst/a.sst', '/sst/b.sst', '/sst/c.sst'];
        for (var i = 0; i < paths.length; i++) {
          await _writeSst(adapter, paths[i], basePhysical: (i + 1) * 100);
        }

        // Capacity of 2: after all 3 are opened sequentially, each insertion
        // of the next file evicts the LRU of the previous two. With 3 files
        // and capacity 2, no file can stay cached while all 3 are opened in
        // sequence — each open ends up being a cache miss.
        //
        // Access trace (LRU = head):
        //   open(a) → [a]              attempts: 1
        //   open(b) → [a,b]            attempts: 2
        //   open(c) → [b,c] evicts a   attempts: 3
        //   open(a) → [c,a] evicts b   attempts: 4
        //   open(b) → [a,b] evicts c   attempts: 5
        //   open(c) → [b,c] evicts a   attempts: 6
        final cache = TableCache(capacity: 2);

        await cache.open(paths[0], adapter); // attempts: 1
        await cache.open(paths[1], adapter); // attempts: 2
        await cache.open(paths[2], adapter); // attempts: 3, evicts a
        expect(cache.length, equals(2));

        // Each subsequent open is also a cache miss for this 3-file / cap-2 scenario.
        await cache.open(paths[0], adapter); // attempts: 4, evicts b
        await cache.open(paths[1], adapter); // attempts: 5, evicts c
        await cache.open(paths[2], adapter); // attempts: 6, evicts a
        expect(adapter.openAttempts, equals(6));
      });

      test('get promotes LRU entry to MRU position', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());

        const paths = ['/sst/a.sst', '/sst/b.sst', '/sst/c.sst'];
        for (var i = 0; i < paths.length; i++) {
          await _writeSst(adapter, paths[i], basePhysical: (i + 1) * 100);
        }

        final cache = TableCache(capacity: 2);

        await cache.open(paths[0], adapter); // cache: [a]
        await cache.open(paths[1], adapter); // cache: [a, b]
        // Promote 'a' to MRU — 'b' is now LRU.
        await cache.open(paths[0], adapter); // no-op open, promotes a
        await cache.open(paths[2], adapter); // cache: [a, c], evicts b
        expect(cache.length, equals(2));

        // 'a' should still be cached; 'b' evicted.
        await cache.open(paths[0], adapter); // cached — no new open
        await cache.open(paths[1], adapter); // evicted — opens again
        // Initial: 2 opens for a,b; +1 for c; +1 re-open for b = 4.
        expect(adapter.openAttempts, equals(4));
      });

      test('reads remain correct regardless of eviction', () async {
        // Verifies that eviction does not corrupt data — reads after eviction
        // correctly open fresh readers from disk.
        final inner = MemoryStorageAdapter();
        final writer = SstableWriter();
        final hlc = const Hlc(1000, 0);
        final hexKey = '${'0'.padLeft(12, '0')}70008${'a'.padLeft(15, '0')}';
        final keyBytes = KeyCodec.keyToBytes(hexKey);
        final internalKey = KeyCodec.encodeInternalKey(
          'ns',
          keyBytes,
          hlc,
          RecordType.put,
        );
        writer.add(internalKey, Uint8List.fromList([99]));
        const path = '/sst/data.sst';
        await inner.writeFile(path, writer.finish());

        final cache = TableCache(capacity: 1);
        final adapter = _CountingAdapter(inner);

        // Fill cache with a different file (forces data.sst out).
        const other = '/sst/other.sst';
        await _writeSst(adapter, other, basePhysical: 2000);
        await cache.open(path, adapter); // caches data.sst
        await cache.open(other, adapter); // evicts data.sst, caches other.sst

        // Read from data.sst — re-opens from disk after eviction.
        final reader = await cache.open(path, adapter);
        final value = await reader.get(internalKey);
        expect(value, equals(Uint8List.fromList([99])));
      });
    });

    group('capacity', () {
      test('capacity is reported correctly', () {
        final cache = TableCache(capacity: 42);
        expect(cache.capacity, equals(42));
      });

      test('initial length is 0', () {
        final cache = TableCache(capacity: 8);
        expect(cache.length, equals(0));
      });
    });

    group('error handling', () {
      test('missing file throws StorageException and is not cached', () async {
        final adapter = _CountingAdapter(MemoryStorageAdapter());
        final cache = TableCache(capacity: 8);

        await expectLater(
          () => cache.open('/sst/nonexistent.sst', adapter),
          throwsA(isA<StorageException>()),
        );
        // The failed open must not be cached — length stays 0.
        expect(cache.length, equals(0));
      });

      test(
        'corrupt SSTable throws CorruptedSstableException and is not cached',
        () async {
          final inner = MemoryStorageAdapter();
          // Write garbage bytes (not a valid SSTable — too short / bad checksum).
          await inner.writeFile(
            '/sst/corrupt.sst',
            Uint8List.fromList(List.generate(64, (i) => i)),
          );
          final adapter = _CountingAdapter(inner);
          final cache = TableCache(capacity: 8);

          await expectLater(
            () => cache.open('/sst/corrupt.sst', adapter),
            throwsA(isA<CorruptedSstableException>()),
          );
          expect(cache.length, equals(0));
        },
      );
    });
  });
}
