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

/// End-to-end reproductions of the 2026-07-18 release-readiness review's
/// PEER-A/PEER-B probes, run against a **real on-disk database**
/// ([StorageAdapterNative]) rather than [MemoryStorageAdapter].
///
/// `test/sync/sync_engine_test.dart` — the primary [SyncEngine] suite —
/// hardcodes [MemoryStorageAdapter] in its `setUp`. The review found that
/// this hides the most severe form of S-1: [MemoryStorageAdapter] bounds-
/// checks `readFileRange` where [StorageAdapterNative] previously did not,
/// converting an uncatchable `OutOfMemoryError` into a catchable
/// `StorageException`. This file exercises the same `pull()` ingest path
/// against the native adapter so that class of bug is actually visible to
/// the test suite (Phase 8 of the sync-trust-boundary plan; D-3 in the
/// review names this exact gap).
///
/// The load-bearing test here is `recovery after quarantine`: every other
/// assertion in this file (and in `sstable_hostile_parsing_test.dart`) shows
/// a hostile file is *rejected*. S-1's actual harm was **persistent**
/// denial-of-sync — the same poisoned file re-downloaded and re-rejected on
/// every pull, forever. Asserting the HWM advances past it and a
/// *subsequent* pull still ingests *new, legitimate* data is what actually
/// proves the fix, not just the rejection.
library;

import 'dart:io';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_native.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:test/test.dart';

import '../util/hostile_sstable.dart';

void main() {
  late Directory tempDir;
  late StorageAdapterNative localAdapter;
  late MemorySyncAdapter cloudAdapter;
  late KvStoreImpl store;
  late String dbDir;

  const syncRoot = 'sync';
  const localDeviceId = 'dev00001';
  const peerDeviceId = 'peer0001';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kmdb_native_sync_trust_');
    dbDir = tempDir.path;
    localAdapter = StorageAdapterNative();
    cloudAdapter = MemorySyncAdapter();
    final (openedStore, _) = await KvStoreImpl.open(
      dbDir,
      localAdapter,
      config: KvStoreConfig.forTesting(),
      deviceId: localDeviceId,
    );
    store = openedStore;
  });

  tearDown(() async {
    await store.close();
    await localAdapter.releaseLock('$dbDir/LOCK');
    await tempDir.delete(recursive: true);
  });

  SyncEngine makeEngine() => SyncEngine(
    store: store,
    cloudAdapter: cloudAdapter,
    localAdapter: localAdapter,
    deviceId: localDeviceId,
    dbDir: dbDir,
    syncRoot: syncRoot,
    syncNamespaces: {'test'},
    consolidationConfig: const ConsolidationConfig(),
  );

  group('SyncEngine.pull against StorageAdapterNative (S-1, D-3)', () {
    test('PEER-A/B — a checksum-valid, structurally hostile peer SSTable does '
        'not crash pull(), and does not produce an OutOfMemoryError', () async {
      final hostile = patchFooterField(
        buildValidSstable(basePhysical: 9000),
        field: FooterField.filterSize,
        value: 1 << 40,
      );
      final peerFilename = SstableInfo.flushName(
        peerDeviceId,
        const Hlc(9000, 0),
        const Hlc(9003, 0),
      );
      await cloudAdapter.upload('$syncRoot/sstables/$peerFilename', hostile);

      final engine = makeEngine();
      // Must complete without throwing — this is the actual regression:
      // prior to the S-1 fix, this call could surface an uncatchable
      // OutOfMemoryError on this exact adapter.
      await expectLater(engine.pull(), completes);
    });

    test('recovery after quarantine — HWM advances past a rejected hostile '
        'file, and a subsequent pull() still ingests new legitimate data '
        '(the load-bearing S-1 assertion)', () async {
      // 1. Upload a hostile file from the peer.
      final hostileFilename = SstableInfo.flushName(
        peerDeviceId,
        const Hlc(9000, 0),
        const Hlc(9003, 0),
      );
      final hostileBytes = patchFooterField(
        buildValidSstable(basePhysical: 9000),
        field: FooterField.filterSize,
        value: 1 << 40,
      );
      await cloudAdapter.upload(
        '$syncRoot/sstables/$hostileFilename',
        hostileBytes,
      );

      final engine = makeEngine();
      await engine.pull();

      // 2. The peer HWM must have advanced past the hostile file's maxHlc
      //    — quarantined, not retried forever.
      final hwmAfterFirstPull = await HighwaterMark.load(
        '$syncRoot/highwater/$localDeviceId.hwm',
        cloudAdapter,
      );
      expect(hwmAfterFirstPull, isNotNull);
      expect(
        hwmAfterFirstPull!.peers[peerDeviceId],
        equals(const Hlc(9003, 0)),
      );

      // 3. The peer now uploads a *legitimate* SSTable with a later HLC
      //    range. A healthy sync cycle must still pick this up — proving
      //    the earlier hostile file did not permanently wedge this device
      //    against this peer.
      final legitimateFilename = SstableInfo.flushName(
        peerDeviceId,
        const Hlc(9100, 0),
        const Hlc(9103, 0),
      );
      final legitimateBytes = buildValidSstable(basePhysical: 9100);
      await cloudAdapter.upload(
        '$syncRoot/sstables/$legitimateFilename',
        legitimateBytes,
      );

      await engine.pull();

      final hwmAfterSecondPull = await HighwaterMark.load(
        '$syncRoot/highwater/$localDeviceId.hwm',
        cloudAdapter,
      );
      expect(
        hwmAfterSecondPull!.peers[peerDeviceId],
        equals(const Hlc(9103, 0)),
        reason:
            'a subsequent pull() must still advance past new legitimate '
            'peer data — the earlier hostile file must not have '
            'permanently broken sync with this peer',
      );

      // 4. And the legitimate data must actually be queryable locally —
      //    not just "HWM advanced" bookkeeping, but real ingested content.
      final scanned = <String>[];
      await for (final entry in store.scan('test')) {
        scanned.add(entry.key);
      }
      expect(
        scanned,
        isNotEmpty,
        reason: 'the legitimate peer SSTable must have been ingested',
      );
    });
  });
}
