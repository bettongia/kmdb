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
import '../util/namespace_codec.dart' show isLocalOnly;
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

  /// The number of **syncable** delete tombstones dropped during [run].
  ///
  /// Incremented inside `_flushCollapsed` each time a surviving tombstone in
  /// a *syncable* (non-`$$`-prefixed) namespace is eligible for GC (its
  /// [ReclamationPolicy.dropTombstone] returns `true`). This requires
  /// [allLevels] to be `true` and the tombstone's HLC to be strictly below
  /// [horizon] (for syncable namespaces).
  ///
  /// Local-only (`$$`-prefixed) tombstones are also dropped from the output
  /// when eligible, but they are **not** counted here. The GC floor in
  /// `$meta` is advanced by [LsmEngine._compactAll] only when
  /// `tombstonesDropped > 0`, which correctly means "at least one syncable
  /// tombstone was GC'd" — a purely local-only drop does not advance the floor.
  ///
  /// Readable after [run] returns. [CompactionJob] is a single-use object;
  /// the count is reset to zero before each [run] call to allow safe re-use
  /// in tests, though production code constructs a fresh job per compaction.
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
  /// ## Two-writer split (local-only namespace segregation)
  ///
  /// Entries are routed to one of two writers based on the namespace resolved
  /// at each group boundary:
  ///
  /// - **Syncable writer** — receives entries whose namespace does NOT start
  ///   with `$$`. Produces `{deviceId}-{minHlc}-{maxHlc}.sst`.
  /// - **Local-only writer** — receives entries whose namespace starts with
  ///   `$$` (FTS, vector, secondary indexes). Produces
  ///   `{deviceId}-{minHlc}-{maxHlc}.local.sst`.
  ///
  /// Empty partitions produce no file and no `SstableMeta` entry. The finish
  /// block writes up to two files and appends a single [VersionEdit] with up
  /// to two `added` entries — one atomic Manifest record regardless of how
  /// many partitions were non-empty.
  ///
  /// The namespace is resolved once per group boundary (line ~312), not per
  /// entry, so the routing decision is O(groups), not O(entries).
  ///
  /// ## Tombstone GC accounting
  ///
  /// [tombstonesDropped] counts only syncable tombstone drops. Local-only
  /// tombstones are dropped from the output when the [LocalOnlyCollapsePolicy]
  /// returns `true` (requires [allLevels] = `true`; no horizon check) but are
  /// not counted. The GC floor in `$meta` advances only when at least one
  /// syncable tombstone was dropped.
  ///
  /// Steps:
  /// 1. Open all input SSTables.
  /// 2. Merge their entries (oldest file first → newest wins on duplicate keys).
  /// 3. Apply the reclamation transform with per-writer routing.
  /// 4. Write up to two output SSTables (syncable + local-only).
  /// 5. Fsync all outputs; syncDir.
  /// 6. Append a single [VersionEdit] to the Manifest.
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

    // ── Per-partition state ──────────────────────────────────────────────────
    //
    // Syncable partition (non-$$ namespaces) — uploaded to sync folder.
    final syncWriter = SstableWriter();
    Hlc? syncMinHlc;
    Hlc? syncMaxHlc;
    var syncEntryCount = 0;
    Uint8List? syncMinKeyBytes;
    Uint8List? syncMaxKeyBytes;

    // Local-only partition ($$ namespaces) — never uploaded.
    final localWriter = SstableWriter();
    Hlc? localMinHlc;
    Hlc? localMaxHlc;
    var localEntryCount = 0;
    Uint8List? localMinKeyBytes;
    Uint8List? localMaxKeyBytes;

    // Streaming reclamation transform.
    //
    // The merge yields entries in ascending internal-key order, so all
    // versions of a given `(namespace, userKey)` are contiguous and ordered
    // ascending by HLC (HLC is big-endian and sits just before the trailing
    // 1-byte record type). The user-key prefix length is therefore
    // `key.length - 9` (HLC=8B + type=1B).
    //
    // For each contiguous group we resolve the namespace's
    // [ReclamationPolicy] once at group-boundary time:
    //   - collapseVersions=true  → buffer the latest entry; on group change,
    //                              emit the buffered entry — unless that
    //                              entry is a delete tombstone whose
    //                              [ReclamationPolicy.dropTombstone] returns
    //                              true, in which case the group is elided.
    //   - collapseVersions=false → buffer the entire group; at group-end call
    //                              policy.filterGroup() to obtain the retained
    //                              subset. Dropped entries' values are appended
    //                              to [droppedVersionValues] for the vault
    //                              ref-decrement callback (RQ5).
    //
    // The current group's `isLocal` flag (resolved once per group) routes
    // entries to the appropriate writer without re-decoding the namespace
    // for every entry.
    Uint8List? groupPrefix;
    MergeEntry? pendingCollapsed;
    // Buffer for collapseVersions=false groups (e.g. $ver: entries).
    List<MergeEntry>? groupBuffer;
    ReclamationPolicy? policy;
    // Whether the current group belongs to a local-only namespace.
    // Resolved once per group at the boundary, reused for every entry.
    bool currentGroupIsLocal = false;

    // Routes an accepted entry to the correct partition writer.
    void emit(Uint8List key, Uint8List value, bool entryIsLocal) {
      if (entryIsLocal) {
        localWriter.add(key, value);
        localEntryCount++;
        final hlc = KeyCodec.decodeHlc(key);
        if (localMinHlc == null || hlc < localMinHlc!) localMinHlc = hlc;
        if (localMaxHlc == null || hlc > localMaxHlc!) localMaxHlc = hlc;
        localMinKeyBytes ??= key;
        localMaxKeyBytes = key;
      } else {
        syncWriter.add(key, value);
        syncEntryCount++;
        final hlc = KeyCodec.decodeHlc(key);
        if (syncMinHlc == null || hlc < syncMinHlc!) syncMinHlc = hlc;
        if (syncMaxHlc == null || hlc > syncMaxHlc!) syncMaxHlc = hlc;
        syncMinKeyBytes ??= key;
        syncMaxKeyBytes = key;
      }
    }

    /// Emits [entry] unless it is a tombstone the active [policy] is willing
    /// to drop. Tombstone drops in syncable namespaces increment
    /// [tombstonesDropped]; local-only drops are silent (do not advance the
    /// GC floor — see [tombstonesDropped] doc).
    void flushCollapsed(
      MergeEntry entry,
      ReclamationPolicy activePolicy,
      bool entryIsLocal,
    ) {
      if (KeyCodec.decodeRecordType(entry.key) == RecordType.delete) {
        final canDrop = activePolicy.dropTombstone(
          allLevels: allLevels,
          tombstoneHlc: KeyCodec.decodeHlc(entry.key),
          horizon: horizon,
        );
        if (canDrop) {
          // Count only syncable tombstone drops: these advance the GC floor.
          // Local-only drops are free but do not affect the sync horizon.
          if (!entryIsLocal) tombstonesDropped++;
          return; // elide from output
        }
      }
      emit(entry.key, entry.value, entryIsLocal);
    }

    /// Flushes the current [groupBuffer] through [policy.filterGroup], emits
    /// survivors, and records dropped entries' values in [droppedVersionValues].
    void flushGroupBuffer(ReclamationPolicy activePolicy, bool groupIsLocal) {
      final buf = groupBuffer;
      if (buf == null || buf.isEmpty) return;
      groupBuffer = null;

      final survivors = activePolicy.filterGroup(buf, nowMs: nowMs);
      for (final s in survivors) {
        emit(s.key, s.value, groupIsLocal);
      }
      // Record dropped entries' values for the post-compaction vault
      // ref-decrement callback (RQ5). $$-namespaced entries never hold vault
      // URIs, so droppedVersionValues is populated only for syncable entries
      // (which can only reach here via history-bearing $ver: namespaces).
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
        // Flush the previous group before starting a new one.
        if (pendingCollapsed != null) {
          flushCollapsed(pendingCollapsed, policy!, currentGroupIsLocal);
          pendingCollapsed = null;
        }
        if (groupBuffer != null) {
          flushGroupBuffer(policy!, currentGroupIsLocal);
        }
        // Resolve the policy and local-only flag for this new group.
        // Both are resolved once per group, not per entry.
        final ns = KeyCodec.decodeNamespace(entry.key);
        policy = _policyRegistry.resolve(ns);
        currentGroupIsLocal = isLocalOnly(ns);
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
      flushCollapsed(pendingCollapsed, policy!, currentGroupIsLocal);
    }
    if (groupBuffer != null) {
      flushGroupBuffer(policy!, currentGroupIsLocal);
    }

    final totalEntryCount = syncEntryCount + localEntryCount;

    if (totalEntryCount == 0) {
      // All inputs were empty — nothing to write.
      final edit = VersionEdit(
        logNumber: logNumber,
        nextSeq: nextSeq,
        removed: inputs,
      );
      await manifestWriter.append(edit);
      return edit;
    }

    // ── Write non-empty partitions to disk ────────────────────────────────────
    //
    // Both files (if present) are written and fsynced before the single
    // Manifest append. A crash between the two file writes leaves both files
    // on disk but neither referenced by the Manifest; crash recovery discards
    // them as orphans. This preserves crash-atomicity via a single VersionEdit.
    final adds = <SstableMeta>[];

    if (syncEntryCount > 0) {
      final effectiveMin = syncMinHlc ?? const Hlc(0, 0);
      final effectiveMax = syncMaxHlc ?? const Hlc(0, 0);
      final filename = SstableInfo.flushName(
        deviceId,
        effectiveMin,
        effectiveMax,
      );
      final outputPath = '$sstDir/$filename';
      await adapter.writeFile(outputPath, syncWriter.finish());
      await adapter.syncFile(outputPath);
      adds.add(
        SstableMeta(
          level: outputLevel,
          filename: filename,
          minKey: syncMinKeyBytes != null ? _toHex(syncMinKeyBytes!) : '',
          maxKey: syncMaxKeyBytes != null ? _toHex(syncMaxKeyBytes!) : '',
          entryCount: syncEntryCount,
          localOnly: false,
        ),
      );
    }

    if (localEntryCount > 0) {
      final effectiveMin = localMinHlc ?? const Hlc(0, 0);
      final effectiveMax = localMaxHlc ?? const Hlc(0, 0);
      final filename = SstableInfo.flushName(
        deviceId,
        effectiveMin,
        effectiveMax,
        localOnly: true,
      );
      final outputPath = '$sstDir/$filename';
      await adapter.writeFile(outputPath, localWriter.finish());
      await adapter.syncFile(outputPath);
      adds.add(
        SstableMeta(
          level: outputLevel,
          filename: filename,
          minKey: localMinKeyBytes != null ? _toHex(localMinKeyBytes!) : '',
          maxKey: localMaxKeyBytes != null ? _toHex(localMaxKeyBytes!) : '',
          entryCount: localEntryCount,
          localOnly: true,
        ),
      );
    }

    // Durably link all output directory entries before the manifest records them
    // (review finding H1). The manifest append below fsyncs the manifest, so the
    // edit is durable before the engine deletes the input SSTables after run()
    // returns (review finding C2).
    await adapter.syncDir(sstDir);

    final edit = VersionEdit(
      logNumber: logNumber,
      nextSeq: nextSeq,
      added: adds,
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
