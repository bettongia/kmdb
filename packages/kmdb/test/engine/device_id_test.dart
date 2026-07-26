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

/// Tests for [DeviceId] and [KvStoreImpl.ensureDeviceId].
///
/// Rewritten by the "retire the $meta device_id copy" plan (SC-5): device
/// identity no longer touches `$meta` at all (read or write) — the local
/// `DEVICE_ID` file is the sole persistence mechanism. [DeviceId.generate]
/// is now a pure generator with no persistence side effect, so the
/// close/reopen persistence guarantee the old `$meta`-based tests exercised
/// is re-homed here onto [KvStoreImpl.ensureDeviceId], which is the only
/// method that persists a device ID.
library;

import 'package:kmdb/src/engine/kvstore/device_id.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:test/test.dart';

const _dbDir = '/db';

Future<(KvStoreImpl, OpenResult)> _open(MemoryStorageAdapter adapter) =>
    KvStoreImpl.open(_dbDir, adapter, config: KvStoreConfig.forTesting());

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('DeviceId.generate', () {
    test('returns an 8-character lowercase hex string', () {
      final id = DeviceId.generate();
      expect(id, isNotEmpty);
      expect(id.length, equals(8));
      expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('is a pure generator — repeated calls return different values', () {
      // Unlike the removed DeviceId.load(meta), generate() has no
      // persistence side effect: it is purely random per call (see the
      // class doc comment for the UUIDv4-over-UUIDv7 collision rationale).
      final id1 = DeviceId.generate();
      final id2 = DeviceId.generate();
      expect(id1, isNot(equals(id2)));
    });
  });

  group('KvStoreImpl.ensureDeviceId', () {
    test('generates an ID on a fresh database', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await store.ensureDeviceId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));
      await store.close();
    });

    test(
      'returns the same ID on subsequent calls in the same session',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        final id1 = await store.ensureDeviceId();
        final id2 = await store.ensureDeviceId();
        expect(id1, equals(id2));
        await store.close();
      },
    );

    test(
      'ID is persistent across close and reopen via the DEVICE_ID file',
      () async {
        // This is the property the deleted $meta-based tests guaranteed —
        // re-homed onto the file, which is now the sole store.
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        final id = await store.ensureDeviceId();
        await store.close();

        final (store2, _) = await _open(adapter);
        final id2 = await store2.ensureDeviceId();
        expect(id2, equals(id));
        await store2.close();
      },
    );

    test('does not overwrite an existing DEVICE_ID file value', () async {
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      // First call writes and persists a value.
      final firstId = await store.ensureDeviceId();
      await store.close();

      // Reopening and calling again must return the same (file-backed)
      // value, not silently mint a new one.
      final (store2, _) = await _open(adapter);
      final secondId = await store2.ensureDeviceId();
      expect(secondId, equals(firstId));
      await store2.close();
    });

    test('ID survives flush and compaction', () async {
      // The DEVICE_ID file lives outside sst/, so flush/compaction (which
      // only affect the LSM's SSTables) must not disturb it.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      final id = await store.ensureDeviceId();
      await store.flush();
      await store.compactAll();
      await store.close();

      final (store2, _) = await _open(adapter);
      final id2 = await store2.ensureDeviceId();
      expect(id2, equals(id));
      await store2.close();
    });

    test('does not consult \$meta when the DEVICE_ID file is absent', () async {
      // SC-5 regression: a fresh database's ensureDeviceId() must resolve
      // purely from the (absent) file and generate+write a fresh id — it
      // must never read or write $meta. Verified deterministically via
      // MetaStore.symbolicKey, which computes the identical key the deleted
      // MetaStore.deviceIdKey constant did.
      final adapter = MemoryStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.ensureDeviceId();

      final raw = await store.get(
        MetaStore.kNamespace,
        MetaStore.symbolicKey('device_id'),
      );
      expect(raw, isNull);
      await store.close();
    });
  });

  group('SC-5 regression — \$meta never holds a device_id entry', () {
    test(
      'a fresh database writes the DEVICE_ID file and \$meta stays clean',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        await store.ensureDeviceId();

        final raw = await store.get(
          MetaStore.kNamespace,
          MetaStore.symbolicKey('device_id'),
        );
        expect(
          raw,
          isNull,
          reason:
              '\$meta replicates via synced SSTables; a device_id entry '
              'there could resolve to a peer identity via Last-Write-Wins '
              '(SC-5)',
        );
        await store.close();
      },
    );

    test(
      'a flushed SSTable does not contain a device_id entry (illustrative)',
      () async {
        // Mirrors how the $meta copy was originally found empirically in
        // demodb. Kept as a secondary, illustrative check — the
        // deterministic $meta-key-absence assertion above is the
        // load-bearing one, since scanning raw SSTable bytes for a
        // coincidental hex match is fragile.
        final adapter = MemoryStorageAdapter();
        final (store, _) = await _open(adapter);
        await store.ensureDeviceId();
        await store.flush();

        final sstFiles = await adapter.listFiles(
          '$_dbDir/sst',
          extension: '.sst',
        );
        expect(sstFiles, isNotEmpty);
        for (final filename in sstFiles) {
          final bytes = await adapter.readFile('$_dbDir/sst/$filename');
          final text = String.fromCharCodes(bytes);
          expect(text, isNot(contains('device_id')));
        }
        await store.close();
      },
    );
  });

  group('KvStoreImpl.storeInfo — device ID resolution (Q2)', () {
    // storeInfo() resolves from the running LsmEngine's deviceId, not from
    // $meta or the DEVICE_ID file. This is scoped to stores that received
    // their id via the open-time `deviceId:` param (or, per
    // reassign_device_id_test.dart, post-reassign) — NOT the single-phase
    // `KmdbDatabase.open()` + bare `ensureDeviceId()` pattern, where the
    // engine genuinely keeps naming SSTables '00000000' and storeInfo
    // honestly reporting that is correct, not a gap (see the plan's Q2).
    test(
      'returns the deviceId supplied at open time, with no reassign',
      () async {
        final adapter = MemoryStorageAdapter();
        final (store, _) = await KvStoreImpl.open(
          _dbDir,
          adapter,
          config: KvStoreConfig.forTesting(),
          deviceId: 'a1b2c3d4',
        );
        final info = await store.storeInfo();
        expect(info.deviceId, equals('a1b2c3d4'));
        await store.close();
      },
    );
  });
}
