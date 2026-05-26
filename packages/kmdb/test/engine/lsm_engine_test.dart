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

import 'package:kmdb/src/engine/kvstore/crash_recovery.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/hlc_clock.dart';
import 'package:test/test.dart';

const _dbDir = '/db';

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

Future<(KvStoreImpl, OpenResult)> _open(
  MemoryStorageAdapter adapter, {
  KvStoreConfig? config,
}) => KvStoreImpl.open(
  _dbDir,
  adapter,
  config: config ?? KvStoreConfig.forTesting(),
  deviceId: 'testdev1',
);

/// Opens a [KvStoreImpl] with [clock] injected via [CrashRecovery] so that
/// the wall clock seen by [LsmEngine] is fully deterministic.
Future<KvStoreImpl> openWithClock(
  MemoryStorageAdapter adapter,
  HlcClock clock,
) async {
  final config = KvStoreConfig.forTesting();
  final recovery = CrashRecovery(adapter: adapter, config: config);
  final (engine, recoveryResult) = await recovery.open(
    _dbDir,
    deviceId: 'testdev1',
    clock: clock,
  );
  final meta = MetaStore(engine);
  final hadUnclosedSession = await meta.getDirtyFlag();
  return KvStoreImpl.forTesting(
    engine,
    meta,
    config,
    dirtyFlagPresent: hadUnclosedSession || recoveryResult.hadInterruptedWrites,
  );
}

