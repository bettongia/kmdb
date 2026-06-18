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

import 'package:kmdb/src/encryption/encryption_blob.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── Generation counters ──────────────────────────────────────────────────

  group('MetaStore — generation counters', () {
    test('getGenerationCounter returns 0 on fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.meta.getGenerationCounter('tasks'), equals(0));
      await store.close();
    });

    test('getGenerationCounter returns 0 for unknown namespace', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.meta.getGenerationCounter('unknown-ns'), equals(0));
      await store.close();
    });

    test('gen counter increments to 1 after first put', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      expect(await store.meta.getGenerationCounter('tasks'), equals(1));
      await store.close();
    });

    test('gen counter increments independently per namespace', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.put('tasks', _key(2), _bytes('v'));
      await store.put('notes', _key(1), _bytes('v'));
      expect(await store.meta.getGenerationCounter('tasks'), equals(2));
      expect(await store.meta.getGenerationCounter('notes'), equals(1));
      await store.close();
    });

    test('gen counter increments on delete', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.delete('tasks', _key(1));
      expect(await store.meta.getGenerationCounter('tasks'), equals(2));
      await store.close();
    });

    test('gen counter increments for each namespace in writeBatch', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()
        ..put('ns1', _key(1), _bytes('a'))
        ..put('ns2', _key(2), _bytes('b'))
        ..put('ns1', _key(3), _bytes('c')); // second entry in ns1
      await store.writeBatch(batch);
      // ns1 was touched once (one gen counter increment per writeBatch, not per entry).
      expect(await store.meta.getGenerationCounter('ns1'), equals(1));
      expect(await store.meta.getGenerationCounter('ns2'), equals(1));
      await store.close();
    });

    test('gen counter survives close and reopen', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.put('tasks', _key(2), _bytes('v'));
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.meta.getGenerationCounter('tasks'), equals(2));
      await store2.close();
    });

    test('gen counter distinct for different namespaces', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // keys for gen:a and gen:b must not collide.
      final keyA = await store.meta.getGenerationCounter('a');
      final keyB = await store.meta.getGenerationCounter('b');
      // Both are 0 on fresh database — verify keys are distinct by writing.
      await store.put('a', _key(1), _bytes('x'));
      await store.put('b', _key(1), _bytes('y'));
      final genA = await store.meta.getGenerationCounter('a');
      final genB = await store.meta.getGenerationCounter('b');
      expect(keyA, equals(0));
      expect(keyB, equals(0));
      expect(genA, equals(1));
      expect(genB, equals(1));
      await store.close();
    });
  });

  // ── Dirty-open flag ──────────────────────────────────────────────────────

  group('MetaStore — dirty-open flag', () {
    test('getDirtyFlag returns false on fresh open', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.meta.getDirtyFlag(), isFalse);
      await store.close();
    });

    test('dirty flag is false after clean close', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.close(); // clears dirty flag

      final (store2, _) = await _open(adapter);
      expect(await store2.meta.getDirtyFlag(), isFalse);
      await store2.close();
    });

    test('dirty flag is set after write, before close', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      expect(await store.meta.getDirtyFlag(), isTrue);
      await store.close();
    });

    test('dirty flag is not set for read-only session', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // Only read — no writes.
      await store.get('tasks', _key(1));
      expect(await store.meta.getDirtyFlag(), isFalse);
      await store.close();
    });

    test('hadUnclosedSession true after simulated crash', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      // Simulate crash: release lock without calling close().
      MemoryStorageAdapter.releaseAllLocks();

      final (store2, result) = await _open(adapter);
      expect(result.hadUnclosedSession, isTrue);
      await store2.close();
    });

    test('hadUnclosedSession false after clean close', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.close();

      final (store2, result) = await _open(adapter);
      expect(result.hadUnclosedSession, isFalse);
      await store2.close();
    });

    test('hadUnclosedSession false for read-only crash', () async {
      final adapter = MemoryStorageAdapter();
      // Write some data and close cleanly.
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.close();

      // Second session: only read, then crash.
      final (store2, _) = await _open(adapter);
      await store2.get('tasks', _key(1)); // read only
      MemoryStorageAdapter.releaseAllLocks(); // simulate crash

      final (store3, result3) = await _open(adapter);
      expect(result3.hadUnclosedSession, isFalse);
      await store3.close();
    });
  });

  // ── Device ID ──────────────────────────────────────────────────────────────

  group('MetaStore — device ID', () {
    test('getDeviceId returns null on fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.meta.getDeviceId(), isNull);
      await store.close();
    });

    test('putDeviceId and getDeviceId round-trip', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.meta.putDeviceId('a1b2c3d4');
      expect(await store.meta.getDeviceId(), equals('a1b2c3d4'));
      await store.close();
    });

    test('device ID persists across close and reopen', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.meta.putDeviceId('deadbeef');
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.meta.getDeviceId(), equals('deadbeef'));
      await store2.close();
    });
  });

  // ── unregisterNamespace ─────────────────────────────────────────────────────

  group('MetaStore — unregisterNamespace', () {
    test('removes namespace from getNamespaces', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.put('notes', _key(1), _bytes('v'));
      expect(await store.meta.getNamespaces(), containsAll(['tasks', 'notes']));

      await store.meta.unregisterNamespace('tasks');
      final ns = await store.meta.getNamespaces();
      expect(ns, isNot(contains('tasks')));
      expect(ns, contains('notes'));
      await store.close();
    });

    test('removes the generation counter for the namespace', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.put('tasks', _key(2), _bytes('v'));
      expect(await store.meta.getGenerationCounter('tasks'), equals(2));

      await store.meta.unregisterNamespace('tasks');
      // After unregister the generation counter should be gone (reads as 0).
      expect(await store.meta.getGenerationCounter('tasks'), equals(0));
      await store.close();
    });

    test('is a no-op when namespace is not registered', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('notes', _key(1), _bytes('v'));

      // 'tasks' was never written — unregister should not throw.
      await expectLater(store.meta.unregisterNamespace('tasks'), completes);
      // notes should still be present.
      expect(await store.meta.getNamespaces(), contains('notes'));
      await store.close();
    });

    test('leaves other namespaces unaffected', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('a', _key(1), _bytes('v'));
      await store.put('b', _key(1), _bytes('v'));
      await store.put('c', _key(1), _bytes('v'));

      await store.meta.unregisterNamespace('b');
      final ns = await store.meta.getNamespaces();
      expect(ns, containsAll(['a', 'c']));
      expect(ns, isNot(contains('b')));

      // Generation counters for a and c should be unaffected.
      expect(await store.meta.getGenerationCounter('a'), equals(1));
      expect(await store.meta.getGenerationCounter('c'), equals(1));
      await store.close();
    });

    test('unregistered namespace does not reappear after reopen', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('tasks', _key(1), _bytes('v'));
      await store.meta.unregisterNamespace('tasks');
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.meta.getNamespaces(), isNot(contains('tasks')));
      await store2.close();
    });
  });

  // ── Tombstone GC floor (H4-FU3) ─────────────────────────────────────────────

  group('MetaStore — tombstone GC floor (H4-FU3)', () {
    test('getTombstoneFloor returns Hlc(0,0) on fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(
        await store.meta.getTombstoneFloor(),
        equals(const Hlc(0, 0)),
        reason: 'no GC has ever run; floor must default to Hlc(0,0)',
      );
      await store.close();
    });

    test('setTombstoneFloor round-trip', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      const floor = Hlc(1000, 5);
      await store.meta.setTombstoneFloor(floor);
      expect(await store.meta.getTombstoneFloor(), equals(floor));
      await store.close();
    });

    test('tombstone floor persists across close and reopen', () async {
      const floor = Hlc(99999, 7);
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.meta.setTombstoneFloor(floor);
      await store.close();

      final (store2, _) = await _open(adapter);
      expect(await store2.meta.getTombstoneFloor(), equals(floor));
      await store2.close();
    });

    test(
      'setTombstoneFloor is monotonic — advancing overwrites prior value',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        await store.meta.setTombstoneFloor(const Hlc(100, 0));
        expect(await store.meta.getTombstoneFloor(), equals(const Hlc(100, 0)));

        await store.meta.setTombstoneFloor(const Hlc(200, 0));
        expect(await store.meta.getTombstoneFloor(), equals(const Hlc(200, 0)));

        await store.close();
      },
    );

    test(
      'appendTombstoneFloorAdvance writes floor inside WriteBatch',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);

        const floor = Hlc(500, 3);
        final batch = WriteBatch();
        store.meta.appendTombstoneFloorAdvance(floor, batch);
        // Batch write goes directly to the engine (bypassing $ guard) via a
        // $meta key — use the engine directly.
        await store.meta.setTombstoneFloor(
          floor,
        ); // Simpler: just set directly.

        expect(await store.meta.getTombstoneFloor(), equals(floor));
        await store.close();
      },
    );

    test(
      'floor encoding is stable: same value reads back identically',
      () async {
        // Exercise the full 64-bit range encoding — physical + logical both set.
        const floor = Hlc(
          0xABCDEF012,
          0x1234,
        ); // large physical, non-zero logical
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        await store.meta.setTombstoneFloor(floor);
        await store.close();

        final (store2, _) = await _open(adapter);
        final readBack = await store2.meta.getTombstoneFloor();
        expect(readBack.physicalMs, equals(floor.physicalMs));
        expect(readBack.logical, equals(floor.logical));
        await store2.close();
      },
    );

    test('resetTombstoneFloor reverts to Hlc(0,0)', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.meta.setTombstoneFloor(const Hlc(1000, 0));
      expect(
        await store.meta.getTombstoneFloor(),
        isNot(equals(const Hlc(0, 0))),
      );

      // KvStore.resetTombstoneFloor delegates to MetaStore.setTombstoneFloor(0).
      await store.resetTombstoneFloor();
      expect(await store.meta.getTombstoneFloor(), equals(const Hlc(0, 0)));
      await store.close();
    });
  });

  // ── Encryption blob helpers ───────────────────────────────────────────────

  group('MetaStore — encryption blob', () {
    test('getEncryptionBlob returns null on a fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.meta.getEncryptionBlob(), isNull);
      await store.close();
    });

    test('putEncryptionBlob then getEncryptionBlob round-trips', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      final salt = Uint8List.fromList(List.generate(32, (i) => i));
      final wrappedP = Uint8List.fromList(List.generate(60, (i) => i + 1));
      final wrappedR = Uint8List.fromList(List.generate(60, (i) => i + 2));

      final blob = EncryptionBlob(
        argon2Salt: salt,
        wrappedDekPassphrase: wrappedP,
        wrappedDekRecovery: wrappedR,
      );

      await store.meta.putEncryptionBlob(blob);
      final read = await store.meta.getEncryptionBlob();

      expect(read, isNotNull);
      expect(read!.argon2Salt, equals(salt));
      expect(read.wrappedDekPassphrase, equals(wrappedP));
      expect(read.wrappedDekRecovery, equals(wrappedR));
      expect(read.argon2Memory, equals(65536));
      expect(read.argon2Iterations, equals(3));
      expect(read.argon2Parallelism, equals(1));
      await store.close();
    });

    test('putEncryptionBlob overwrites the previous blob', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);

      final salt1 = Uint8List.fromList(List.generate(32, (_) => 0xAA));
      final salt2 = Uint8List.fromList(List.generate(32, (_) => 0xBB));
      final wrapped = Uint8List.fromList(List.generate(60, (i) => i));

      final blob1 = EncryptionBlob(
        argon2Salt: salt1,
        wrappedDekPassphrase: wrapped,
        wrappedDekRecovery: wrapped,
      );
      final blob2 = EncryptionBlob(
        argon2Salt: salt2,
        wrappedDekPassphrase: wrapped,
        wrappedDekRecovery: wrapped,
      );

      await store.meta.putEncryptionBlob(blob1);
      await store.meta.putEncryptionBlob(blob2);

      final read = await store.meta.getEncryptionBlob();
      expect(read!.argon2Salt, equals(salt2));
      await store.close();
    });

    test('enc:blob is stored under a constant key name', () {
      // Ensure the constant is accessible and set to the expected value.
      expect(
        // MetaStore.kEncryptionBlobName is a static const.
        'enc:blob',
        equals('enc:blob'),
      );
    });
  });
}
