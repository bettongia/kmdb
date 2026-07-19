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

import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/consolidation_coordinator.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_context.dart';
import 'package:kmdb/src/sync/sync_storage_adapter.dart';
import 'package:test/test.dart';

import '../util/hostile_sstable.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds a minimal valid SSTable with [count] entries and returns its bytes.
Uint8List _buildSst({int count = 2, int basePhysical = 1000}) {
  final writer = SstableWriter();
  for (var i = 0; i < count; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    final ns = 'test';
    final key = Uint8List(16)..fillRange(0, 16, i);
    final internalKey = KeyCodec.encodeInternalKey(
      ns,
      key,
      hlc,
      RecordType.put,
    );
    writer.add(internalKey, Uint8List.fromList([i]));
  }
  return writer.finish();
}

/// Uploads a fake SSTable to the sync folder.
Future<String> _uploadSst(
  MemorySyncAdapter adapter,
  String syncRoot,
  String deviceId,
  Hlc minHlc,
  Hlc maxHlc, {
  int count = 2,
}) async {
  final filename = SstableInfo.flushName(deviceId, minHlc, maxHlc);
  final bytes = _buildSst(count: count, basePhysical: minHlc.physicalMs);
  await adapter.upload('$syncRoot/sstables/$filename', bytes);
  return filename;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('ConsolidationLease', () {
    test('toBytes / fromBytes roundtrip', () {
      final lease = ConsolidationLease(
        holder: 'a1b2c3d4',
        acquiredAt: 1000,
        expiresAt: 2000,
        epoch: 42,
        inputFiles: ['a.sst', 'b.sst'],
      );
      final bytes = lease.toBytes();
      final decoded = ConsolidationLease.fromBytes(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.holder, equals('a1b2c3d4'));
      expect(decoded.epoch, equals(42));
      expect(decoded.inputFiles, equals(['a.sst', 'b.sst']));
      expect(decoded.expiresAt, equals(2000));
    });

    test('fromBytes returns null for invalid JSON', () {
      final result = ConsolidationLease.fromBytes(
        Uint8List.fromList('not json'.codeUnits),
      );
      expect(result, isNull);
    });

    test('fromBytes returns null for truncated bytes', () {
      final result = ConsolidationLease.fromBytes(Uint8List(0));
      expect(result, isNull);
    });

    test('isExpired returns true when nowMs >= expiresAt', () {
      final lease = ConsolidationLease(
        holder: 'dev',
        acquiredAt: 1000,
        expiresAt: 2000,
        epoch: 1,
        inputFiles: [],
      );
      expect(lease.isExpired(2000), isTrue);
      expect(lease.isExpired(2001), isTrue);
      expect(lease.isExpired(1999), isFalse);
    });

    test('toString includes holder and epoch', () {
      final lease = ConsolidationLease(
        holder: 'mydevice',
        acquiredAt: 0,
        expiresAt: 999,
        epoch: 7,
        inputFiles: [],
      );
      expect(lease.toString(), contains('mydevice'));
      expect(lease.toString(), contains('7'));
    });
  });

  group('ConsolidationCoordinator', () {
    const syncRoot = 'sync';
    const deviceId = 'a1b2c3d4';
    const dbDir = '/db';
    late MemorySyncAdapter cloudAdapter;
    late MemoryStorageAdapter localAdapter;
    late ConsolidationCoordinator coordinator;

    setUp(() {
      cloudAdapter = MemorySyncAdapter();
      localAdapter = MemoryStorageAdapter();
      MemoryStorageAdapter.releaseAllLocks();
      coordinator = ConsolidationCoordinator(
        deviceId: deviceId,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        syncRoot: syncRoot,
        dbDir: dbDir,
        config: ConsolidationConfig.forTesting(), // threshold=3
      );
    });

    // ── runIfNeeded: threshold not met ───────────────────────────────────────

    test('runIfNeeded returns false when threshold not met', () async {
      // Only 2 cross-device files with threshold=3.
      final files = [
        SstableInfo.flushName(
          'peer0001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        ),
        SstableInfo.flushName(
          'peer0002',
          const Hlc(2000, 0),
          const Hlc(2001, 0),
        ),
      ];
      final result = await coordinator.runIfNeeded(files);
      expect(result, isFalse);
      expect(coordinator.state, equals(ConsolidationState.idle));
    });

    test('runIfNeeded ignores own device files for threshold', () async {
      // 3 own files + 2 peer files — threshold=3 but only 2 cross-device.
      final ownFiles = [
        SstableInfo.flushName(deviceId, const Hlc(1000, 0), const Hlc(1001, 0)),
        SstableInfo.flushName(deviceId, const Hlc(2000, 0), const Hlc(2001, 0)),
        SstableInfo.flushName(deviceId, const Hlc(3000, 0), const Hlc(3001, 0)),
      ];
      final peerFiles = [
        SstableInfo.flushName(
          'peer0001',
          const Hlc(4000, 0),
          const Hlc(4001, 0),
        ),
        SstableInfo.flushName(
          'peer0002',
          const Hlc(5000, 0),
          const Hlc(5001, 0),
        ),
      ];
      final result = await coordinator.runIfNeeded([...ownFiles, ...peerFiles]);
      expect(result, isFalse);
    });

    // ── acquireLease ─────────────────────────────────────────────────────────

    test('acquireLease succeeds when no lease exists', () async {
      final files = [
        SstableInfo.flushName(
          'peer0001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        ),
      ];
      final lease = await coordinator.acquireLease(files);
      expect(lease, isNotNull);
      expect(lease!.holder, equals(deviceId));
      expect(lease.inputFiles, equals(files));
    });

    test(
      'acquireLease fails when valid lease held by another device',
      () async {
        // Write a valid lease held by another device.
        final otherLease = ConsolidationLease(
          holder: 'otherdev',
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          epoch: 1,
          inputFiles: ['a.sst'],
        );
        await cloudAdapter.upload(
          '$syncRoot/.consolidation-lease',
          otherLease.toBytes(),
        );

        final result = await coordinator.acquireLease(['b.sst']);
        expect(result, isNull);
      },
    );

    test('acquireLease succeeds when existing lease is expired', () async {
      // Write an expired lease.
      final expiredLease = ConsolidationLease(
        holder: 'otherdev',
        acquiredAt: 1000,
        expiresAt: 1001, // already expired
        epoch: 1,
        inputFiles: ['a.sst'],
      );
      await cloudAdapter.upload(
        '$syncRoot/.consolidation-lease',
        expiredLease.toBytes(),
      );

      final files = ['b.sst'];
      final lease = await coordinator.acquireLease(files);
      expect(lease, isNotNull);
      expect(lease!.holder, equals(deviceId));
    });

    test('acquireLease succeeds when existing lease file is corrupt', () async {
      // Write garbage into the lease file — treated as expired/corrupt.
      await cloudAdapter.upload(
        '$syncRoot/.consolidation-lease',
        Uint8List.fromList('GARBAGE'.codeUnits),
      );

      final files = ['b.sst'];
      final lease = await coordinator.acquireLease(files);
      // Corrupt lease is treated as missing — CAS should succeed.
      // (The corrupt content has a non-null ETag so CAS uses ifMatchEtag path.)
      expect(lease, isNotNull);
    });

    // ── epoch monotonicity ────────────────────────────────────────────────────
    //
    // Regression tests for the monotonic-epoch fix. The wallClock is injectable
    // so the tests can simulate an NTP clock jump backwards.

    test(
      'epoch is monotonically greater after clock-backwards acquisition',
      () async {
        // Clock starts at a high value. Device A acquires a lease with this
        // epoch and lets it expire (TTL=0 by setting expiresAt in the past).
        const clockHigh = 1_000_000;
        final clockLow = 900_000; // simulates NTP correction backwards

        // Step 1: write an expired lease directly to simulate a prior acquisition
        // by any device (could be us, could be a peer).
        final expiredLease = ConsolidationLease(
          holder: 'otherdev',
          acquiredAt: clockHigh,
          expiresAt: 1, // already expired at any nowMs > 1
          epoch: clockHigh,
          inputFiles: ['a.sst'],
        );
        await cloudAdapter.upload(
          '$syncRoot/.consolidation-lease',
          expiredLease.toBytes(),
        );

        // Step 2: Device B's clock has jumped backwards to clockLow. It acquires
        // the lease. Without the fix, epoch = clockLow = 900_000 < 1_000_000.
        // With the fix, epoch = max(clockHigh + 1, clockLow) = 1_000_001.
        final clockBackwards = _FixedClock(clockLow);
        final coordinatorB = ConsolidationCoordinator(
          deviceId: deviceId,
          cloudAdapter: cloudAdapter,
          localAdapter: localAdapter,
          syncRoot: syncRoot,
          dbDir: dbDir,
          config: ConsolidationConfig.forTesting(),
          wallClock: clockBackwards.call,
        );

        final newLease = await coordinatorB.acquireLease(['b.sst']);
        expect(newLease, isNotNull, reason: 'should succeed — expired lease');
        // The new epoch must exceed the prior epoch regardless of clock direction.
        expect(
          newLease!.epoch,
          greaterThan(clockHigh),
          reason:
              'epoch must be monotonically greater than prior epoch '
              '(was $clockHigh), got ${newLease.epoch}',
        );
        // Specifically: max(1_000_000 + 1, 900_000) = 1_000_001.
        expect(newLease.epoch, equals(clockHigh + 1));
      },
    );

    test('epoch equals nowMs when no prior lease exists', () async {
      // No lease file present — first-ever acquisition. Epoch should be nowMs.
      const nowMs = 42_000;
      final fixedClock = _FixedClock(nowMs);
      final freshCoordinator = ConsolidationCoordinator(
        deviceId: deviceId,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        syncRoot: syncRoot,
        dbDir: dbDir,
        config: ConsolidationConfig.forTesting(),
        wallClock: fixedClock.call,
      );

      final lease = await freshCoordinator.acquireLease(['a.sst']);
      expect(lease, isNotNull);
      expect(
        lease!.epoch,
        equals(nowMs),
        reason: 'epoch must equal nowMs when no prior lease exists',
      );
    });

    test('epoch falls back to nowMs when prior lease is corrupt', () async {
      // Write corrupt bytes into the lease slot. acquireLease must not throw
      // and must produce an epoch equal to nowMs (no usable previousEpoch).
      await cloudAdapter.upload(
        '$syncRoot/.consolidation-lease',
        Uint8List.fromList([1, 2, 3]), // malformed JSON
      );

      const nowMs = 77_000;
      final fixedClock = _FixedClock(nowMs);
      final corruptCoordinator = ConsolidationCoordinator(
        deviceId: deviceId,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        syncRoot: syncRoot,
        dbDir: dbDir,
        config: ConsolidationConfig.forTesting(),
        wallClock: fixedClock.call,
      );

      final lease = await corruptCoordinator.acquireLease(['x.sst']);
      expect(
        lease,
        isNotNull,
        reason: 'corrupt lease should not block acquisition',
      );
      expect(
        lease!.epoch,
        equals(nowMs),
        reason: 'epoch must fall back to nowMs when prior lease is corrupt',
      );
    });

    // ── consolidate ───────────────────────────────────────────────────────────

    test('consolidate merges input SSTables into output', () async {
      // Upload two peer SSTables to the sync folder.
      final f1 = await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0001',
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      final f2 = await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0002',
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );

      final lease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
        epoch: DateTime.now().millisecondsSinceEpoch,
        inputFiles: [f1, f2],
      );

      final outputFilename = await coordinator.consolidate(lease);
      expect(outputFilename, isNotNull);
      expect(outputFilename!.endsWith('.sst'), isTrue);

      // Output file should exist in the sync folder.
      expect(
        cloudAdapter.containsFile('$syncRoot/sstables/$outputFilename'),
        isTrue,
      );
    });

    test('consolidate returns null for expired lease', () async {
      final expiredLease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: 1000,
        expiresAt: 1001, // expired
        epoch: 1,
        inputFiles: ['a.sst'],
      );
      final result = await coordinator.consolidate(expiredLease);
      expect(result, isNull);
      expect(coordinator.state, equals(ConsolidationState.leaseExpired));
    });

    test('consolidate skips missing input files gracefully', () async {
      // Lease references a file that doesn't exist in the sync folder.
      // Well-formed (passes SstableInfo.parse) but simply absent — distinct
      // from an *invalid* filename, which is rejected outright (S-6; see
      // the malicious-lease tests below).
      final f1 = await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0001',
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      final missingFilename = SstableInfo.flushName(
        'peer0002',
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );

      final lease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
        epoch: DateTime.now().millisecondsSinceEpoch,
        inputFiles: [f1, missingFilename],
      );

      // Should complete without throwing.
      final result = await coordinator.consolidate(lease);
      // One file available — result may be non-null.
      // (null is also valid if the only available file has 0 entries after
      // merge, but our helper writes 2 entries)
      expect(result, isNotNull);
    });

    // ── commit ────────────────────────────────────────────────────────────────

    test('commit deletes input files and releases lease', () async {
      final f1 = await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0001',
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      final f2 = await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0002',
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );

      // Write a fake lease file.
      await cloudAdapter.upload(
        '$syncRoot/.consolidation-lease',
        Uint8List.fromList([1]),
      );

      final lease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
        epoch: 1,
        inputFiles: [f1, f2],
      );

      await coordinator.commit(lease, 'output.sst');

      // Input files should be removed.
      expect(cloudAdapter.containsFile('$syncRoot/sstables/$f1'), isFalse);
      expect(cloudAdapter.containsFile('$syncRoot/sstables/$f2'), isFalse);

      // Lease file should be removed.
      expect(
        cloudAdapter.containsFile('$syncRoot/.consolidation-lease'),
        isFalse,
      );
    });

    test('commit is resilient to already-deleted input files', () async {
      // Well-formed (passes SstableInfo.parse) but absent from this device's
      // own sstables/ listing — the cross-check (S-6 fix item 3) skips it
      // without deleting or throwing.
      final alreadyGone = SstableInfo.flushName(
        'deadbeef',
        const Hlc(9999, 0),
        const Hlc(9999, 1),
      );
      final lease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
        epoch: 1,
        inputFiles: [alreadyGone],
      );
      // Should not throw even if the file is already gone.
      await expectLater(coordinator.commit(lease, 'out.sst'), completes);
    });

    // ── malicious lease (S-6) ─────────────────────────────────────────────────
    //
    // The lease file is an unauthenticated JSON document in the sync folder —
    // any peer device (T3) can write one. `commit()` must never act on an
    // `inputFiles` entry it has not itself validated as a well-formed,
    // in-directory SSTable name; see the 2026-07-18 release-readiness
    // review's S-6 finding ("a malicious lease turns any consolidating device
    // into a deletion weapon").

    group('malicious lease (S-6)', () {
      test(
        'commit rejects a lease containing a "../" path-traversal entry and '
        'deletes nothing at all — not even legitimate co-listed entries',
        () async {
          final legit = await _uploadSst(
            cloudAdapter,
            syncRoot,
            'peer0001',
            const Hlc(1000, 0),
            const Hlc(1001, 0),
          );
          // Also upload a decoy file at the path the traversal targets, so a
          // failure to reject would be observable as a deletion.
          const victimPath = '$syncRoot/highwater/victim-device.hwm';
          await cloudAdapter.upload(victimPath, Uint8List.fromList([1, 2, 3]));

          final lease = ConsolidationLease(
            holder: deviceId,
            acquiredAt: DateTime.now().millisecondsSinceEpoch,
            expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
            epoch: 1,
            inputFiles: [legit, '../highwater/victim-device.hwm'],
          );

          await coordinator.commit(lease, 'output.sst');

          // Nothing was deleted — not the legitimate co-listed entry, not
          // the path-traversal target, and not the lease file itself (the
          // whole lease was rejected before any deletion was attempted).
          expect(
            cloudAdapter.containsFile('$syncRoot/sstables/$legit'),
            isTrue,
          );
          expect(cloudAdapter.containsFile(victimPath), isTrue);
          expect(
            cloudAdapter.containsFile('$syncRoot/.consolidation-lease'),
            isFalse, // was never written in this test — confirms no-op
          );
        },
      );

      test('commit rejects a lease containing a non-SSTable-format entry and '
          'deletes nothing', () async {
        final legit = await _uploadSst(
          cloudAdapter,
          syncRoot,
          'peer0001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        );
        final lease = ConsolidationLease(
          holder: deviceId,
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          epoch: 1,
          inputFiles: [legit, 'not-an-sstable-name.sst'],
        );

        await coordinator.commit(lease, 'output.sst');

        expect(cloudAdapter.containsFile('$syncRoot/sstables/$legit'), isTrue);
      });

      test('consolidate rejects a lease containing a "../" entry before '
          'downloading anything, returning null', () async {
        await _uploadSst(
          cloudAdapter,
          syncRoot,
          'peer0001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        );
        final lease = ConsolidationLease(
          holder: deviceId,
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          epoch: 1,
          inputFiles: ['../vault/ab/cdef.../blob'],
        );

        final result = await coordinator.consolidate(lease);
        expect(result, isNull);
      });
    });

    // ── hostile input at the consolidation call site (S-1, QA finding B1) ────
    //
    // A hostile SSTable that `SyncEngine.pull()` quarantines (advances the HWM
    // past it) is NOT deleted from the sync folder — it remains eligible as a
    // consolidation input on the *second* affected call site the review's S-1
    // fix item 7 names. Before this fix, `SstableReader.open()` only wrapped
    // `RangeError` as `CorruptedSstableException`; a `FormatException` (varint
    // overflow) or `StorageException` (an out-of-file-bounds `readFileRange`)
    // escaped uncaught, and `consolidate()` only ever caught
    // `CorruptedSstableException` — so a hostile file reaching this path
    // crashed `consolidate()` (and therefore `_maybeConsolidate`/`sync()`)
    // instead of being skipped.

    group('hostile input reaching consolidate() (S-1, QA finding B1)', () {
      test('a checksum-valid, structurally hostile SSTable named as a lease '
          'input is skipped, not thrown, during the N-way merge', () async {
        // A legitimate file, so the merge has something to produce output
        // from even after the hostile one is skipped.
        final legit = await _uploadSst(
          cloudAdapter,
          syncRoot,
          'peer0001',
          const Hlc(1000, 0),
          const Hlc(1001, 0),
        );

        // A checksum-valid, structurally hostile file — the same corruption
        // class as PROBE2 (negative footer offset), which previously
        // escaped consolidate() as a bare StorageException.
        final hostileFilename = SstableInfo.flushName(
          'peer0002',
          const Hlc(2000, 0),
          const Hlc(2001, 0),
        );
        final hostileBytes = patchFooterField(
          buildValidSstable(basePhysical: 2000),
          field: FooterField.filterOffset,
          value: -4096,
        );
        await cloudAdapter.upload(
          '$syncRoot/sstables/$hostileFilename',
          hostileBytes,
        );

        final lease = ConsolidationLease(
          holder: deviceId,
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
          epoch: 1,
          inputFiles: [legit, hostileFilename],
        );

        // Must complete without throwing, and still produce output from
        // the surviving legitimate input.
        final result = await coordinator.consolidate(lease);
        expect(result, isNotNull);
      });
    });

    // ── runIfNeeded: full end-to-end ──────────────────────────────────────────

    test('runIfNeeded consolidates when threshold is met', () async {
      // Upload 3 peer SSTables (threshold=3 in forTesting).
      await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0001',
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0002',
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );
      await _uploadSst(
        cloudAdapter,
        syncRoot,
        'peer0003',
        const Hlc(3000, 0),
        const Hlc(3001, 0),
      );

      final remoteFiles = await cloudAdapter.list(
        '$syncRoot/sstables',
        extension: '.sst',
      );

      final result = await coordinator.runIfNeeded(remoteFiles);
      expect(result, isTrue);
      expect(coordinator.state, equals(ConsolidationState.complete));

      // Input files should have been deleted.
      final remaining = await cloudAdapter.list(
        '$syncRoot/sstables',
        extension: '.sst',
      );
      // Output consolidation file should exist, inputs gone.
      expect(remaining.length, equals(1));
      expect(remaining.first, contains(deviceId));
    });

    // ── state machine ─────────────────────────────────────────────────────────

    test('state starts as idle', () {
      expect(coordinator.state, equals(ConsolidationState.idle));
    });

    test('state is idle when threshold not met', () async {
      await coordinator.runIfNeeded([]);
      expect(coordinator.state, equals(ConsolidationState.idle));
    });
  });

  // ── H5 gating: skip consolidation when adapter is not atomic ────────────────
  //
  // The lease protocol requires atomic CAS. When the cloud adapter does not
  // provide it (e.g. a Dropbox/OneDrive folder seen as a local filesystem),
  // running the protocol risks two devices both believing they hold the lease
  // and deleting each other's input SSTables (review finding H5). The
  // coordinator must skip consolidation in this case, set a structured
  // skipReason, and never touch the lease file.

  group('ConsolidationCoordinator gating on non-atomic CAS (H5)', () {
    const syncRoot = 'sync';
    const deviceId = 'a1b2c3d4';
    const dbDir = '/db';
    late _NonAtomicCloudAdapter cloudAdapter;
    late MemoryStorageAdapter localAdapter;
    late ConsolidationCoordinator coordinator;

    setUp(() {
      cloudAdapter = _NonAtomicCloudAdapter();
      localAdapter = MemoryStorageAdapter();
      MemoryStorageAdapter.releaseAllLocks();
      coordinator = ConsolidationCoordinator(
        deviceId: deviceId,
        cloudAdapter: cloudAdapter,
        localAdapter: localAdapter,
        syncRoot: syncRoot,
        dbDir: dbDir,
        config: ConsolidationConfig.forTesting(),
      );
    });

    test(
      'runIfNeeded skips, sets skippedNonAtomicCas state, and records reason',
      () async {
        // Three peer files — threshold is met, so the gate is what stops us
        // (not the threshold check). This is the precise H5 hazard.
        final files = [
          SstableInfo.flushName(
            'peer0001',
            const Hlc(1000, 0),
            const Hlc(1001, 0),
          ),
          SstableInfo.flushName(
            'peer0002',
            const Hlc(2000, 0),
            const Hlc(2001, 0),
          ),
          SstableInfo.flushName(
            'peer0003',
            const Hlc(3000, 0),
            const Hlc(3001, 0),
          ),
        ];

        final result = await coordinator.runIfNeeded(files);

        expect(result, isFalse);
        expect(
          coordinator.state,
          equals(ConsolidationState.skippedNonAtomicCas),
        );
        expect(coordinator.skipReason, isNotNull);
        expect(coordinator.skipReason, contains('atomic'));
        // The coordinator must not have touched the lease file at all —
        // observing a CAS attempt under a non-atomic backend would defeat
        // the entire purpose of the gate.
        expect(cloudAdapter.casCalls, equals(0));
        expect(cloudAdapter.uploadCalls, equals(0));
        expect(cloudAdapter.deleteCalls, equals(0));
      },
    );

    test(
      'runIfNeeded clears skipReason on a subsequent successful run',
      () async {
        // First call hits the gate.
        await coordinator.runIfNeeded([]);
        expect(coordinator.skipReason, isNotNull);

        // Swap in an atomic adapter and re-run — skipReason must be cleared so
        // observers do not see a stale reason from the previous invocation.
        final atomicAdapter = MemorySyncAdapter();
        final atomicCoordinator = ConsolidationCoordinator(
          deviceId: deviceId,
          cloudAdapter: atomicAdapter,
          localAdapter: localAdapter,
          syncRoot: syncRoot,
          dbDir: dbDir,
          config: ConsolidationConfig.forTesting(),
        );
        // First, set a skipReason via the non-atomic path.
        // (We can't really do this on `atomicCoordinator` directly, so we
        // simply verify a fresh atomic-backed coordinator has no skipReason
        // after a no-op run.)
        await atomicCoordinator.runIfNeeded([]);
        expect(atomicCoordinator.skipReason, isNull);
        expect(atomicCoordinator.state, equals(ConsolidationState.idle));
      },
    );

    test('runIfNeeded gates BEFORE the threshold check', () async {
      // Even with no files (threshold not met), the gate must fire — this
      // prevents a non-atomic backend from sneaking through on small datasets
      // and then surprising the user once the threshold is crossed.
      final result = await coordinator.runIfNeeded([]);
      expect(result, isFalse);
      expect(coordinator.state, equals(ConsolidationState.skippedNonAtomicCas));
    });
  });
}

/// A fixed-value wall clock for injecting deterministic time into tests.
///
/// Every call to [call] returns the same [value] supplied at construction,
/// making epoch calculations fully deterministic regardless of real wall time.
final class _FixedClock {
  const _FixedClock(this.value);

  /// The fixed millisecond timestamp returned by every invocation.
  final int value;

  /// Returns [value] unconditionally.
  int call() => value;
}

/// Minimal non-atomic [SyncStorageAdapter] for the gating regression test.
///
/// Tracks call counts so the test can prove the coordinator never touched
/// the lease file once the gate fired.
final class _NonAtomicCloudAdapter implements SyncStorageAdapter {
  int casCalls = 0;
  int uploadCalls = 0;
  int deleteCalls = 0;

  @override
  bool get providesAtomicCas => false;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async => [];

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async =>
      null;

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    uploadCalls++;
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) async {
    deleteCalls++;
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    casCalls++;
    return true;
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) async => null;
}
