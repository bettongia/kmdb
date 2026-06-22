// Copyright 2026 The Authors.
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

/// Tests for local-only namespace segregation (WI-0).
///
/// Covers:
/// - Phase 1: [isLocalOnly] predicate, [SstableMeta.localOnly] CBOR
///   round-trip, and user-collection enumeration guard for `$$` namespaces.
/// - Phase 2: [SstableInfo] parser round-trips for `.local.sst` filenames.
/// - Phase 3: [LsmEngine.flush] two-writer split into `.sst` (syncable) and
///   `.local.sst` (local-only) partitions.
/// - Phase 4: [CompactionJob.run] two-writer split, [LocalOnlyCollapsePolicy]
///   tombstone drop (horizon relaxed, allLevels gate retained), and
///   [tombstonesDropped] counting only syncable drops.
library;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/compaction/compaction_job.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart';
import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/manifest/manifest_reader.dart';
import 'package:kmdb/src/engine/manifest/manifest_writer.dart';
import 'package:kmdb/src/engine/manifest/version_edit.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/engine/util/namespace_codec.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const _dbDir = '/db';
const _sstDir = '$_dbDir/sst';
const _manifestPath = '$_dbDir/MANIFEST-00001';
const _deviceId = 'testdev1';

// ── Helpers ───────────────────────────────────────────────────────────────────

MemoryStorageAdapter _newAdapter() => MemoryStorageAdapter();

/// Opens a KvStore backed by [adapter] with [deviceId].
Future<(KvStoreImpl, OpenResult)> _open(
  MemoryStorageAdapter adapter, {
  String deviceId = _deviceId,
}) => KvStoreImpl.open(
  _dbDir,
  adapter,
  config: KvStoreConfig.forTesting(),
  deviceId: deviceId,
);

/// Builds an internal key for namespace [ns], user key suffix [hexSuffix],
/// at [hlc] with [type] record type.
Uint8List _ikey(
  String ns,
  String hexSuffix,
  Hlc hlc, {
  RecordType type = RecordType.put,
}) {
  final hexKey =
      '${hexSuffix.padLeft(12, '0')}70008${hexSuffix.padLeft(15, '0')}';
  return KeyCodec.encodeInternalKey(ns, KeyCodec.keyToBytes(hexKey), hlc, type);
}

Uint8List _val(int b) => Uint8List.fromList([b]);

/// Writes a single key-value pair to a [$$]-prefixed namespace using the
/// internal path that bypasses the namespace guard on the public API.
///
/// The public [KvStoreImpl.put] rejects `$`-prefixed namespaces (they are
/// reserved for system use). The query layer uses [KvStoreImpl.writeBatchInternal]
/// to write derived-data namespaces (`$$index:`, `$$fts:`, `$$vec:`). Tests
/// must do the same to exercise the flush-partitioning logic.
Future<void> _putInternal(
  KvStoreImpl store,
  String namespace,
  String key,
  Uint8List value,
) async {
  final batch = WriteBatch()..put(namespace, key, value);
  await store.writeBatchInternal(batch);
}

/// Writes a small SSTable containing [entries] to [adapter] at [filename].
Future<void> _writeSst(
  MemoryStorageAdapter adapter,
  String filename,
  List<(Uint8List, Uint8List)> entries,
) async {
  final sorted = List.of(entries)
    ..sort((a, b) {
      final ak = a.$1;
      final bk = b.$1;
      final len = ak.length < bk.length ? ak.length : bk.length;
      for (var i = 0; i < len; i++) {
        if (ak[i] != bk[i]) return ak[i] - bk[i];
      }
      return ak.length - bk.length;
    });
  final writer = SstableWriter();
  for (final (k, v) in sorted) {
    writer.add(k, v);
  }
  await adapter.writeFile('$_sstDir/$filename', writer.finish());
}

// ── Phase 1: isLocalOnly predicate ────────────────────────────────────────────

