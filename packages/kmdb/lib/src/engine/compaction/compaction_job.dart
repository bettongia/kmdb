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
import 'reclamation_policy.dart';

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
    this.allLevels = false,
    this.horizon = const Hlc(0, 0),
    this.nowMs = 0,
    ReclamationPolicyRegistry? policyRegistry,
  }) : _policyRegistry = policyRegistry ?? ReclamationPolicyRegistry();

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

  /// Whether this compaction covers **every level** that could hold an
  /// older version of any key in [inputs]. True only for the single-file
  /// `_compactAll` path; partial compactions (L0→L1, L1→L2) set this
  /// `false`. A surviving tombstone can be dropped only when this is `true`
  /// **and** its HLC is below [horizon] — see [ReclamationPolicy.dropTombstone].
  ///
  /// Defaults to `false` so callers that haven't been updated for H4 PR2
  /// continue to retain tombstones (the existing safe behaviour).
  final bool allLevels;

  /// The sync horizon below which a delete tombstone is safe to drop —
  /// `min(currentHlc)` across all devices on a synced database, or
  /// `now - tombstoneGraceDuration` on a local-only database. The
  /// `LsmEngine` computes this per compaction and passes it in; compaction
  /// itself does not read the sync folder.
  ///
  /// Defaults to `Hlc(0, 0)` so callers that haven't been updated for H4
  /// PR2 never drop tombstones (no realistic tombstone HLC is below zero).
  final Hlc horizon;

  /// Wall-clock time at job-construction time, in milliseconds since Unix
  /// epoch. Injected by [LsmEngine._compactAll] as
  /// `DateTime.now().millisecondsSinceEpoch` (RQ6 clock-injection pattern).
  ///
  /// Passed to [ReclamationPolicy.filterGroup] so the retention-window check
  /// does not call `DateTime.now()` internally. Tests supply a fixed value
  /// to obtain deterministic behaviour.
  ///
  /// Defaults to `0` (epoch) so callers that don't supply a value never
  /// incorrectly age out entries (all entries would appear to be in the future).
  final int nowMs;

  /// Resolves the [ReclamationPolicy] for each namespace encountered during
  /// the compaction's streaming transform. PR1 of H4 uses this to gate
  /// version collapse; PR2 of H4 also uses it to gate tombstone drops.
  /// `$ver:` (and any caller-registered history-bearing class) passes
  /// every version through unchanged and never drops tombstones.
  final ReclamationPolicyRegistry _policyRegistry;

  /// The number of delete tombstones dropped during [run].
  ///
  /// Incremented inside `flushCollapsed` each time a surviving tombstone
  /// is eligible for GC (its [ReclamationPolicy.dropTombstone] returns
  /// `true`). This requires [allLevels] to be `true` and the tombstone's
  /// HLC to be strictly below [horizon].
  ///
  /// Readable after [run] returns. [CompactionJob] is a single-use object;
  /// the count is reset to zero before each [run] call to allow safe re-use
  /// in tests, though production code constructs a fresh job per compaction.
  ///
  /// [LsmEngine._compactAll] reads this value to decide whether to advance
  /// the tombstone GC floor in `$meta` (H4-FU3). A non-zero count means
  /// the all-levels compaction dropped at least one tombstone, so the floor
  /// must be advanced to [horizon].
  int tombstonesDropped = 0;

  /// Raw value bytes of every `$ver:` version entry trimmed by
  /// [ReclamationPolicy.filterGroup] during [run].
  ///
  /// Populated by the retain-all path when `collapseVersions=false` and
  /// `filterGroup` returns a subset of the group's entries. [LsmEngine] reads
  /// this field after [run] returns and, if non-empty, invokes the registered
  /// version-drop callback to release vault ref counts (RQ5).
  ///
  /// Reset to `[]` at the start of each [run] call so the object is safe to
  /// reuse in tests (parallel to [tombstonesDropped]).
  List<Uint8List> droppedVersionValues = [];

  // ── Run ───────────────────────────────────────────────────────────────────

  /// Executes the compaction and returns the [VersionEdit] that was written.
  ///
  /// Steps:
  /// 1. Open all input SSTables.
  /// 2. Merge their entries (oldest file first → newest wins on duplicate keys).
  /// 3. Apply the reclamation transform: version collapse (H4 PR1 — keep
  ///    only the highest-HLC entry per `(namespace, userKey)` group, except
  ///    in namespaces whose [ReclamationPolicy] retains all versions) and,
  ///    when the group's surviving entry is a delete tombstone, optionally
  ///    drop it (H4 PR2 — only when [allLevels] is `true` and the
  ///    tombstone's HLC is strictly below [horizon]).
  /// 4. Write merged output to a new SSTable.
  /// 5. Fsync the output.
  /// 6. Append a [VersionEdit] to the Manifest.
  ///
  /// The caller is responsible for deleting the input files after the
  /// [VersionEdit] is confirmed durable.
  Future<VersionEdit> run() async {
    // Reset drop counters so run() is safe to call again (e.g. in tests).
    tombstonesDropped = 0;
    droppedVersionValues = [];

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

    // Streaming reclamation transform.
    //
    // The merge yields entries in ascending internal-key order, so all
    // versions of a given `(namespace, userKey)` are contiguous and ordered
    // ascending by HLC (HLC is big-endian and sits just before the trailing
    // 1-byte record type). The user-key prefix length is therefore
    // `key.length - 9` (HLC=8B + type=1B).
    //
    // For each contiguous group we resolve the namespace's
    // [ReclamationPolicy] once:
    //   - collapseVersions=true  → buffer the latest entry; on group change,
    //                              emit the buffered entry — unless that
    //                              entry is a delete tombstone whose
    //                              [ReclamationPolicy.dropTombstone] returns
    //                              true (H4 PR2: gated by [allLevels] +
    //                              [horizon]), in which case the group is
    //                              elided entirely.
    //   - collapseVersions=false → buffer the entire group; at group-end call
    //                              policy.filterGroup() to obtain the retained
    //                              subset. Drop entries not in the survivor set
    //                              and append their values to
    //                              [droppedVersionValues] for the post-compaction
    //                              vault ref-decrement callback (RQ5).
    Uint8List? groupPrefix;
    MergeEntry? pendingCollapsed;
    // Buffer for collapseVersions=false groups (e.g. $ver: entries).
    List<MergeEntry>? groupBuffer;
    ReclamationPolicy? policy;

    void emit(Uint8List key, Uint8List value) {
      writer.add(key, value);
      entryCount++;
      final hlc = KeyCodec.decodeHlc(key);
      if (minHlc == null || hlc < minHlc!) minHlc = hlc;
      if (maxHlc == null || hlc > maxHlc!) maxHlc = hlc;
      minKeyBytes ??= key;
      maxKeyBytes = key;
    }

    /// Emits [entry] unless it is a tombstone the active [policy] is
    /// willing to drop given this compaction's [allLevels] and [horizon].
    /// Used to finalise a collapsed group.
    ///
    /// When a tombstone is dropped, [tombstonesDropped] is incremented so
    /// [LsmEngine._compactAll] can advance the GC floor after the manifest
    /// commits (H4-FU3).
    void flushCollapsed(MergeEntry entry, ReclamationPolicy activePolicy) {
      if (KeyCodec.decodeRecordType(entry.key) == RecordType.delete) {
        final canDrop = activePolicy.dropTombstone(
          allLevels: allLevels,
          tombstoneHlc: KeyCodec.decodeHlc(entry.key),
          horizon: horizon,
        );
        if (canDrop) {
          tombstonesDropped++;
          return;
        }
      }
      emit(entry.key, entry.value);
    }

    /// Flushes the current [groupBuffer] through [policy.filterGroup], emits
    /// survivors, and records dropped entries' values in [droppedVersionValues].
    void flushGroupBuffer(ReclamationPolicy activePolicy) {
      final buf = groupBuffer;
      if (buf == null || buf.isEmpty) return;
      groupBuffer = null;

      final survivors = activePolicy.filterGroup(buf, nowMs: nowMs);
      // Emit every survivor.
      for (final s in survivors) {
        emit(s.key, s.value);
      }
      // Record dropped entries' values for the post-compaction vault
      // ref-decrement callback (RQ5). Build a set of survivor keys for O(1)
      // membership check.
      if (survivors.length < buf.length) {
        final survivorKeys = survivors.map((s) => s.key).toSet();
        for (final dropped in buf) {
          if (!survivorKeys.contains(dropped.key)) {
            droppedVersionValues.add(dropped.value);
          }
        }
      }
    }

    await for (final entry in merge.entries) {
      final prefixLen = entry.key.length - 9;
      final isNewGroup =
          groupPrefix == null || !_keyMatchesPrefix(entry.key, groupPrefix);

      if (isNewGroup) {
        // Flush the previous group (collapsed or buffered) before starting a
        // new one.
        if (pendingCollapsed != null) {
          flushCollapsed(pendingCollapsed, policy!);
          pendingCollapsed = null;
        }
        if (groupBuffer != null) {
          flushGroupBuffer(policy!);
        }
        // Resolve the policy for this new group's namespace.
        final ns = KeyCodec.decodeNamespace(entry.key);
        policy = _policyRegistry.resolve(ns);
        groupPrefix = Uint8List.sublistView(entry.key, 0, prefixLen);
      }

      if (policy!.collapseVersions) {
        // Buffer; the last (highest-HLC) entry in this group wins.
        pendingCollapsed = entry;
      } else {
        // History-bearing class — buffer the entire group for filterGroup.
        (groupBuffer ??= []).add(entry);
      }
    }
    // Flush any remaining group.
    if (pendingCollapsed != null) {
      flushCollapsed(pendingCollapsed, policy!);
    }
    if (groupBuffer != null) {
      flushGroupBuffer(policy!);
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
    // Durably link the output's directory entry before the manifest records it
    // (review finding H1). The manifest append below fsyncs the manifest, so the
    // edit is durable before the engine deletes the input SSTables after run()
    // returns (review finding C2).
    await adapter.syncDir(sstDir);

    final meta = SstableMeta(
      level: outputLevel,
      filename: outputFilename,
      minKey: minKeyBytes != null ? _toHex(minKeyBytes!) : '',
      maxKey: maxKeyBytes != null ? _toHex(maxKeyBytes!) : '',
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

  /// Returns `true` iff [key]'s `(nsLen + ns + userKey)` prefix matches
  /// [prefix] byte-for-byte. The prefix excludes the trailing
  /// `[hlc 8B][type 1B]` of the internal key encoding.
  static bool _keyMatchesPrefix(Uint8List key, Uint8List prefix) {
    if (key.length - 9 != prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }
}
