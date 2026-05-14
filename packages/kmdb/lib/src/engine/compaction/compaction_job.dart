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

import '../manifest/manifest_writer.dart';
import '../manifest/version_edit.dart';
import '../platform/storage_adapter_interface.dart';
import '../sstable/sstable_info.dart';
import '../sstable/sstable_reader.dart';
import '../sstable/sstable_writer.dart';
import '../util/hlc.dart';
import '../util/key_codec.dart';
import 'merge_iterator.dart';

/// The LSM compaction levels and their size thresholds.
///
/// L0 triggers compaction when it has ≥ 2 files. L1 is capped at 2 MB; L2
/// at 20 MB. The single-file shortcut collapses everything to L2 when total
/// data is ≤ 512 KB (common case for small databases).
const int kL0CompactionTrigger = 2;
const int kL1MaxBytes = 2 * 1024 * 1024; // 2 MB
const int kL2MaxBytes = 20 * 1024 * 1024; // 20 MB
const int kSingleFileCollapseThreshold = 512 * 1024; // 512 KB

/// A fully-resolved compaction task.
///
/// [CompactionJob] merges one or more source SSTables from [inputLevel] and
/// writes the output to [outputLevel]. It does not make any Manifest decisions
/// — the [LsmEngine] coordinates those.
///
/// ## Usage
///
/// ```dart
/// final job = CompactionJob(
///   sstDir: '/db/sst',
///   deviceId: 'a1b2c3d4',
///   inputLevel: 0,
///   outputLevel: 1,
///   inputFiles: ['file1.sst', 'file2.sst'],
///   adapter: adapter,
///   manifestWriter: writer,
///   logNumber: 2,
/// );
/// final edit = await job.run();
/// ```
final class CompactionJob {
  CompactionJob({
    required this.sstDir,
    required this.deviceId,
    required this.outputLevel,
    required this.inputs,
    required this.adapter,
    required this.manifestWriter,
    required this.logNumber,
    required this.nextSeq,
  });

  /// Directory containing all SSTable files.
  final String sstDir;

  /// Device identifier prefix for the output filename.
  final String deviceId;

  /// Level of the output file.
  final int outputLevel;

  /// References to the input SSTables.
  final List<SstableRef> inputs;

  /// Storage adapter for file I/O.
  final StorageAdapter adapter;

  /// Manifest writer for persisting the [VersionEdit].
  final ManifestWriter manifestWriter;

  /// Current WAL log number (written into the [VersionEdit]).
  final int logNumber;

  /// Next HLC sequence number (written into the [VersionEdit]).
  final int nextSeq;

  // ── Run ───────────────────────────────────────────────────────────────────

  /// Executes the compaction and returns the [VersionEdit] that was written.
  ///
  /// Steps:
  /// 1. Open all input SSTables.
  /// 2. Merge their entries (oldest file first → newest wins on duplicate keys).
  /// 3. Write merged output to a new SSTable.
  /// 4. Fsync the output.
  /// 5. Append a [VersionEdit] to the Manifest.
  ///
  /// The caller is responsible for deleting the input files after the
  /// [VersionEdit] is confirmed durable.
  Future<VersionEdit> run() async {
    // Open all input readers (ordered newest-first: index 0 = highest priority).
    final readers = <SstableReader>[];
    for (final ref in inputs.reversed) {
      final path = '$sstDir/${ref.filename}';
      readers.add(await SstableReader.open(path, adapter));
    }

    // Merge streams: source 0 is the newest file, source N is the oldest.
    final streams = readers.map((r) => r.scan()).toList();
    final merge = MergeIterator(streams);

    final writer = SstableWriter();
    Hlc? minHlc;
    Hlc? maxHlc;
    var entryCount = 0;
    Uint8List? minKeyBytes;
    Uint8List? maxKeyBytes;

    await for (final entry in merge.entries) {
      writer.add(entry.key, entry.value);
      entryCount++;

      // Track HLC range from the key's embedded HLC.
      final hlc = KeyCodec.decodeHlc(entry.key);
      if (minHlc == null || hlc < minHlc) minHlc = hlc;
      if (maxHlc == null || hlc > maxHlc) maxHlc = hlc;
      minKeyBytes ??= entry.key;
      maxKeyBytes = entry.key;
    }

    if (entryCount == 0) {
      // All inputs were empty — nothing to write.
      final edit = VersionEdit(
        logNumber: logNumber,
        nextSeq: nextSeq,
        removed: inputs,
      );
      await manifestWriter.append(edit);
      return edit;
    }

    final effectiveMin = minHlc ?? const Hlc(0, 0);
    final effectiveMax = maxHlc ?? const Hlc(0, 0);
    final outputFilename = SstableInfo.flushName(
      deviceId,
      effectiveMin,
      effectiveMax,
    );
    final outputPath = '$sstDir/$outputFilename';

    final outputBytes = writer.finish();
    await adapter.writeFile(outputPath, outputBytes);
    await adapter.syncFile(outputPath);

    final meta = SstableMeta(
      level: outputLevel,
      filename: outputFilename,
      minKey: minKeyBytes != null ? _toHex(minKeyBytes) : '',
      maxKey: maxKeyBytes != null ? _toHex(maxKeyBytes) : '',
      entryCount: entryCount,
    );

    final edit = VersionEdit(
      logNumber: logNumber,
      nextSeq: nextSeq,
      added: [meta],
      removed: inputs,
    );
    await manifestWriter.append(edit);
    return edit;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _toHex(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
