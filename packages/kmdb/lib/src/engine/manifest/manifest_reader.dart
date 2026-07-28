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

import '../platform/storage_adapter_interface.dart';
import '../util/xxhash.dart';
import 'version_edit.dart';

/// Reads and replays a Manifest file, reconstructing the LSM level state.
///
/// Replay stops at the first record whose checksum does not match (indicating
/// a truncated final write — the normal crash scenario). All records before
/// that point are valid.
///
/// ## Usage
///
/// ```dart
/// final result = await ManifestReader(adapter: adapter).replay(manifestPath);
/// // result.levels contains all live SSTables grouped by level.
/// ```
final class ManifestReader {
  const ManifestReader({required this.adapter});

  /// Storage adapter for file reads.
  final StorageAdapter adapter;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Replays all valid VersionEdits from [path] and returns them as a list
  /// without computing any [ManifestState].
  ///
  /// Unlike [replay], this method preserves the raw edit sequence so diagnostic
  /// tooling can display the full version history. Use [replay] for crash
  /// recovery; use [replayEdits] only for `util manifest --full` output.
  ///
  /// Returns an empty list if the file does not exist or has no valid records.
  Future<List<VersionEdit>> replayEdits(String path) async {
    final Uint8List bytes;
    try {
      bytes = await adapter.readFile(path);
    } on StorageException {
      return [];
    }

    final edits = <VersionEdit>[];
    var offset = 0;

    while (offset < bytes.length) {
      // Need at least checksum(8) + length(4) = 12 bytes.
      if (bytes.length - offset < 12) break;

      final bd = ByteData.sublistView(bytes);
      final storedChecksum = bd.getInt64(offset, Endian.big);
      final cborLen = bd.getUint32(offset + 8, Endian.big);

      // Validate we have the full record.
      if (bytes.length - offset < 12 + cborLen) break;

      // Verify checksum over [length(4) + cbor(N)].
      final toHash = Uint8List.sublistView(
        bytes,
        offset + 8,
        offset + 12 + cborLen,
      );
      final actualChecksum = XxHash64.digest(toHash);
      if (storedChecksum != actualChecksum) break; // truncation / corruption

      final cborBytes = bytes.sublist(offset + 12, offset + 12 + cborLen);
      try {
        edits.add(VersionEdit.fromCbor(cborBytes));
      } on FormatException {
        break; // malformed CBOR — stop replay
      }

      offset += 12 + cborLen;
    }

    return edits;
  }

  /// Replays all valid VersionEdits from [path] and returns the resulting
  /// [ManifestState].
  ///
  /// Returns an empty [ManifestState] if the file does not exist.
  Future<ManifestState> replay(String path) async {
    final Uint8List bytes;
    try {
      bytes = await adapter.readFile(path);
    } on StorageException {
      return ManifestState.empty();
    }

    final edits = <VersionEdit>[];
    var offset = 0;

    while (offset < bytes.length) {
      // Need at least checksum(8) + length(4) = 12 bytes.
      if (bytes.length - offset < 12) break;

      final bd = ByteData.sublistView(bytes);
      final storedChecksum = bd.getInt64(offset, Endian.big);
      final cborLen = bd.getUint32(offset + 8, Endian.big);

      // Validate we have the full record.
      if (bytes.length - offset < 12 + cborLen) break;

      // Verify checksum over [length(4) + cbor(N)].
      final toHash = Uint8List.sublistView(
        bytes,
        offset + 8,
        offset + 12 + cborLen,
      );
      final actualChecksum = XxHash64.digest(toHash);
      if (storedChecksum != actualChecksum) break; // truncation / corruption

      final cborBytes = bytes.sublist(offset + 12, offset + 12 + cborLen);
      try {
        edits.add(VersionEdit.fromCbor(cborBytes));
      } on FormatException {
        break; // malformed CBOR — stop replay
      }

      offset += 12 + cborLen;
    }

    return ManifestState._fromEdits(edits);
  }
}

// ── Manifest state ─────────────────────────────────────────────────────────

/// Reconstructed LSM level state after replaying a Manifest.
final class ManifestState {
  ManifestState._({
    required this.levels,
    required this.maxLogNumber,
    required this.maxNextSeq,
  });

  factory ManifestState.empty() => ManifestState._(
    levels: {0: [], 1: [], 2: []},
    maxLogNumber: 0,
    maxNextSeq: 0,
  );

