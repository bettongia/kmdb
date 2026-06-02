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

import 'dart:convert';
import 'dart:math' show max;
import 'dart:typed_data';

import '../engine/compaction/merge_iterator.dart';
import '../engine/platform/storage_adapter_interface.dart';
import '../engine/sstable/sstable_info.dart';
import '../engine/sstable/sstable_reader.dart';
import '../engine/sstable/sstable_writer.dart';
import '../engine/util/hlc.dart';
import '../engine/util/key_codec.dart';
import 'sync_context.dart';
import 'sync_storage_adapter.dart';
import 'consolidation_config.dart';

/// The lease state machine states for consolidation coordination.
///
/// Valid transitions (spec §12.6.1):
/// ```
/// idle → leaseAcquired   (this device wins the CAS write)
/// idle → idle            (threshold not met, or another device holds lease)
/// idle → skippedNonAtomicCas (adapter cannot provide atomic CAS)
/// leaseAcquired → consolidating
/// consolidating → verifying  (N-way merge written to sync folder)
/// consolidating → leaseExpired (lease TTL exceeded during merge)
/// verifying → complete   (inputs deleted, lease released)
/// ```
enum ConsolidationState {
  /// No consolidation is in progress or needed.
  idle,

  /// This device holds the consolidation lease.
  leaseAcquired,

  /// Actively merging input SSTables into the consolidated output.
  consolidating,

  /// Output SSTable uploaded; deleting input SSTables and releasing the lease.
  verifying,

  /// Consolidation completed successfully; inputs deleted, lease released.
  complete,

  /// Lease TTL expired before consolidation finished; state is reset to [idle]
  /// on the next [ConsolidationCoordinator.runIfNeeded] call.
  leaseExpired,

  /// Consolidation was skipped because [SyncStorageAdapter.providesAtomicCas]
  /// is `false`. The lease protocol depends on atomic CAS; running it against
  /// a non-atomic backend could let two devices both believe they hold the
  /// lease and delete each other's inputs. Skipping is loss-free — SSTables
  /// simply accumulate un-consolidated.
  skippedNonAtomicCas,
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
/// increasing fencing token over the single lease-file slot. Each new epoch
/// satisfies: `epoch = max(previousEpoch + 1, nowMs)` where `previousEpoch`
/// is the epoch of whatever lease was last written to the slot (by any device).
/// When no prior lease exists the epoch equals `nowMs`. This guarantees the
/// token never regresses even across NTP corrections or clock adjustments,
/// which prevents a previously-timed-out device from presenting a stale epoch
/// as the largest known.
///
/// ## Cancellation
///
/// [ConsolidationCoordinator] accepts a [SyncContext] at construction time and
/// forwards it to every adapter call site. A cancelled or timed-out context
/// causes the first adapter call to throw [SyncCancelledException].
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
  ///
  /// [ctx] is the optional per-sync-run cancellation/deadline context,
  /// forwarded to every adapter call site.
  ConsolidationCoordinator({
    required this.deviceId,
    required this.cloudAdapter,
    required this.localAdapter,
    required this.syncRoot,
    this._config = const ConsolidationConfig(),
    int Function()? wallClock,
    this._ctx,
  }) : _wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The 8-character identifier for this device.
  final String deviceId;

  /// Cloud adapter for accessing the sync folder.
  final SyncStorageAdapter cloudAdapter;

  /// Local storage adapter (used to write intermediate files if needed).
  final StorageAdapter localAdapter;

  /// Root path of the sync folder (e.g. `'kmdb-sync'`).
  final String syncRoot;

  final ConsolidationConfig _config;
  final int Function() _wallClock;

  /// The optional per-sync-run cancellation/deadline context.
  ///
  /// Forwarded to every adapter call site.
  final SyncContext? _ctx;

  /// Current state of the coordination state machine.
  ConsolidationState _state = ConsolidationState.idle;

  /// Returns the current state.
  ConsolidationState get state => _state;

  /// Human-readable explanation for the most recent skip, or `null` if the
  /// coordinator did not skip on the last invocation.
  ///
  /// Currently populated only when the state is [ConsolidationState.skippedNonAtomicCas].
  /// Threshold-not-met and lease-held-elsewhere skips leave this `null`
  /// (the state itself — `idle` — is sufficient signal for those routine paths).
  String? get skipReason => _skipReason;
  String? _skipReason;

  /// Path to the lease file in the sync folder.
  ///
  /// When [syncRoot] is empty, the path is `'.consolidation-lease'` (no
  /// leading slash). When [syncRoot] is non-empty, the path is
  /// `'$syncRoot/.consolidation-lease'`. This avoids a leading-slash mismatch
  /// in adapters that use exact string matching (e.g. [MemorySyncAdapter]).
  String get _leasePath => syncRoot.isEmpty
      ? '.consolidation-lease'
      : '$syncRoot/.consolidation-lease';

  /// Path prefix for SSTable files in the sync folder.
  ///
  /// Same empty-root handling as [_leasePath].
  String get _sstablesDir =>
      syncRoot.isEmpty ? 'sstables' : '$syncRoot/sstables';

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
    _skipReason = null;

