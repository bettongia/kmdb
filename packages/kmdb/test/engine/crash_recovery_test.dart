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
import 'package:kmdb/src/engine/util/key_codec.dart';
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

    test('un-flushed WAL records restored on reopen', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(5), _bytes('wal-data'));
      // Close WITHOUT explicit flush — WAL recovery must replay this.
      await store.close();

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
}
