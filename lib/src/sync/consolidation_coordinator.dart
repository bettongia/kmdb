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

import 'dart:convert';
import 'dart:typed_data';

import '../engine/compaction/merge_iterator.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/sstable/sstable_info.dart';
import '../engine/sstable/sstable_reader.dart';
import '../engine/sstable/sstable_writer.dart';
import '../engine/util/hlc.dart';
import '../engine/util/key_codec.dart';
import 'cloud/cloud_adapter.dart';
import 'consolidation_config.dart';

/// The lease state machine states for consolidation coordination.
enum ConsolidationState {
  /// No consolidation is in progress or needed.
  idle,

  /// This device holds the consolidation lease.
  leaseAcquired,

  /// Actively merging input SSTables.
  consolidating,

  /// Verifying the output and updating the manifest.
  verifying,

  /// Consolidation completed successfully.
  complete,

  /// Lease expired before consolidation finished.
  leaseExpired,
}

/// A parsed consolidation lease record.
///
/// The lease file at `{syncRoot}/.consolidation-lease` is a JSON document:
/// ```json
/// {
///   "holder": "a1b2c3d4",
///   "acquiredAt": 1711540200000,
///   "expiresAt": 1711540320000,
///   "epoch": 42,
///   "inputFiles": ["dev1-....sst", "dev2-....sst"]
/// }
/// ```
final class ConsolidationLease {
  /// Creates a [ConsolidationLease].
  const ConsolidationLease({
    required this.holder,
    required this.acquiredAt,
    required this.expiresAt,
    required this.epoch,
    required this.inputFiles,
  });

  /// The device ID of the lease holder.
  final String holder;

  /// Unix timestamp (ms) when the lease was acquired.
  final int acquiredAt;

  /// Unix timestamp (ms) when the lease expires.
  final int expiresAt;

  /// Monotonically-increasing fencing token for this consolidation round.
  ///
  /// The epoch is used in the output SSTable filename to identify which
  /// consolidation round produced it:
  /// `{deviceId}-{epoch}-{minHlc}-{maxHlc}.sst`
  final int epoch;

  /// The input SSTable filenames included in this consolidation.
  final List<String> inputFiles;

  /// Returns `true` if the lease has expired relative to [nowMs].
  bool isExpired(int nowMs) => nowMs >= expiresAt;