/// Builds a minimal valid SSTable in memory with [count] entries whose HLC
/// physical component starts at [basePhysical].
Uint8List buildSst({int count = 2, required int basePhysical}) {
  final writer = SstableWriter();
  for (var i = 0; i < count; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    final keyHex =
        '${i.toRadixString(16).padLeft(12, '0')}70008${i.toRadixString(16).padLeft(15, '0')}';
    final keyBytes = KeyCodec.keyToBytes(keyHex);
    final internalKey = KeyCodec.encodeInternalKey(
      'ns',
      keyBytes,
      hlc,
      RecordType.put,
    );
    writer.add(internalKey, Uint8List.fromList([i + 1]));
  }
  return writer.finish();
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _key(int n) => SequentialKeyGenerator(start: n).next();

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('LsmEngine — basic reads and writes', () {
    test('put and get a single value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('tasks', key, _bytes('hello'));
      final result = await store.get('tasks', key);
      expect(result, equals(_bytes('hello')));
      await store.close();
    });

    test('get returns null for missing key', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final result = await store.get('tasks', _key(1));
      expect(result, isNull);
      await store.close();
    });

    test('delete writes tombstone — get returns null', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('tasks', key, _bytes('data'));
      await store.delete('tasks', key);
      final result = await store.get('tasks', key);
      expect(result, isNull);
      await store.close();
    });

    test('overwrite returns new value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.put('ns', key, _bytes('v2'));
      final result = await store.get('ns', key);
      expect(result, equals(_bytes('v2')));
      await store.close();
    });

    test('keys in different namespaces are isolated', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns1', key, _bytes('ns1-val'));
      await store.put('ns2', key, _bytes('ns2-val'));
      expect(await store.get('ns1', key), equals(_bytes('ns1-val')));
      expect(await store.get('ns2', key), equals(_bytes('ns2-val')));
      await store.close();
    });

    test('writeBatch commits multiple entries atomically', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()
        ..put('ns', _key(1), _bytes('a'))
        ..put('ns', _key(2), _bytes('b'))
        ..put('ns', _key(3), _bytes('c'));
      await store.writeBatch(batch);
      expect(await store.get('ns', _key(1)), equals(_bytes('a')));
      expect(await store.get('ns', _key(2)), equals(_bytes('b')));
      expect(await store.get('ns', _key(3)), equals(_bytes('c')));
      await store.close();
    });
  });

  group('LsmEngine — scan', () {
    test('scan all keys in namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns').toList();
      expect(entries.length, equals(5));
      // Keys are UUIDv7-like but sequential, so they should be in order.
      final keys = entries.map((e) => e.key).toList();
      for (var i = 0; i < keys.length - 1; i++) {
        expect(keys[i].compareTo(keys[i + 1]), lessThan(0));
      }
      await store.close();
    });

    test('scan suppresses tombstones', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v1'));
      await store.put('ns', _key(2), _bytes('v2'));
      await store.delete('ns', _key(1));
      final entries = await store.scan('ns').toList();
      expect(entries.length, equals(1));
      expect(entries.first.key, equals(_key(2)));
      await store.close();
    });

    test('scan with startKey is inclusive', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns', startKey: _key(2)).toList();
      final keys = entries.map((e) => e.key).toList();
      expect(keys, contains(_key(2)));
      expect(keys, isNot(contains(_key(0))));
      expect(keys, isNot(contains(_key(1))));
      await store.close();
    });

    test('scan with endKey is exclusive', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns', endKey: _key(3)).toList();
      final keys = entries.map((e) => e.key).toList();
      expect(keys, isNot(contains(_key(3))));
      expect(keys, isNot(contains(_key(4))));
      await store.close();
    });

    test('scan returns empty stream for empty namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final entries = await store.scan('empty').toList();
      expect(entries, isEmpty);
      await store.close();
    });
  });

  group('LsmEngine — flush and SSTable reads', () {
    test('values survive explicit flush', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('persistent'));
      await store.flush();
      // Value should now be in the SSTable, not memtable.
      final result = await store.get('ns', key);
      expect(result, equals(_bytes('persistent')));
      await store.close();
    });

    test('delete tombstone visible after flush', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.flush();
      await store.delete('ns', key);
      expect(await store.get('ns', key), isNull);
      await store.close();
    });

    test('automatic flush fires when memtable exceeds threshold', () async {
      final adapter = _newAdapter();
      // forTesting() has a 4KB threshold.
      final (store, _) = await _open(adapter);
      // Write enough data to exceed the 4KB memtable threshold.
      final bigVal = Uint8List(1024);
      for (var i = 0; i < 6; i++) {
        await store.put('ns', _key(i), bigVal);
      }
      // At least one SSTable should have been flushed.
      final sstFiles = await adapter.listFiles('/db/sst', extension: '.sst');
      expect(sstFiles, isNotEmpty);
      await store.close();
    });
  });

  group('LsmEngine — compaction', () {
    test('compactAll reduces L0 to 0 files when data fits in one L2', () async {
      final adapter = _newAdapter();
      final config = KvStoreConfig.forTesting();
      final (store, _) = await _open(adapter, config: config);

      for (var i = 0; i < 10; i++) {
        await store.put('ns', _key(i), _bytes('value-$i'));
      }
      await store.flush();
      await store.compactAll();

      // After compactAll, L0 should be empty.
      final l0Files = adapter.files.keys
          .where((k) => k.endsWith('.sst'))
          .toList();
      // All data should be in a single consolidated SSTable.
      expect(l0Files.length, lessThanOrEqualTo(1));
      await store.close();
    });

    test('values readable after compaction', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      await store.flush();
      await store.compactAll();
      for (var i = 0; i < 5; i++) {
        final val = await store.get('ns', _key(i));
        expect(val, equals(_bytes('v$i')));
      }
      await store.close();
    });

    test('tombstones retained during compaction (not yet at L2 GC)', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.flush();
      await store.delete('ns', key);
      await store.flush();
      await store.compactAll();
      expect(await store.get('ns', key), isNull);
      await store.close();
    });

    test(
      'H4 PR1: overwrites are collapsed by compaction — repeated writes to '
      'one key end up as a single SSTable entry; reads return the newest',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);

        // Overwrite the same key many times across several flush boundaries.
        // Without PR1's collapse, the post-compaction SSTable would carry
        // every version of `key`; with collapse it carries exactly one.
        final key = _key(0);
        for (var i = 0; i < 20; i++) {
          await store.put('ns', key, _bytes('v$i'));
          if (i % 4 == 3) await store.flush();
        }
        await store.flush();
        await store.compactAll();

        // Reading must still return the latest value.
        expect(await store.get('ns', key), equals(_bytes('v19')));

        // Inspect on-disk SSTables: across all of them, exactly one stored
        // entry should reference this user key (no superseded versions left
        // behind by collapse).
        final sstPaths = adapter.files.keys
            .where((k) => k.endsWith('.sst'))
            .toList();
        expect(sstPaths, isNotEmpty);

        final keyBytes = KeyCodec.keyToBytes(key);
        var matching = 0;
        for (final path in sstPaths) {
          final reader = await SstableReader.open(path, adapter);
          await for (final entry in reader.scan()) {
            final entryKey = KeyCodec.decodeUserKey(entry.key);
            if (_bytesEqual(entryKey, keyBytes)) matching++;
          }
        }
        expect(matching, equals(1));

        await store.close();
      },
    );
  });

  group('LsmEngine — writeEvents', () {
    test('writeEvents fires namespace after put', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final emitted = <String>[];
      store.writeEvents.listen(emitted.add);
      await store.put('tasks', _key(1), _bytes('x'));
      expect(emitted, contains('tasks'));
      await store.close();
    });

    test('writeEvents fires all namespaces in writeBatch', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final emitted = <String>[];
      store.writeEvents.listen(emitted.add);
      final batch = WriteBatch()
        ..put('ns1', _key(1), _bytes('a'))
        ..put('ns2', _key(2), _bytes('b'));
      await store.writeBatch(batch);
      expect(emitted, containsAll(['ns1', 'ns2']));
      await store.close();
    });
  });

  group('LsmEngine — close and reopen', () {
    test('close releases lock; second open succeeds', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v'));
      await store.close();
      // Should be able to open again without LockException.
      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), equals(_bytes('v')));
      await store2.close();
    });
  });

  // ── HLC clock injection ──────────────────────────────────────────────────────
  //
  // These tests use CrashRecovery.open with an injected HlcClock so that the
  // wall clock seen by LsmEngine is fully deterministic. The injected clock
  // eliminates all reliance on DateTime.now() inside the write path.

  group('LsmEngine — HLC clock injection', () {
    test(
      'monotonic ordering: successive writes get strictly increasing HLCs',
      () async {
        // Freeze the wall clock at a fixed millisecond. Both writes happen within
        // the same "millisecond" so the logical counter must increment.
        const frozenMs = 1_000_000_000;
        final clock = HlcClock(wallClock: () => frozenMs);

        final adapter = _newAdapter();
        final store = await openWithClock(adapter, clock);

        await store.put('ns', _key(1), _bytes('a'));
        await store.put('ns', _key(2), _bytes('b'));

        // currentHlc reflects the most-recently issued HLC. After two puts
        // into the same frozen millisecond the logical counter should be ≥ 1.
        final hlcStr = (await store.storeInfo()).currentHlc;
        // Format: 12-hex-physical:4-hex-logical
        final parts = hlcStr.split(':');
        expect(parts, hasLength(2), reason: 'expected <physical>:<logical>');
        final logical = int.parse(parts[1], radix: 16);
        expect(
          logical,
          greaterThanOrEqualTo(1),
          reason: 'second write must have logical > 0 in the same ms',
        );

        await store.close();
      },
    );

    test('clock advances after SSTable ingest', () async {
      // Wall clock fixed at 1 000 000 ms. Ingest a peer SSTable whose maxHlc
      // is 1 030 000 ms — 30 s ahead, within the 60 s skew limit. After ingest
      // the engine clock must reflect that value.
      const localMs = 1_000_000;
      const peerPhysical = 1_030_000; // 30 s ahead — within the 60 s skew limit
      final clock = HlcClock(wallClock: () => localMs);

      final adapter = _newAdapter();
      final store = await openWithClock(adapter, clock);

      final filename = SstableInfo.flushName(
        'peer0099',
        const Hlc(peerPhysical, 0),
        const Hlc(peerPhysical, 1),
      );
      final bytes = buildSst(basePhysical: peerPhysical);
      await store.ingestSstable(filename, bytes);

      // After ingest the clock must have advanced to at least peerPhysical.
      final hlcStr = (await store.storeInfo()).currentHlc;
      final physHex = hlcStr.split(':').first;
      final physMs = int.parse(physHex, radix: 16);
      expect(
        physMs,
        greaterThanOrEqualTo(peerPhysical),
        reason: 'engine clock must advance to ingested maxHlc',
      );

      await store.close();
    });

    test(
      'ClockSkewException thrown when ingested maxHlc exceeds skew limit',
      () async {
        // Wall clock at 0 ms. SSTable maxHlc is 61 000 ms — just beyond the
        // default 60-second skew window (60 000 ms).
        const localMs = 0;
        const skewExceededMs = 61_000; // > 60 s default limit
        final clock = HlcClock(
          wallClock: () => localMs,
          maxClockSkew: const Duration(seconds: 60),
        );

        final adapter = _newAdapter();
        final store = await openWithClock(adapter, clock);

        final filename = SstableInfo.flushName(
          'peer0099',
          const Hlc(skewExceededMs, 0),
          const Hlc(skewExceededMs, 1),
        );
        final bytes = buildSst(basePhysical: skewExceededMs);

        expect(
          () => store.ingestSstable(filename, bytes),
          throwsA(isA<ClockSkewException>()),
          reason: 'ingesting an SSTable beyond maxClockSkew must throw',
        );

        await store.close();
      },
    );

    test(
      'flush filename contains the expected HLC physical timestamp',
      () async {
        // Freeze wall clock at a known value. After a flush the SSTable filename
        // must embed that physical timestamp in its encoded HLC segments.
        const frozenMs = 0xABCDEF; // arbitrary fixed millisecond
        final clock = HlcClock(wallClock: () => frozenMs);

        final adapter = _newAdapter();
        final store = await openWithClock(adapter, clock);

        // Write one entry then flush explicitly.
        await store.put('ns', _key(1), _bytes('hello'));
        await store.flush();

        // Find the SSTable file created in the sst/ directory.
        final sstFiles = await adapter.listFiles(
          '$_dbDir/sst',
          extension: '.sst',
        );
        expect(
          sstFiles,
          isNotEmpty,
          reason: 'flush should have created an SSTable',
        );

        // The filename format is: {deviceId}-{minHlcHex}-{maxHlcHex}.sst
        // Parse and verify the physical component matches the injected clock.
        final info = SstableInfo.parse(sstFiles.first);
        expect(
          info.minHlc.physicalMs,
          equals(frozenMs),
          reason: 'SSTable minHlc physical must match injected wall clock',
        );

        await store.close();
      },
    );
  });
}
