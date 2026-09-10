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

/// Fault-injection regression tests for the `close(flush:true)` /
/// tombstone-GC-horizon `SyncAuthException` hardening
/// (`docs/plans/completed/plan_0_10_01_close_flush_syncauth_horizon.md`,
/// found by `kmdb-qa`'s finding #2 during the 0.1.0 integration-guide review).
///
/// ## The bug
///
/// When the sync folder contains a peer `.hwm` file this device cannot
/// authenticate (a forged file, or one enveloped under a different sync-set
/// key), the *next* `close(flush: true)` could throw an uncaught
/// `SyncAuthException` from deep inside the tombstone-GC-horizon computation
/// (`SyncEngine`'s `setTombstoneHorizonProvider` closure →
/// `HighwaterMark.minCurrentHlcAcrossDevices` → `HighwaterMark.load` →
/// `SyncAuthEnvelope.unwrap`), reached via `LsmEngine.close` → `flush()` →
/// `_compactIfNeeded()`'s single-file compaction shortcut → `_compactAll()` →
/// `_computeTombstoneHorizon()`. The throw escaped `close()` **before** it
/// released the LOCK file — a LOCK leak, not data loss.
///
/// ## The fix
///
/// The horizon-provider closure in `sync_engine.dart` now catches
/// `SyncAuthException` and returns the conservative `Hlc(0, 0)` — deferring
/// (blocking) all tombstone drops for that round rather than skipping the
/// unauthenticatable peer's contribution to the `min`. Skipping would *raise*
/// the horizon and risk tombstone resurrection on a genuinely-behind peer
/// under §34's T1 threat model (a mere write-access attacker can forge any
/// `.hwm` filename). See `docs/spec/34_sync_authentication.md`'s
/// per-site rejection-policy table for the full rationale.
///
/// ## Test structure
///
/// - **T1** reproduces the exact failure chain end-to-end with two real
///   [KvStoreImpl] instances sharing a [MemorySyncAdapter] "sync folder",
///   using mismatched [DefaultSyncAuthenticator] root keys (the fault is a
///   MAC key mismatch, not a disk fault, so an in-memory sync adapter
///   genuinely reproduces the bug — no [FaultyStorageAdapter] is needed for
///   this scenario). This asserts `close(flush: true)` completes (rather
///   than throwing) and that a fresh `open()` on the same directory
///   afterwards succeeds with data intact.
/// - **T2** proves the fix *defers* GC rather than *skips* the bad peer: with
///   a bad `.hwm` present alongside a genuine authenticated peer whose
///   `currentHlc` is far ahead of a local tombstone, the tombstone must
///   survive a `_compactAll` (it would be dropped under the rejected "skip"
///   disposition, since skipping would let the authenticated peer's `min`
///   through unobstructed).
/// - **T3** proves the defer is transient: once the bad `.hwm` is removed,
///   the next `_compactAll` resumes normal GC and drops the same tombstone.
///
/// T4 (a direct unit test invoking the registered provider) is intentionally
/// omitted per the plan — the catch branch and its `Hlc(0, 0)` return are
/// already fully exercised end-to-end by T1 (no-throw) and T2 (defer, not
/// skip), and there is no public getter for the registered provider.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/quarantine.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_native.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/auth/default_sync_authenticator.dart';
import 'package:kmdb/src/sync/auth/sync_authenticating_adapter.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:test/test.dart';

const _syncRoot = 'sync';
const _deviceA = 'devA0001'; // pushes real data + its own .hwm, key1
const _deviceB = 'devB0001'; // the device under test, key2 (cannot auth A)
const _deviceC = 'devC0001'; // a genuine peer authenticated with B's key2

/// Deterministic 32-byte MAC root key, distinct per [seed].
Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

