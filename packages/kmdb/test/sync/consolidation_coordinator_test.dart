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
import 'package:test/test.dart';

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
      final f1 = await _uploadSst(
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
        epoch: DateTime.now().millisecondsSinceEpoch,
        inputFiles: [f1, 'nonexistent-peer-000000000000-000000000001.sst'],
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
      final lease = ConsolidationLease(
        holder: deviceId,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
        epoch: 1,
        inputFiles: ['already-gone.sst'],
      );
      // Should not throw even if the file is already gone.
      await expectLater(coordinator.commit(lease, 'out.sst'), completes);
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
}
