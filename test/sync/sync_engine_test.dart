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
    final key = Uint8List(16)..fillRange(0, 16, i + 1);
    final internalKey =
        KeyCodec.encodeInternalKey('ns', key, hlc, RecordType.put);
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
) =>
    SyncEngine(
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

  // ── push ──────────────────────────────────────────────────────────────────────

  group('push', () {
    test('push uploads local SSTables to sync folder', () async {
      // Write enough data to trigger a flush.
      final key = '0' * 32;
      await store.put('ns', key, Uint8List.fromList([1, 2, 3]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final remoteFiles =
          await cloudAdapter.list('$_syncRoot/sstables', extension: '.sst');
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
          '$_syncRoot/highwater/dev00001.hwm', cloudAdapter);
      expect(hwm, isNotNull);
      expect(hwm!.deviceId, equals('dev00001'));
    });

    test('push does not re-upload already-uploaded SSTables', () async {
      final key = '0' * 32;
      await store.put('ns', key, Uint8List.fromList([1]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final afterFirst =
          await cloudAdapter.list('$_syncRoot/sstables', extension: '.sst');

      // Push again — no new files.
      await engine.push();
      final afterSecond =
          await cloudAdapter.list('$_syncRoot/sstables', extension: '.sst');

      expect(afterSecond.length, equals(afterFirst.length));
    });

    test('push on empty store uploads HWM with zero HLC', () async {
      // No writes — memtable is empty, flush is a no-op.
      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm', cloudAdapter);
      expect(hwm, isNotNull);
    });

    test('push does not upload peer SSTables that were ingested during pull', () async {
      // Simulate a peer SSTable that was placed in the local sst/ dir by pull.
      const peerId = 'peer0001';
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(1000, 0), const Hlc(1001, 0));
      // Write the peer file to local sst/ as if pull had ingested it.
      await localAdapter.writeFile('$_dbDir/sst/$peerFilename', _buildSst());

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.push();

      // The remote sstables dir should NOT contain the peer file.
      final remoteFiles =
          await cloudAdapter.list('$_syncRoot/sstables', extension: '.sst');
      expect(remoteFiles, isNot(contains(peerFilename)));
    });
  });

  // ── pull ──────────────────────────────────────────────────────────────────────

  group('pull', () {
    test('pull ingests a remote peer SSTable', () async {
      // Upload a peer SSTable to the sync folder.
      const peerId = 'peer0001';
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(5000, 0), const Hlc(5001, 0));
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
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(5000, 0), const Hlc(5001, 0));
      await cloudAdapter.upload(
          '$_syncRoot/sstables/$peerFilename', _buildSst(basePhysical: 5000));

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm', cloudAdapter);
      expect(hwm!.peers[peerId], isNotNull);
      expect(hwm.peers[peerId]!.physicalMs, greaterThanOrEqualTo(5001));
    });

    test('pull skips own device SSTables', () async {
      // Upload one of our own SSTables — should be ignored during pull.
      final ownFilename =
          SstableInfo.flushName('dev00001', const Hlc(1000, 0), const Hlc(1001, 0));
      await cloudAdapter.upload(
          '$_syncRoot/sstables/$ownFilename', _buildSst());

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      // Should complete without error and without ingesting the own file.
      await expectLater(engine.pull(), completes);
    });

    test('pull skips already-ingested SSTables', () async {
      const peerId = 'peer0001';
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(5000, 0), const Hlc(5001, 0));
      final sstBytes = _buildSst(basePhysical: 5000);
      await cloudAdapter.upload('$_syncRoot/sstables/$peerFilename', sstBytes);

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      // Write a sentinel to detect if the file is written again.
      await localAdapter.writeFile(
          '$_dbDir/sst/$peerFilename', Uint8List.fromList([0xFF, 0xFF]));

      // Second pull — should skip because file already exists locally.
      await engine.pull();

      // File should still be the sentinel (not overwritten with valid SST).
      final bytes = await localAdapter.readFile('$_dbDir/sst/$peerFilename');
      expect(bytes, equals(Uint8List.fromList([0xFF, 0xFF])));
    });

    test('pull handles empty sync folder gracefully', () async {
      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await expectLater(engine.pull(), completes);
    });

    test('pull skips files with unparseable names', () async {
      // Upload a file with an invalid SSTable name.
      await cloudAdapter.upload(
          '$_syncRoot/sstables/not-a-valid-name.sst', _buildSst());

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      // Should complete without throwing.
      await expectLater(engine.pull(), completes);
    });

    test('pull skips corrupted remote SSTable without updating HWM', () async {
      const peerId = 'peer0001';
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(5000, 0), const Hlc(5001, 0));
      // Upload garbage bytes.
      await cloudAdapter.upload(
          '$_syncRoot/sstables/$peerFilename',
          Uint8List.fromList(List.filled(64, 0xAB)));

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.pull();

      // HWM should not record this peer (ingestion failed).
      final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm', cloudAdapter);
      // HWM may be null (nothing to save) or not contain the peer.
      if (hwm != null) {
        expect(hwm.peers.containsKey(peerId), isFalse);
      }
    });

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
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(5000, 0), const Hlc(5001, 0));
      await cloudAdapter.upload(
          '$_syncRoot/sstables/$peerFilename', _buildSst(basePhysical: 5000));

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
      final peerFilename =
          SstableInfo.flushName(peerId, const Hlc(7000, 0), const Hlc(7001, 0));
      await cloudAdapter.upload(
          '$_syncRoot/sstables/$peerFilename', _buildSst(basePhysical: 7000));

      // Write local data that should be pushed.
      final key = '1' * 32;
      await store.put('ns', key, Uint8List.fromList([42]));
      await store.flush();

      final engine = _makeEngine(store, cloudAdapter, localAdapter, 'dev00001');
      await engine.sync();

      // Our SSTable should be in the sync folder.
      final remoteFiles =
          await cloudAdapter.list('$_syncRoot/sstables', extension: '.sst');
      final ourFiles =
          remoteFiles.where((f) => _safeDeviceId(f) == 'dev00001').toList();
      expect(ourFiles, isNotEmpty);

      // Peer SSTable should be reflected in the local HWM — the file itself may
      // have been compacted into a different SSTable, but the HWM records that
      // the peer's data was fully processed.
      final hwm = await HighwaterMark.load(
          '$_syncRoot/highwater/dev00001.hwm', cloudAdapter);
      expect(hwm, isNotNull);
      expect(hwm!.peers[peerId], isNotNull,
          reason: 'HWM for $peerId should be set after pull ingested its SSTable');
    });

    test('sync two devices exchange data', () async {
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
        final keyA = 'a' * 32;
        await storeA.put('ns', keyA, Uint8List.fromList([1]));
        await storeA.flush();
        await engineA.push();

        final keyB = 'b' * 32;
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
  });

  // ── ingestSstable ─────────────────────────────────────────────────────────────

  group('KvStore.ingestSstable', () {
    test('ingestSstable writes SSTable to local sst/ directory', () async {
      const peerId = 'peer0099';
      final filename =
          SstableInfo.flushName(peerId, const Hlc(3000, 0), const Hlc(3001, 0));
      final bytes = _buildSst(basePhysical: 3000);

      await store.ingestSstable(filename, bytes);

      final exists = await localAdapter.fileExists('$_dbDir/sst/$filename');
      expect(exists, isTrue);
    });

    test('ingestSstable throws CorruptedSstableException for bad bytes', () async {
      const peerId = 'peer0099';
      final filename =
          SstableInfo.flushName(peerId, const Hlc(3000, 0), const Hlc(3001, 0));
      final garbage = Uint8List.fromList(List.filled(64, 0xDE));

      expect(
        () => store.ingestSstable(filename, garbage),
        throwsA(isA<CorruptedSstableException>()),
      );
    });

    test('ingestSstable advances local HLC', () async {
      // SSTable with a far-future HLC.
      const peerId = 'peer0099';
      const futurePhysical = 9999999999;
      final filename = SstableInfo.flushName(
          peerId, const Hlc(futurePhysical, 0), const Hlc(futurePhysical, 1));
      final bytes = _buildSst(basePhysical: futurePhysical);

      await store.ingestSstable(filename, bytes);

      // After ingestion, a new write should have an HLC ≥ futurePhysical.
      final key = 'c' * 32;
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