/// Scans every `.sst` file directly reachable from [adapter] under [dbDir]'s
/// `sst/` subdirectory and counts entries whose user key equals [key].
///
/// Used to prove *physical* tombstone retention/removal — `store.get()`
/// returns `null` for a deleted key regardless of whether the tombstone was
/// actually reclaimed, so it cannot distinguish "deferred" from "dropped".
/// Mirrors the pattern in `lsm_engine_test.dart`'s PR2 horizon tests.
Future<int> _countSstEntriesForKey(
  StorageAdapterNative adapter,
  String dbDir,
  String key,
) async {
  final keyBytes = KeyCodec.keyToBytes(key);
  final sstDir = '$dbDir/sst';
  final filenames = await adapter.listFiles(sstDir, extension: '.sst');
  var matches = 0;
  for (final filename in filenames) {
    final reader = await SstableReader.open('$sstDir/$filename', adapter);
    await for (final entry in reader.scan()) {
      final entryKey = KeyCodec.decodeUserKey(entry.key);
      if (entryKey.length == keyBytes.length) {
        var equal = true;
        for (var i = 0; i < entryKey.length; i++) {
          if (entryKey[i] != keyBytes[i]) {
            equal = false;
            break;
          }
        }
        if (equal) matches++;
      }
    }
  }
  return matches;
}

