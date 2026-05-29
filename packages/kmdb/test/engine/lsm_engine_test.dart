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
/// the wall clock seen by [LsmEngine] is fully deterministic. [config]
/// overrides the default test config (useful for tuning
/// `tombstoneGraceDuration`).
Future<KvStoreImpl> openWithClock(
  MemoryStorageAdapter adapter,
  HlcClock clock, {
  KvStoreConfig? config,
}) async {
  final resolvedConfig = config ?? KvStoreConfig.forTesting();
  final recovery = CrashRecovery(adapter: adapter, config: resolvedConfig);
  final (engine, recoveryResult) = await recovery.open(
    _dbDir,
    deviceId: 'testdev1',
    clock: clock,
  );
  final meta = MetaStore(engine);
  // Inject the MetaStore so the engine can advance the GC floor (H4-FU3).
  engine.setMetaStore(meta);
  final hadUnclosedSession = await meta.getDirtyFlag();
  return KvStoreImpl.forTesting(
    engine,
    meta,
    resolvedConfig,
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

    test(
      'H4 PR2 (local-only): a tombstone older than tombstoneGraceDuration is '
      'dropped by compactAll; a younger one is retained',
      () async {
        // Inject a mutable wall clock so we can deterministically position
        // writes/deletes inside vs outside the grace window.
        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);

        final adapter = _newAdapter();
        // Short grace window so the test stays fast and exercises the
        // wall-clock fallback path inside _computeTombstoneHorizon.
        final config = KvStoreConfig.forTesting();
        // forTesting() doesn't override tombstoneGraceDuration; rebuild with
        // a short window so the test isn't tied to the 7-day default.
        final shortGrace = KvStoreConfig(
          memtableSizeBytes: config.memtableSizeBytes,
          l0CompactionTrigger: config.l0CompactionTrigger,
          l1MaxBytes: config.l1MaxBytes,
          l2MaxBytes: config.l2MaxBytes,
          singleFileThresholdBytes: config.singleFileThresholdBytes,
          fsyncOnWrite: config.fsyncOnWrite,
          tombstoneGraceDuration: const Duration(milliseconds: 100),
        );
        final store = await openWithClock(adapter, clock, config: shortGrace);

        final oldKey = _key(0);
        final newKey = _key(1);

        // First batch — old data at wallMs=1000, then flush so the next
        // round produces a second SSTable. Two SSTables satisfies the
        // `totalFiles > 1` condition for the single-file collapse path,
        // which is what fires `_compactAll` (the only path that may drop
        // tombstones).
        await store.put('ns', oldKey, _bytes('old-payload'));
        await store.put('ns', newKey, _bytes('new-payload'));
        await store.delete('ns', oldKey); // tombstone hlc ~ (1000, _)
        await store.flush();

        // Advance past the grace window only for oldKey's tombstone.
        wallMs =
            1300; // 1300 - 100 (grace) = 1200 horizon; oldKey delete < 1200.
        await store.delete('ns', newKey); // tombstone hlc ~ (1300, _)
        await store.flush();

        // 2 small L0 files → totalFiles > 1, total bytes small → single-file
        // collapse fires `_compactAll`, which is the only path that can drop
        // tombstones (allLevels=true). horizon = now(1300) - grace(100) = 1200.
        //   oldKey delete (HLC ~ 1000) < 1200 → eligible for drop.
        //   newKey delete (HLC ~ 1300) >= 1200 → retained.
        await store.compactAll();

        // Reads return absent for both (both deleted).
        expect(await store.get('ns', oldKey), isNull);
        expect(await store.get('ns', newKey), isNull);

        // Scan on-disk SSTables to verify physical reclamation. The oldKey's
        // tombstone must be gone; the newKey's tombstone must remain.
        final oldKeyBytes = KeyCodec.keyToBytes(oldKey);
        final newKeyBytes = KeyCodec.keyToBytes(newKey);
        var oldMatches = 0;
        var newMatches = 0;
        for (final path in adapter.files.keys.where(
          (k) => k.endsWith('.sst'),
        )) {
          final reader = await SstableReader.open(path, adapter);
          await for (final entry in reader.scan()) {
            final entryKey = KeyCodec.decodeUserKey(entry.key);
            if (_bytesEqual(entryKey, oldKeyBytes)) oldMatches++;
            if (_bytesEqual(entryKey, newKeyBytes)) newMatches++;
          }
        }
        expect(oldMatches, equals(0), reason: 'oldKey tombstone must be GC\'d');
        expect(newMatches, equals(1), reason: 'newKey tombstone must remain');

        await store.close();
      },
    );

    test('H4 PR2: setTombstoneHorizonProvider overrides the local-only '
        'wall-clock fallback (used by SyncEngine for min(currentHlc) across '
        'HWMs)', () async {
      // Wall clock far in the future; the local-only fallback would
      // therefore drop any tombstone we can write here. But we install a
      // provider that pegs the horizon at Hlc(0, 0) — simulating a synced
      // database where peers have not yet pushed any HWMs — and assert
      // that the override wins.
      var wallMs = 100000;
      final clock = HlcClock(wallClock: () => wallMs);
      final adapter = _newAdapter();
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        l0CompactionTrigger: 2,
        l1MaxBytes: 16 * 1024,
        l2MaxBytes: 64 * 1024,
        singleFileThresholdBytes: 8 * 1024,
        fsyncOnWrite: false,
        tombstoneGraceDuration: const Duration(milliseconds: 10),
      );
      final store = await openWithClock(adapter, clock, config: config);

      // Override: provider always returns Hlc(0, 0) — no tombstone can
      // ever satisfy `hlc < Hlc(0, 0)`, so none should ever drop.
      store.setTombstoneHorizonProvider(() async => const Hlc(0, 0));

      final key = _key(0);
      await store.put('ns', key, _bytes('x'));
      await store.flush();
      await store.delete('ns', key);
      await store.flush();
      wallMs = 200000;
      // 2 small L0 files → single-file collapse → `_compactAll` fires.
      await store.compactAll();

      // Tombstone must survive — the provider's Hlc(0, 0) horizon takes
      // precedence over the wall-clock fallback that would have dropped it.
      final keyBytes = KeyCodec.keyToBytes(key);
      var matches = 0;
      for (final path in adapter.files.keys.where((k) => k.endsWith('.sst'))) {
        final reader = await SstableReader.open(path, adapter);
        await for (final entry in reader.scan()) {
          if (_bytesEqual(KeyCodec.decodeUserKey(entry.key), keyBytes)) {
            matches++;
          }
        }
      }
      expect(matches, equals(1));

      // Now clear the provider — wall-clock fallback should fire on the
      // next compactAll, dropping the tombstone.
      store.setTombstoneHorizonProvider(null);
      // Need 2+ files for the single-file collapse path that triggers
      // `_compactAll`. We have the one consolidated file from above; add
      // a second flush so the trigger fires.
      await store.put('ns', _key(1), _bytes('y'));
      await store.flush();
      await store.put('ns', _key(2), _bytes('z'));
      await store.flush();
      await store.compactAll();

      matches = 0;
      for (final path in adapter.files.keys.where((k) => k.endsWith('.sst'))) {
        final reader = await SstableReader.open(path, adapter);
        await for (final entry in reader.scan()) {
          if (_bytesEqual(KeyCodec.decodeUserKey(entry.key), keyBytes)) {
            matches++;
          }
        }
      }
      expect(matches, equals(0));

      await store.close();
    });
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

  // ── H4-FU3: tombstone GC floor — ingest-side horizon floor ────────────────
  //
  // H4-FU3 adds a per-device "GC floor" in $meta that records the highest
  // horizon ever used by a tombstone-dropping compaction. LsmEngine.ingestAt0
  // rejects SSTables whose maxHlc <= floor with StaleSstableIngestException.
  //
  // This group covers:
  //   (a) Fresh DB has floor zero and accepts everything.
  //   (b) _compactAll advances the floor when it drops tombstones.
  //   (c) _compactAll does NOT advance the floor when no tombstones drop.
  //   (d) Ingest of a sub-floor SSTable throws StaleSstableIngestException.
  //   (e) PR2 deferred Step 5: delete + compact + ingest old SSTable → key
  //       stays absent (the "no resurrection" CI assertion).
  //   (f) Floor is monotonic across two GC cycles.
  //   (g) Crash window (Q6 option b): compaction committed, floor not yet
  //       written → floor is pessimistically low, not ahead.

  group('H4-FU3: tombstone GC floor', () {
    test(
      '(a) fresh database: floor is Hlc(0,0) and ingest accepts every SSTable',
      () async {
        var wallMs = 5000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final store = await openWithClock(adapter, clock);

        // Floor starts at zero — confirmed via meta.
        expect(await store.meta.getTombstoneFloor(), equals(const Hlc(0, 0)));

        // Ingest an SSTable with a modest maxHlc — should succeed with zero floor.
        final filename = SstableInfo.flushName(
          'peer0001',
          const Hlc(1, 0),
          const Hlc(2, 0),
        );
        final bytes = buildSst(count: 2, basePhysical: 1);
        await expectLater(
          store.ingestSstable(filename, bytes),
          completes,
          reason: 'zero floor must accept any SSTable',
        );

        await store.close();
      },
    );

    test(
      '(b) _compactAll advances floor to horizon when tombstones are dropped',
      () async {
        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          // Short grace so the tombstone becomes eligible quickly.
          tombstoneGraceDuration: const Duration(milliseconds: 100),
        );
        final store = await openWithClock(adapter, clock, config: config);

        // Write and delete a key at wallMs=1000.
        final key = _key(0);
        await store.put('ns', key, _bytes('data'));
        await store.flush();

        // Advance wall clock so the tombstone HLC will be 1300.
        wallMs = 1300;
        await store.delete('ns', key);
        // Flush triggers a _compactAll DURING flush. The horizon at that point
        // is wallMs(=1300) - grace(=100) = 1200, which is NOT strictly above
        // the tombstone HLC of 1300 — so the tombstone survives this pass.
        await store.flush();

        // Advance the wall clock further, then issue an extra write + flush.
        // The next flush-triggered _compactAll reads the now-higher horizon
        // (1500 - 100 = 1400 > tombstone HLC 1300), so the tombstone is
        // dropped and the floor is written. The user-level compactAll() loop
        // alone would NOT have re-fired _compactAll because the prior pass
        // collapsed everything to a single file.
        wallMs = 1500;
        await store.put('ns', _key(1), _bytes('horizon-raiser'));
        await store.flush();

        // Floor must now equal the horizon used in the second compaction:
        // 1500 - 100 = 1400.
        final floor = await store.meta.getTombstoneFloor();
        expect(
          floor.physicalMs,
          equals(1400),
          reason: '_compactAll must advance floor to the horizon used',
        );
        expect(floor.logical, equals(0));

        await store.close();
      },
    );

    test(
      '(c) _compactAll does NOT advance floor when no tombstones are dropped',
      () async {
        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tombstoneGraceDuration: const Duration(days: 365), // never eligible
        );
        final store = await openWithClock(adapter, clock, config: config);

        await store.put('ns', _key(0), _bytes('a'));
        await store.flush();
        await store.put('ns', _key(1), _bytes('b'));
        await store.flush();
        await store.compactAll();

        // No tombstones exist — floor must stay at Hlc(0,0).
        expect(
          await store.meta.getTombstoneFloor(),
          equals(const Hlc(0, 0)),
          reason: 'floor must not advance when no tombstones were dropped',
        );

        await store.close();
      },
    );

    test(
      '(d) ingestAt0 throws StaleSstableIngestException when maxHlc <= floor',
      () async {
        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tombstoneGraceDuration: const Duration(milliseconds: 100),
        );
        final store = await openWithClock(adapter, clock, config: config);

        // Write + delete + advance + extra flush → flush-triggered _compactAll
        // sees horizon > tombstone HLC and drops it, advancing the floor.
        // See test (b) for the rationale behind the extra advance-write step.
        await store.put('ns', _key(0), _bytes('v'));
        await store.flush();
        wallMs = 1300;
        await store.delete('ns', _key(0));
        await store.flush();
        wallMs = 1500;
        await store.put('ns', _key(2), _bytes('horizon-raiser'));
        await store.flush();

        final floor = await store.meta.getTombstoneFloor();
        expect(floor.physicalMs, greaterThan(0));

        // Build an SSTable whose maxHlc equals the floor — should be rejected.
        final subFloorFilename = SstableInfo.flushName(
          'peer0001',
          Hlc(floor.physicalMs - 1, 0),
          floor, // maxHlc == floor → rejected by <= predicate
        );
        final bytes = buildSst(count: 1, basePhysical: floor.physicalMs - 1);
        expect(
          () => store.ingestSstable(subFloorFilename, bytes),
          throwsA(
            isA<StaleSstableIngestException>()
                .having((e) => e.filename, 'filename', equals(subFloorFilename))
                .having((e) => e.maxHlc, 'maxHlc', equals(floor))
                .having((e) => e.floor, 'floor', equals(floor)),
          ),
          reason: 'SSTable with maxHlc == floor must be rejected',
        );

        await store.close();
      },
    );

    test('(e) PR2 deferred Step 5 — no resurrection: delete + GC + ingest older '
        'SSTable → key stays absent (CI assertion)', () async {
      // This is the deterministic CI test that was deferred from H4 PR2
      // because it required the ingest-side floor to be testable.
      //
      // Scenario:
      //   T1: write put(k, v_old) at wallMs=1000.
      //   T2: write delete(k) at wallMs=1000 (higher logical counter).
      //   Compact with horizon > T2 → tombstone dropped, floor advances.
      //   T3: construct a sub-floor SSTable carrying put(k, v_old) at T1.
      //   Ingest it → must throw StaleSstableIngestException.
      //   Final read of k → must return null (never resurrected).

      var wallMs = 1000;
      final clock = HlcClock(wallClock: () => wallMs);
      final adapter = _newAdapter();
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        l0CompactionTrigger: 2,
        l1MaxBytes: 16 * 1024,
        l2MaxBytes: 64 * 1024,
        singleFileThresholdBytes: 8 * 1024,
        fsyncOnWrite: false,
        tombstoneGraceDuration: const Duration(milliseconds: 50),
      );
      final store = await openWithClock(adapter, clock, config: config);

      final key = _key(0);

      // Step 1: write the value to be "deleted later".
      await store.put('ns', key, _bytes('v_old'));
      await store.flush();

      // Step 2: delete it (tombstone HLC ≈ 1100).
      wallMs = 1100;
      await store.delete('ns', key);
      await store.flush();

      // Step 3: advance wall past grace window AND issue an extra write to
      // re-trigger _compactAll with a horizon above the tombstone HLC.
      // The flush-triggered compaction in step 2 saw horizon=1100-50=1050,
      // which did not exceed the tombstone HLC of 1100; the user-level
      // compactAll() loop will not re-fire _compactAll because the prior
      // pass collapsed to a single file. The extra put+flush below puts a
      // second file at L0 and the resulting _compactAll uses
      // horizon = 1300 - 50 = 1250 > tombstone HLC 1100, so the tombstone
      // drops and the floor is set. See test (b) for the same pattern.
      wallMs = 1300;
      await store.put('ns', _key(1), _bytes('horizon-raiser'));
      await store.flush();

      final floor = await store.meta.getTombstoneFloor();
      expect(floor.physicalMs, greaterThan(0), reason: 'floor must advance');

      // Verify key is absent after GC.
      expect(await store.get('ns', key), isNull);

      // Step 4: construct a peer SSTable carrying put(k, v_old) at an HLC
      // below the floor. This simulates a returning device that had written
      // the key before it was deleted on this device.
      final subFloorPhysical = floor.physicalMs - 100;
      final subFloorFilename = SstableInfo.flushName(
        'peer0001',
        Hlc(subFloorPhysical, 0),
        Hlc(subFloorPhysical + 1, 0),
      );
      // Build the SSTable with a put for the same key at the sub-floor HLC.
      final writer = SstableWriter();
      final keyBytes = KeyCodec.keyToBytes(key);
      final putIkey = KeyCodec.encodeInternalKey(
        'ns',
        keyBytes,
        Hlc(subFloorPhysical, 0),
        RecordType.put,
      );
      writer.add(putIkey, _bytes('v_old'));
      final subFloorBytes = writer.finish();

      // Step 5: ingest must throw StaleSstableIngestException.
      expect(
        () => store.ingestSstable(subFloorFilename, subFloorBytes),
        throwsA(isA<StaleSstableIngestException>()),
        reason:
            'sub-floor SSTable ingest must be rejected to prevent resurrection',
      );

      // Step 6: key must still read as absent — no resurrection.
      expect(
        await store.get('ns', key),
        isNull,
        reason: 'key must remain absent after sub-floor ingest rejection',
      );

      await store.close();
    });

    test(
      '(f) floor is monotonic: two GC cycles each advance the floor',
      () async {
        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tombstoneGraceDuration: const Duration(milliseconds: 50),
        );
        final store = await openWithClock(adapter, clock, config: config);

        // First GC cycle. See test (b) for why an extra advance-write is
        // required to coax _compactAll into firing with a horizon above
        // the tombstone HLC.
        await store.put('ns', _key(0), _bytes('a'));
        await store.flush();
        wallMs = 1200;
        await store.delete('ns', _key(0));
        await store.flush();
        wallMs = 1400;
        await store.put('ns', _key(2), _bytes('raiser1'));
        await store.flush();
        final floor1 = await store.meta.getTombstoneFloor();
        expect(
          floor1.physicalMs,
          greaterThan(0),
          reason: 'first GC must set floor',
        );

        // Second GC cycle at a later time.
        wallMs = 2000;
        await store.put('ns', _key(1), _bytes('b'));
        await store.flush();
        wallMs = 2200;
        await store.delete('ns', _key(1));
        await store.flush();
        wallMs = 2400;
        await store.put('ns', _key(3), _bytes('raiser2'));
        await store.flush();
        final floor2 = await store.meta.getTombstoneFloor();

        expect(
          floor2.physicalMs,
          greaterThan(floor1.physicalMs),
          reason: 'floor must advance with each GC cycle',
        );

        await store.close();
      },
    );

    test(
      '(g) Q6 crash window: floor is pessimistically low after crash between '
      'manifest commit and floor write (floor behind reality, not ahead)',
      () async {
        // The Q6 atomicity decision chose option (b): the floor write is a
        // separate $meta put after the manifest commits. If the process
        // crashes between these two steps the floor is stale (pre-compaction
        // value), which is pessimistic (safe) — sub-floor files are still
        // accepted, not incorrectly rejected.
        //
        // We simulate this by: (1) running the compaction normally to confirm
        // the floor advances, (2) manually rolling the floor back to the
        // pre-compaction value (simulating a crash before the floor write),
        // and (3) verifying the engine is still consistent — reads work,
        // and a well-HLC'd ingest succeeds (sub-floor check does not
        // over-reject).

        var wallMs = 1000;
        final clock = HlcClock(wallClock: () => wallMs);
        final adapter = _newAdapter();
        final config = KvStoreConfig(
          memtableSizeBytes: 4096,
          l0CompactionTrigger: 2,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          tombstoneGraceDuration: const Duration(milliseconds: 100),
        );
        final store = await openWithClock(adapter, clock, config: config);

        await store.put('ns', _key(0), _bytes('v'));
        await store.flush();
        wallMs = 1300;
        await store.delete('ns', _key(0));
        await store.flush();
        // Extra advance-write to force _compactAll with horizon > tombstone HLC.
        // See test (b) for the rationale.
        wallMs = 1500;
        await store.put('ns', _key(1), _bytes('horizon-raiser'));
        await store.flush();

        final actualFloor = await store.meta.getTombstoneFloor();
        expect(actualFloor.physicalMs, greaterThan(0));

        // Simulate the crash by rolling the floor back to zero (i.e. the
        // floor write never happened). The manifest already reflects the
        // post-compaction state (tombstone dropped).
        await store.resetTombstoneFloor();
        expect(
          await store.meta.getTombstoneFloor(),
          equals(const Hlc(0, 0)),
          reason: 'floor rolled back to simulate crash before floor write',
        );

        // With a zeroed floor, a post-floor SSTable is accepted (no false
        // rejection). This is the "pessimistic" outcome: we are slightly more
        // permissive than we should be, but we do not reject valid data.
        wallMs = 2000;
        final postFloorFilename = SstableInfo.flushName(
          'peer0001',
          Hlc(actualFloor.physicalMs + 1, 0),
          Hlc(actualFloor.physicalMs + 2, 0),
        );
        final postFloorBytes = buildSst(
          basePhysical: actualFloor.physicalMs + 1,
        );
        await expectLater(
          store.ingestSstable(postFloorFilename, postFloorBytes),
          completes,
          reason:
              'with zeroed floor, post-actual-floor SSTable must still be accepted',
        );

        await store.close();
      },
    );

    test(
      'StaleSstableIngestException carries correct filename, maxHlc, and floor',
      () async {
        final adapter = _newAdapter();
        // Manually set the floor without running GC.
        final (store, _) = await _open(adapter);
        await store.meta.setTombstoneFloor(const Hlc(500, 0));

        // Build SSTable with maxHlc == floor.
        final filename = SstableInfo.flushName(
          'peer0001',
          const Hlc(499, 0),
          const Hlc(500, 0),
        );
        final bytes = buildSst(count: 1, basePhysical: 499);

        StaleSstableIngestException? caught;
        try {
          await store.ingestSstable(filename, bytes);
        } on StaleSstableIngestException catch (e) {
          caught = e;
        }

        expect(caught, isNotNull, reason: 'exception must be thrown');
        expect(caught!.filename, equals(filename));
        expect(caught.maxHlc, equals(const Hlc(500, 0)));
        expect(caught.floor, equals(const Hlc(500, 0)));
        expect(caught.toString(), contains('GC floor'));

        await store.close();
      },
    );
  });
}