    // Gate: the lease protocol relies on cloudAdapter.compareAndSwap being
    // atomic across processes/devices. If the adapter cannot honour that
    // contract — typically because it is pointed at an eventually-consistent
    // cloud-synced folder — two devices could both win the CAS write and
    // delete each other's inputs. Skipping is the safe, loss-free response:
    // consolidation is a storage-shape optimisation, not a correctness
    // requirement. SSTables continue to sync; they merely accumulate
    // un-consolidated.
    if (!cloudAdapter.providesAtomicCas) {
      _state = ConsolidationState.skippedNonAtomicCas;
      _skipReason =
          'cloudAdapter does not provide atomic compareAndSwap; '
          'consolidation skipped to avoid split-lease data loss';
      return false;
    }

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

    // Hoisted before the existingBytes branch so that existingEpoch is visible
    // to both the "overwrite expired" path and the "file disappeared, fall
    // through to create" path. A corrupt lease (fromBytes returns null) leaves
    // existingEpoch as null, which _buildLease handles by falling back to nowMs.
    int? existingEpoch;

    // Read existing lease if any.
    final existingBytes = await cloudAdapter.download(_leasePath, ctx: _ctx);
    if (existingBytes != null) {
      final existing = ConsolidationLease.fromBytes(existingBytes);
      // Capture the prior epoch regardless of whether the lease is expired, so
      // the new lease's epoch is always strictly greater (global monotonicity).
      existingEpoch = existing?.epoch;

      if (existing != null && !existing.isExpired(nowMs)) {
        // A valid, unexpired lease exists — do not compete.
        return null;
      }
      // Lease is expired or corrupt — we need to overwrite it using CAS with
      // the current ETag so that only one device wins the race to replace it.
      final currentEtag = await cloudAdapter.getEtag(_leasePath, ctx: _ctx);
      if (currentEtag != null) {
        final candidate = _buildLease(
          inputFiles,
          nowMs,
          previousEpoch: existingEpoch,
        );
        final won = await cloudAdapter.compareAndSwap(
          _leasePath,
          candidate.toBytes(),
          ifMatchEtag: currentEtag,
          ctx: _ctx,
        );
        if (!won) return null; // another device overwrote the expired lease
        // Fencing: re-read and verify we are the holder.
        return await _verifyLeaseHolder(candidate.epoch);
      }
      // File disappeared between read and getEtag — fall through to create,
      // keeping existingEpoch so the new epoch is still monotonically greater.
    }

    // No lease file exists (or file disappeared) — attempt if-none-match: * write.
    final candidate = _buildLease(
      inputFiles,
      nowMs,
      previousEpoch: existingEpoch,
    );
    final won = await cloudAdapter.compareAndSwap(
      _leasePath,
      candidate.toBytes(),
      ifMatchEtag: null, // if-none-match: * semantics
      ctx: _ctx,
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
        final bytes = await cloudAdapter.download(
          '$_sstablesDir/$filename',
          ctx: _ctx,
        );
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
      await cloudAdapter.upload(
        '$_sstablesDir/$outputFilename',
        outputBytes,
        ctx: _ctx,
      );

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
  /// Commit sequence:
  /// 1. Delete each input SSTable from the sync folder (failures are non-fatal
  ///    — a file may already have been removed by a previous partial commit).
  /// 2. Delete the lease file so other devices may proceed.
  ///
  /// The output SSTable was uploaded by [consolidate] before this method is
  /// called, so it is safe to delete inputs. The lease is released last.
  ///
  /// Note: the spec also describes a `.consolidation-manifest` file for crash
  /// recovery of the commit step (§12 sync folder structure). That file is not
  /// written in this implementation; instead, idempotent deletion makes partial
  /// commits safe to retry without a manifest.
  Future<void> commit(ConsolidationLease lease, String outputFilename) async {
    // Delete input SSTables from the sync folder.
    for (final filename in lease.inputFiles) {
      try {
        await cloudAdapter.delete('$_sstablesDir/$filename', ctx: _ctx);
      } catch (_) {
        // Deletion failure is non-fatal — the file may have already been
        // removed by another device or a previous partial commit.
      }
    }

    // Release the lease.
    try {
      await cloudAdapter.delete(_leasePath, ctx: _ctx);
    } catch (_) {
      // Non-fatal: lease will expire naturally.
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Builds a candidate lease for this device.
  ///
  /// [previousEpoch] is the epoch of the lease currently (or most recently)
  /// stored in the lease-file slot, as decoded by [ConsolidationLease.fromBytes].
  /// Pass `null` when no prior lease exists or the prior lease was corrupt.
  ///
  /// The new epoch is `max(previousEpoch + 1, nowMs)` when [previousEpoch] is
  /// non-null, or simply `nowMs` when it is null. The `max` ensures the epoch
  /// is strictly greater than any prior value even if the wall clock has moved
  /// backwards (NTP correction, daylight-saving transition, manual adjustment).
  /// This gives a global total order over all epochs written to the single
  /// `.consolidation-lease` slot, regardless of which device wrote each one.
  ConsolidationLease _buildLease(
    List<String> inputFiles,
    int nowMs, {
    int? previousEpoch,
  }) {
    // If a previous epoch is known, the new epoch must exceed it (monotonic
    // fencing token). Taking max with nowMs means the epoch still advances with
    // the wall clock in the normal case; the +1 only kicks in when the clock
    // moved backwards.
    final epoch = previousEpoch != null ? max(previousEpoch + 1, nowMs) : nowMs;
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
    final bytes = await cloudAdapter.download(_leasePath, ctx: _ctx);
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
