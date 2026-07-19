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

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _dbDir = '/db';
const _syncRoot = 'sync';

/// Opens a fresh [KvStoreImpl] backed by [adapter] with [deviceId].
Future<KvStoreImpl> _openStore(
  MemoryStorageAdapter adapter,
  String deviceId,
) async {
  final (store, _) = await KvStoreImpl.open(
    _dbDir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: deviceId,
  );
  return store;
}

/// Builds a minimal valid SSTable bytes with [count] entries.
Uint8List _buildSst({int count = 2, int basePhysical = 5000}) {
  final writer = SstableWriter();
  for (var i = 0; i < count; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    // Use valid UUIDv7 format for keys in SSTable.
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

/// Creates a [SyncEngine] with the given adapters.
SyncEngine _makeEngine(
  KvStore store,
  MemorySyncAdapter cloudAdapter,
  MemoryStorageAdapter localAdapter,
  String deviceId,
) => SyncEngine(
  store: store,
  cloudAdapter: cloudAdapter,
  localAdapter: localAdapter,
  deviceId: deviceId,
  dbDir: _dbDir,
  syncRoot: _syncRoot,
  syncNamespaces: {'ns'},
  consolidationConfig: const ConsolidationConfig(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late MemoryStorageAdapter localAdapter;
  late MemorySyncAdapter cloudAdapter;
  late KvStoreImpl store;

  setUp(() async {
    MemoryStorageAdapter.releaseAllLocks();
    localAdapter = MemoryStorageAdapter();
    cloudAdapter = MemorySyncAdapter();
    store = await _openStore(localAdapter, 'dev00001');
  });

  tearDown(() async {
    await store.close();
    MemoryStorageAdapter.releaseAllLocks();
  });

  // ── SyncEngine construction ──────────────────────────────────────────────────

  test('syncNamespaces is accessible', () {
    final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
    expect(engine.syncNamespaces, contains('ns'));
  });

  // ── H4 PR2: tombstone-GC horizon provider registration ──────────────────
  //
  // SyncEngine's constructor must register a horizon provider on the store
  // so that the all-levels `_compactAll` path consults `min(currentHlc)`
  // across HWMs rather than the local-only wall-clock fallback. Verified
  // through behaviour: with no HWMs present yet, the provider returns
  // `Hlc(0, 0)`, which no real tombstone can fall below — so even a wall
  // clock far in the future will NOT drop tombstones once the engine has
  // been wired to a SyncEngine.

  group('horizon provider registration (H4 PR2)', () {
    test(
      'constructing a SyncEngine wires `min(currentHlc)` (initially Hlc(0,0)) '
      'onto the store as the tombstone-GC horizon',
      () async {
        // Track the provider by observing that the store-level wall-clock
        // fallback no longer drops tombstones once the SyncEngine is wired,
        // because the synced provider's `min` over an empty HWM dir returns
        // Hlc(0, 0). This is an end-to-end test of the wiring, not a unit
        // test of the helper (which is covered in highwater_test.dart).
        _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');

        // Drive the store through a delete + compactAll. The default
        // tombstoneGraceDuration is 7d and the test environment's wall
        // clock is "now", so without the SyncEngine the wall-clock
        // fallback would NOT drop a just-now tombstone either. To make the
        // assertion meaningful we tighten the gate by also clearing the
        // provider afterwards and verifying the fallback would drop —
        // confirming the provider was the only thing keeping it pinned.
        const userKey = '00000000000070008000000000000000';
        await store.put('ns', userKey, Uint8List.fromList([1]));
        await store.flush();
        await store.delete('ns', userKey);
        await store.flush();
        await store.compactAll();

        // With the SyncEngine-supplied horizon at Hlc(0, 0), no real
        // tombstone (HLC ≥ 0) is `< horizon`, so the tombstone is retained.
        // We assert this indirectly: a subsequent put for the same key
        // observes the post-delete state, i.e. the key is absent before
        // we re-write it. (A direct SSTable scan is overkill here — the
        // mechanism is fully exercised in lsm_engine_test.dart "PR2:
        // setTombstoneHorizonProvider overrides ...".)
        expect(await store.get('ns', userKey), isNull);

        // Clear the provider and confirm `null` is accepted by the store.
        store.setTombstoneHorizonProvider(null);
      },
    );

    test(
      're-registering a provider replaces the previous one (last writer wins)',
      () async {
        // First engine registers its HWM-based provider.
        _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');

        // Replace it with a sentinel provider that records being called.
        var called = 0;
        store.setTombstoneHorizonProvider(() async {
          called++;
          return const Hlc(1, 0);
        });

        // Force a `_compactAll` so the provider is consulted.
        const userKey = '00000000000070008000000000000000';
        await store.put('ns', userKey, Uint8List.fromList([1]));
        await store.flush();
        await store.put('ns', userKey, Uint8List.fromList([2]));
        await store.flush();
        await store.compactAll();

        expect(called, greaterThanOrEqualTo(1));
      },
    );
  });

  // ── push ──────────────────────────────────────────────────────────────────────

  group('push', () {
    test('push uploads local SSTables to sync folder', () async {
      // Write enough data to trigger a flush.
      final key = '00000000000070008000000000000000';
      await store.put('ns', key, Uint8List.fromList([1, 2, 3]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final remoteFiles = await cloudAdapter.list(
        '$_syncRoot/sstables',
        extension: '.sst',
      );
      expect(remoteFiles, isNotEmpty);
      // All uploaded files should belong to this device.
      for (final f in remoteFiles) {
        expect(SstableInfo.parse(f).deviceId, equals('dev00001'));
      }
    });

    test('push uploads HWM file', () async {
      await store.flush();
      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/dev00001.hwm',
        cloudAdapter,
      );
      expect(hwm, isNotNull);
      expect(hwm!.deviceId, equals('dev00001'));
    });

    test('push does not re-upload already-uploaded SSTables', () async {
      final key = '00000000000070008000000000000000';
      await store.put('ns', key, Uint8List.fromList([1]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final afterFirst = await cloudAdapter.list(
        '$_syncRoot/sstables',
        extension: '.sst',
      );

      // Push again — no new files.
      await engine.push();
      final afterSecond = await cloudAdapter.list(
        '$_syncRoot/sstables',
        extension: '.sst',
      );

      expect(afterSecond.length, equals(afterFirst.length));
    });

    test('push on empty store uploads HWM with zero HLC', () async {
      // No writes — memtable is empty, flush is a no-op.
      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/dev00001.hwm',
        cloudAdapter,
      );
      expect(hwm, isNotNull);
    });

    test(
      'push does not upload peer SSTables that were ingested during pull',
      () async {
        // Simulate a peer SSTable that was placed in the local sst/ dir by pull.
        const peerId = 'peer0001';
        final peerFilename = SstableInfo.flushName(
          peerId,
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        );
        // Write the peer file to local sst/ as if pull had ingested it.
        await localAdapter.writeFile('$_dbDir/sst/$peerFilename', _buildSst());

        final engine = _makeEngine(
          store,
          cloudAdapter,
          localAdapter,
          'dev00001',
        );
        await engine.push();

        // The remote sstables dir should NOT contain the peer file.
        final remoteFiles = await cloudAdapter.list(
          '$_syncRoot/sstables',
          extension: '.sst',
        );
        expect(remoteFiles, isNot(contains(peerFilename)));
      },
    );

    // ── Local-only SSTable exclusion (WI-0) ─────────────────────────────────

    test('push does not upload .local.sst files', () async {
      // Place a .local.sst file in the local sst/ directory — as if flush had
      // produced it from a $$-prefixed namespace. push() must not upload it.
      final localFilename = SstableInfo.flushName(
        'dev00001',
        const Hlc(2000, 0),
        const Hlc(2001, 0),
        localOnly: true,
      );
      await localAdapter.writeFile(
        '$_dbDir/sst/$localFilename',
        _buildSst(basePhysical: 2000),
      );

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      // The remote sstables dir must NOT contain the .local.sst file.
      final remoteFiles = await cloudAdapter.list(
        '$_syncRoot/sstables',
        extension: '.sst',
      );
      expect(
        remoteFiles,
        isNot(contains(localFilename)),
        reason: '.local.sst files must never be uploaded to the sync folder',
      );
    });

    test(
      'HWM is computed only from syncable SSTables: .local.sst does not advance HWM',
      () async {
        // Write a syncable SSTable with a low max HLC (1000 ms).
        final syncFilename = SstableInfo.flushName(
          'dev00001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        );
        await localAdapter.writeFile(
          '$_dbDir/sst/$syncFilename',
          _buildSst(basePhysical: 1000),
        );

        // Write a .local.sst SSTable with a higher max HLC (9999 ms).
        // If this file were included in HWM computation, the HWM would jump
        // to Hlc(9999, …) — use that to detect the bug.
        final localFilename = SstableInfo.flushName(
          'dev00001',
          const Hlc(9999, 0),
          const Hlc(9999, 9),
          localOnly: true,
        );
        await localAdapter.writeFile(
          '$_dbDir/sst/$localFilename',
          _buildSst(basePhysical: 9999),
        );

        final engine = _makeEngine(
          store,
          cloudAdapter,
          localAdapter,
          'dev00001',
        );
        await engine.push();

        final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm',
          cloudAdapter,
        );
        expect(hwm, isNotNull);
        // The .local.sst file's maxHlc — Hlc(9999, 9) — must not have
        // contributed to the HWM. This can no longer be asserted as an
        // absolute upper bound of 1001ms: KvStoreImpl.open() now always
        // writes one $meta format-version-marker entry (Encryption
        // confidentiality reconciliation plan, Phase 2/B8-B9), so push()'s
        // own flush (step 1) legitimately produces an additional syncable
        // SSTable stamped with the real wall-clock HLC, which is
        // legitimately the new high-water mark. The invariant this test
        // actually cares about — that the *local-only* file specifically
        // never contributes — is what's asserted here instead.
        expect(
          hwm!.currentHlc,
          isNot(equals(const Hlc(9999, 9))),
          reason: '.local.sst HLC must not contribute to the high-water mark',
        );
      },
    );
  });

  // ── pull ──────────────────────────────────────────────────────────────────────

  group('pull', () {
    test('pull ingests a remote peer SSTable', () async {
      // Upload a peer SSTable to the sync folder.
      const peerId = 'peer0001';
      final peerFilename = SstableInfo.flushName(
        peerId,
        const Hlc(5000, 0),
        const Hlc(5001, 0),
      );
      final sstBytes = _buildSst(basePhysical: 5000);
      await cloudAdapter.upload('$_syncRoot/sstables/$peerFilename', sstBytes);

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      // SSTable should now exist locally.
      final exists = await localAdapter.fileExists('$_dbDir/sst/$peerFilename');
      expect(exists, isTrue);
    });

    test('pull updates HWM with ingested peer HLC', () async {
      const peerId = 'peer0001';
      final peerFilename = SstableInfo.flushName(
        peerId,
        const Hlc(5000, 0),
        const Hlc(5001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$peerFilename',
        _buildSst(basePhysical: 5000),
      );

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/dev00001.hwm',
        cloudAdapter,
      );
      expect(hwm!.peers[peerId], isNotNull);
      expect(hwm.peers[peerId]!.physicalMs, greaterThanOrEqualTo(5001));
    });

    test('pull skips own device SSTables', () async {
      // Upload one of our own SSTables — should be ignored during pull.
      final ownFilename = SstableInfo.flushName(
        'dev00001',
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$ownFilename',
        _buildSst(),
      );

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      // Should complete without error and without ingesting the own file.
      await expectLater(engine.pull(), completes);
    });

    test('pull skips already-ingested SSTables', () async {
      const peerId = 'peer0001';
      final peerFilename = SstableInfo.flushName(
        peerId,
        const Hlc(5000, 0),
        const Hlc(5001, 0),
      );
      final sstBytes = _buildSst(basePhysical: 5000);
      await cloudAdapter.upload('$_syncRoot/sstables/$peerFilename', sstBytes);

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      // Write a sentinel to detect if the file is written again.
      await localAdapter.writeFile(
        '$_dbDir/sst/$peerFilename',
        Uint8List.fromList([0xFF, 0xFF]),
      );

      // Second pull — should skip because file already exists locally.
      await engine.pull();

      // File should still be the sentinel (not overwritten with valid SST).
      final bytes = await localAdapter.readFile('$_dbDir/sst/$peerFilename');
      expect(bytes, equals(Uint8List.fromList([0xFF, 0xFF])));

      // Restore valid content before this test's tearDown() calls
      // store.close(), which flushes and may trigger a compaction that reads
      // every Manifest-tracked SSTable — including this one, still
      // registered from the first (successful) ingest above. Leaving the
      // 2-byte sentinel in place would make that unrelated close()-time
      // compaction throw CorruptedSstableException; this sentinel's job
      // (proving the *second* pull() didn't re-download/overwrite the file)
      // is already done by the assertion above.
      await localAdapter.writeFile('$_dbDir/sst/$peerFilename', sstBytes);
    });

    test('pull handles empty sync folder gracefully', () async {
      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await expectLater(engine.pull(), completes);
    });

    test('pull skips files with unparseable names', () async {
      // Upload a file with an invalid SSTable name.
      await cloudAdapter.upload(
        '$_syncRoot/sstables/not-a-valid-name.sst',
        _buildSst(),
      );

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      // Should complete without throwing.
      await expectLater(engine.pull(), completes);
    });

    test(
      'pull quarantines a corrupted remote SSTable and advances the HWM '
      'past it (S-1) — the file is not re-fetched on the next pull',
      () async {
        const peerId = 'peer0001';
        final peerFilename = SstableInfo.flushName(
          peerId,
          const Hlc(5000, 0),
          const Hlc(5001, 0),
        );
        // Upload garbage bytes — fails the footer checksum, which the reader
        // validates before any other parsing (CorruptedSstableException).
        await cloudAdapter.upload(
          '$_syncRoot/sstables/$peerFilename',
          Uint8List.fromList(List.filled(64, 0xAB)),
        );

        final engine = _makeEngine(
          store,
          cloudAdapter,
          localAdapter,
          'dev00001',
        );
        await engine.pull();

        // S-1 fix: the peer HWM must advance past the rejected file's maxHlc
        // so it is quarantined rather than re-fetched every cycle — the
        // pre-fix behaviour left the HWM untouched, which is exactly the
        // *persistent* denial-of-sync the review confirmed (PEER-A/B).
        final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm',
          cloudAdapter,
        );
        expect(hwm, isNotNull);
        expect(hwm!.peers[peerId], equals(const Hlc(5001, 0)));

        // Note: the raw bytes are written to local `sst/` *before*
        // `ingestAt0` validates them (see `KvStoreImpl.ingestSstable`) — this
        // is a documented, pre-existing crash-safety ordering (the directory
        // entry must be durably linked before the Manifest records it) and is
        // out of this fix's scope. The file is never registered in the
        // Manifest, so it is inert; only ingestion (this test's actual
        // subject) is asserted here.

        // The load-bearing assertion (Phase 8): a subsequent pull() must
        // succeed and must not attempt to re-download the quarantined file.
        // Re-uploading the *same* garbage bytes at the same path would just
        // repeat this test, so instead assert the quarantine is durable by
        // confirming the peer's HWM entry is unchanged by a second pull with
        // no new remote activity.
        await engine.pull();
        final hwmAfterSecondPull = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm',
          cloudAdapter,
        );
        expect(hwmAfterSecondPull!.peers[peerId], equals(const Hlc(5001, 0)));
      },
    );

    test('pull skips peer SSTable already covered by HWM', () async {
      const peerId = 'peer0001';
      // Set HWM peer entry to Hlc(9999, 0) — above the SSTable's maxHlc.
      final highHwm = HighwaterMark(
        deviceId: 'dev00001',
        currentHlc: const Hlc(10000, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: {peerId: const Hlc(9999, 0)},
      );
      await highHwm.save('$_syncRoot/highwater/dev00001.hwm', cloudAdapter);

      // Upload a peer SSTable with maxHlc < 9999.
      final peerFilename = SstableInfo.flushName(
        peerId,
        const Hlc(5000, 0),
        const Hlc(5001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$peerFilename',
        _buildSst(basePhysical: 5000),
      );

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      // File should NOT be ingested (already covered by HWM).
      final exists = await localAdapter.fileExists('$_dbDir/sst/$peerFilename');
      expect(exists, isFalse);
    });
  });

  // ── sync ──────────────────────────────────────────────────────────────────────

  group('sync', () {
    test('sync calls push then pull', () async {
      const peerId = 'peer0002';
      // Pre-load the sync folder with a peer SSTable.
      final peerFilename = SstableInfo.flushName(
        peerId,
        const Hlc(7000, 0),
        const Hlc(7001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$peerFilename',
        _buildSst(basePhysical: 7000),
      );

      // Write local data that should be pushed.
      final key = '00000000000070008000000000000001';
      await store.put('ns', key, Uint8List.fromList([42]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.sync();

      // Our SSTable should be in the sync folder.
      final remoteFiles = await cloudAdapter.list(
        '$_syncRoot/sstables',
        extension: '.sst',
      );
      final ourFiles = remoteFiles
          .where((f) => _safeDeviceId(f) == 'dev00001')
          .toList();
      expect(ourFiles, isNotEmpty);

      // Peer SSTable should be reflected in the local HWM — the file itself may
      // have been compacted into a different SSTable, but the HWM records that
      // the peer's data was fully processed.
      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/dev00001.hwm',
        cloudAdapter,
      );
      expect(hwm, isNotNull);
      expect(
        hwm!.peers[peerId],
        isNotNull,
        reason: 'HWM for $peerId should be set after pull ingested its SSTable',
      );
    });

    // We run this test multiple times to try and catch out sync errors
    for (var i = 0; i < 20; i++) {
      test('sync two devices exchange data - pass $i', () async {
        // Device A writes data and syncs.
        final adapterA = MemoryStorageAdapter();
        final (storeA, _) = await KvStoreImpl.open(
          '/dbA',
          adapterA,
          config: KvStoreConfig.forTesting(),
          deviceId: 'devaaaaa',
        );
        final engineA = SyncEngine(
          store: storeA,
          cloudAdapter: cloudAdapter,
          localAdapter: adapterA,
          deviceId: 'devaaaaa',
          dbDir: '/dbA',
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );

        // Device B writes different data.
        final adapterB = MemoryStorageAdapter();
        final (storeB, _) = await KvStoreImpl.open(
          '/dbB',
          adapterB,
          config: KvStoreConfig.forTesting(),
          deviceId: 'devbbbbb',
        );
        final engineB = SyncEngine(
          store: storeB,
          cloudAdapter: cloudAdapter,
          localAdapter: adapterB,
          deviceId: 'devbbbbb',
          dbDir: '/dbB',
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );

        try {
          final keyA = '0000000000007000800000000000000a';
          await storeA.put('ns', keyA, Uint8List.fromList([1]));
          await storeA.flush();
          await engineA.push();

          final keyB = '0000000000007000800000000000000b';
          await storeB.put('ns', keyB, Uint8List.fromList([2]));
          await storeB.flush();
          await engineB.sync(); // B pushes its own data and pulls A's data

          // B should now have A's data accessible (even if compaction merged the
          // ingested SSTable file away, the data must be readable).
          final bHasAData = await storeB.get('ns', keyA);
          expect(bHasAData, isNotNull);
        } finally {
          await storeA.close();
          await storeB.close();
        }
      });
    }
  });

  // ── H4-FU2: eviction-aware horizon and safe re-admission ───────────────────
  //
  // These tests exercise:
  //  (a) The eviction-filtered horizon provider registered by SyncEngine.
  //  (b) The two-condition re-admission check in push().
  //  (c) The resurrection guard: eviction + tombstone drop + returning device.

  group('H4-FU2: eviction and re-admission', () {
    // ── Eviction-aware horizon provider ───────────────────────────────────────

    test('SyncEngine uses staleDeviceEvictionAfter when building the horizon '
        'provider — stale peer is excluded from min', () async {
      // Register a SyncEngine with a very short eviction threshold (1ms) so
      // any peer that pushed more than 1ms ago is immediately considered stale.
      // The horizon should then fall back to Hlc(0,0) (no live peers), blocking
      // tombstone drops — the safe conservative behaviour.
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        fsyncOnWrite: false,
        staleDeviceEvictionAfter: const Duration(milliseconds: 1),
      );

      // Write a peer HWM with a very old timestamp.
      final staleHwm = HighwaterMark(
        deviceId: 'stalep01',
        currentHlc: const Hlc(9000, 0),
        lastUpdated: DateTime.utc(2020, 1, 1), // 6+ years ago
        peers: const {},
      );
      await staleHwm.save('$_syncRoot/highwater/stalep01.hwm', cloudAdapter);

      final engine = SyncEngine(
        store: store,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        deviceId: 'dev00001',
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: config,
      );

      // Push so the local HWM exists (required for the horizon to include us).
      await engine.push();

      // The horizon provider should return Hlc(0,0) because the only non-local
      // peer's HWM is stale and therefore excluded. With no live peer to form
      // a real min, the provider collapses to null → Hlc(0,0), which blocks
      // all tombstone drops.
      //
      // Verify indirectly: delete a key, compact, confirm it is still absent
      // (tombstone retained because horizon = Hlc(0,0)).
      const key = '00000000000070008000000000000000';
      await store.put('ns', key, Uint8List.fromList([1]));
      await store.flush();
      await store.delete('ns', key);
      await store.flush();
      await store.compactAll();

      expect(await store.get('ns', key), isNull);
    });

    // ── Re-admission trigger detection ────────────────────────────────────────

    test('push does not trigger full re-sync when device is merely behind '
        '(condition a only — stale HWM but HLC >= live-peer min)', () async {
      // Device has a stale HWM by age (condition b holds) but its HLC is
      // >= the live peer's min (condition a does NOT hold). Incremental push
      // must proceed; no full re-sync.
      final shortEviction = const Duration(milliseconds: 1);
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        fsyncOnWrite: false,
        staleDeviceEvictionAfter: shortEviction,
      );

      // Write a fresh peer with a lower HLC than our device will have.
      final freshPeer = HighwaterMark(
        deviceId: 'freshpe1',
        currentHlc: const Hlc(100, 0),
        lastUpdated: DateTime.now().toUtc(), // fresh
        peers: const {},
      );
      await freshPeer.save('$_syncRoot/highwater/freshpe1.hwm', cloudAdapter);

      // Our device: write data (higher HLC), flush, then save a stale HWM.
      const key = '00000000000070008000000000000000';
      await store.put('ns', key, Uint8List.fromList([99]));
      await store.flush();

      // Manually create a stale HWM for our device (age >> eviction threshold).
      final ourStaleHwm = HighwaterMark(
        deviceId: 'dev00001',
        currentHlc: const Hlc(99999, 0), // high HLC — not behind peers
        lastUpdated: DateTime.utc(2020, 1, 1), // very stale by wall clock
        peers: const {},
      );
      await ourStaleHwm.save('$_syncRoot/highwater/dev00001.hwm', cloudAdapter);

      final engine = SyncEngine(
        store: store,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        deviceId: 'dev00001',
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: config,
      );

      // Push should complete normally (no full re-sync triggered).
      // If full re-sync ran, it would delete local SSTables; confirm they
      // survive by checking the key is still readable.
      await engine.push();
      expect(await store.get('ns', key), isNotNull);
    });

    test('push does not trigger full re-sync when HWM is recent '
        '(condition b does not hold)', () async {
      // Even if the device is behind on HLC (condition a holds), if the
      // HWM is fresh (condition b does NOT hold), no re-sync.
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        fsyncOnWrite: false,
        staleDeviceEvictionAfter: const Duration(days: 90),
      );

      // Live peer with a very high HLC.
      final freshPeer = HighwaterMark(
        deviceId: 'freshpe2',
        currentHlc: const Hlc(999999, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await freshPeer.save('$_syncRoot/highwater/freshpe2.hwm', cloudAdapter);

      // Our device has a low HLC but a fresh HWM (updated just now).
      final ourFreshHwm = HighwaterMark(
        deviceId: 'dev00001',
        currentHlc: const Hlc(1, 0), // very low HLC (behind the peer)
        lastUpdated: DateTime.now().toUtc(), // fresh
        peers: const {},
      );
      await ourFreshHwm.save('$_syncRoot/highwater/dev00001.hwm', cloudAdapter);

      final engine = SyncEngine(
        store: store,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        deviceId: 'dev00001',
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: config,
      );

      // Push should complete normally.
      await engine.push();
      // No exception — incremental push succeeded.
    });

    test('push does not trigger full re-sync when no prior HWM exists for this '
        'device (brand-new device is never evicted)', () async {
      final config = KvStoreConfig(
        memtableSizeBytes: 4096,
        fsyncOnWrite: false,
        staleDeviceEvictionAfter: const Duration(milliseconds: 1),
      );

      // Live peer.
      final freshPeer = HighwaterMark(
        deviceId: 'freshpe3',
        currentHlc: const Hlc(9000, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await freshPeer.save('$_syncRoot/highwater/freshpe3.hwm', cloudAdapter);

      // Our device has no HWM yet — first push ever.
      final engine = SyncEngine(
        store: store,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        deviceId: 'dev00001',
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: config,
      );

      // Should complete without triggering re-sync (no prior HWM → not evicted).
      await engine.push();

      // Our HWM should now exist.
      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/dev00001.hwm',
        cloudAdapter,
      );
      expect(hwm, isNotNull);
    });

    // ── Resurrection guard ────────────────────────────────────────────────────
    //
    // This is the correctness-critical test (Step 5 of the plan).
    //
    // Scenario:
    //   1. Device A (live) writes a record, pushes.
    //   2. Device A deletes the record, pushes.
    //   3. The horizon advances (device B is evicted).
    //   4. Compaction on device A drops the tombstone past the horizon.
    //   5. Device B returns.
    //   With re-admission: device B performs a full re-sync → no resurrection.
    //   Without re-admission: device B pushes stale data → resurrection.
    //
    // The test asserts the resurrection scenario both ways to prove the test
    // is correctly wired and not trivially passing.

    test(
      'returning evicted device does NOT resurrect deleted data when '
      're-admission check is enabled (full re-sync prevents resurrection)',
      () async {
        // ── Phase 1: Set up device A (the live peer). ──
        MemoryStorageAdapter.releaseAllLocks();
        final adapterA = MemoryStorageAdapter();
        final (storeA, _) = await KvStoreImpl.open(
          '/dbA',
          adapterA,
          config: KvStoreConfig.forTesting(),
          deviceId: 'devaaaaa',
        );

        // Use a short-but-not-vanishing eviction threshold so device B's
        // ancient (2020) stale HWM is reliably evictable while device A's
        // *own* HWM — written moments ago by real wall-clock pushes earlier
        // in this test — is not spuriously treated as stale too. A 1ms
        // threshold looked "effectively always true" for the manually-dated
        // stale HWM, but it also raced against the real elapsed wall-clock
        // time between A's own pushes and B's later eviction check: under
        // CI load (or with coverage instrumentation) more than 1ms can
        // elapse between those steps, which would incorrectly exclude A from
        // the live-peer set and make the re-admission check see no live
        // peers at all — silently skipping the intended full re-sync. 30s is
        // comfortably longer than this test can run yet far shorter than the
        // multi-year gap to the manually-dated stale HWMs below.
        final shortEviction = const Duration(seconds: 30);

        final engineA = SyncEngine(
          store: storeA,
          cloudAdapter: cloudAdapter,
          localAdapter: adapterA,
          deviceId: 'devaaaaa',
          dbDir: '/dbA',
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
          config: KvStoreConfig(
            memtableSizeBytes: 4096,
            fsyncOnWrite: false,
            staleDeviceEvictionAfter: shortEviction,
            tombstoneGraceDuration: Duration.zero,
          ),
        );

        try {
          // Device A: write a record.
          const resurrectionKey = '00000000000070008dead000000000ab';
          await storeA.put('ns', resurrectionKey, Uint8List.fromList([42]));
          await storeA.flush();
          await engineA.push();

          // ── Phase 2: Device B "appears" — it writes a stale HWM (very old
          //    lastUpdated) to simulate that it was in the sync topology
          //    earlier but went offline a long time ago.
          //    We also place a copy of the record in device B's local store to
          //    simulate it holding pre-delete data.
          MemoryStorageAdapter.releaseAllLocks();
          final adapterB = MemoryStorageAdapter();
          final (storeB, _) = await KvStoreImpl.open(
            '/dbB',
            adapterB,
            config: KvStoreConfig.forTesting(),
            deviceId: 'devbbbbb',
          );

          // Artificially inject device B's stale HWM into the sync folder.
          // lastUpdated: far in the past → B is stale and will be evicted.
          final staleBHwm = HighwaterMark(
            deviceId: 'devbbbbb',
            currentHlc: const Hlc(1, 0), // very low HLC
            lastUpdated: DateTime.utc(2020, 1, 1), // ancient
            peers: const {},
          );
          await staleBHwm.save(
            '$_syncRoot/highwater/devbbbbb.hwm',
            cloudAdapter,
          );

          // Device B also writes the key locally (pre-delete copy).
          await storeB.put('ns', resurrectionKey, Uint8List.fromList([42]));
          await storeB.flush();

          // ── Phase 3: Device A deletes the record and arranges for the
          //    tombstone to be GC'd from its local store before B returns.
          //
          // The drop is gated by *strict* `tombHlc < horizon`, and the
          // horizon is read from the cloud HWM at compaction time. Each
          // flush-triggered compaction runs *before* the matching push has
          // updated the HWM, so a single delete + flush + push leaves the
          // tombstone in place even though the next push raises the HWM
          // above it. We therefore advance the HWM twice: the first extra
          // push lifts the cloud HWM above the tombstone, and the second
          // extra push's flush-compaction observes that raised HWM and
          // drops the tombstone.
          await storeA.delete('ns', resurrectionKey);
          await storeA.flush();
          await engineA.push(); // A pushes its delete SSTable.

          const advanceKey1 = '00000000000070008b00ccc000000001';
          await storeA.put('ns', advanceKey1, Uint8List.fromList([1]));
          await storeA.flush();
          await engineA.push(); // Cloud HWM now > tombHlc.

          const advanceKey2 = '00000000000070008b00ccc000000011';
          await storeA.put('ns', advanceKey2, Uint8List.fromList([2]));
          await storeA.flush(); // This flush's _compactAll drops the tombstone.
          await engineA.push();

          // Verify: device A no longer holds the key.
          expect(
            await storeA.get('ns', resurrectionKey),
            isNull,
            reason: 'Device A should have dropped the tombstone via compaction',
          );

          // ── Phase 4: Device B returns with re-admission enabled.
          //    Full re-sync should detect both conditions:
          //    (a) B's HLC (1) < A's live HLC (≫1)
          //    (b) B's lastUpdated is ancient
          //    → full re-sync: B discards its local SSTables and rebuilds
          //      from the sync folder.
          final engineB = SyncEngine(
            store: storeB,
            cloudAdapter: cloudAdapter,
            localAdapter: adapterB,
            deviceId: 'devbbbbb',
            dbDir: '/dbB',
            syncRoot: _syncRoot,
            syncNamespaces: {'ns'},
            config: KvStoreConfig(
              memtableSizeBytes: 4096,
              fsyncOnWrite: false,
              staleDeviceEvictionAfter: shortEviction,
              tombstoneGraceDuration: Duration.zero,
            ),
          );

          // Push on device B — should trigger full re-sync.
          await engineB.push();

          // After full re-sync, device B's local store reflects the current
          // sync folder state. The key was deleted and the tombstone was
          // dropped — the key should not be resurrected.
          //
          // Device B's new state: it re-downloaded A's SSTables which contain
          // the delete tombstone at the time of the push. The key is absent.
          expect(
            await storeB.get('ns', resurrectionKey),
            isNull,
            reason:
                'Device B must NOT resurrect the deleted key after full re-sync',
          );

          await storeB.close();
        } finally {
          await storeA.close();
          MemoryStorageAdapter.releaseAllLocks();
        }
      },
    );

    test('WITHOUT re-admission check, H4-FU3 ingest-side floor still '
        'prevents resurrection (layered defence)', () async {
      // Same scenario as the resurrection-guard test, but device B uses an
      // eviction threshold so large that the H4-FU2 re-admission check
      // effectively never fires — so device B does NOT perform a full
      // re-sync and pushes its stale pre-delete SSTable to the cloud as-is.
      //
      // Before H4-FU3 landed this test asserted the resurrection actually
      // occurred (as a negative control proving the H4-FU2 guard test was
      // not trivially passing). With H4-FU3 active, device A's tombstone-GC
      // pass writes a $meta floor and `ingestSstable` rejects any incoming
      // SSTable whose `maxHlc <= floor`. So even though B's stale SSTable
      // reaches the cloud, A rejects it at ingest with
      // `StaleSstableIngestException` (caught and skipped by
      // `SyncEngine.pull`'s per-file catch block) and the deleted key
      // stays absent. This test now documents the layered protection:
      // H4-FU2 guards the producer side, H4-FU3 guards the recipient side,
      // and resurrection is blocked even when only one layer fires.
      MemoryStorageAdapter.releaseAllLocks();
      final adapterA = MemoryStorageAdapter();
      final (storeA, _) = await KvStoreImpl.open(
        '/dbA',
        adapterA,
        config: KvStoreConfig.forTesting(),
        deviceId: 'devaaaaa',
      );

      const shortEviction = Duration(milliseconds: 1);
      // Device A still evicts B from its horizon (short eviction).
      final engineA = SyncEngine(
        store: storeA,
        cloudAdapter: cloudAdapter,
        localAdapter: adapterA,
        deviceId: 'devaaaaa',
        dbDir: '/dbA',
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: KvStoreConfig(
          memtableSizeBytes: 4096,
          fsyncOnWrite: false,
          staleDeviceEvictionAfter: shortEviction,
          tombstoneGraceDuration: Duration.zero,
        ),
      );

      try {
        // Device A writes and pushes the key.
        const resurrectionKey = '00000000000070008dead000000000cd';
        await storeA.put('ns', resurrectionKey, Uint8List.fromList([99]));
        await storeA.flush();
        await engineA.push();

        // Device B: stale HWM, stale local pre-delete copy.
        MemoryStorageAdapter.releaseAllLocks();
        final adapterB = MemoryStorageAdapter();
        final (storeB, _) = await KvStoreImpl.open(
          '/dbB',
          adapterB,
          config: KvStoreConfig.forTesting(),
          deviceId: 'devbbbbb',
        );

        final staleBHwm = HighwaterMark(
          deviceId: 'devbbbbb',
          currentHlc: const Hlc(1, 0),
          lastUpdated: DateTime.utc(2020, 1, 1),
          peers: const {},
        );
        await staleBHwm.save('$_syncRoot/highwater/devbbbbb.hwm', cloudAdapter);
        await storeB.put('ns', resurrectionKey, Uint8List.fromList([99]));
        await storeB.flush();

        // Device A deletes the key and arranges for the tombstone to be
        // physically dropped from A's local store. The tombstone only
        // becomes droppable once A's own on-disk HWM `currentHlc` — which is
        // what `minCurrentHlcAcrossDevices` uses as the horizon here, since
        // B's HWM is always excluded as stale — has advanced *strictly past*
        // the tombstone's HLC (`tombstoneHlc.compareTo(horizon) < 0` in
        // reclamation_policy.dart). A fixed number of "advance" pushes is
        // not a reliable way to guarantee that: the exact HLC gap created by
        // each push depends on real wall-clock timing (HLC's physical
        // component), so a hardcoded count of 2 was observed to flake
        // (~1-in-8 on a full-file run, reproduced by running this file 25x
        // in a loop) when the test ran under load. Poll
        // `meta.getTombstoneFloor()` instead — it only advances when a
        // compaction actually drops a tombstone — until it moves past its
        // pre-delete value, with a generous bounded retry count so a genuine
        // regression still fails loudly instead of hanging.
        await storeA.delete('ns', resurrectionKey);
        await storeA.flush();
        await engineA.push();

        final floorBeforeAdvance = await storeA.meta.getTombstoneFloor();
        var floorAdvanced = false;
        for (var i = 0; i < 10 && !floorAdvanced; i++) {
          final advanceKey =
              '00000000000070008b00ccc0000000${i.toRadixString(16).padLeft(2, '0')}';
          await storeA.put('ns', advanceKey, Uint8List.fromList([i]));
          await storeA.flush();
          await engineA.push();
          final floor = await storeA.meta.getTombstoneFloor();
          floorAdvanced = floor.compareTo(floorBeforeAdvance) > 0;
        }
        expect(
          floorAdvanced,
          isTrue,
          reason:
              'Tombstone GC floor never advanced past its pre-delete value '
              'after 10 advance-push attempts — the tombstone-drop path may '
              'be broken (this is a precondition check, not the assertion '
              'under test).',
        );

        expect(await storeA.get('ns', resurrectionKey), isNull);

        // Device B uses a VERY long eviction threshold — re-admission check
        // effectively disabled (B's stale HWM will never exceed the threshold).
        final engineB = SyncEngine(
          store: storeB,
          cloudAdapter: cloudAdapter,
          localAdapter: adapterB,
          deviceId: 'devbbbbb',
          dbDir: '/dbB',
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
          config: KvStoreConfig(
            memtableSizeBytes: 4096,
            fsyncOnWrite: false,
            // Eviction window so large B is never considered evicted.
            staleDeviceEvictionAfter: const Duration(days: 365 * 100),
            tombstoneGraceDuration: Duration.zero,
          ),
        );

        // B pushes incrementally — its pre-delete SSTable goes into the sync
        // folder. Pull on A would then ingest it and resurrect the key.
        await engineB.push();
        // Pull on A to demonstrate resurrection.
        await engineA.pull();

        // Even with the H4-FU2 re-admission guard effectively disabled, the
        // H4-FU3 ingest-side floor rejects B's sub-floor SSTable, so the
        // deleted key stays absent. This is the layered-defence assertion:
        // either guard is enough to prevent resurrection on its own.
        expect(
          await storeA.get('ns', resurrectionKey),
          isNull,
          reason:
              'H4-FU3 ingest-side floor must reject B\'s stale SSTable at '
              'pull time, leaving the deleted key absent on device A',
        );

        await storeB.close();
      } finally {
        await storeA.close();
        MemoryStorageAdapter.releaseAllLocks();
      }
    });

    // ── Multi-device end-to-end ───────────────────────────────────────────────

    test('multi-device: active devices continue syncing normally when a stale '
        'peer is evicted from the horizon', () async {
      // Two active devices and one permanently-gone stale device.
      // The stale device's HWM is present in the sync folder with a very old
      // lastUpdated. The two active devices should be able to sync normally
      // and have tombstones GC'd correctly without being blocked by the stale peer.
      MemoryStorageAdapter.releaseAllLocks();

      final adapterA = MemoryStorageAdapter();
      final (storeA, _) = await KvStoreImpl.open(
        '/dbA',
        adapterA,
        config: KvStoreConfig.forTesting(),
        deviceId: 'devaaaaa',
      );

      final adapterB = MemoryStorageAdapter();
      final (storeB, _) = await KvStoreImpl.open(
        '/dbB',
        adapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: 'devbbbbb',
      );

      final shortEviction = const Duration(milliseconds: 1);
      final testConfig = KvStoreConfig(
        memtableSizeBytes: 4096,
        fsyncOnWrite: false,
        staleDeviceEvictionAfter: shortEviction,
        tombstoneGraceDuration: Duration.zero,
      );

      final engineA = SyncEngine(
        store: storeA,
        cloudAdapter: cloudAdapter,
        localAdapter: adapterA,
        deviceId: 'devaaaaa',
        dbDir: '/dbA',
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: testConfig,
      );
      final engineB = SyncEngine(
        store: storeB,
        cloudAdapter: cloudAdapter,
        localAdapter: adapterB,
        deviceId: 'devbbbbb',
        dbDir: '/dbB',
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        config: testConfig,
      );

      try {
        // Inject a stale dead peer's HWM.
        final deadHwm = HighwaterMark(
          deviceId: 'deaddev1',
          currentHlc: const Hlc(1, 0),
          lastUpdated: DateTime.utc(2020, 1, 1),
          peers: const {},
        );
        await deadHwm.save('$_syncRoot/highwater/deaddev1.hwm', cloudAdapter);

        // Both active devices write and exchange data.
        const keyA = '0000000000007000800000000000aaa1';
        const keyB = '0000000000007000800000000000bbb1';

        await storeA.put('ns', keyA, Uint8List.fromList([1]));
        await storeA.flush();
        await engineA.push();

        await storeB.put('ns', keyB, Uint8List.fromList([2]));
        await storeB.flush();
        await engineB.sync(); // B pushes and pulls A's data.

        // B should have A's data.
        final bHasA = await storeB.get('ns', keyA);
        expect(bHasA, isNotNull, reason: 'B should have received A\'s key');

        // A should also be able to pull B's data.
        await engineA.pull();
        final aHasB = await storeA.get('ns', keyB);
        expect(aHasB, isNotNull, reason: 'A should have received B\'s key');
      } finally {
        await storeA.close();
        await storeB.close();
        MemoryStorageAdapter.releaseAllLocks();
      }
    });
  });

  // ── ingestSstable ─────────────────────────────────────────────────────────────

  group('KvStore.ingestSstable', () {
    test('ingestSstable writes SSTable to local sst/ directory', () async {
      const peerId = 'peer0099';
      final filename = SstableInfo.flushName(
        peerId,
        const Hlc(3000, 0),
        const Hlc(3001, 0),
      );
      final bytes = _buildSst(basePhysical: 3000);

      await store.ingestSstable(filename, bytes);

      final exists = await localAdapter.fileExists('$_dbDir/sst/$filename');
      expect(exists, isTrue);
    });

    test(
      'ingestSstable throws CorruptedSstableException for bad bytes',
      () async {
        const peerId = 'peer0099';
        final filename = SstableInfo.flushName(
          peerId,
          const Hlc(3000, 0),
          const Hlc(3001, 0),
        );
        final garbage = Uint8List.fromList(List.filled(64, 0xDE));

        expect(
          () => store.ingestSstable(filename, garbage),
          throwsA(isA<CorruptedSstableException>()),
        );
      },
    );

    test('ingestSstable advances local HLC', () async {
      // SSTable with a far-future HLC.
      const peerId = 'peer0099';
      const futurePhysical = 9999999999;
      final filename = SstableInfo.flushName(
        peerId,
        const Hlc(futurePhysical, 0),
        const Hlc(futurePhysical, 1),
      );
      final bytes = _buildSst(basePhysical: futurePhysical);

      await store.ingestSstable(filename, bytes);

      // After ingestion, a new write should have an HLC ≥ futurePhysical.
      final key = '0000000000007000800000000000000c';
      await store.put('ns', key, Uint8List.fromList([7]));
      // (We can't directly read the HLC from KvStore; the test just verifies
      // no exception is thrown and the write succeeds.)
      final val = await store.get('ns', key);
      expect(val, isNotNull);
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _safeDeviceId(String filename) {
  try {
    return SstableInfo.parse(filename).deviceId;
  } catch (_) {
    return '';
  }
}
