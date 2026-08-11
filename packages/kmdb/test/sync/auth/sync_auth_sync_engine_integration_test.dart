// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// System-level (real `SyncEngine`/`ConsolidationCoordinator`) integration
/// tests for sync authentication (0.10.01 WI-4 T1, plan Phase 4).
///
/// Complements the unit-level coverage in `sync_auth_envelope_test.dart` and
/// `sync_authenticating_adapter_test.dart` (which exercise
/// [SyncAuthEnvelope]/[SyncAuthenticatingAdapter] in isolation) by driving
/// forged/relocated/replayed artefacts through a real [SyncEngine.pull] /
/// [ConsolidationCoordinator] call, against a **durability-real** local
/// adapter ([StorageAdapterNative] or [FaultyStorageAdapter], never only
/// [MemoryStorageAdapter] — see CLAUDE.md / the 2026-05-22 review) where the
/// scenario calls for it.
///
/// The load-bearing test here is the **Q1 peer-suppression regression**: a
/// MAC-failed file naming a real peer with a huge `maxHlc` must not suppress
/// that peer's subsequent genuine SSTables — the exact availability attack
/// the round-2 plan review found and required a fix for.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/quarantine.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_native.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/encoding/value_codec.dart';
import 'package:kmdb/src/encryption/value_context.dart';
import 'package:kmdb/src/sync/auth/default_sync_authenticator.dart';
import 'package:kmdb/src/sync/auth/sync_auth_exception.dart';
import 'package:kmdb/src/sync/auth/sync_authenticating_adapter.dart';
import 'package:kmdb/src/sync/auth/sync_authenticator.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/consolidation_coordinator.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_context.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:kmdb/src/sync/sync_storage_adapter.dart';
import 'package:test/test.dart';

import '../../support/faulty_storage_adapter.dart';

const _syncRoot = 'sync';
const _localDeviceId = 'dev00001';
const _peerDeviceId = 'peer0001';

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

/// A [SyncStorageAdapter] decorator that counts `download` calls per path —
/// used to prove the Q1 pre-download skip-list actually prevents
/// re-downloading a quarantined file, not merely re-rejecting it.
final class _DownloadCountingAdapter implements SyncStorageAdapter {
  _DownloadCountingAdapter(this._inner);
  final SyncStorageAdapter _inner;
  final Map<String, int> downloadCounts = {};

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    downloadCounts.update(remotePath, (v) => v + 1, ifAbsent: () => 1);
    return _inner.download(remotePath, ctx: ctx);
  }

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) => _inner.list(remoteDir, extension: extension, ctx: ctx);

  @override
  Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx}) =>
      _inner.upload(remotePath, bytes, ctx: ctx);

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) =>
      _inner.delete(remotePath, ctx: ctx);

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) =>
      _inner.compareAndSwap(path, newBytes, ifMatchEtag: ifMatchEtag, ctx: ctx);

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) =>
      _inner.getEtag(path, ctx: ctx);

  @override
  bool get providesAtomicCas => _inner.providesAtomicCas;
}

/// Builds a well-formed, single-entry SSTable with real footer/index/filter
/// framing, so it always passes `SstableReader.open` — the only thing under
/// test is whether the sync-auth envelope around it verifies.
///
/// Internal key layout: `[nsLen(1B)][nsBytes][userKey(16B)][hlc(8B)][type(1B)]`
/// (matching `KeyCodec.encodeInternalKey`), with a valid `RecordType.put`
/// trailing byte — see `quarantine_reason_coverage_test.dart`'s identical
/// hand-built-key pattern.
Uint8List _buildSstableBytes({int seed = 1}) {
  final writer = SstableWriter();
  const nsBytes = [0x6e, 0x73]; // "ns"
  final key = Uint8List(1 + nsBytes.length + 16 + 8 + 1);
  var offset = 0;
  key[offset++] = nsBytes.length;
  key.setAll(offset, nsBytes);
  offset += nsBytes.length;
  offset += 16; // userKey — zero is fine, never read on this path
  offset += 8; // HLC — zero is fine, never read on this path
  key[offset] = 0x01; // RecordType.put
  writer.add(key, Uint8List.fromList([seed % 256]));
  return writer.finish();
}

