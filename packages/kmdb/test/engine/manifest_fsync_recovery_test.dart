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
import 'package:kmdb/src/engine/manifest/current_file.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _deviceId = 'testdev1';

/// Test config with realistic durability ([fsyncOnWrite] true) plus tiny
/// thresholds so flushes and compactions fire after only a few writes.
KvStoreConfig _config() => const KvStoreConfig(
  memtableSizeBytes: 4096,
  l0CompactionTrigger: 2,
  l1MaxBytes: 16 * 1024,
  l2MaxBytes: 64 * 1024,
  singleFileThresholdBytes: 8 * 1024,
  fsyncOnWrite: true,
);

Future<(KvStoreImpl, OpenResult)> _open(FaultyStorageAdapter adapter) =>
    KvStoreImpl.open(_dbDir, adapter, config: _config(), deviceId: _deviceId);

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

String _key(int n) => SequentialKeyGenerator(start: n).next();

/// Builds a minimal valid peer SSTable for the ingest scenario, with [count]
/// entries in the `peerns` namespace whose HLC physical component starts at
/// [basePhysical].
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

void main() {
  // These tests use [FaultyStorageAdapter], which models power-loss durability:
  // only data made durable by syncFile (content) and syncDir (directory entries)
  // survives crash(). Each test performs an operation, crashes, reopens, and
  // asserts the data is intact. On the pre-C2 engine — where the manifest is
  // never fsynced and syncDir is never called — nothing is made durable, so
  // every test below fails; the fixes make each operation crash-safe.
  group('Manifest fsync & durability ordering (C2 / H1 / M3)', () {
    test('flush is durable across a crash', () async {
      final adapter = FaultyStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _b('v1'));
      await store.flush();
      adapter.crash();

      final (store2, _) = await _open(adapter);
      expect(
        await store2.get('ns', _key(1)),
        equals(_b('v1')),
        reason: 'flushed data needs a durable manifest + SSTable to survive',
      );
      await store2.close();
    });

    test('flushed SSTable directory entry is durable (H1)', () async {
      final adapter = FaultyStorageAdapter();
      final (store, _) = await _open(adapter);
      await store.put('ns', _key(1), _b('v1'));
      await store.flush();

      final before = await adapter.listFiles('$_dbDir/sst', extension: '.sst');
      expect(before, isNotEmpty);

      adapter.crash();
      final after = await adapter.listFiles('$_dbDir/sst', extension: '.sst');
      expect(
        after,
        equals(before),
        reason: 'syncDir(sstDir) must durably link the new SSTable name',
      );
      await (await _open(adapter)).$1.close();
    });

    test('compaction is durable across a crash', () async {
      final adapter = FaultyStorageAdapter();
      final (store, _) = await _open(adapter);
      // l0CompactionTrigger is 2, so several flushes drive a compaction that
      // deletes its input SSTables.
      for (var i = 0; i < 4; i++) {
        await store.put('ns', _key(i), _b('v$i'));
        await store.flush();
      }
      adapter.crash();

      final (store2, _) = await _open(adapter);
      for (var i = 0; i < 4; i++) {
        expect(
          await store2.get('ns', _key(i)),
          equals(_b('v$i')),
          reason: 'data folded into a compaction must survive a crash',
        );
      }
      await store2.close();
    });

    test('sync ingest is durable across a crash', () async {
      final adapter = FaultyStorageAdapter();
      final (store, _) = await _open(adapter);

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
      adapter.crash();

      final (store2, _) = await _open(adapter);
      final entries = await store2.scan('peerns').toList();
      expect(
        entries,
        isNotEmpty,
        reason: 'an ingested SSTable must be durable and manifest-referenced',
      );
      await store2.close();
    });

    test('CURRENT swap is durable (M3)', () async {
      final adapter = FaultyStorageAdapter();
      final current = CurrentFile(dbDir: _dbDir, adapter: adapter);

      await current.write('MANIFEST-00001');
      adapter.crash();
      expect(
        await current.read(),
        equals('MANIFEST-00001'),
        reason: 'a completed CURRENT write must survive a crash',
      );

      await current.write('MANIFEST-00002');
      adapter.crash();
      expect(await current.read(), equals('MANIFEST-00002'));
    });

    test('fresh database create is durable (crash right after open)', () async {
      final adapter = FaultyStorageAdapter();
      await _open(adapter);
      // Power loss immediately after the fresh-create completes.
      adapter.crash();

      expect(
        await adapter.fileExists('$_dbDir/CURRENT'),
        isTrue,
        reason: 'fresh create must fsync CURRENT + the initial manifest',
      );

      final (store2, _) = await _open(adapter);
      await store2.put('ns', _key(1), _b('v1'));
      await store2.flush();
      expect(await store2.get('ns', _key(1)), equals(_b('v1')));
      await store2.close();
    });
  });
}
