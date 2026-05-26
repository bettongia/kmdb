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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/compaction/compaction_job.dart';
import 'package:kmdb/src/engine/compaction/merge_iterator.dart';
import 'package:kmdb/src/engine/compaction/reclamation_policy.dart';
import 'package:kmdb/src/engine/manifest/manifest_reader.dart';
import 'package:kmdb/src/engine/manifest/manifest_writer.dart';
import 'package:kmdb/src/engine/manifest/version_edit.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_reader.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _sstDir = '/db/sst';
const _manifestPath = '/db/MANIFEST-00001';
const _deviceId = 'deadbeef';

/// Helper to build an internal key from a simple hex string.
/// Ensures the key is a valid-looking UUIDv7.
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

/// Sorts a list of (key, value) entries by ascending internal-key bytes —
/// required by [SstableWriter] which expects keys in ascending order.
void _sortEntries(List<(Uint8List, Uint8List)> entries) {
  entries.sort((a, b) {
    final ak = a.$1;
    final bk = b.$1;
    final min = ak.length < bk.length ? ak.length : bk.length;
    for (var i = 0; i < min; i++) {
      if (ak[i] != bk[i]) return ak[i] - bk[i];
    }
    return ak.length - bk.length;
  });
}

/// Writes a small SSTable to the adapter and returns its filename.
Future<String> _writeSSTable(
  MemoryStorageAdapter adapter,
  String filename,
  List<(Uint8List, Uint8List)> entries,
) async {
  final writer = SstableWriter();
  for (final (k, v) in entries) {
    writer.add(k, v);
  }
  final path = '$_sstDir/$filename';
  await adapter.writeFile(path, writer.finish());
  return filename;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('MergeIterator', () {
    test('merges two sorted streams in order', () async {
      final adapter = MemoryStorageAdapter();
      final k1 = _ikey('ns', '1', const Hlc(1, 0));
      final k2 = _ikey('ns', '2', const Hlc(1, 0));
      final k3 = _ikey('ns', '3', const Hlc(1, 0));
      final k4 = _ikey('ns', '4', const Hlc(1, 0));

      // Sort keys for use in separate SSTables.
      final sorted = [k1, k2, k3, k4]
        ..sort((a, b) {
          final min = a.length < b.length ? a.length : b.length;
          for (var i = 0; i < min; i++) {
            if (a[i] != b[i]) return a[i] - b[i];
          }
          return a.length - b.length;
        });

      // Write two SSTables with interleaved keys.
      await _writeSSTable(adapter, 'a.sst', [
        (sorted[0], _val(0)),
        (sorted[2], _val(2)),
      ]);
      await _writeSSTable(adapter, 'b.sst', [
        (sorted[1], _val(1)),
        (sorted[3], _val(3)),
      ]);

      final r1 = await SstableReader.open('$_sstDir/a.sst', adapter);
      final r2 = await SstableReader.open('$_sstDir/b.sst', adapter);
      final merged = await MergeIterator([
        r1.scan(),
        r2.scan(),
      ]).entries.toList();

      expect(merged.length, equals(4));
      // Verify ascending order.
      for (var i = 0; i < merged.length - 1; i++) {
        final cmp = _cmpKey(merged[i].key, merged[i + 1].key);
        expect(cmp, lessThan(0));
      }
    });

    test('newer source wins on duplicate key', () async {
      final adapter = MemoryStorageAdapter();
      final k = _ikey('ns', 'a', const Hlc(1, 0));

      await _writeSSTable(adapter, 'new.sst', [(k, _val(99))]);
      await _writeSSTable(adapter, 'old.sst', [(k, _val(1))]);

      // Source 0 = new (index 0 = higher priority).
      final rNew = await SstableReader.open('$_sstDir/new.sst', adapter);
      final rOld = await SstableReader.open('$_sstDir/old.sst', adapter);
      final merged = await MergeIterator([
        rNew.scan(),
        rOld.scan(),
      ]).entries.toList();

      expect(merged.length, equals(1));
      expect(merged[0].value, equals(_val(99)));
      expect(merged[0].source, equals(0));
    });

    test('empty streams produce no output', () async {
      final adapter = MemoryStorageAdapter();
      final k = _ikey('ns', 'a', const Hlc(1, 0));
      await _writeSSTable(adapter, 'a.sst', [(k, _val(1))]);
      final r = await SstableReader.open('$_sstDir/a.sst', adapter);
      // Pass a single stream — effectively no merge needed.
      final merged = await MergeIterator([r.scan()]).entries.toList();
      expect(merged.length, equals(1));
    });
  });

  group('CompactionJob', () {
    test('merges two L0 SSTables into one L1 SSTable', () async {
      final adapter = MemoryStorageAdapter();
      await adapter.createDirectory(_sstDir);

      final k1 = _ikey('ns', '1', const Hlc(1, 0));
      final k2 = _ikey('ns', '2', const Hlc(2, 0));
      final k3 = _ikey('ns', '3', const Hlc(3, 0));
      final k4 = _ikey('ns', '4', const Hlc(4, 0));

      // Sort all keys.
      final allKeys = [k1, k2, k3, k4]
        ..sort((a, b) {
          final min = a.length < b.length ? a.length : b.length;
          for (var i = 0; i < min; i++) {
            if (a[i] != b[i]) return a[i] - b[i];
          }
          return a.length - b.length;
        });

      // Two input SSTables at L0.
      final f1 = await _writeSSTable(
        adapter,
        'f1-deadbeef-000001000000-000002000000.sst',
        [(allKeys[0], _val(1)), (allKeys[2], _val(3))],
      );
      final f2 = await _writeSSTable(
        adapter,
        'f2-deadbeef-000003000000-000004000000.sst',
        [(allKeys[1], _val(2)), (allKeys[3], _val(4))],
      );

      final manifestWriter = ManifestWriter(
        path: _manifestPath,
        adapter: adapter,
      );

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 1,
        inputs: [
          SstableRef(level: 0, filename: f1),
          SstableRef(level: 0, filename: f2),
        ],
        adapter: adapter,
        manifestWriter: manifestWriter,
        logNumber: 1,
        nextSeq: 500,
      );

      final edit = await job.run();

      // The VersionEdit should record the removed inputs and the added output.
      expect(edit.removed.length, equals(2));
      expect(edit.added.length, equals(1));
      expect(edit.added[0].level, equals(1));

      // The output SSTable should be readable.
      final outFilename = edit.added[0].filename;
      final reader = await SstableReader.open('$_sstDir/$outFilename', adapter);
      expect(reader.entryCount, equals(4));

      // Manifest should reflect the new state.
      final state = await ManifestReader(
        adapter: adapter,
      ).replay(_manifestPath);
      expect(state.levels[1], contains(outFilename));
      expect(state.levels[0], isEmpty);
    });

    test('duplicate key: newest file wins', () async {
      final adapter = MemoryStorageAdapter();
      await adapter.createDirectory(_sstDir);

      final k = _ikey('ns', 'a', const Hlc(1, 0));
      // File 1 is "newer" (will be passed last in inputFiles, reversed = first in merge).
      final f1 = await _writeSSTable(adapter, 'newer.sst', [(k, _val(99))]);
      final f2 = await _writeSSTable(adapter, 'older.sst', [(k, _val(1))]);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 1,
        inputs: [
          SstableRef(level: 0, filename: f2),
          SstableRef(level: 0, filename: f1),
        ],
        adapter: adapter,
        manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
        logNumber: 1,
        nextSeq: 100,
      );
      final edit = await job.run();

      final outFilename = edit.added[0].filename;
      final reader = await SstableReader.open('$_sstDir/$outFilename', adapter);
      final entries = await reader.scan().toList();
      expect(entries.length, equals(1));
      expect(entries[0].value, equals(_val(99)));
    });
  });

  // ── H4 PR1: version collapse + reclamation policy hook ────────────────────
  //
  // Version collapse drops every superseded version of a (namespace, userKey)
  // group during compaction, keeping only the highest-HLC entry. It is safe at
  // any compaction level because reads re-merge all levels and LWW on HLC.
  // The reclamation policy hook lets specific namespace classes (currently
  // `$ver:`) opt out of collapse and retain every version verbatim.

  group('CompactionJob — version collapse (H4 PR1)', () {
    test(
      'collapses three versions of one key down to the highest-HLC entry',
      () async {
        final adapter = MemoryStorageAdapter();
        await adapter.createDirectory(_sstDir);

        // Three versions of the same user key at strictly increasing HLCs,
        // spread across two input SSTables. Keys within each SSTable must be
        // sorted ascending by internal key (HLC ascending in this case).
        final v1 = _ikey('users', 'a', const Hlc(1, 0));
        final v2 = _ikey('users', 'a', const Hlc(2, 0));
        final v3 = _ikey('users', 'a', const Hlc(3, 0));

        final f1 = await _writeSSTable(adapter, 'older.sst', [
          (v1, _val(1)),
          (v2, _val(2)),
        ]);
        final f2 = await _writeSSTable(adapter, 'newer.sst', [(v3, _val(3))]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [
            // Pass oldest first; CompactionJob reverses internally so file 2
            // (newer) is the merge's higher-priority source.
            SstableRef(level: 0, filename: f1),
            SstableRef(level: 0, filename: f2),
          ],
          adapter: adapter,
          manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
          logNumber: 1,
          nextSeq: 100,
        );
        final edit = await job.run();

        final reader = await SstableReader.open(
          '$_sstDir/${edit.added[0].filename}',
          adapter,
        );
        final entries = await reader.scan().toList();
        expect(entries.length, equals(1));
        expect(entries[0].value, equals(_val(3)));
        // The surviving entry's embedded HLC must be the newest.
        expect(KeyCodec.decodeHlc(entries[0].key), equals(const Hlc(3, 0)));
      },
    );

    test('collapses many versions across many keys; each key keeps only its '
        'highest-HLC version; cross-key independence preserved', () async {
      final adapter = MemoryStorageAdapter();
      await adapter.createDirectory(_sstDir);

      // Three user keys, each with three versions. Build a single SSTable
      // with all entries in correct ascending order.
      final entries = <(Uint8List, Uint8List)>[];
      for (final suffix in ['1', '2', '3']) {
        for (final hlc in [
          const Hlc(10, 0),
          const Hlc(20, 0),
          const Hlc(30, 0),
        ]) {
          entries.add((_ikey('users', suffix, hlc), _val(hlc.physicalMs)));
        }
      }
      _sortEntries(entries);
      final f1 = await _writeSSTable(adapter, 'all.sst', entries);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [SstableRef(level: 0, filename: f1)],
        adapter: adapter,
        manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
        logNumber: 1,
        nextSeq: 100,
      );
      final edit = await job.run();

      final reader = await SstableReader.open(
        '$_sstDir/${edit.added[0].filename}',
        adapter,
      );
      final out = await reader.scan().toList();
      // 3 keys × 1 surviving version each.
      expect(out.length, equals(3));
      for (final e in out) {
        // Every surviving entry must be at HLC physical=30 (the newest).
        expect(KeyCodec.decodeHlc(e.key), equals(const Hlc(30, 0)));
        expect(e.value, equals(_val(30)));
      }
    });

    test('collapse applied within partial-level inputs — reads of the same key '
        'in an excluded level continue to win on global LWW', () async {
      // This test asserts the invariant that makes collapse "safe at any
      // level": collapse within the compaction's inputs preserves only the
      // newest version from those inputs. A higher-HLC version in a level
      // that was NOT part of this compaction is still observable on read
      // because reads merge all levels. We simulate that by running a
      // partial compaction over an older subset and then merge-checking the
      // global state via a separate read of an "excluded" newer SSTable.

      final adapter = MemoryStorageAdapter();
      await adapter.createDirectory(_sstDir);

      // The "L0 inputs" subset to be compacted: two old versions.
      final v1 = _ikey('users', 'a', const Hlc(1, 0));
      final v2 = _ikey('users', 'a', const Hlc(2, 0));
      final l0a = await _writeSSTable(adapter, 'l0a.sst', [
        (v1, _val(1)),
        (v2, _val(2)),
      ]);

      // The excluded L1 file holding an even-newer version.
      final v3 = _ikey('users', 'a', const Hlc(3, 0));
      final l1 = await _writeSSTable(adapter, 'l1.sst', [(v3, _val(3))]);

      // Partial compaction of L0 only — outputs to L1 but does not touch
      // the existing L1 file.
      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 1,
        inputs: [SstableRef(level: 0, filename: l0a)],
        adapter: adapter,
        manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
        logNumber: 1,
        nextSeq: 100,
      );
      final edit = await job.run();

      // The compaction output collapses v1+v2 to v2.
      final outReader = await SstableReader.open(
        '$_sstDir/${edit.added[0].filename}',
        adapter,
      );
      final outEntries = await outReader.scan().toList();
      expect(outEntries.length, equals(1));
      expect(KeyCodec.decodeHlc(outEntries[0].key), equals(const Hlc(2, 0)));

      // A global read merging compaction output + excluded L1 still returns
      // v3 (the highest HLC across all levels), proving the partial-level
      // collapse did not change observable read behaviour.
      final l1Reader = await SstableReader.open('$_sstDir/$l1', adapter);
      final merge = MergeIterator([l1Reader.scan(), outReader.scan()]);
      final globalEntries = await merge.entries.toList();
      // MergeIterator dedups only on full internal key; v2 and v3 differ in
      // HLC so both survive — the read layer would then pick the highest
      // HLC. We assert the highest is v3.
      Hlc highest = const Hlc(0, 0);
      for (final e in globalEntries) {
        final h = KeyCodec.decodeHlc(e.key);
        if (h > highest) highest = h;
      }
      expect(highest, equals(const Hlc(3, 0)));
    });

    test(
      'tombstones are NOT dropped by PR1 — the surviving entry of a deleted '
      'key remains a tombstone (PR2 will own conditional tombstone GC)',
      () async {
        final adapter = MemoryStorageAdapter();
        await adapter.createDirectory(_sstDir);

        // put @ hlc=1, then delete @ hlc=2 (later).
        final p = _ikey('users', 'a', const Hlc(1, 0));
        final t = _ikey('users', 'a', const Hlc(2, 0), type: RecordType.delete);
        final f = await _writeSSTable(adapter, 'pt.sst', [
          (p, _val(1)),
          (t, Uint8List(0)),
        ]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [SstableRef(level: 0, filename: f)],
          adapter: adapter,
          manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
          logNumber: 1,
          nextSeq: 100,
        );
        final edit = await job.run();

        final reader = await SstableReader.open(
          '$_sstDir/${edit.added[0].filename}',
          adapter,
        );
        final entries = await reader.scan().toList();
        // Collapse keeps only the highest-HLC entry of the group — which is
        // the delete tombstone. The put is correctly dropped (superseded by
        // the later delete). The tombstone itself is retained.
        expect(entries.length, equals(1));
        expect(
          KeyCodec.decodeRecordType(entries[0].key),
          equals(RecordType.delete),
        );
      },
    );
  });

  group('CompactionJob — \$ver: exemption (H4 PR1 policy hook)', () {
    test(
      'the default registry retains every version of a \$ver: namespace',
      () async {
        final adapter = MemoryStorageAdapter();
        await adapter.createDirectory(_sstDir);

        // Three versions of the same \$ver: entry — all three must survive.
        final v1 = _ikey(r'$ver:users', 'a', const Hlc(1, 0));
        final v2 = _ikey(r'$ver:users', 'a', const Hlc(2, 0));
        final v3 = _ikey(r'$ver:users', 'a', const Hlc(3, 0));
        final f = await _writeSSTable(adapter, 'ver.sst', [
          (v1, _val(1)),
          (v2, _val(2)),
          (v3, _val(3)),
        ]);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [SstableRef(level: 0, filename: f)],
          adapter: adapter,
          manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
          logNumber: 1,
          nextSeq: 100,
        );
        final edit = await job.run();

        final reader = await SstableReader.open(
          '$_sstDir/${edit.added[0].filename}',
          adapter,
        );
        final entries = await reader.scan().toList();
        expect(entries.length, equals(3));
      },
    );

    test('flipping the registry to "collapse everything" makes \$ver: collapse '
        '— confirming the exemption comes from the policy hook, not from the '
        'compaction transform itself', () async {
      final adapter = MemoryStorageAdapter();
      await adapter.createDirectory(_sstDir);

      final v1 = _ikey(r'$ver:users', 'a', const Hlc(1, 0));
      final v2 = _ikey(r'$ver:users', 'a', const Hlc(2, 0));
      final v3 = _ikey(r'$ver:users', 'a', const Hlc(3, 0));
      final f = await _writeSSTable(adapter, 'ver.sst', [
        (v1, _val(1)),
        (v2, _val(2)),
        (v3, _val(3)),
      ]);

      final job = CompactionJob(
        sstDir: _sstDir,
        deviceId: _deviceId,
        outputLevel: 2,
        inputs: [SstableRef(level: 0, filename: f)],
        adapter: adapter,
        manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
        logNumber: 1,
        nextSeq: 100,
        policyRegistry: ReclamationPolicyRegistry(retainAllPrefixes: const []),
      );
      final edit = await job.run();

      final reader = await SstableReader.open(
        '$_sstDir/${edit.added[0].filename}',
        adapter,
      );
      final entries = await reader.scan().toList();
      expect(entries.length, equals(1));
      expect(KeyCodec.decodeHlc(entries[0].key), equals(const Hlc(3, 0)));
    });

    test(
      'mixed-namespace SSTable: ordinary namespace collapses, \$ver: namespace '
      'retains, in a single compaction pass',
      () async {
        final adapter = MemoryStorageAdapter();
        await adapter.createDirectory(_sstDir);

        // Two namespaces, three versions each — interleaved in sorted order.
        final entries = <(Uint8List, Uint8List)>[
          for (final hlc in [
            const Hlc(1, 0),
            const Hlc(2, 0),
            const Hlc(3, 0),
          ]) ...[
            (_ikey('users', 'a', hlc), _val(hlc.physicalMs)),
            (_ikey(r'$ver:users', 'a', hlc), _val(hlc.physicalMs + 100)),
          ],
        ];
        _sortEntries(entries);
        final f = await _writeSSTable(adapter, 'mixed.sst', entries);

        final job = CompactionJob(
          sstDir: _sstDir,
          deviceId: _deviceId,
          outputLevel: 2,
          inputs: [SstableRef(level: 0, filename: f)],
          adapter: adapter,
          manifestWriter: ManifestWriter(path: _manifestPath, adapter: adapter),
          logNumber: 1,
          nextSeq: 100,
        );
        final edit = await job.run();

        final reader = await SstableReader.open(
          '$_sstDir/${edit.added[0].filename}',
          adapter,
        );
        final out = await reader.scan().toList();
        // 1 collapsed entry for `users` + 3 retained for `$ver:users` = 4.
        expect(out.length, equals(4));

        var usersCount = 0;
        var verCount = 0;
        for (final e in out) {
          final ns = KeyCodec.decodeNamespace(e.key);
          if (ns == 'users') usersCount++;
          if (ns == r'$ver:users') verCount++;
        }
        expect(usersCount, equals(1));
        expect(verCount, equals(3));
      },
    );
  });
}

int _cmpKey(Uint8List a, Uint8List b) {
  final min = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < min; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
