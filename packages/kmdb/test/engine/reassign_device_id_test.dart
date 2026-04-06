// Copyright 2026 The KMDB Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
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
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

int _dbCounter = 0;

/// Returns a unique in-memory database directory path per call.
String _uniqueDir() => '/db${_dbCounter++}';

/// A valid UUIDv7-format key for use in tests.
///
/// Builds a synthetic key from [seed] while ensuring the version (nibble 12)
/// is '7' and the variant (nibble 16) is '8'.
String _key(String seed) {
  final hex = seed.codeUnits
      .map((c) => c.toRadixString(16))
      .join()
      .padRight(32, '0')
      .substring(0, 32);
  final chars = hex.split('');
  chars[12] = '7';
  chars[16] = '8';
  return chars.join();
}

/// Opens a test store with a deterministic device ID.
///
/// [dir] is the in-memory path; [adapter] is the shared memory adapter;
/// [deviceId] is the 8-character hex device ID for SSTable filenames.
/// Uses [KvStoreConfig.forTesting] for fast flushes.
Future<KvStoreImpl> _openStore(
  String dir,
  MemoryStorageAdapter adapter, {
  String deviceId = 'aaaaaaaa',
}) async {
  final (store, _) = await KvStoreImpl.open(
    dir,
    adapter,
    config: KvStoreConfig.forTesting(),
    deviceId: deviceId,
  );
  return store;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('KvStore.reassignDeviceId', () {
    // ── Validation ────────────────────────────────────────────────────────────

    test('throws ArgumentError for non-hex characters', () async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(_uniqueDir(), adapter);
      addTearDown(() => store.close(flush: false));

      expect(
        () => store.reassignDeviceId('GGGGGGGG'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError for ID shorter than 8 characters', () async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(_uniqueDir(), adapter);
      addTearDown(() => store.close(flush: false));

      expect(
        () => store.reassignDeviceId('abc'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError for ID longer than 8 characters', () async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(_uniqueDir(), adapter);
      addTearDown(() => store.close(flush: false));

      expect(
        () => store.reassignDeviceId('aabbccdd11'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError when new ID equals current ID', () async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(
        _uniqueDir(),
        adapter,
        deviceId: 'aaaaaaaa',
      );
      addTearDown(() => store.close(flush: false));

      expect(
        () => store.reassignDeviceId('aaaaaaaa'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError for uppercase hex in new ID', () async {
      final adapter = MemoryStorageAdapter();
      final store = await _openStore(_uniqueDir(), adapter);
      addTearDown(() => store.close(flush: false));

      expect(
        () => store.reassignDeviceId('AABBCCDD'),
        throwsA(isA<ArgumentError>()),
      );
    });

    // ── Happy path ────────────────────────────────────────────────────────────

    test(
      'all documents remain readable after reassign and close/reopen',
      () async {
        final adapter = MemoryStorageAdapter();
        final dir = _uniqueDir();
        final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

        // Write a batch of documents across multiple flushes.
        final k1 = _key('key1');
        final k2 = _key('key2');
        final k3 = _key('key3');
        await store.put('col', k1, Uint8List.fromList([1]));
        await store.flush();
        await store.put('col', k2, Uint8List.fromList([2]));
        await store.flush();
        await store.put('col', k3, Uint8List.fromList([3]));

        await store.reassignDeviceId('bbbbbbbb');
        await store.close();

        // Reopen with the new device ID — all data must still be accessible.
        final store2 = await _openStore(dir, adapter, deviceId: 'bbbbbbbb');
        addTearDown(() => store2.close());

        expect(await store2.get('col', k1), Uint8List.fromList([1]));
        expect(await store2.get('col', k2), Uint8List.fromList([2]));
        expect(await store2.get('col', k3), Uint8List.fromList([3]));
      },
    );

    test('old SSTable filenames no longer exist after reassign', () async {
      final adapter = MemoryStorageAdapter();
      final dir = _uniqueDir();
      final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

      await store.put('col', _key('key1'), Uint8List.fromList([1]));
      await store.flush();

      await store.reassignDeviceId('bbbbbbbb');

      // No SSTable files should begin with the old device ID prefix.
      final sstFiles = await adapter.listFiles('$dir/sst', extension: '.sst');
      final oldPrefixFiles = sstFiles
          .where((f) => f.startsWith('aaaaaaaa-'))
          .toList();
      expect(
        oldPrefixFiles,
        isEmpty,
        reason: 'old-prefixed SSTables should be gone after reassign',
      );

      await store.close();
    });

    test('new SSTable filenames exist with the new device ID prefix', () async {
      final adapter = MemoryStorageAdapter();
      final dir = _uniqueDir();
      final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

      await store.put('col', _key('key1'), Uint8List.fromList([1]));
      await store.flush();

      await store.reassignDeviceId('cccccccc');

      // At least one SSTable should carry the new prefix.
      final sstFiles = await adapter.listFiles('$dir/sst', extension: '.sst');
      final newPrefixFiles = sstFiles
          .where((f) => f.startsWith('cccccccc-'))
          .toList();
      expect(
        newPrefixFiles,
        isNotEmpty,
        reason: 'at least one new-prefixed SSTable should exist',
      );

      await store.close();
    });

    test('storeInfo returns new device ID after reassign', () async {
      final adapter = MemoryStorageAdapter();
      final dir = _uniqueDir();
      final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');
      await store.put('col', _key('key1'), Uint8List.fromList([1]));
      await store.flush();

      await store.reassignDeviceId('dddddddd');

      final info = await store.storeInfo();
      expect(info.deviceId, 'dddddddd');

      await store.close();
    });

    test(
      'storeInfo returns new device ID after reassign, close, and reopen',
      () async {
        final adapter = MemoryStorageAdapter();
        final dir = _uniqueDir();
        final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

        await store.put('col', _key('key1'), Uint8List.fromList([1]));
        await store.flush();
        await store.reassignDeviceId('eeeeeeee');
        await store.close();

        final store2 = await _openStore(dir, adapter, deviceId: 'eeeeeeee');
        addTearDown(() => store2.close());

        // storeInfo reads from $meta which was updated by reassignDeviceId.
        final info = await store2.storeInfo();
        expect(info.deviceId, 'eeeeeeee');
      },
    );

    test(
      'manifest replays correctly after rename (data accessible on reopen)',
      () async {
        // Verifies that the VersionEdit written during reassign is correctly
        // replayed by CrashRecovery on the next open.
        final adapter = MemoryStorageAdapter();
        final dir = _uniqueDir();
        final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

        // Write enough records to force at least two SSTables.
        for (var i = 0; i < 10; i++) {
          final k = _key('key$i');
          await store.put('col', k, Uint8List.fromList([i]));
          await store.flush();
        }

        await store.reassignDeviceId('ffffffff');
        await store.close();

        // Reopen — CrashRecovery replays the Manifest including the rename edit.
        final store2 = await _openStore(dir, adapter, deviceId: 'ffffffff');
        addTearDown(() => store2.close());

        for (var i = 0; i < 10; i++) {
          final k = _key('key$i');
          expect(
            await store2.get('col', k),
            Uint8List.fromList([i]),
            reason: 'doc $i should be readable after manifest replay',
          );
        }
      },
    );

    test('peer-owned SSTables are not renamed by reassignDeviceId', () async {
      // Simulate a peer SSTable ingested via pull. Verify that reassignDeviceId
      // only renames files whose name starts with the OLD local device ID —
      // never peer-owned files (those with a different device ID prefix).
      //
      // To isolate the rename logic from compaction, we disable compaction
      // by setting a very high l0CompactionTrigger.
      final localAdapter = MemoryStorageAdapter();
      final localDir = _uniqueDir();
      final (store, _) = await KvStoreImpl.open(
        localDir,
        localAdapter,
        config: const KvStoreConfig(
          memtableSizeBytes: 1024 * 1024,
          l0CompactionTrigger: 100, // effectively disabled
          singleFileThresholdBytes: 1, // disable single-file shortcut
          fsyncOnWrite: false,
        ),
        deviceId: 'aaaaaaaa',
      );

      await store.put('col', _key('key1'), Uint8List.fromList([1]));
      await store.flush();

      // Create a peer SSTable via a second in-memory store.
      final peerAdapter = MemoryStorageAdapter();
      final peerDir = _uniqueDir();
      final peerStore = await _openStore(
        peerDir,
        peerAdapter,
        deviceId: '12345678',
      );
      await peerStore.put('col', _key('peerkey'), Uint8List.fromList([99]));
      await peerStore.flush();
      final peerSstFiles = await peerAdapter.listFiles(
        '$peerDir/sst',
        extension: '.sst',
      );
      expect(peerSstFiles, isNotEmpty);
      final peerFilename = peerSstFiles.first;
      expect(
        peerFilename,
        startsWith('12345678-'),
        reason: 'sanity check: peer SSTable should have peer prefix',
      );
      final peerBytes = await peerAdapter.readFile(
        '$peerDir/sst/$peerFilename',
      );
      await peerStore.close();

      // Ingest the peer SSTable into the local store (compaction disabled,
      // so it stays as an L0 file with its original '12345678-' prefix).
      await store.ingestSstable(peerFilename, peerBytes);

      // Verify the peer file is present before reassign.
      final filesBeforeReassign = (await localAdapter.listFiles(
        '$localDir/sst',
        extension: '.sst',
      )).toSet();
      expect(
        filesBeforeReassign,
        contains(peerFilename),
        reason:
            'peer SSTable should be present (no compaction) before reassign',
      );

      // Reassign the local device ID.
      await store.reassignDeviceId('bbbbbbbb');

      final filesAfterReassign = (await localAdapter.listFiles(
        '$localDir/sst',
        extension: '.sst',
      )).toSet();

      // The renaming code only touches files whose names start with the OLD
      // local device ID prefix ('aaaaaaaa-'). Peer files ('12345678-...') must
      // retain their original name.
      expect(
        filesAfterReassign,
        contains(peerFilename),
        reason:
            'peer SSTable must remain under its original name after reassign',
      );

      // No file whose name starts with '12345678-' should have been renamed
      // to 'bbbbbbbb-...'.
      // All bbbbbbbb- files must be renamed locals, not renamed peer files.
      // The local file (aaaaaaaa-...) should now be (bbbbbbbb-...) and the
      // peer file should still be (12345678-...).
      expect(
        filesAfterReassign.where((f) => f.startsWith('12345678-')),
        contains(peerFilename),
        reason: 'peer file must still have 12345678- prefix, not be renamed',
      );

      // Peer data must still be readable.
      expect(
        await store.get('col', _key('peerkey')),
        Uint8List.fromList([99]),
        reason: 'peer document must remain readable after reassign',
      );

      await store.close();
    });

    test('empty store (no SSTables) reassigns cleanly', () async {
      final adapter = MemoryStorageAdapter();
      final dir = _uniqueDir();
      // Open without writing anything — the memtable is empty and flush() is
      // a no-op, so no SSTables exist to rename.
      final store = await _openStore(dir, adapter, deviceId: 'aaaaaaaa');

      // Should not throw even though there are no SSTables to rename.
      await store.reassignDeviceId('bbbbbbbb');

      final info = await store.storeInfo();
      expect(info.deviceId, 'bbbbbbbb');

      await store.close();
    });

    test('subsequent writes after reassign use the new device ID', () async {
      final adapter = MemoryStorageAdapter();
      final dir = _uniqueDir();
      // Use a large memtable to prevent automatic compaction from merging
      // our manually flushed SSTables before we can inspect them.
      final (store, _) = await KvStoreImpl.open(
        dir,
        adapter,
        config: const KvStoreConfig(
          memtableSizeBytes: 1024 * 1024,
          l0CompactionTrigger: 100, // effectively disabled
          fsyncOnWrite: false,
        ),
        deviceId: 'aaaaaaaa',
      );

      await store.put('col', _key('before'), Uint8List.fromList([1]));
      await store.flush();

      await store.reassignDeviceId('bbbbbbbb');

      // Write and flush a new document after the reassign.
      await store.put('col', _key('after'), Uint8List.fromList([2]));
      await store.flush();

      // All SSTables in the directory must use the new device ID prefix —
      // the old-renamed SSTable from before reassign uses 'bbbbbbbb-...',
      // and the newly flushed SSTable also uses 'bbbbbbbb-...'.
      final sstFiles = await adapter.listFiles('$dir/sst', extension: '.sst');
      expect(sstFiles, isNotEmpty);
      for (final filename in sstFiles) {
        expect(
          filename,
          startsWith('bbbbbbbb-'),
          reason: 'every SSTable must use the new device ID after reassign',
        );
      }
      // Sanity-check: no old-prefix files remain.
      final oldPrefixFiles = sstFiles
          .where((f) => f.startsWith('aaaaaaaa-'))
          .toList();
      expect(
        oldPrefixFiles,
        isEmpty,
        reason: 'no old-prefix SSTables should remain',
      );

      // Both documents must be readable.
      expect(await store.get('col', _key('before')), Uint8List.fromList([1]));
      expect(await store.get('col', _key('after')), Uint8List.fromList([2]));

      await store.close();
    });
  });
}
