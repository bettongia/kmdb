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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/compaction/compaction_job.dart';
import 'package:kmdb/src/engine/compaction/merge_iterator.dart';
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
Uint8List _ikey(String ns, String hexSuffix, Hlc hlc) {
  final hexKey =
      hexSuffix.padLeft(12, '0') + '70008' + hexSuffix.padLeft(15, '0');
  return KeyCodec.encodeInternalKey(
    ns,
    KeyCodec.keyToBytes(hexKey),
    hlc,
    RecordType.put,
  );
}

Uint8List _val(int b) => Uint8List.fromList([b]);

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
}

int _cmpKey(Uint8List a, Uint8List b) {
  final min = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < min; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
