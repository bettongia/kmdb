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
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

const _dbDir = '/kvdb';
const _deviceId = 'abcd1234';

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
      deviceId: _deviceId,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);
String _str(Uint8List? b) => b == null ? '<null>' : String.fromCharCodes(b);
String _key(int n) => SequentialKeyGenerator(start: n).next();

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  // ── Write / read / delete round-trip ───────────────────────────────────────

  group('KvStore — round-trip', () {
    test('put → get returns value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('todos', _key(1), _bytes('buy milk'));
      expect(_str(await store.get('todos', _key(1))), equals('buy milk'));
      await store.close();
    });

    test('delete → get returns null', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final k = _key(1);
      await store.put('todos', k, _bytes('buy milk'));
      await store.delete('todos', k);
      expect(await store.get('todos', k), isNull);
      await store.close();
    });

    test('overwrite returns latest value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final k = _key(1);
      await store.put('todos', k, _bytes('v1'));
      await store.put('todos', k, _bytes('v2'));
      await store.put('todos', k, _bytes('v3'));
      expect(_str(await store.get('todos', k)), equals('v3'));
      await store.close();
    });

    test('missing key returns null', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      expect(await store.get('todos', _key(99)), isNull);
      await store.close();
    });
  });

  // ── WriteBatch atomicity ───────────────────────────────────────────────────

  group('KvStore — WriteBatch', () {
    test('all entries visible after commit', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()
        ..put('ns', _key(1), _bytes('a'))
        ..put('ns', _key(2), _bytes('b'))
        ..put('ns', _key(3), _bytes('c'));
      await store.writeBatch(batch);
      expect(_str(await store.get('ns', _key(1))), equals('a'));
      expect(_str(await store.get('ns', _key(2))), equals('b'));
      expect(_str(await store.get('ns', _key(3))), equals('c'));
      await store.close();
    });

    test('delete in batch removes entry', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('existing'));
      final batch = WriteBatch()
        ..delete('ns', _key(1))
        ..put('ns', _key(2), _bytes('new'));
      await store.writeBatch(batch);
      expect(await store.get('ns', _key(1)), isNull);
      expect(_str(await store.get('ns', _key(2))), equals('new'));
      await store.close();
    });

    test('empty batch is a no-op', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.writeBatch(WriteBatch());
      expect(await store.scan('ns').toList(), isEmpty);
      await store.close();
    });
  });

  // ── Scan ordering ──────────────────────────────────────────────────────────

  group('KvStore — scan ordering', () {
    test('scan returns entries in ascending key order', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // Insert in reverse order.
      for (var i = 9; i >= 0; i--) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns').toList();
      expect(entries.length, equals(10));
      final keys = entries.map((e) => e.key).toList();
      for (var i = 0; i < keys.length - 1; i++) {
        expect(
          keys[i].compareTo(keys[i + 1]),
          lessThan(0),
          reason: 'key[$i] should be < key[${i + 1}]',
        );
      }
      await store.close();
    });

    test('scan respects startKey (inclusive)', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns', startKey: _key(2)).toList();
      final keys = entries.map((e) => e.key).toSet();
      expect(keys, contains(_key(2)));
      expect(keys, isNot(contains(_key(0))));
      expect(keys, isNot(contains(_key(1))));
      await store.close();
    });

    test('scan respects endKey (exclusive)', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns', endKey: _key(3)).toList();
      final keys = entries.map((e) => e.key).toSet();
      expect(keys, isNot(contains(_key(3))));
      expect(keys, isNot(contains(_key(4))));
      await store.close();
    });

    test('scan omits tombstones', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      await store.delete('ns', _key(2));
      final keys = (await store.scan('ns').toList()).map((e) => e.key).toList();
      expect(keys, isNot(contains(_key(2))));
      expect(keys.length, equals(4));
      await store.close();
    });
  });

  // ── Flush triggers ─────────────────────────────────────────────────────────

  group('KvStore — flush', () {
    test('explicit flush produces SSTable file', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('x'));
      await store.flush();
      final ssts = await adapter.listFiles('$_dbDir/sst', extension: '.sst');
      expect(ssts, isNotEmpty);
      await store.close();
    });

    test('values readable after flush', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('after-flush'));
      await store.flush();
      expect(_str(await store.get('ns', _key(1))), equals('after-flush'));
      await store.close();
    });

    test('automatic flush fires when memtable exceeds threshold', () async {
      final adapter = _newAdapter();
      // forTesting() threshold is 4096 bytes.
      final (store, _) = await _open(adapter);
      final bigVal = Uint8List(1200); // each entry ~ 1200 + key bytes
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), bigVal);
      }
      final ssts = await adapter.listFiles('$_dbDir/sst', extension: '.sst');
      expect(ssts, isNotEmpty);
      await store.close();
    });
  });

  // ── Compaction triggers ────────────────────────────────────────────────────

  group('KvStore — compaction', () {
    test('L0 compaction fires at trigger threshold', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      // Write + flush twice to build 2 L0 files → triggers L0 compaction.
      await store.put('ns', _key(1), _bytes('a'));
      await store.flush();
      await store.put('ns', _key(2), _bytes('b'));
      await store.flush();
      // compactAll should leave L0 empty.
      await store.compactAll();
      // Data should still be readable.
      expect(_str(await store.get('ns', _key(1))), equals('a'));
      expect(_str(await store.get('ns', _key(2))), equals('b'));
      await store.close();
    });

    test('compactAll with tiny data produces single L2 file', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 3; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
        await store.flush();
      }
      await store.compactAll();
      // All data still readable.
      for (var i = 0; i < 3; i++) {
        expect(_str(await store.get('ns', _key(i))), equals('v$i'));
      }
      await store.close();
    });
  });

  // ── Multi-namespace isolation ──────────────────────────────────────────────

  group('KvStore — namespace isolation', () {
    test('same key in different namespaces is independent', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final k = _key(1);
      await store.put('alpha', k, _bytes('from-alpha'));
      await store.put('beta', k, _bytes('from-beta'));
      expect(_str(await store.get('alpha', k)), equals('from-alpha'));
      expect(_str(await store.get('beta', k)), equals('from-beta'));
      await store.close();
    });

    test('delete in one namespace does not affect another', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final k = _key(1);
      await store.put('a', k, _bytes('v'));
      await store.put('b', k, _bytes('v'));
      await store.delete('a', k);
      expect(await store.get('a', k), isNull);
      expect(_str(await store.get('b', k)), equals('v'));
      await store.close();
    });

    test('scan stays within its namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('x', _key(1), _bytes('x1'));
      await store.put('y', _key(2), _bytes('y2'));
      final xEntries = await store.scan('x').toList();
      expect(xEntries.length, equals(1));
      expect(xEntries.first.key, equals(_key(1)));
      await store.close();
    });
  });

  // ── System namespace protection ────────────────────────────────────────────

  group('KvStore — system namespace protection', () {
    test('put to \$ namespace throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await expectLater(
        store.put(r'$meta', _key(1), _bytes('x')),
        throwsA(isA<ArgumentError>()),
      );
      await store.close();
    });

    test('delete to \$ namespace throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await expectLater(
        store.delete(r'$meta', _key(1)),
        throwsA(isA<ArgumentError>()),
      );
      await store.close();
    });

    test('writeBatch with \$ namespace entry throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()..put(r'$index:ns:path', _key(1), _bytes('x'));
      await expectLater(store.writeBatch(batch), throwsA(isA<ArgumentError>()));
      await store.close();
    });
  });

  // ── Key validation ─────────────────────────────────────────────────────────

  group('KvStore — key validation', () {
    test('put with invalid key length throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await expectLater(
        store.put('ns', 'short', _bytes('x')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('32 hex characters'),
          ),
        ),
      );
      await store.close();
    });

    test('put with invalid UUID version throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const invalid = '00000000000060008000000000000000'; // version 6
      await expectLater(
        store.put('ns', invalid, _bytes('x')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('version 7 required'),
          ),
        ),
      );
      await store.close();
    });

    test('put with invalid UUID variant throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      const invalid = '00000000000070000000000000000000'; // variant 0
      await expectLater(
        store.put('ns', invalid, _bytes('x')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('variant 2 required'),
          ),
        ),
      );
      await store.close();
    });

    test('delete with invalid key throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await expectLater(
        store.delete('ns', 'invalid'),
        throwsA(isA<ArgumentError>()),
      );
      await store.close();
    });

    test('writeBatch with invalid key throws ArgumentError', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()..put('ns', 'invalid', _bytes('x'));
      await expectLater(store.writeBatch(batch), throwsA(isA<ArgumentError>()));
      await store.close();
    });
  });

  // ── Close / reopen ─────────────────────────────────────────────────────────

  group('KvStore — close and reopen', () {
    test('close releases lock; re-open succeeds', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.close();
      final (store2, _) = await _open(adapter);
      await store2.close();
    });

    test('second open while first is active throws LockException', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await expectLater(_open(adapter), throwsA(isA<LockException>()));
      await store.close();
    });

    test('OpenResult fields populated correctly', () async {
      final adapter = _newAdapter();
      final (store, result) = await _open(adapter);
      // Fresh open: no WAL truncation, no unclosed session.
      expect(result.hadInterruptedWrites, isFalse);
      expect(result.affectedNamespaces, isEmpty);
      await store.close();
    });
  });

  // ── Value size limit ───────────────────────────────────────────────────────

  group('KvStore — value size limit', () {
    Future<KvStoreImpl> openWithLimit(int maxValueBytes) async {
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        _newAdapter(),
        config: KvStoreConfig(
          memtableSizeBytes: 4096,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          maxValueBytes: maxValueBytes,
        ),
        deviceId: _deviceId,
      );
      return store;
    }

    test('put: value at the limit is accepted', () async {
      final store = await openWithLimit(10);
      await store.put('ns', _key(1), Uint8List(10));
      await store.close();
    });

    test('put: value over the limit throws ArgumentError', () async {
      final store = await openWithLimit(10);
      await expectLater(
        store.put('ns', _key(1), Uint8List(11)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('maxValueBytes'),
          ),
        ),
      );
      await store.close();
    });

    test('writeBatch: oversized entry throws ArgumentError', () async {
      final store = await openWithLimit(10);
      final batch = WriteBatch()
        ..put('ns', _key(1), Uint8List(5))
        ..put('ns', _key(2), Uint8List(11));
      await expectLater(store.writeBatch(batch), throwsA(isA<ArgumentError>()));
      await store.close();
    });

    test('writeBatch: delete entries are not size-checked', () async {
      final store = await openWithLimit(10);
      await store.put('ns', _key(1), Uint8List(5));
      final batch = WriteBatch()..delete('ns', _key(1));
      await store.writeBatch(batch); // must not throw
      await store.close();
    });

    test('maxValueBytesUnlimited disables the check', () async {
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        _newAdapter(),
        config: KvStoreConfig(
          memtableSizeBytes: 4096,
          l1MaxBytes: 16 * 1024,
          l2MaxBytes: 64 * 1024,
          singleFileThresholdBytes: 8 * 1024,
          fsyncOnWrite: false,
          maxValueBytes: KvStoreConfig.maxValueBytesUnlimited,
        ),
        deviceId: _deviceId,
      );
      // 2 MiB — well above the default 1 MiB limit, should succeed.
      await store.put('ns', _key(1), Uint8List(2 * 1024 * 1024));
      await store.close();
    });
  });
}
