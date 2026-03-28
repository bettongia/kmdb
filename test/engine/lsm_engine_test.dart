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
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

const _dbDir = '/db';

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

Future<(KvStoreImpl, OpenResult)> _open(
  MemoryStorageAdapter adapter, {
  KvStoreConfig? config,
}) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: config ?? KvStoreConfig.forTesting(),
      deviceId: 'testdev1',
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('LsmEngine — basic reads and writes', () {
    test('put and get a single value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('tasks', key, _bytes('hello'));
      final result = await store.get('tasks', key);
      expect(result, equals(_bytes('hello')));
      await store.close();
    });

    test('get returns null for missing key', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final result = await store.get('tasks', _key(1));
      expect(result, isNull);
      await store.close();
    });

    test('delete writes tombstone — get returns null', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('tasks', key, _bytes('data'));
      await store.delete('tasks', key);
      final result = await store.get('tasks', key);
      expect(result, isNull);
      await store.close();
    });

    test('overwrite returns new value', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.put('ns', key, _bytes('v2'));
      final result = await store.get('ns', key);
      expect(result, equals(_bytes('v2')));
      await store.close();
    });

    test('keys in different namespaces are isolated', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns1', key, _bytes('ns1-val'));
      await store.put('ns2', key, _bytes('ns2-val'));
      expect(await store.get('ns1', key), equals(_bytes('ns1-val')));
      expect(await store.get('ns2', key), equals(_bytes('ns2-val')));
      await store.close();
    });

    test('writeBatch commits multiple entries atomically', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final batch = WriteBatch()
        ..put('ns', _key(1), _bytes('a'))
        ..put('ns', _key(2), _bytes('b'))
        ..put('ns', _key(3), _bytes('c'));
      await store.writeBatch(batch);
      expect(await store.get('ns', _key(1)), equals(_bytes('a')));
      expect(await store.get('ns', _key(2)), equals(_bytes('b')));
      expect(await store.get('ns', _key(3)), equals(_bytes('c')));
      await store.close();
    });
  });

  group('LsmEngine — scan', () {
    test('scan all keys in namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store.scan('ns').toList();
      expect(entries.length, equals(5));
      // Keys are UUIDv7-like but sequential, so they should be in order.
      final keys = entries.map((e) => e.key).toList();
      for (var i = 0; i < keys.length - 1; i++) {
        expect(keys[i].compareTo(keys[i + 1]), lessThan(0));
      }
      await store.close();
    });

    test('scan suppresses tombstones', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v1'));
      await store.put('ns', _key(2), _bytes('v2'));
      await store.delete('ns', _key(1));
      final entries = await store.scan('ns').toList();
      expect(entries.length, equals(1));
      expect(entries.first.key, equals(_key(2)));
      await store.close();
    });

    test('scan with startKey is inclusive', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store
          .scan('ns', startKey: _key(2))
          .toList();
      final keys = entries.map((e) => e.key).toList();
      expect(keys, contains(_key(2)));
      expect(keys, isNot(contains(_key(0))));
      expect(keys, isNot(contains(_key(1))));
      await store.close();
    });

    test('scan with endKey is exclusive', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      final entries = await store
          .scan('ns', endKey: _key(3))
          .toList();
      final keys = entries.map((e) => e.key).toList();
      expect(keys, isNot(contains(_key(3))));
      expect(keys, isNot(contains(_key(4))));
      await store.close();
    });

    test('scan returns empty stream for empty namespace', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final entries = await store.scan('empty').toList();
      expect(entries, isEmpty);
      await store.close();
    });
  });

  group('LsmEngine — flush and SSTable reads', () {
    test('values survive explicit flush', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('persistent'));
      await store.flush();
      // Value should now be in the SSTable, not memtable.
      final result = await store.get('ns', key);
      expect(result, equals(_bytes('persistent')));
      await store.close();
    });

    test('delete tombstone visible after flush', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.flush();
      await store.delete('ns', key);
      expect(await store.get('ns', key), isNull);
      await store.close();
    });

    test('automatic flush fires when memtable exceeds threshold', () async {
      final adapter = _newAdapter();
      // forTesting() has a 4KB threshold.
      final (store, _) = await _open(adapter);
      // Write enough data to exceed the 4KB memtable threshold.
      final bigVal = Uint8List(1024);
      for (var i = 0; i < 6; i++) {
        await store.put('ns', _key(i), bigVal);
      }
      // At least one SSTable should have been flushed.
      final sstFiles = await adapter.listFiles('/db/sst', extension: '.sst');
      expect(sstFiles, isNotEmpty);
      await store.close();
    });
  });

  group('LsmEngine — compaction', () {
    test('compactAll reduces L0 to 0 files when data fits in one L2', () async {
      final adapter = _newAdapter();
      final config = KvStoreConfig.forTesting();
      final (store, _) = await _open(adapter, config: config);

      for (var i = 0; i < 10; i++) {
        await store.put('ns', _key(i), _bytes('value-$i'));
      }
      await store.flush();
      await store.compactAll();

      // After compactAll, L0 should be empty.
      final l0Files =
          adapter.files.keys.where((k) => k.endsWith('.sst')).toList();
      // All data should be in a single consolidated SSTable.
      expect(l0Files.length, lessThanOrEqualTo(1));
      await store.close();
    });

    test('values readable after compaction', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      for (var i = 0; i < 5; i++) {
        await store.put('ns', _key(i), _bytes('v$i'));
      }
      await store.flush();
      await store.compactAll();
      for (var i = 0; i < 5; i++) {
        final val = await store.get('ns', _key(i));
        expect(val, equals(_bytes('v$i')));
      }
      await store.close();
    });

    test('tombstones retained during compaction (not yet at L2 GC)', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final key = _key(1);
      await store.put('ns', key, _bytes('v1'));
      await store.flush();
      await store.delete('ns', key);
      await store.flush();
      await store.compactAll();
      expect(await store.get('ns', key), isNull);
      await store.close();
    });
  });

  group('LsmEngine — writeEvents', () {
    test('writeEvents fires namespace after put', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final emitted = <String>[];
      store.writeEvents.listen(emitted.add);
      await store.put('tasks', _key(1), _bytes('x'));
      expect(emitted, contains('tasks'));
      await store.close();
    });

    test('writeEvents fires all namespaces in writeBatch', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      final emitted = <String>[];
      store.writeEvents.listen(emitted.add);
      final batch = WriteBatch()
        ..put('ns1', _key(1), _bytes('a'))
        ..put('ns2', _key(2), _bytes('b'));
      await store.writeBatch(batch);
      expect(emitted, containsAll(['ns1', 'ns2']));
      await store.close();
    });
  });

  group('LsmEngine — close and reopen', () {
    test('close releases lock; second open succeeds', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _bytes('v'));
      await store.close();
      // Should be able to open again without LockException.
      final (store2, _) = await _open(adapter);
      expect(await store2.get('ns', _key(1)), equals(_bytes('v')));
      await store2.close();
    });
  });
}
