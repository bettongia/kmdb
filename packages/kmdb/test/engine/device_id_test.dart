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

import 'package:kmdb/src/engine/kvstore/device_id.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:test/test.dart';

const _dbDir = '/db';

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(
      _dbDir,
      adapter,
      config: KvStoreConfig.forTesting(),
    );

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('DeviceId', () {
    test('load generates an ID on fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await DeviceId.load(store.meta);
      expect(id, isNotEmpty);
      expect(id.length, equals(8));
      // Should be lowercase hex only.
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(id), isTrue);
      await store.close();
    });

    test('load returns same ID on subsequent calls in same session', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id1 = await DeviceId.load(store.meta);
      final id2 = await DeviceId.load(store.meta);
      expect(id1, equals(id2));
      await store.close();
    });

    test('ID is persistent across close and reopen', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await DeviceId.load(store.meta);
      await store.close();

      final (store2, _) = await _open(adapter);
      final id2 = await DeviceId.load(store2.meta);
      expect(id2, equals(id));
      await store2.close();
    });

    test('load does not overwrite an existing stored ID', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // Manually store a known ID.
      await store.meta.putDeviceId('cafebabe');
      // load() should return the existing value, not generate a new one.
      final id = await DeviceId.load(store.meta);
      expect(id, equals('cafebabe'));
      await store.close();
    });

    test('stored ID is exactly 8 lowercase hex characters', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await DeviceId.load(store.meta);
      expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
      await store.close();
    });

    test('ID survives flush and compaction', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await DeviceId.load(store.meta);
      // Force the ID into an SSTable.
      await store.flush();
      await store.compactAll();
      await store.close();

      final (store2, _) = await _open(adapter);
      final id2 = await DeviceId.load(store2.meta);
      expect(id2, equals(id));
      await store2.close();
    });
  });
}