void main() {
  group('T1 — close(flush:true) survives an unauthenticatable peer .hwm', () {
    test('close(flush: true) completes (does not throw SyncAuthException), '
        'releases the LOCK, and B\'s data survives a fresh open()', () async {
      final rawCloud = MemorySyncAdapter();

      // ── Device A: writes a document, flushes, and pushes — uploading
      // both A's SSTable and A's <A>.hwm, both enveloped under key1. ──
      final tempDirA = await Directory.systemTemp.createTemp(
        'kmdb_close_horizon_a_',
      );
      final localAdapterA = StorageAdapterNative();
      final (storeA, _) = await KvStoreImpl.open(
        tempDirA.path,
        localAdapterA,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceA,
      );
      try {
        final keyA = SequentialKeyGenerator(start: 1).next();
        await storeA.put('ns', keyA, Uint8List.fromList([1, 2, 3]));
        await storeA.flush();

        final authenticatorA = DefaultSyncAuthenticator(_key(1));
        final cloudAdapterA = SyncAuthenticatingAdapter(
          rawCloud,
          authenticatorA,
        );
        final engineA = SyncEngine(
          store: storeA,
          cloudAdapter: cloudAdapterA,
          localAdapter: localAdapterA,
          deviceId: _deviceA,
          dbDir: tempDirA.path,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );
        await engineA.push();
      } finally {
        await storeA.close();
        await localAdapterA.releaseLock('${tempDirA.path}/LOCK');
        await tempDirA.delete(recursive: true);
      }

      // ── Device B: pulls with a *different* root key (key2) — A's SSTable
      // is quarantined as unauthenticated, and A's .hwm is left untouched
      // in `highwater/`, unauthenticatable by B. ──
      final tempDirB = await Directory.systemTemp.createTemp(
        'kmdb_close_horizon_b_',
      );
      final dbDirB = tempDirB.path;
      final localAdapterB = StorageAdapterNative();
      final (storeB, _) = await KvStoreImpl.open(
        dbDirB,
        localAdapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceB,
      );

      final authenticatorB = DefaultSyncAuthenticator(_key(2));
      final cloudAdapterB = SyncAuthenticatingAdapter(rawCloud, authenticatorB);
      final engineB = SyncEngine(
        store: storeB,
        cloudAdapter: cloudAdapterB,
        localAdapter: localAdapterB,
        deviceId: _deviceB,
        dbDir: dbDirB,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
      );

      final pullResult = await engineB.pull();
      expect(
        pullResult.quarantined,
        hasLength(1),
        reason: 'A\'s SSTable must be quarantined as unauthenticated by B',
      );
      expect(
        pullResult.quarantined.single.reason,
        equals(QuarantineReason.unauthenticated),
      );

      // ── Force the single-file compaction shortcut inside the upcoming
      // close(flush:true): two small L0 files, well under
      // KvStoreConfig.forTesting()'s 8KB singleFileThresholdBytes. ──
      final keyB1 = SequentialKeyGenerator(start: 100).next();
      final keyB2 = SequentialKeyGenerator(start: 200).next();
      await storeB.put('ns', keyB1, Uint8List.fromList([9]));
      await storeB.flush(); // first L0 file
      await storeB.put('ns', keyB2, Uint8List.fromList([10]));
      // keyB2 stays in the active memtable — close(flush:true) flushes it,
      // producing a second L0 file and triggering _compactIfNeeded's
      // single-file shortcut, which invokes the horizon provider.

      // The load-bearing assertion: this must complete, not throw
      // SyncAuthException. (Verified separately, by temporarily reverting
      // the fix, that this line throws pre-fix.)
      await storeB.close(flush: true);

      // Confirm the LOCK was released and B's data survives: a fresh
      // KvStoreImpl.open() on the same directory (with a brand-new
      // StorageAdapterNative instance) must succeed, and both documents
      // written above must still be readable.
      final newLocalAdapterB = StorageAdapterNative();
      final (reopenedStore, openResult) = await KvStoreImpl.open(
        dbDirB,
        newLocalAdapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceB,
      );
      expect(openResult, isNotNull);
      expect(await reopenedStore.get('ns', keyB1), isNotNull);
      expect(await reopenedStore.get('ns', keyB2), isNotNull);
      await reopenedStore.close();
      await newLocalAdapterB.releaseLock('$dbDirB/LOCK');

      await tempDirB.delete(recursive: true);
    });
  });

  group('T2 — the horizon is deferred, not advanced, while a bad HWM is '
      'present', () {
    test('a tombstone below an authenticated peer\'s min is retained (not '
        'skip-and-advance)', () async {
      final rawCloud = MemorySyncAdapter();

      // A's forged/unauthenticatable-by-B .hwm — enveloped under key1.
      final authenticatorA = DefaultSyncAuthenticator(_key(1));
      final cloudAdapterA = SyncAuthenticatingAdapter(rawCloud, authenticatorA);
      final badHwm = HighwaterMark(
        deviceId: _deviceA,
        currentHlc: const Hlc(500, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await badHwm.save('$_syncRoot/highwater/$_deviceA.hwm', cloudAdapterA);

      // C's genuine, B-authenticatable .hwm (key2, same as B) with a
      // currentHlc far ahead of any tombstone B will write below — under
      // the rejected "skip" disposition this would let B's tombstone GC
      // proceed using C's min alone.
      final authenticatorC = DefaultSyncAuthenticator(_key(2));
      final cloudAdapterC = SyncAuthenticatingAdapter(rawCloud, authenticatorC);
      final farFutureHlc = Hlc(
        DateTime.now().millisecondsSinceEpoch + 1000000000,
        0,
      );
      final goodHwm = HighwaterMark(
        deviceId: _deviceC,
        currentHlc: farFutureHlc,
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await goodHwm.save('$_syncRoot/highwater/$_deviceC.hwm', cloudAdapterC);

      // Device B: write + delete a key (tombstone at "now", far below
      // C's currentHlc), producing two small L0 files so the single-file
      // shortcut fires on the next compactAll().
      final tempDirB = await Directory.systemTemp.createTemp(
        'kmdb_close_horizon_t2_',
      );
      final dbDirB = tempDirB.path;
      final localAdapterB = StorageAdapterNative();
      final (storeB, _) = await KvStoreImpl.open(
        dbDirB,
        localAdapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceB,
      );
      try {
        final authenticatorB = DefaultSyncAuthenticator(_key(2));
        final cloudAdapterB = SyncAuthenticatingAdapter(
          rawCloud,
          authenticatorB,
        );
        // Constructing SyncEngine registers the horizon provider on storeB.
        SyncEngine(
          store: storeB,
          cloudAdapter: cloudAdapterB,
          localAdapter: localAdapterB,
          deviceId: _deviceB,
          dbDir: dbDirB,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );

        final key = SequentialKeyGenerator(start: 1).next();
        await storeB.put('ns', key, Uint8List.fromList([1]));
        await storeB.flush(); // first L0 file
        await storeB.delete('ns', key);
        await storeB.flush(); // second L0 file (tombstone)

        // Drives _compactIfNeeded → single-file shortcut →_compactAll →
        // the horizon provider, which must catch SyncAuthException on
        // A's bad .hwm and defer to Hlc(0, 0) rather than throw or skip.
        await storeB.compactAll();

        // Proof this is "defer", not "skip": if the bad peer's
        // contribution were simply skipped, the horizon would be C's
        // far-future min and this tombstone (HLC ~ now) would have been
        // physically dropped. It must still be present on disk.
        final matches = await _countSstEntriesForKey(
          localAdapterB,
          dbDirB,
          key,
        );
        expect(
          matches,
          equals(1),
          reason:
              'the tombstone must be retained — deferring GC, not '
              'advancing the horizon past the bad peer',
        );
      } finally {
        await storeB.close();
        await localAdapterB.releaseLock('$dbDirB/LOCK');
        await tempDirB.delete(recursive: true);
      }
    });
  });

  group('T3 — GC resumes once the bad HWM is removed', () {
    test('removing the bad .hwm lets the next compaction advance the horizon '
        'and drop the eligible tombstone', () async {
      final rawCloud = MemorySyncAdapter();

      final authenticatorA = DefaultSyncAuthenticator(_key(1));
      final cloudAdapterA = SyncAuthenticatingAdapter(rawCloud, authenticatorA);
      final badHwm = HighwaterMark(
        deviceId: _deviceA,
        currentHlc: const Hlc(500, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      final badHwmPath = '$_syncRoot/highwater/$_deviceA.hwm';
      await badHwm.save(badHwmPath, cloudAdapterA);

      final authenticatorC = DefaultSyncAuthenticator(_key(2));
      final cloudAdapterC = SyncAuthenticatingAdapter(rawCloud, authenticatorC);
      final farFutureHlc = Hlc(
        DateTime.now().millisecondsSinceEpoch + 1000000000,
        0,
      );
      final goodHwm = HighwaterMark(
        deviceId: _deviceC,
        currentHlc: farFutureHlc,
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await goodHwm.save('$_syncRoot/highwater/$_deviceC.hwm', cloudAdapterC);

      final tempDirB = await Directory.systemTemp.createTemp(
        'kmdb_close_horizon_t3_',
      );
      final dbDirB = tempDirB.path;
      final localAdapterB = StorageAdapterNative();
      final (storeB, _) = await KvStoreImpl.open(
        dbDirB,
        localAdapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceB,
      );
      try {
        final authenticatorB = DefaultSyncAuthenticator(_key(2));
        final cloudAdapterB = SyncAuthenticatingAdapter(
          rawCloud,
          authenticatorB,
        );
        SyncEngine(
          store: storeB,
          cloudAdapter: cloudAdapterB,
          localAdapter: localAdapterB,
          deviceId: _deviceB,
          dbDir: dbDirB,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );

        final key = SequentialKeyGenerator(start: 1).next();
        await storeB.put('ns', key, Uint8List.fromList([1]));
        await storeB.flush();
        await storeB.delete('ns', key);
        await storeB.flush();

        // First compaction: bad HWM present → deferred, tombstone
        // retained (mirrors T2).
        await storeB.compactAll();
        expect(
          await _countSstEntriesForKey(localAdapterB, dbDirB, key),
          equals(1),
          reason:
              'sanity check: tombstone retained while the bad HWM '
              'is still present',
        );

        // Remove the bad HWM — the sync set "heals" (re-enrollment, or
        // simply deleting the stale/forged artefact).
        await rawCloud.delete(badHwmPath);

        // Add one more L0 file so the single-file shortcut fires again
        // (the prior compactAll already collapsed everything into one
        // L2 file; totalFiles must be > 1 to re-trigger).
        final otherKey = SequentialKeyGenerator(start: 2).next();
        await storeB.put('ns', otherKey, Uint8List.fromList([2]));
        await storeB.flush();

        await storeB.compactAll();

        // Now only C's (authenticated, far-future) HWM remains live, so
        // the horizon advances past the tombstone's HLC and it is
        // physically dropped.
        expect(
          await _countSstEntriesForKey(localAdapterB, dbDirB, key),
          equals(0),
          reason:
              'once the bad HWM is gone, GC must resume and drop the '
              'now-eligible tombstone',
        );
      } finally {
        await storeB.close();
        await localAdapterB.releaseLock('$dbDirB/LOCK');
        await tempDirB.delete(recursive: true);
      }
    });
  });

  group('Sanity — happy-path horizon computation from authenticated peers '
      'only', () {
    test('with only authenticated peer HWMs present, the horizon equals '
        'min(currentHlc) across them', () async {
      final rawCloud = MemorySyncAdapter();
      final authenticator = DefaultSyncAuthenticator(_key(2));
      final cloudAdapter = SyncAuthenticatingAdapter(rawCloud, authenticator);

      // Two authenticated peers, both using the same key as B.
      final lowerHwm = HighwaterMark(
        deviceId: 'peerlow1',
        currentHlc: const Hlc(1000, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await lowerHwm.save('$_syncRoot/highwater/peerlow1.hwm', cloudAdapter);
      final higherHwm = HighwaterMark(
        deviceId: 'peerhi01',
        currentHlc: const Hlc(9999999, 0),
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await higherHwm.save('$_syncRoot/highwater/peerhi01.hwm', cloudAdapter);

      final min = await HighwaterMark.minCurrentHlcAcrossDevices(
        '$_syncRoot/highwater',
        cloudAdapter,
        localDeviceId: _deviceB,
      );
      expect(min, equals(const Hlc(1000, 0)));
    });

    test('tombstone GC still works end-to-end on a later successful '
        'compaction with only authenticated peers present', () async {
      final rawCloud = MemorySyncAdapter();
      final authenticator = DefaultSyncAuthenticator(_key(2));
      final cloudAdapter = SyncAuthenticatingAdapter(rawCloud, authenticator);
      final farFutureHlc = Hlc(
        DateTime.now().millisecondsSinceEpoch + 1000000000,
        0,
      );
      final goodHwm = HighwaterMark(
        deviceId: _deviceC,
        currentHlc: farFutureHlc,
        lastUpdated: DateTime.now().toUtc(),
        peers: const {},
      );
      await goodHwm.save('$_syncRoot/highwater/$_deviceC.hwm', cloudAdapter);

      final tempDirB = await Directory.systemTemp.createTemp(
        'kmdb_close_horizon_happy_',
      );
      final dbDirB = tempDirB.path;
      final localAdapterB = StorageAdapterNative();
      final (storeB, _) = await KvStoreImpl.open(
        dbDirB,
        localAdapterB,
        config: KvStoreConfig.forTesting(),
        deviceId: _deviceB,
      );
      try {
        SyncEngine(
          store: storeB,
          cloudAdapter: cloudAdapter,
          localAdapter: localAdapterB,
          deviceId: _deviceB,
          dbDir: dbDirB,
          syncRoot: _syncRoot,
          syncNamespaces: {'ns'},
        );

        final key = SequentialKeyGenerator(start: 1).next();
        await storeB.put('ns', key, Uint8List.fromList([1]));
        await storeB.flush();
        await storeB.delete('ns', key);
        await storeB.flush();

        await storeB.compactAll();

        expect(
          await _countSstEntriesForKey(localAdapterB, dbDirB, key),
          equals(0),
          reason:
              'with no unauthenticatable peer present, GC must proceed '
              'normally using the authenticated min',
        );
      } finally {
        await storeB.close();
        await localAdapterB.releaseLock('$dbDirB/LOCK');
        await tempDirB.delete(recursive: true);
      }
    });
  });
}