void main() {
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('isLocalOnly predicate', () {
    test(r'returns true for $$-prefixed namespaces', () {
      expect(isLocalOnly(r'$$fts:articles:body:abc'), isTrue);
      expect(isLocalOnly(r'$$vec:docs:embedding'), isTrue);
      expect(isLocalOnly(r'$$index:users:email'), isTrue);
      expect(isLocalOnly(r'$$'), isTrue);
      expect(isLocalOnly(r'$$custom:namespace'), isTrue);
    });

    test(r'returns false for single-$ system namespaces', () {
      expect(isLocalOnly(r'$meta'), isFalse);
      expect(isLocalOnly(r'$cache'), isFalse);
      expect(isLocalOnly(r'$ver:users'), isFalse);
      expect(isLocalOnly(r'$sync'), isFalse);
    });

    test('returns false for user namespaces', () {
      expect(isLocalOnly('users'), isFalse);
      expect(isLocalOnly('tasks'), isFalse);
      expect(isLocalOnly(''), isFalse);
    });
  });

  // ── Phase 1: SstableMeta.localOnly CBOR round-trip ────────────────────────

  group('SstableMeta.localOnly CBOR round-trip', () {
    SstableMeta makeMeta(String filename, {bool localOnly = false}) => SstableMeta(
      level: 0,
      filename: filename,
      minKey: '0' * 32,
      maxKey: 'f' * 32,
      entryCount: 10,
      localOnly: localOnly,
    );

    test('localOnly=true round-trips through toCbor/fromCbor', () {
      final edit = VersionEdit(
        logNumber: 1,
        nextSeq: 100,
        added: [makeMeta('dev-0001-0002.local.sst', localOnly: true)],
      );
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.added.length, equals(1));
      expect(decoded.added.first.localOnly, isTrue);
    });

    test('localOnly=false round-trips correctly', () {
      final edit = VersionEdit(
        logNumber: 1,
        nextSeq: 100,
        added: [makeMeta('dev-0001-0002.sst', localOnly: false)],
      );
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.added.first.localOnly, isFalse);
    });

    test('absent localOnly key decodes as false (backward compatibility)', () {
      // Simulate an old Manifest record that has no localOnly key.
      final edit = VersionEdit(
        logNumber: 1,
        nextSeq: 100,
        added: [
          SstableMeta(
            level: 0,
            filename: 'dev-0001-0002.sst',
            minKey: '0' * 32,
            maxKey: 'f' * 32,
            entryCount: 5,
          ), // default localOnly=false
        ],
      );
      // The CBOR encoding of a default-false SstableMeta should not include
      // the key; decoding must still produce localOnly=false.
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.added.first.localOnly, isFalse);
    });

    test('localOnly=true is written compactly (key absent when false)', () {
      // Inspect the raw toCbor/toMap output: the 'localOnly' key must be
      // present in the map when true but absent when false.
      final trueMeta = makeMeta('dev-0001.local.sst', localOnly: true);
      final falseMeta = makeMeta('dev-0001.sst', localOnly: false);

      final trueMap = trueMeta.toMap();
      final falseMap = falseMeta.toMap();

      expect(trueMap.containsKey('localOnly'), isTrue);
      expect(falseMap.containsKey('localOnly'), isFalse);
    });
  });

  // ── Phase 1: $$ namespace not listed in user-collection enumeration ────────

  group(r'$$-namespace user-collection guard', () {
    test(r'$$-prefixed writes do not appear in listNamespaces', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);

      // Write a user document.
      final k = SequentialKeyGenerator(start: 0).next();
      await store.put('users', k, Uint8List.fromList([1]));
      // Write a $$-prefixed entry simulating a derived index (internal path).
      final k2 = SequentialKeyGenerator(start: 1).next();
      await _putInternal(
        store,
        r'$$index:users:email',
        k2,
        Uint8List.fromList([2]),
      );

      // listNamespaces must include 'users' but not '$$index:users:email'.
      final namespaces = await store.listNamespaces();
      expect(namespaces, contains('users'));
      expect(namespaces, isNot(contains(r'$$index:users:email')));

      await store.close();
    });
  });

  // ── Phase 2: SstableInfo .local.sst parsing ────────────────────────────────

  group('SstableInfo .local.sst filename parsing', () {
    test('parses .local.sst flush filename and sets localOnly=true', () {
      const name = 'a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.local.sst';
      final info = SstableInfo.parse(name);
      expect(info.deviceId, equals('a1b2c3d4'));
      expect(info.localOnly, isTrue);
      expect(info.epoch, isNull);
      expect(info.isConsolidation, isFalse);
      expect(info.filename, equals(name));
    });

    test('parses plain .sst flush filename and sets localOnly=false', () {
      const name = 'a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst';
      final info = SstableInfo.parse(name);
      expect(info.localOnly, isFalse);
    });

    test('parses 4-segment consolidation filename with localOnly=false', () {
      const name = 'a1b2c3d4-7-017F8A090000-017F8A0AFFFF.sst';
      final info = SstableInfo.parse(name);
      expect(info.isConsolidation, isTrue);
      expect(info.localOnly, isFalse);
    });

    test('flushName with localOnly=true generates .local.sst suffix', () {
      final name = SstableInfo.flushName(
        'a1b2c3d4',
        const Hlc(0x017F8A0A0000, 0),
        const Hlc(0x017F8A0AFFFF, 0),
        localOnly: true,
      );
      expect(name, endsWith('.local.sst'));
      expect(name, startsWith('a1b2c3d4-'));
    });

    test('flushName default (localOnly=false) generates .sst suffix', () {
      final name = SstableInfo.flushName(
        'a1b2c3d4',
        const Hlc(0x017F8A0A0000, 0),
        const Hlc(0x017F8A0AFFFF, 0),
      );
      expect(name, endsWith('.sst'));
      expect(name, isNot(endsWith('.local.sst')));
    });

    test('.local.sst flushName round-trips through parse (localOnly=true)', () {
      final name = SstableInfo.flushName(
        'deadbeef',
        const Hlc(1000, 5),
        const Hlc(2000, 7),
        localOnly: true,
      );
      final info = SstableInfo.parse(name);
      expect(info.localOnly, isTrue);
      expect(info.deviceId, equals('deadbeef'));
      expect(info.minHlc, equals(const Hlc(1000, 5)));
      expect(info.maxHlc, equals(const Hlc(2000, 7)));
    });

    test('.sst flushName round-trips through parse (localOnly=false)', () {
      final name = SstableInfo.flushName(
        'deadbeef',
        const Hlc(1000, 0),
        const Hlc(2000, 0),
      );
      final info = SstableInfo.parse(name);
      expect(info.localOnly, isFalse);
    });

    test('consolidationName never generates .local.sst', () {
      final name = SstableInfo.consolidationName(
        'a1b2c3d4',
        42,
        const Hlc(1500, 0),
        const Hlc(3000, 0),
      );
      expect(name, isNot(contains('.local')));
      expect(name, endsWith('.sst'));
      final info = SstableInfo.parse(name);
      expect(info.localOnly, isFalse);
      expect(info.isConsolidation, isTrue);
    });

    test(
      'syncable and local-only flushName from same HLC range produce distinct filenames',
      () {
        // Both partitions from a single flush share the same HLC range; the
        // .local.sst suffix is the only distinguisher.
        final syncName = SstableInfo.flushName(
          'a1b2c3d4',
          const Hlc(1000, 0),
          const Hlc(2000, 0),
        );
        final localName = SstableInfo.flushName(
          'a1b2c3d4',
          const Hlc(1000, 0),
          const Hlc(2000, 0),
          localOnly: true,
        );
        expect(syncName, isNot(equals(localName)));
      },
    );
  });

  // ── Phase 3: LsmEngine.flush two-writer split ─────────────────────────────

  group('LsmEngine.flush two-writer split', () {
    test('flush with only syncable entries produces one .sst file', () async {
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);

      // Write only user-namespace entries.
      final k = SequentialKeyGenerator(start: 0).next();
      await store.put('users', k, Uint8List.fromList([1]));
      await store.flush();

      // Exactly one SSTable produced; it must be a .sst file.
      final files = await adapter.listFiles('$_dbDir/sst');
      final sstFiles = files.where((f) => f.endsWith('.sst')).toList();
      expect(sstFiles.length, equals(1));
      expect(sstFiles.first, isNot(endsWith('.local.sst')));

      await store.close();
    });

    test(
      'flush with only local-only entries produces one .local.sst file',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);

        // Write only $$-prefixed entries (internal path required).
        final k = SequentialKeyGenerator(start: 0).next();
        await _putInternal(
          store,
          r'$$index:users:email',
          k,
          Uint8List.fromList([1]),
        );
        await store.flush();

        final files = await adapter.listFiles('$_dbDir/sst');
        // Exactly one .local.sst file. ($meta written by open() produces a
        // syncable .sst alongside it, so we assert on the .local.sst count only.)
        final localFiles = files
            .where((f) => f.endsWith('.local.sst'))
            .toList();
        expect(localFiles.length, equals(1));

        await store.close();
      },
    );

    test(
      'flush with mixed entries produces both .sst and .local.sst files',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);

        // Write one syncable and one local-only entry (internal path for $$).
        final k1 = SequentialKeyGenerator(start: 0).next();
        final k2 = SequentialKeyGenerator(start: 1).next();
        await store.put('users', k1, Uint8List.fromList([1]));
        await _putInternal(
          store,
          r'$$fts:users:name',
          k2,
          Uint8List.fromList([2]),
        );
        await store.flush();

        final files = await adapter.listFiles('$_dbDir/sst');
        expect(files.length, equals(2));

        final syncFiles = files
            .where((f) => f.endsWith('.sst') && !f.endsWith('.local.sst'))
            .toList();
        final localFiles = files
            .where((f) => f.endsWith('.local.sst'))
            .toList();
        expect(syncFiles.length, equals(1));
        expect(localFiles.length, equals(1));

        await store.close();
      },
    );

    test(
      'Manifest has one VersionEdit with up to two SstableMeta entries for a mixed flush',
      () async {
        final adapter = _newAdapter();
        final (store, _) = await _open(adapter);

        // Write both syncable and local-only entries, then flush.
        final k1 = SequentialKeyGenerator(start: 0).next();
        final k2 = SequentialKeyGenerator(start: 1).next();
        await store.put('users', k1, Uint8List.fromList([1]));
        await _putInternal(
          store,
          r'$$vec:users:embedding',
          k2,
          Uint8List.fromList([2]),
        );
        await store.flush();

        // Read the Manifest and verify.
        final manifestFiles = await adapter.listFiles(_dbDir);
        final manifestName = manifestFiles.firstWhere(
          (f) => f.startsWith('MANIFEST-'),
        );
        final state = await ManifestReader(
          adapter: adapter,
        ).replay('$_dbDir/$manifestName');

        // Compaction may have moved L0 files to L2 (l0CompactionTrigger=2).
        // Check all levels for at least one syncable and one local-only SSTable.
        final allMeta = state.levels.values.expand((l) => l).toList();
        final addedFiles = allMeta.map((m) => m.filename).toList();
        final syncAdded = addedFiles
            .where((f) => !f.endsWith('.local.sst'))
            .toList();
        final localAdded = addedFiles
            .where((f) => f.endsWith('.local.sst'))
            .toList();
        expect(
          syncAdded,
          isNotEmpty,
          reason: 'syncable SSTable must be in Manifest',
        );
        expect(
          localAdded,
          isNotEmpty,
          reason: 'local-only SSTable must be in Manifest',
        );

        // Verify localOnly flags on the meta.
        final syncMeta = allMeta.firstWhere((m) => !m.localOnly);
        final localMeta = allMeta.firstWhere((m) => m.localOnly);
        expect(syncMeta.localOnly, isFalse);
        expect(localMeta.localOnly, isTrue);

        await store.close();
      },
    );

    test('local-only entries are readable after flush', () async {
      // Even though the SSTable is local-only, the KvStore must still be able
      // to read back from it (it's local to *this* device, just not synced).
      final adapter = _newAdapter();
      final (store, _) = await _open(adapter);

      final k = SequentialKeyGenerator(start: 0).next();
      final value = Uint8List.fromList([0xAB, 0xCD]);
      await _putInternal(store, r'$$index:users:email', k, value);
      await store.flush();

      final result = await store.get(r'$$index:users:email', k);
      expect(result, isNotNull);
      expect(result, equals(value));

      await store.close();
    });
  });

  // ── Phase 4: CompactionJob two-writer split ────────────────────────────────

  group('CompactionJob.run two-writer split', () {
    test('compaction of mixed SSTable produces two output files', () async {
      final adapter = _newAdapter();
      final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
      await adapter.createDirectory(_sstDir);

      // Build an input SSTable with both syncable and local-only entries.
      final k1 = _ikey('users', '1', const Hlc(100, 0));
      final k2 = _ikey(r'$$fts:users:body', '2', const Hlc(101, 0));

      // Sort keys manually (namespace prefix order matters).
      final entries = [
        if (k1.first < k2.first) ...[
          (k1, _val(1)),
          (k2, _val(2)),
        ] else ...[
          (k2, _val(2)),
          (k1, _val(1)),
        ],
      ];

      const inputFilename = 'testdev1-0000000000640000-0000000000650000.sst';
      await _writeSst(adapter, inputFilename, entries);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [const SstableRef(level: 0, filename: inputFilename)],
        adapter: adapter,
        manifestWriter: mWriter,
        logNumber: 1,
        nextSeq: 200,
        allLevels: true,
        horizon: const Hlc(0, 0),
      );
      final edit = await job.run();

      // Two added SstableMeta entries: one syncable, one local-only.
      expect(edit.added.length, equals(2));
      final syncMeta = edit.added.firstWhere((m) => !m.localOnly);
      final localMeta = edit.added.firstWhere((m) => m.localOnly);
      expect(syncMeta.localOnly, isFalse);
      expect(localMeta.localOnly, isTrue);
      expect(localMeta.filename, endsWith('.local.sst'));
      expect(syncMeta.filename, isNot(endsWith('.local.sst')));
    });

    test('compaction of all-syncable input produces one .sst output', () async {
      final adapter = _newAdapter();
      final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
      await adapter.createDirectory(_sstDir);

      final k1 = _ikey('users', '1', const Hlc(100, 0));
      final k2 = _ikey('tasks', '2', const Hlc(101, 0));
      const inputFilename = 'testdev1-0000000000640000-0000000000650000.sst';
      await _writeSst(adapter, inputFilename, [(k1, _val(1)), (k2, _val(2))]);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [const SstableRef(level: 0, filename: inputFilename)],
        adapter: adapter,
        manifestWriter: mWriter,
        logNumber: 1,
        nextSeq: 200,
      );
      final edit = await job.run();

      expect(edit.added.length, equals(1));
      expect(edit.added.first.localOnly, isFalse);
      expect(edit.added.first.filename, isNot(endsWith('.local.sst')));
    });

    test(
      'compaction of all-local-only input produces one .local.sst output',
      () async {
        final adapter = _newAdapter();
        final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
        await adapter.createDirectory(_sstDir);

        final k1 = _ikey(r'$$fts:users:body', '1', const Hlc(100, 0));
        final k2 = _ikey(r'$$vec:docs:emb', '2', const Hlc(101, 0));
        const inputFilename = 'testdev1-0000000000640000-0000000000650000.sst';
        await _writeSst(adapter, inputFilename, [(k1, _val(1)), (k2, _val(2))]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [const SstableRef(level: 0, filename: inputFilename)],
          adapter: adapter,
          manifestWriter: mWriter,
          logNumber: 1,
          nextSeq: 200,
        );
        final edit = await job.run();

        expect(edit.added.length, equals(1));
        expect(edit.added.first.localOnly, isTrue);
        expect(edit.added.first.filename, endsWith('.local.sst'));
      },
    );

    test('local-only output entries are readable after compaction', () async {
      final adapter = _newAdapter();
      final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
      await adapter.createDirectory(_sstDir);

      final k1 = _ikey(r'$$index:users:email', '1', const Hlc(100, 0));
      const inputFilename = 'testdev1-0000000000640000-0000000000640000.sst';
      await _writeSst(adapter, inputFilename, [(k1, _val(42))]);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [const SstableRef(level: 0, filename: inputFilename)],
        adapter: adapter,
        manifestWriter: mWriter,
        logNumber: 1,
        nextSeq: 200,
      );
      final edit = await job.run();
      expect(edit.added.length, equals(1));

      // Read back from the output file.
      final outFile = edit.added.first.filename;
      final reader = await SstableReader.open('$_sstDir/$outFile', adapter);
      final entries = await reader.scan().toList();
      expect(entries.length, equals(1));
      expect(entries.first.key, equals(k1));
    });
  });

  // ── Phase 4: LocalOnlyCollapsePolicy tombstone GC ─────────────────────────

  group('LocalOnlyCollapsePolicy tombstone drop semantics', () {
    const policy = LocalOnlyCollapsePolicy();

    test('drops tombstone when allLevels=true regardless of horizon', () {
      // Local-only data is device-local: the sync horizon is irrelevant.
      // The only safety gate is allLevels.
      expect(
        policy.dropTombstone(
          allLevels: true,
          tombstoneHlc: const Hlc(1000, 0),
          horizon: const Hlc(0, 0), // horizon at epoch — still drops
        ),
        isTrue,
      );
      expect(
        policy.dropTombstone(
          allLevels: true,
          tombstoneHlc: const Hlc(9999, 0),
          horizon: const Hlc(100, 0), // tombstone above horizon — still drops
        ),
        isTrue,
      );
    });

    test('refuses to drop tombstone when allLevels=false', () {
      // Partial compaction: an older version may live in an uncovered level.
      expect(
        policy.dropTombstone(
          allLevels: false,
          tombstoneHlc: const Hlc(1000, 0),
          horizon: const Hlc(9999, 0), // large horizon — still blocks
        ),
        isFalse,
      );
    });

    test('collapseVersions is true', () {
      expect(policy.collapseVersions, isTrue);
    });
  });

  group(
    r'ReclamationPolicyRegistry resolves $$ namespaces to LocalOnlyCollapsePolicy',
    () {
      test(r'$$-prefixed namespaces resolve to LocalOnlyCollapsePolicy', () {
        final registry = ReclamationPolicyRegistry();
        expect(
          registry.resolve(r'$$fts:users:body'),
          isA<LocalOnlyCollapsePolicy>(),
        );
        expect(
          registry.resolve(r'$$vec:docs:emb'),
          isA<LocalOnlyCollapsePolicy>(),
        );
        expect(
          registry.resolve(r'$$index:users:email'),
          isA<LocalOnlyCollapsePolicy>(),
        );
      });

      test(
        r'single-$ namespaces do not resolve to LocalOnlyCollapsePolicy',
        () {
          final registry = ReclamationPolicyRegistry();
          expect(
            registry.resolve(r'$meta'),
            isNot(isA<LocalOnlyCollapsePolicy>()),
          );
          expect(
            registry.resolve('users'),
            isNot(isA<LocalOnlyCollapsePolicy>()),
          );
        },
      );
    },
  );

  group('CompactionJob tombstonesDropped counts only syncable drops', () {
    test(
      'local-only tombstone drop does NOT increment tombstonesDropped',
      () async {
        final adapter = _newAdapter();
        final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
        await adapter.createDirectory(_sstDir);

        // A local-only tombstone entry.
        final k1 = _ikey(
          r'$$fts:users:body',
          '1',
          const Hlc(50, 0),
          type: RecordType.delete,
        );
        const inputFilename = 'testdev1-0000000000320000-0000000000320000.sst';
        await _writeSst(adapter, inputFilename, [(k1, _val(0))]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [const SstableRef(level: 0, filename: inputFilename)],
          adapter: adapter,
          manifestWriter: mWriter,
          logNumber: 1,
          nextSeq: 200,
          allLevels: true,
          horizon: const Hlc(0, 0), // horizon at epoch — local-only still drops
        );
        await job.run();

        // The tombstone was dropped (allLevels=true), but tombstonesDropped
        // must stay zero because the tombstone was in a local-only namespace.
        expect(job.tombstonesDropped, equals(0));
      },
    );

    test('syncable tombstone drop increments tombstonesDropped', () async {
      final adapter = _newAdapter();
      final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
      await adapter.createDirectory(_sstDir);

      // A syncable (user namespace) tombstone with HLC below the horizon.
      final k1 = _ikey('users', '1', const Hlc(50, 0), type: RecordType.delete);
      const inputFilename = 'testdev1-0000000000320000-0000000000320000.sst';
      await _writeSst(adapter, inputFilename, [(k1, _val(0))]);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [const SstableRef(level: 0, filename: inputFilename)],
        adapter: adapter,
        manifestWriter: mWriter,
        logNumber: 1,
        nextSeq: 200,
        allLevels: true,
        horizon: const Hlc(100, 0), // horizon above tombstone HLC — should drop
      );
      await job.run();

      expect(job.tombstonesDropped, equals(1));
    });

    test(
      'local-only tombstone in partial compaction is NOT dropped (allLevels=false)',
      () async {
        final adapter = _newAdapter();
        final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
        await adapter.createDirectory(_sstDir);

        final k1 = _ikey(
          r'$$index:users:email',
          '1',
          const Hlc(50, 0),
          type: RecordType.delete,
        );
        const inputFilename = 'testdev1-0000000000320000-0000000000320000.sst';
        await _writeSst(adapter, inputFilename, [(k1, _val(0))]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 1,
          inputs: [const SstableRef(level: 0, filename: inputFilename)],
          adapter: adapter,
          manifestWriter: mWriter,
          logNumber: 1,
          nextSeq: 200,
          allLevels: false, // partial compaction — must NOT drop
          horizon: const Hlc(9999, 0),
        );
        final edit = await job.run();

        // The tombstone must still be present in the output.
        expect(edit.added, isNotEmpty);
        final outFile = edit.added.first.filename;
        final reader = await SstableReader.open('$_sstDir/$outFile', adapter);
        final entries = await reader.scan().toList();
        expect(
          entries.length,
          equals(1),
          reason: 'tombstone must not be dropped in a partial compaction',
        );
        expect(job.tombstonesDropped, equals(0));
      },
    );

    test(
      r'droppedVersionValues is never populated by $$-namespaced entries',
      () async {
        // $$-namespaced entries never hold vault URIs; droppedVersionValues
        // must remain empty even when local-only entries are trimmed.
        final adapter = _newAdapter();
        final mWriter = ManifestWriter(path: _manifestPath, adapter: adapter);
        await adapter.createDirectory(_sstDir);

        // Write a $$-prefixed tombstone — will be dropped by LocalOnlyCollapsePolicy.
        final k1 = _ikey(
          r'$$vec:docs:emb',
          '1',
          const Hlc(50, 0),
          type: RecordType.delete,
        );
        const inputFilename = 'testdev1-0000000000320000-0000000000320000.sst';
        await _writeSst(adapter, inputFilename, [(k1, _val(0))]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [const SstableRef(level: 0, filename: inputFilename)],
          adapter: adapter,
          manifestWriter: mWriter,
          logNumber: 1,
          nextSeq: 200,
          allLevels: true,
          horizon: const Hlc(0, 0),
        );
        await job.run();

        expect(job.droppedVersionValues, isEmpty);
      },
    );
  });
}