  /// Encodes this lease to JSON bytes.
  Uint8List toBytes() {
    final map = {
      'holder': holder,
      'acquiredAt': acquiredAt,
      'expiresAt': expiresAt,
      'epoch': epoch,
      'inputFiles': inputFiles,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  /// Decodes a [ConsolidationLease] from JSON bytes.
  ///
  /// Returns `null` if the bytes are not a valid lease document.
  static ConsolidationLease? fromBytes(Uint8List bytes) {
    try {
      final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return ConsolidationLease(
        holder: map['holder'] as String,
        acquiredAt: (map['acquiredAt'] as num).toInt(),
        expiresAt: (map['expiresAt'] as num).toInt(),
        epoch: (map['epoch'] as num).toInt(),
        inputFiles: (map['inputFiles'] as List).cast<String>(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'ConsolidationLease(holder: $holder, epoch: $epoch, '
      'expires: ${DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()})';
}

/// Coordinates cross-device SSTable consolidation using a lease file protocol.
///
/// When the number of cross-device SSTables in the sync folder exceeds
/// [ConsolidationConfig.threshold], one device acquires a lease and performs
/// an N-way merge. Other devices skip consolidation while the lease is held.
///
/// ## Lease protocol
///
/// 1. Read current lease file (if any).
/// 2. If no lease or lease is expired:
///    a. Write candidate lease with `compareAndSwap` (if-none-match: *).
///    b. Re-read the lease and verify we are the holder (fencing).
///    c. If we are the holder, proceed to consolidation.
/// 3. Perform N-way merge of input SSTables → write output to sync folder.
/// 4. Upload output SSTable, then delete input SSTables.
/// 5. Delete lease file.
///
/// ## Fencing
///
/// The epoch field in the lease (and the output filename) is a monotonically-
/// increasing token derived from the current wall clock. It prevents a
/// previously-timed-out device from overwriting the output of a newer round.
///
/// ## Usage
///
/// ```dart
/// final coordinator = ConsolidationCoordinator(
///   deviceId: 'a1b2c3d4',
///   cloudAdapter: adapter,
///   localAdapter: localAdapter,
///   syncRoot: 'kmdb-sync',
///   config: ConsolidationConfig(),
/// );
/// final didConsolidate = await coordinator.runIfNeeded(remoteSstables);
/// ```
final class ConsolidationCoordinator {
  /// Creates a [ConsolidationCoordinator].
  ConsolidationCoordinator({
    required this.deviceId,
    required this.cloudAdapter,
    required this.localAdapter,
    required this.syncRoot,
    ConsolidationConfig config = const ConsolidationConfig(),
    int Function()? wallClock,
  })  : _config = config,
        _wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The 8-character identifier for this device.
  final String deviceId;

  /// Cloud adapter for accessing the sync folder.
  final CloudAdapter cloudAdapter;

  /// Local storage adapter (used to write intermediate files if needed).
  final StorageAdapter localAdapter;

  /// Root path of the sync folder (e.g. `'kmdb-sync'`).
  final String syncRoot;

  final ConsolidationConfig _config;
  final int Function() _wallClock;

  /// Current state of the coordination state machine.
  ConsolidationState _state = ConsolidationState.idle;

  /// Returns the current state.
  ConsolidationState get state => _state;

  /// Path to the lease file in the sync folder.
  String get _leasePath => '$syncRoot/.consolidation-lease';

  /// Path prefix for SSTable files in the sync folder.
  String get _sstablesDir => '$syncRoot/sstables';

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Checks whether consolidation is needed and runs it if so.
  ///
  /// [remoteSstables] is the list of bare SSTable filenames currently in the
  /// sync folder. Consolidation is triggered when the count of SSTables from
  /// devices other than this one exceeds [ConsolidationConfig.threshold].
  ///
  /// Returns `true` if this device performed consolidation, `false` if it was
  /// not needed, or if another device holds the lease.
  Future<bool> runIfNeeded(List<String> remoteSstables) async {
    _state = ConsolidationState.idle;

    // Count cross-device SSTables (exclude our own files).
    final crossDeviceFiles = remoteSstables
        .where((f) => _parsedDeviceId(f) != deviceId)
        .toList();

    if (crossDeviceFiles.length < _config.threshold) {
      return false; // threshold not met
    }

    // Attempt to acquire the lease.
    final lease = await acquireLease(crossDeviceFiles);
    if (lease == null) return false; // another device holds the lease

    _state = ConsolidationState.leaseAcquired;

    // Perform the consolidation.
    final outputFilename = await consolidate(lease);
    if (outputFilename == null) {
      _state = ConsolidationState.leaseExpired;
      return false;
    }

    _state = ConsolidationState.verifying;

    // Commit: upload output, delete inputs, release lease.
    await commit(lease, outputFilename);

    _state = ConsolidationState.complete;
    return true;
  }

  /// Attempts to acquire the consolidation lease.
  ///
  /// Returns the [ConsolidationLease] if acquisition succeeded, or `null` if
  /// another device holds a valid lease.
  ///
  /// The acquisition uses compare-and-swap semantics:
  /// - Read the existing lease file.
  /// - If a valid, non-expired lease exists: return null (someone else has it).
  /// - Otherwise write a new lease with `compareAndSwap(ifMatchEtag: null)` to
  ///   atomically claim the lease when no file exists.
  /// - Re-read and verify we are the holder (fencing check).
  Future<ConsolidationLease?> acquireLease(List<String> inputFiles) async {
    final nowMs = _wallClock();

    // Read existing lease if any.
    final existingBytes = await cloudAdapter.download(_leasePath);
    if (existingBytes != null) {
      final existing = ConsolidationLease.fromBytes(existingBytes);
      if (existing != null && !existing.isExpired(nowMs)) {
        // A valid, unexpired lease exists — do not compete.
        return null;
      }
      // Lease is expired or corrupt — we need to overwrite it using CAS with
      // the current ETag so that only one device wins the race to replace it.
      final currentEtag = await cloudAdapter.getEtag(_leasePath);
      if (currentEtag != null) {
        final candidate = _buildLease(inputFiles, nowMs);
        final won = await cloudAdapter.compareAndSwap(
          _leasePath,
          candidate.toBytes(),
          ifMatchEtag: currentEtag,
        );
        if (!won) return null; // another device overwrote the expired lease
        // Fencing: re-read and verify we are the holder.
        return await _verifyLeaseHolder(candidate.epoch);
      }
      // File disappeared between read and getEtag — fall through to create.
    }

    // No lease file exists — attempt if-none-match: * write.
    final candidate = _buildLease(inputFiles, nowMs);
    final won = await cloudAdapter.compareAndSwap(
      _leasePath,
      candidate.toBytes(),
      ifMatchEtag: null, // if-none-match: * semantics
    );
    if (!won) return null; // another device won the race

    // Fencing: re-read to confirm we are the holder.
    return await _verifyLeaseHolder(candidate.epoch);
  }

  /// Performs the N-way merge of the input SSTables from the lease.
  ///
  /// Downloads each input SSTable from the sync folder, merges them in HLC
  /// order (newest-wins for duplicate keys), and writes the output to a
  /// temporary in-memory buffer. The output bytes are returned along with the
  /// chosen output filename.
  ///
  /// Returns the output filename on success, or `null` if the lease expired
  /// before the merge completed.
  Future<String?> consolidate(ConsolidationLease lease) async {
    _state = ConsolidationState.consolidating;
    final nowMs = _wallClock();
    if (lease.isExpired(nowMs)) {
      _state = ConsolidationState.leaseExpired;
      return null;
    }

    // Download all input SSTables and open readers using an in-memory adapter.
    // We use a MemoryStorageAdapter-like approach: write bytes to a local
    // temporary path via the localAdapter, then open with SstableReader.
    final readers = <SstableReader>[];
    final tmpPaths = <String>[];

    try {
      // Sort inputs by their max HLC (oldest first, so newest wins in the
      // merge iterator which gives priority to earlier-indexed streams).
      final sortedInputs = List<String>.from(lease.inputFiles);
      sortedInputs.sort((a, b) {
        try {
          final ia = SstableInfo.parse(a);
          final ib = SstableInfo.parse(b);
          return ia.maxHlc.compareTo(ib.maxHlc);
        } catch (_) {
          return a.compareTo(b);
        }
      });

      for (final filename in sortedInputs.reversed) {
        // Download from sync folder.
        final bytes = await cloudAdapter.download('$_sstablesDir/$filename');
        if (bytes == null) continue; // file deleted by another device

        // Write to a temporary path via the local adapter.
        final tmpPath = '/tmp/kmdb-consolidation-$filename';
        await localAdapter.writeFile(tmpPath, bytes);
        tmpPaths.add(tmpPath);

        try {
          final reader = await SstableReader.open(tmpPath, localAdapter);
          readers.add(reader);
        } on CorruptedSstableException {
          // Skip corrupted input files.
          continue;
        }
      }

      if (readers.isEmpty) return null;

      // Check lease hasn't expired during downloads.
      if (lease.isExpired(_wallClock())) {
        _state = ConsolidationState.leaseExpired;
        return null;
      }

      // N-way merge: streams are ordered newest-first (readers[0] is newest).
      final streams = readers.map((r) => r.scan()).toList();
      final merge = MergeIterator(streams);

      final writer = SstableWriter();
      Hlc? minHlc;
      Hlc? maxHlc;
      var entryCount = 0;

      await for (final entry in merge.entries) {
        writer.add(entry.key, entry.value);
        entryCount++;
        final hlc = KeyCodec.decodeHlc(entry.key);
        if (minHlc == null || hlc < minHlc) minHlc = hlc;
        if (maxHlc == null || hlc > maxHlc) maxHlc = hlc;
      }

      if (entryCount == 0) return null;

      final effectiveMin = minHlc!;
      final effectiveMax = maxHlc!;
      final outputFilename = SstableInfo.consolidationName(
        deviceId,
        lease.epoch,
        effectiveMin,
        effectiveMax,
      );

      final outputBytes = writer.finish();

      // Upload output SSTable to sync folder.
      await cloudAdapter.upload('$_sstablesDir/$outputFilename', outputBytes);

      return outputFilename;
    } finally {
      // Clean up temporary files.
      for (final tmpPath in tmpPaths) {
        try {
          await localAdapter.deleteFile(tmpPath);
        } catch (_) {}
      }
    }
  }

  /// Commits the consolidation by deleting input SSTables and releasing the
  /// lease.
  ///
  /// [lease] is the held lease. [outputFilename] is the output SSTable that
  /// was already uploaded by [consolidate].
  ///
  /// Input SSTables are deleted only after the output is confirmed uploaded.
  /// The lease file is deleted last — after this call returns, other devices
  /// may proceed with their own operations.
  Future<void> commit(ConsolidationLease lease, String outputFilename) async {
    // Delete input SSTables from the sync folder.
    for (final filename in lease.inputFiles) {
      try {
        await cloudAdapter.delete('$_sstablesDir/$filename');
      } catch (_) {
        // Deletion failure is non-fatal — the file may have already been
        // removed by another device or a previous partial commit.
      }
    }

    // Release the lease.
    try {
      await cloudAdapter.delete(_leasePath);
    } catch (_) {
      // Non-fatal: lease will expire naturally.
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Builds a candidate lease for this device.
  ConsolidationLease _buildLease(List<String> inputFiles, int nowMs) {
    final epoch = nowMs; // use wall clock as fencing token
    return ConsolidationLease(
      holder: deviceId,
      acquiredAt: nowMs,
      expiresAt: nowMs + _config.ttlMs,
      epoch: epoch,
      inputFiles: inputFiles,
    );
  }

  /// Re-reads the lease file and returns it only if this device is the holder
  /// with the matching epoch.
  ///
  /// This fencing step guards against a TOCTOU race where two devices both
  /// write a lease in quick succession.
  Future<ConsolidationLease?> _verifyLeaseHolder(int expectedEpoch) async {
    final bytes = await cloudAdapter.download(_leasePath);
    if (bytes == null) return null;
    final lease = ConsolidationLease.fromBytes(bytes);
    if (lease == null) return null;
    if (lease.holder != deviceId) return null;
    if (lease.epoch != expectedEpoch) return null;
    return lease;
  }

  /// Extracts the device ID from a bare SSTable filename.
  ///
  /// Returns an empty string if the filename cannot be parsed.
  static String _parsedDeviceId(String filename) {
    try {
      return SstableInfo.parse(filename).deviceId;
    } catch (_) {
      return '';
    }
  }
}
