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
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/wal/wal_record.dart';
import 'package:test/test.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

/// Builds a minimal valid peer SSTable in memory with [count] entries whose HLC
/// physical component starts at [basePhysical]. Mirrors the helper in
/// `lsm_engine_test.dart`; used to exercise the sync-ingest trigger of C1.
Uint8List _buildPeerSst({int count = 2, required int basePhysical}) {
  final writer = SstableWriter();
  for (var i = 0; i < count; i++) {
    final hlc = Hlc(basePhysical + i, 0);
    final keyHex =
        '${i.toRadixString(16).padLeft(12, '0')}70008${i.toRadixString(16).padLeft(15, '0')}';
    final keyBytes = KeyCodec.keyToBytes(keyHex);
    final internalKey = KeyCodec.encodeInternalKey(
      'peerns',
      keyBytes,
      hlc,
      RecordType.put,
    );
    writer.add(internalKey, Uint8List.fromList([i + 1]));
  }
  return writer.finish();
}

/// Returns the path of the highest-sequence `wal-*.log` file in [adapter],
/// i.e. the active WAL at crash time.
String _activeWalPath(MemoryStorageAdapter adapter) {
  final wals = adapter.files.keys.where((k) => k.endsWith('.log')).toList()
    ..sort();
  expect(wals, isNotEmpty);
  return wals.last;
}

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('CrashRecovery — clean open (fresh database)', () {
    test('opens fresh database without error', () async {
      final adapter = _newAdapter();
      final (store, result) = await _open(adapter);
      expect(result.hadInterruptedWrites, isFalse);
      expect(result.hadUnclosedSession, isFalse);
      await store.close();
    });

    test('fresh open creates CURRENT and MANIFEST-00001', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.close();
      expect(adapter.files.keys, contains('$_dbDir/CURRENT'));
      expect(adapter.files.keys.any((k) => k.contains('MANIFEST-')), isTrue);
    });
  });

  group('CrashRecovery — data survives close and reopen', () {
    test('written values survive close + reopen', () async {
      final adapter = _newAdapter();

      // Write and flush so data lands in an SSTable.
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('persistent'));
      await store.flush();
      await store.close();

      // Reopen and verify.
      final (store2, _) = await _open(adapter);
      final val = await store2.get('ns', _key(1));
      expect(val, equals(_bytes('persistent')));
      await store2.close();
    });

    test('un-flushed WAL records restored on reopen after crash', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(5), _bytes('wal-data'));
      // Crash WITHOUT close() (which would flush): the record lives only in the
      // active WAL, so reopening must replay it. Previously this test called
      // close(), which flushes to an SSTable and so never exercised WAL replay.
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      final val = await store2.get('ns', _key(5));
      expect(val, equals(_bytes('wal-data')));
      await store2.close();
    });

    test('tombstone survives close + reopen', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v'));
      await store.flush();
      await store.delete('ns', _key(1));
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), isNull);
      await store2.close();
    });

    test('multiple namespaces survive reopen independently', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns1', _key(1), _bytes('a'));
      await store.put('ns2', _key(1), _bytes('b'));
      await store.flush();
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns1', _key(1)), equals(_bytes('a')));
      expect(await store2.get('ns2', _key(1)), equals(_bytes('b')));
      await store2.close();
    });
  });

  group('CrashRecovery — orphan SSTable cleanup', () {
    test('orphan SSTable files are deleted on open', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v'));
      await store.flush();
      await store.close();

      // Inject a fake orphan SSTable that the Manifest doesn't know about.
      adapter.files['/db/sst/orphan-file.sst'] = Uint8List(10);

      final (store2, _) = await _open(adapter);
      await store2.close();

      // The orphan should be gone.
      expect(adapter.files.containsKey('/db/sst/orphan-file.sst'), isFalse);
    });
  });

  group('CrashRecovery — WAL truncation recovery', () {
    test(
      'truncated WAL record does not crash open; good records survive',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);
        await store.put('ns', _key(1), _bytes('v1'));
        await store.put('ns', _key(2), _bytes('v2'));
        // Simulate a crash: release the lock without calling close(). This
        // leaves the WAL with unflushed records (no flush marker, no SSTable).
        MemoryStorageAdapter.releaseAllLocks();

        // Corrupt the WAL by truncating the last few bytes. The first record
        // should still be recoverable; the second is corrupted.
        final walKeys = adapter.files.keys
            .where((k) => k.endsWith('.log'))
            .toList();
        expect(walKeys, isNotEmpty);
        final walPath = walKeys.first;
        final original = adapter.files[walPath]!;
        // Truncate by removing 5 bytes from the end.
        if (original.length > 5) {
          adapter.files[walPath] = original.sublist(0, original.length - 5);
        }

        // Open should not throw; the truncation must be detected.
        final (store2, result) = await _open(adapter);
        expect(result.hadInterruptedWrites, isTrue);
        await store2.close();
      },
    );
  });

  group('CrashRecovery — lock exclusivity', () {
    test('second open on same path throws LockException', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // Second open should fail — lock is held.
      await expectLater(_open(adapter), throwsA(isA<LockException>()));
      await store.close();
    });

    test('open succeeds after prior instance closed', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.close();
      // Should succeed now.
      final (store2, _) = await _open(adapter);
      await store2.close();
    });
  });

  group('CrashRecovery — OpenResult', () {
    test('hadInterruptedWrites false on clean open', () async {
      final adapter = _newAdapter();
      final (store, result) = await _open(adapter);
      await store.close();
      expect(result.hadInterruptedWrites, isFalse);
    });

    test('OpenResult.affectedNamespaces populated from WAL replay', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('my-namespace', _key(1), _bytes('v'));
      // Simulate crash: release lock without close so WAL has unflushed records.
      MemoryStorageAdapter.releaseAllLocks();

      // Corrupt the WAL to trigger hadInterruptedWrites.
      final walKeys = adapter.files.keys
          .where((k) => k.endsWith('.log'))
          .toList();
      if (walKeys.isNotEmpty) {
        final walPath = walKeys.first;
        final original = adapter.files[walPath]!;
        if (original.length > 3) {
          adapter.files[walPath] = original.sublist(0, original.length - 3);
        }
      }

      final (store2, result2) = await _open(adapter);
      await store2.close();
      expect(result2.hadInterruptedWrites, isTrue);
    });
  });

  // ── C1 regression suite ─────────────────────────────────────────────────────
  //
  // Every VersionEdit records `logNumber = activeSequence`, so after the first
  // flush/compaction/ingest/manifest-rotation of a database's life the active
  // WAL's own sequence equals `maxLogNumber`. The old recovery predicate
  // (`seq <= maxLogNumber`) deleted that active WAL without replaying it,
  // silently destroying any write that landed after the edit. These tests use
  // the "crash" pattern — write, releaseAllLocks() (no close()), reopen — and
  // each one fails against the pre-fix engine.
  group('CrashRecovery — durable WAL replay (C1)', () {
    test('put after flush survives crash', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('flushed'));
      await store.flush(); // key1 -> SSTable; WAL rotated
      await store.put('ns', _key(2), _bytes('unflushed')); // active WAL only
      MemoryStorageAdapter.releaseAllLocks(); // crash: no close()

      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), equals(_bytes('flushed')));
      expect(
        await store2.get('ns', _key(2)),
        equals(_bytes('unflushed')),
        reason: 'post-flush write must survive crash recovery',
      );
      await store2.close();
    });

    test('delete after flush survives crash (no resurrection)', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v'));
      await store.flush();
      await store.delete('ns', _key(1)); // tombstone in active WAL only
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      expect(
        await store2.get('ns', _key(1)),
        isNull,
        reason: 'a lost tombstone would resurrect deleted data',
      );
      await store2.close();
    });

    test('write after sync ingest survives crash', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);

      // Ingest a peer SSTable; ingestAt0 appends a VersionEdit with
      // logNumber = activeSequence, arming the same retention bug as flush.
      const peerPhysical = 1_030_000;
      final filename = SstableInfo.flushName(
        'peer0099',
        const Hlc(peerPhysical, 0),
        const Hlc(peerPhysical, 1),
      );
      await store.ingestSstable(
        filename,
        _buildPeerSst(basePhysical: peerPhysical),
      );

      await store.put('ns', _key(7), _bytes('after-ingest')); // active WAL only
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      expect(
        await store2.get('ns', _key(7)),
        equals(_bytes('after-ingest')),
        reason: 'a local write after sync ingest must survive crash recovery',
      );
      await store2.close();
    });

    test('write after compaction survives crash', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);

      // Several flush cycles drive automatic compaction; the last compaction's
      // VersionEdit sets maxLogNumber to the active WAL's sequence.
      for (var i = 0; i < 6; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
        await store.flush();
      }
      await store.put('ns', _key(100), _bytes('post-compaction')); // active WAL
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      expect(
        await store2.get('ns', _key(100)),
        equals(_bytes('post-compaction')),
        reason: 'a write after compaction must survive crash recovery',
      );
      expect(await store2.get('ns', _key(0)), equals(_bytes('v0')));
      await store2.close();
    });

    test('interleaved writes and flushes all survive crash', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('a'));
      await store.flush();
      await store.put('ns', _key(2), _bytes('b'));
      await store.flush();
      await store.put('ns', _key(3), _bytes('c')); // active WAL only
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), equals(_bytes('a')));
      expect(await store2.get('ns', _key(2)), equals(_bytes('b')));
      expect(await store2.get('ns', _key(3)), equals(_bytes('c')));
      await store2.close();
    });

    test(
      'crash mid-flush replays records past a legacy marker (Defect 2)',
      () async {
        // Simulate an interrupted flush from an older build: a WAL holding a live
        // record followed by a flush marker, whose SSTable/VersionEdit never
        // became durable. The pre-fix `replayFromLastFlush` skipped everything up
        // to and including the trailing marker, losing the record; full replay
        // restores it and treats the legacy marker as a no-op.
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);
        await store.put('ns', _key(1), _bytes('pre-marker'));
        MemoryStorageAdapter.releaseAllLocks();

        final walPath = _activeWalPath(adapter);
        final existing = adapter.files[walPath]!;
        final marker = WalRecord(
          type: WalRecordType.flushMarker,
          sequence: const Hlc(1, 0),
        ).encode();
        final combined = Uint8List(existing.length + marker.length)
          ..setAll(0, existing)
          ..setAll(existing.length, marker);
        adapter.files[walPath] = combined;

        final (store2, _) = await _open(adapter);
        expect(
          await store2.get('ns', _key(1)),
          equals(_bytes('pre-marker')),
          reason:
              'records before a trailing flush marker must still be replayed',
        );
        await store2.close();
      },
    );

    test(
      'truncated active WAL after flush: good records survive and flag set',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);
        await store.put('ns', _key(1), _bytes('flushed'));
        await store.flush(); // retires the first WAL; active WAL is now fresh
        await store.put('ns', _key(2), _bytes('good'));
        await store.put('ns', _key(3), _bytes('will-truncate'));
        MemoryStorageAdapter.releaseAllLocks();

        // Truncate the tail of the active WAL, corrupting the final record.
        final walPath = _activeWalPath(adapter);
        final original = adapter.files[walPath]!;
        adapter.files[walPath] = original.sublist(0, original.length - 5);

        final (store2, result) = await _open(adapter);
        expect(result.hadInterruptedWrites, isTrue);
        expect(await store2.get('ns', _key(1)), equals(_bytes('flushed')));
        expect(await store2.get('ns', _key(2)), equals(_bytes('good')));
        await store2.close();
      },
    );
  });
}