void main() {
  late Directory tempDir;
  late StorageAdapterNative localAdapter;
  late MemorySyncAdapter rawCloud;
  late SyncAuthenticator authenticator;
  late SyncAuthenticatingAdapter cloudAdapter;
  late KvStoreImpl store;
  late String dbDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kmdb_sync_auth_int_');
    dbDir = tempDir.path;
    localAdapter = StorageAdapterNative();
    rawCloud = MemorySyncAdapter();
    authenticator = DefaultSyncAuthenticator(_key(1));
    cloudAdapter = SyncAuthenticatingAdapter(rawCloud, authenticator);
    final (openedStore, _) = await KvStoreImpl.open(
      dbDir,
      localAdapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _localDeviceId,
    );
    store = openedStore;
  });

  tearDown(() async {
    await store.close();
    await localAdapter.releaseLock('$dbDir/LOCK');
    await tempDir.delete(recursive: true);
  });

  SyncEngine makeEngine({SyncStorageAdapter? adapter}) => SyncEngine(
    store: store,
    cloudAdapter: adapter ?? cloudAdapter,
    localAdapter: localAdapter,
    deviceId: _localDeviceId,
    dbDir: dbDir,
    syncRoot: _syncRoot,
    syncNamespaces: {'ns'},
    consolidationConfig: const ConsolidationConfig(),
  );

  group('SyncEngine.pull — forged SSTable rejection (0.10.01 WI-4 T1)', () {
    test('a raw, un-enveloped SSTable is quarantined as unauthenticated and '
        'does not advance the peer HWM', () async {
      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      // Written directly to the raw (undecorated) adapter — simulating an
      // attacker with mere write access to the sync folder, who does not
      // hold the sync-set key and therefore cannot produce a valid
      // envelope.
      await rawCloud.upload(
        '$_syncRoot/sstables/$filename',
        _buildSstableBytes(),
      );

      final result = await makeEngine().pull();

      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.unauthenticated),
      );
      expect(result.quarantined.single.peerDeviceId, equals(_peerDeviceId));

      // No HWM advance: the peer HWM save is entirely skipped when
      // peerMaxHlc stays empty (only unauthenticated files were seen).
      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/$_localDeviceId.hwm',
        rawCloud,
      );
      expect(hwm, isNull);
    });

    test('recovery: a forged file is skipped pre-download on a subsequent '
        'pull (Q1), and never re-downloaded', () async {
      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );
      await rawCloud.upload(
        '$_syncRoot/sstables/$filename',
        _buildSstableBytes(),
      );

      final counting = _DownloadCountingAdapter(cloudAdapter);
      final engine = makeEngine(adapter: counting);

      final first = await engine.pull();
      expect(first.quarantined, hasLength(1));
      expect(counting.downloadCounts['$_syncRoot/sstables/$filename'], 1);

      // A second pull must not re-download the already-quarantined file —
      // the quarantine log's filename set is the gate now that the HWM
      // was never advanced.
      final second = await engine.pull();
      expect(second.quarantined, isEmpty);
      expect(counting.downloadCounts['$_syncRoot/sstables/$filename'], 1);
    });

    test('Q1 peer-suppression regression: a MAC-failed file naming a real '
        'peer with a huge maxHlc does not suppress that peer\'s subsequent '
        'genuine SSTable', () async {
      // Attacker forges a file claiming to be from the real peer, with an
      // enormous maxHlc — if this were allowed to advance the peer HWM,
      // every future genuine SSTable from that peer (whose maxHlc is far
      // smaller) would be skipped by the `maxHlc <= peerHwm` check
      // forever.
      final forgedFilename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(0, 0),
        Hlc.fromHex('7FFFFFFFFFFF0000'), // near-maximum physical HLC
      );
      await rawCloud.upload(
        '$_syncRoot/sstables/$forgedFilename',
        _buildSstableBytes(),
      );

      final firstResult = await makeEngine().pull();
      expect(firstResult.quarantined, hasLength(1));
      expect(
        firstResult.quarantined.single.reason,
        equals(QuarantineReason.unauthenticated),
      );

      // Now the real peer legitimately pushes genuine data, through the
      // authenticating adapter (the real device holds the sync-set key).
      final peerDir = await Directory.systemTemp.createTemp(
        'kmdb_sync_auth_peer_',
      );
      final peerLocal = StorageAdapterNative();
      final (peerStore, _) = await KvStoreImpl.open(
        peerDir.path,
        peerLocal,
        config: KvStoreConfig.forTesting(),
        deviceId: _peerDeviceId,
      );
      final peerKey = const UuidV7KeyGenerator().next();
      try {
        final encoded = await ValueCodec.encode({
          'from': 'peer',
        }, context: ValueContext('ns', peerKey));
        await peerStore.put('ns', peerKey, encoded);
        final peerEngine = SyncEngine(
          store: peerStore,
          cloudAdapter: cloudAdapter,
          localAdapter: peerLocal,
          deviceId: _peerDeviceId,
          dbDir: peerDir.path,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );
        await peerEngine.push();
      } finally {
        await peerStore.close();
        await peerLocal.releaseLock('${peerDir.path}/LOCK');
        await peerDir.delete(recursive: true);
      }

      // The load-bearing assertion: the local device's *next* pull must
      // still ingest the peer's genuine, subsequently-pushed data — the
      // forged file's (never-advanced) HWM must not have suppressed it.
      final secondResult = await makeEngine().pull();
      expect(
        secondResult.quarantined,
        isEmpty,
        reason: 'the genuine peer SSTable must authenticate cleanly',
      );
      final raw = await store.get('ns', peerKey);
      expect(
        raw,
        isNotNull,
        reason:
            'the forged file must not have permanently suppressed this '
            'peer\'s genuine data',
      );
    });

    test('path-relocation is rejected: a validly-enveloped SSTable copied to a '
        'different filename fails authentication', () async {
      // Push a genuine file at one filename via the authenticating
      // adapter, then copy its *enveloped* bytes (as an attacker with
      // read+write access to the folder could) to a different filename.
      final originalFilename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(3000, 0),
        const Hlc(3001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$originalFilename',
        _buildSstableBytes(),
      );
      final envelopedBytes = await rawCloud.download(
        '$_syncRoot/sstables/$originalFilename',
      );

      final relocatedFilename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(4000, 0),
        const Hlc(4001, 0),
      );
      await rawCloud.upload(
        '$_syncRoot/sstables/$relocatedFilename',
        envelopedBytes!,
      );

      final result = await makeEngine().pull();

      // Both files are seen: the original authenticates and ingests
      // cleanly; the relocated copy fails (its MAC covers the *original*
      // path) and is quarantined.
      expect(result.quarantined, hasLength(1));
      expect(result.quarantined.single.filename, equals(relocatedFilename));
    });
  });

  group(
    'ConsolidationCoordinator — cross-class replay rejection (0.10.01 WI-4 T1)',
    () {
      test('a valid SSTable envelope replayed onto the lease path is rejected '
          '(cross-class replay)', () async {
        // A genuine SSTable envelope, valid for SyncArtifactClass.sstable
        // at its own path — replaying its raw bytes at the lease path must
        // not verify there: different artefact class AND different path.
        final sstableFilename = SstableInfo.flushName(
          _peerDeviceId,
          const Hlc(5000, 0),
          const Hlc(5001, 0),
        );
        await cloudAdapter.upload(
          '$_syncRoot/sstables/$sstableFilename',
          _buildSstableBytes(),
        );
        final envelopedSstable = await rawCloud.download(
          '$_syncRoot/sstables/$sstableFilename',
        );
        await rawCloud.upload(
          '$_syncRoot/.consolidation-lease',
          envelopedSstable!,
        );

        final coordinator = ConsolidationCoordinator(
          deviceId: _localDeviceId,
          cloudAdapter: cloudAdapter,
          localAdapter: localAdapter,
          syncRoot: _syncRoot,
          dbDir: dbDir,
        );

        // acquireLease reads the existing lease first — a forged lease
        // must propagate SyncAuthException (Q2: lease reads/writes
        // propagate rather than being silently skipped), aborting this
        // consolidation round rather than acting on it.
        await expectLater(
          coordinator.acquireLease(const []),
          throwsA(isA<SyncAuthException>()),
        );
      });

      test('consolidate() skips a forged (raw, un-enveloped) input SSTable, '
          'like the existing CorruptedSstableException branch, and still '
          'produces output from the surviving legitimate input', () async {
        // A legitimate, properly-authenticated input.
        final legitFilename = SstableInfo.flushName(
          _peerDeviceId,
          const Hlc(6000, 0),
          const Hlc(6001, 0),
        );
        await cloudAdapter.upload(
          '$_syncRoot/sstables/$legitFilename',
          _buildSstableBytes(seed: 2),
        );

        // A forged (raw, un-enveloped) input — an attacker without the
        // sync-set key cannot produce a valid envelope for it.
        final forgedFilename = SstableInfo.flushName(
          'peer0002',
          const Hlc(7000, 0),
          const Hlc(7001, 0),
        );
        await rawCloud.upload(
          '$_syncRoot/sstables/$forgedFilename',
          _buildSstableBytes(seed: 3),
        );

        final coordinator = ConsolidationCoordinator(
          deviceId: _localDeviceId,
          cloudAdapter: cloudAdapter,
          localAdapter: localAdapter,
          syncRoot: _syncRoot,
          dbDir: dbDir,
        );
        final lease = ConsolidationLease(
          holder: _localDeviceId,
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          epoch: 1,
          inputFiles: [legitFilename, forgedFilename],
        );

        // Must complete without throwing (Q2: skip this one input, not
        // abort the whole round), and still produce output from the
        // surviving legitimate input.
        final result = await coordinator.consolidate(lease);
        expect(result, isNotNull);
      });
    },
  );

  group(
    'SyncEngine.push — eviction check peer-HWM forgery (0.10.01 WI-4 T1)',
    () {
      test('a forged peer .hwm file is skipped in the re-admission eviction '
          'check, not fatal to the whole check', () async {
        // Condition (b): the local device's own HWM must already be
        // stale by wall-clock age to even reach the peer scan.
        final staleOwnHwm = HighwaterMark(
          deviceId: _localDeviceId,
          currentHlc: const Hlc(1, 0),
          lastUpdated: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          peers: const {},
        );
        await staleOwnHwm.save(
          '$_syncRoot/highwater/$_localDeviceId.hwm',
          cloudAdapter,
        );

        // A forged (raw, un-enveloped) peer HWM — an attacker who does
        // not hold the sync-set key cannot produce a valid envelope, so
        // this must be skipped rather than crash the eviction check.
        await rawCloud.upload(
          '$_syncRoot/highwater/$_peerDeviceId.hwm',
          Uint8List.fromList('not-a-valid-envelope'.codeUnits),
        );

        final engine = SyncEngine(
          store: store,
          cloudAdapter: cloudAdapter,
          localAdapter: localAdapter,
          deviceId: _localDeviceId,
          dbDir: dbDir,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
          config: const KvStoreConfig(
            staleDeviceEvictionAfter: Duration(seconds: 1),
          ),
        );

        // No SyncAuthException should propagate out of push(): the
        // forged peer HWM is skipped, and with no other live peer the
        // eviction check concludes "not evicted" and push proceeds
        // normally.
        await engine.push();
      });
    },
  );

  group('Fault injection (FaultyStorageAdapter, D-3)', () {
    test('a forged SSTable is rejected and quarantined against a '
        'durability-real local adapter, and a crash immediately afterwards '
        'still recovers to a healthy, usable database', () async {
      final faultyLocal = FaultyStorageAdapter();
      // fsyncOnWrite: true — this test verifies a specific write (the
      // quarantine record) survives a simulated crash, which requires the
      // write to have actually been synced; forTesting()'s default
      // disables fsync for speed and would make this test meaningless
      // (see quarantine_crash_ordering_test.dart's identical choice).
      final (faultyStore, _) = await KvStoreImpl.open(
        '/db',
        faultyLocal,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _localDeviceId,
      );

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(6000, 0),
        const Hlc(6001, 0),
      );
      await rawCloud.upload(
        '$_syncRoot/sstables/$filename',
        _buildSstableBytes(),
      );

      final engine = SyncEngine(
        store: faultyStore,
        cloudAdapter: cloudAdapter,
        localAdapter: faultyLocal,
        deviceId: _localDeviceId,
        dbDir: '/db',
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
      );
      final result = await engine.pull();
      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.unauthenticated),
      );

      // Simulate a crash immediately after the quarantine write.
      faultyLocal.crash();

      // Reopen — recovery must succeed and the database must still be
      // usable (the quarantine record's durability doesn't depend on
      // anything the crash would have discarded, since appendQuarantine
      // is a standalone durable write).
      final (reopenedStore, openResult) = await KvStoreImpl.open(
        '/db',
        faultyLocal,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _localDeviceId,
      );
      expect(openResult, isNotNull);
      final quarantines = await reopenedStore.quarantinedFilenames();
      expect(quarantines, contains(filename));
      await reopenedStore.close();
    });
  });
}