  factory ManifestState._fromEdits(List<VersionEdit> edits) {
    // liveMeta[level][filename] holds the most recent SstableMeta seen for
    // each live file. An 'add' replaces (or inserts) the entry; a 'remove'
    // deletes it. Using filename as the inner key means a later add
    // (e.g. from a compaction or reassignment) properly supersedes an earlier
    // add for the same file, preserving whatever metadata that edit carried.
    //
    // ## Within-edit ordering: removed before added (data-loss fix)
    //
    // `liveMeta` is keyed by the PAIR (level, filename), so ordering only
    // matters within a single edit when that same pair appears in both
    // `added` and `removed` — which happens when a compaction output reuses
    // an input's filename via an in-place overwrite (identical deviceId +
    // minHlc/maxHlc, e.g. a `_compactAll` merge whose surviving range exactly
    // reproduces one of its own same-level inputs). On disk there is exactly
    // one file at that path after the compaction, and it holds the *output*
    // content — so `added` must win. Applying `removed` before `added` within
    // each edit achieves this: whichever loop runs second determines the
    // final state for a given (level, filename) pair, so putting `added`
    // last means a reused pair always resolves to present with the added
    // entry's (fresh) metadata. This matches the runtime: every compaction
    // method in `LsmEngine` (`_compactL0ToL1`, `_compactL1ToL2`,
    // `_compactAll`) evicts the stale cached reader for a reused filename but
    // explicitly *skips deleting it from disk*, because the file was
    // overwritten in place, not removed (see the `outputNames` guard around
    // `lsm_engine.dart:960-991` and its siblings). Before this fix, the loops
    // ran in the opposite order, so a same-level reused filename was
    // incorrectly dropped from the reconstructed state — and crash
    // recovery's orphan sweep then deleted the still-live SSTable from disk
    // (plan_manifest_replay_added_removed_ordering.md). Cross-edit
    // accumulation order (edits are folded in list order) is unaffected by
    // this change — only the intra-edit order flips.
    final Map<int, Map<String, SstableMeta>> liveMeta = {0: {}, 1: {}, 2: {}};
    var maxLogNumber = 0;
    var maxNextSeq = 0;

    for (final edit in edits) {
      if (edit.logNumber > maxLogNumber) maxLogNumber = edit.logNumber;
      if (edit.nextSeq > maxNextSeq) maxNextSeq = edit.nextSeq;

      for (final removed in edit.removed) {
        liveMeta[removed.level]?.remove(removed.filename);
      }
      for (final added in edit.added) {
        // putIfAbsent initialises the inner map for levels beyond 0-2 if they
        // ever appear (forward-compatibility). Applied after `removed` (see
        // above), so the last add always wins for a filename, including one
        // reused in place within the same edit.
        liveMeta.putIfAbsent(added.level, () => {})[added.filename] = added;
      }
    }

    // Convert to sorted SstableMeta lists. Sort by filename so L1/L2 ordering
    // is deterministic and matches the previous filename-sorted behaviour.
    final levels = <int, List<SstableMeta>>{};
    for (final entry in liveMeta.entries) {
      final sorted = entry.value.values.toList()
        ..sort((a, b) => a.filename.compareTo(b.filename));
      levels[entry.key] = sorted;
    }

    return ManifestState._(
      levels: levels,
      maxLogNumber: maxLogNumber,
      maxNextSeq: maxNextSeq,
    );
  }

  /// Live SSTable metadata grouped by level.
  ///
  /// Keys are 0, 1, 2 (and any additional levels written by future versions).
  /// Values are sorted lists of [SstableMeta], ordered by filename for
  /// deterministic L1/L2 ordering. L0 ordering is also by filename; callers
  /// that need L0 newest-first must reverse the list themselves (the
  /// `LsmEngine` does this in its read path).
  ///
  /// The metadata fields ([SstableMeta.minKey], [SstableMeta.maxKey],
  /// [SstableMeta.entryCount]) reflect whatever the manifest recorded verbatim.
  /// Pre-fix manifests (written before this plan was implemented) will surface
  /// empty strings for keys and zero for entry counts for files that were last
  /// recorded by a rotation-snapshot edit. These values are self-healing: the
  /// next flush/compaction/ingest/reassign edit for those files will carry real
  /// metadata, and the next rotation will snapshot the now-accurate in-memory
  /// level map.
  final Map<int, List<SstableMeta>> levels;

  /// Highest `logNumber` seen across all replayed edits.
  ///
  /// WAL files with sequence number ≤ this value are fully persisted and safe
  /// to delete on recovery.
  final int maxLogNumber;

  /// Highest `nextSeq` seen across all replayed edits.
  ///
  /// The HLC clock must be advanced to at least this value on recovery.
  final int maxNextSeq;

  /// All live SSTable filenames across all levels.
  ///
  /// Returns bare filenames (no directory path). Used by the orphan-sweep in
  /// crash recovery to determine which `.sst` files on disk are referenced by
  /// the manifest.
  Iterable<String> get allFiles =>
      levels.values.expand((metas) => metas.map((m) => m.filename));
}
