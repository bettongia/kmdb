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

import 'actions.dart';

/// An entry in the write log maintained by the [ReconciliationAgent].
///
/// Captures the essential details of a single document write or delete so
/// that the agent can reconstruct expected per-device and global state.
final class WriteLogEntry {
  /// Creates a [WriteLogEntry].
  const WriteLogEntry({
    required this.actionId,
    required this.deviceId,
    required this.collectionName,
    required this.key,
    required this.document,
    required this.isDelete,
    this.hlcEncoded,
  });

  /// The action ID that produced this write.
  final int actionId;

  /// The device that performed the write.
  final int deviceId;

  /// The collection the document belongs to.
  final String collectionName;

  /// The document key.
  final String key;

  /// The document payload (`null` for deletes).
  final Map<String, dynamic>? document;

  /// Whether this entry represents a deletion.
  final bool isDelete;

  /// The HLC timestamp (encoded 64-bit int) of the write, if available.
  ///
  /// Used for LWW (Last-Write-Wins) resolution when two devices write to
  /// the same key between sync points. A higher value wins.
  final int? hlcEncoded;

  @override
  String toString() =>
      'WriteLogEntry(actionId=$actionId, device=$deviceId, '
      'col=$collectionName, key=$key, delete=$isDelete)';
}

/// An entry in the sync log maintained by the [ReconciliationAgent].
///
/// Records each sync attempt (push+pull) including whether it completed
/// successfully. Incomplete syncs (e.g. interrupted by a network partition)
/// are recorded with [completed] = `false` and do NOT advance the receiving
/// device's expected state.
final class SyncLogEntry {
  /// Creates a [SyncLogEntry].
  const SyncLogEntry({
    required this.actionId,
    required this.deviceId,
    required this.direction,
    required this.completed,
    this.sstablesTransferred,
  });

  /// The action ID that triggered this sync.
  final int actionId;

  /// The device that initiated the sync.
  final int deviceId;

  /// The sync direction: `'push'`, `'pull'`, or `'both'`.
  final String direction;

  /// Whether the sync completed successfully.
  ///
  /// When `false`, the expected state for the receiving device is not
  /// advanced — the pull did not deliver peer writes.
  final bool completed;

  /// Number of SSTables transferred, if reported.
  final int? sstablesTransferred;

  @override
  String toString() =>
      'SyncLogEntry(actionId=$actionId, device=$deviceId, '
      'dir=$direction, completed=$completed)';
}

/// A detected fork: two devices wrote to the same key between their last
/// common sync point.
///
/// The [ReconciliationAgent] records a [ForkEvent] whenever it observes
/// divergent writes to the same `(collectionName, key)` tuple from different
/// devices. After the next completed sync, the agent verifies that each
/// device's actual document matches [lwwWinner].
final class ForkEvent {
  /// Creates a [ForkEvent].
  const ForkEvent({
    required this.collectionName,
    required this.key,
    required this.writeA,
    required this.writeB,
    required this.lwwWinner,
  });

  /// The collection containing the forked key.
  final String collectionName;

  /// The document key that was written by both devices.
  final String key;

  /// The write from the first device.
  final WriteLogEntry writeA;

  /// The write from the second device.
  final WriteLogEntry writeB;

  /// The entry that should win under LWW semantics (higher HLC or, on tie,
  /// higher device ID as a deterministic tiebreaker).
  final WriteLogEntry lwwWinner;

  @override
  String toString() =>
      'ForkEvent(col=$collectionName, key=$key, '
      'winner=device${lwwWinner.deviceId})';
}

/// Tracks the per-device document state used for expected-state comparison.
final class _DeviceState {
  /// Latest known document per `(collectionName, key)` tuple.
  ///
  /// A `null` value means the document was deleted.
  final Map<String, Map<String, dynamic>?> documents = {};

  /// The action ID of the most recent completed sync for this device.
  int lastSyncActionId = -1;

  /// Returns the compound key used in [documents].
  static String compoundKey(String collection, String key) =>
      '$collection\x00$key';
}

/// The harness source of truth for expected device state.
///
/// The [ReconciliationAgent] maintains two append-only in-memory logs:
/// - A **write log** of every document put/delete across all devices.
/// - A **sync log** of every sync operation (completed or not).
///
/// From these logs it computes:
/// - **Per-device expected state**: local writes plus writes received via
///   completed pulls, with LWW per key.
/// - **Global expected state**: LWW winner across all writes on all devices —
///   the state every device converges to once fully synced.
///
/// The agent also performs **fork detection**: when two devices write to the
/// same key between their last common sync point, a [ForkEvent] is recorded.
///
/// All [Device] actors call [record] immediately after each action. The agent
/// processes the result synchronously, keeping both logs and computed state
/// consistent without any async concurrency.
final class ReconciliationAgent {
  /// Creates a [ReconciliationAgent] for [deviceCount] devices.
  ReconciliationAgent({required this.deviceCount}) {
    for (var i = 0; i < deviceCount; i++) {
      _deviceStates[i] = _DeviceState();
    }
  }

  /// The total number of devices being tracked.
  final int deviceCount;

  /// Append-only write log.
  final List<WriteLogEntry> writeLog = [];

  /// Append-only sync log.
  final List<SyncLogEntry> syncLog = [];

  /// All detected fork events (appended as discovered, not cleared).
  final List<ForkEvent> forkEvents = [];

  /// Per-device state tracking.
  final Map<int, _DeviceState> _deviceStates = {};

  // The last write seen per (collectionName, key) per device, for fork
  // detection. Keyed by compound key → (deviceId → entry).
  final Map<String, Map<int, WriteLogEntry>> _lastWritePerKey = {};

  // ── Public API ────────────────────────────────────────────────────────────

  /// Receives an [ActionResult] from a [Device] and updates all logs.
  ///
  /// No-op results are appended to the write/sync logs only for sync actions
  /// (so the log remains complete for regression diffing). All other no-ops
  /// are silently skipped — they must not advance expected state.
  void record(ActionResult result) {
    if (result.isNoOp) return;

    switch (result.type) {
      case ActionType.put:
        _recordWrite(result, isDelete: false);
      case ActionType.delete:
        _recordWrite(result, isDelete: true);
      case ActionType.sync:
        _recordSync(result);
      default:
        // createDb, createCollection, get, networkPartition — not relevant for
        // expected-state computation.
        break;
    }
  }

  /// Returns the expected state for [deviceId] as a flat map of
  /// `'collectionName\x00key'` → document (or `null` for deleted docs).
  ///
  /// This reflects all writes the device has performed locally plus all
  /// writes received via completed pull operations, with LWW applied.
  Map<String, Map<String, dynamic>?> expectedStateForDevice(int deviceId) {
    final ds = _deviceStates[deviceId];
    if (ds == null) return {};
    return Map.unmodifiable(ds.documents);
  }

  /// Returns the global expected state as a flat map of
  /// `'collectionName\x00key'` → document.
  ///
  /// This is the LWW winner across ALL writes from ALL devices — the state
  /// every device should converge to once fully synced.
  Map<String, Map<String, dynamic>?> globalExpectedState() {
    // Aggregate all write log entries, applying LWW per key.
    final result = <String, Map<String, dynamic>?>{};
    final winners = <String, WriteLogEntry>{};

    for (final entry in writeLog) {
      final ck = _DeviceState.compoundKey(entry.collectionName, entry.key);
      final current = winners[ck];
      if (current == null || _lwwWins(entry, current)) {
        winners[ck] = entry;
        result[ck] = entry.isDelete ? null : entry.document;
      }
    }

    return Map.unmodifiable(result);
  }

  /// Reports all currently detected [ForkEvent]s.
  List<ForkEvent> get detectedForks => List.unmodifiable(forkEvents);

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _recordWrite(ActionResult result, {required bool isDelete}) {
    final key = result.key;
    final col = result.collectionName;
    if (key == null || col == null) return;

    final entry = WriteLogEntry(
      actionId: result.actionId,
      deviceId: result.deviceId,
      collectionName: col,
      key: key,
      document: isDelete ? null : result.document,
      isDelete: isDelete,
      hlcEncoded: result.hlcEncoded,
    );
    writeLog.add(entry);

    // Advance per-device expected state with LWW.
    _applyWriteToDevice(result.deviceId, entry);

    // Fork detection: check if any other device has written this key since
    // their last common sync point.
    _detectFork(entry);
  }

  void _applyWriteToDevice(int deviceId, WriteLogEntry entry) {
    final ds = _deviceStates[deviceId]!;
    final ck = _DeviceState.compoundKey(entry.collectionName, entry.key);
    // Since devices write directly to their own state, we always apply the
    // latest write without needing LWW comparison here — this device owns
    // the timeline for its own writes.
    ds.documents[ck] = entry.isDelete ? null : entry.document;
  }

  void _recordSync(ActionResult result) {
    final entry = SyncLogEntry(
      actionId: result.actionId,
      deviceId: result.deviceId,
      direction: result.syncDirection ?? 'both',
      completed: result.syncCompleted ?? false,
      sstablesTransferred: result.sstablesTransferred,
    );
    syncLog.add(entry);

    if (!entry.completed) return;

    // A completed sync means this device has pulled all peer writes. Merge
    // the global expected state into the device's expected state using LWW.
    _mergeGlobalIntoDevice(result.deviceId);

    // Update the last sync action ID for this device.
    _deviceStates[result.deviceId]!.lastSyncActionId = result.actionId;
  }

  /// Merges the global LWW state into [deviceId]'s expected state.
  ///
  /// After a successful sync, a device should have all writes from all
  /// peers. We compute the global LWW state and merge it into the device's
  /// view, applying LWW at each key.
  void _mergeGlobalIntoDevice(int deviceId) {
    final ds = _deviceStates[deviceId]!;
    final global = globalExpectedState();

    for (final entry in global.entries) {
      // Only advance the device's state if the global entry is newer (LWW).
      // Since we don't always have HLC data, we use a presence check:
      // if the global state has a key the device doesn't, add it.
      // If both have it, the global value (LWW winner) takes precedence.
      ds.documents[entry.key] = entry.value;
    }

    // Also ensure deletes from global state propagate.
    for (final ck in global.keys) {
      if (!ds.documents.containsKey(ck)) {
        ds.documents[ck] = global[ck];
      }
    }
  }

  void _detectFork(WriteLogEntry newEntry) {
    final ck = _DeviceState.compoundKey(newEntry.collectionName, newEntry.key);

    _lastWritePerKey.putIfAbsent(ck, () => {});
    final writersForKey = _lastWritePerKey[ck]!;

    // Check if any OTHER device has written this key since the last time
    // both devices synced (simplified: since any write from another device).
    for (final existingEntry in writersForKey.values) {
      if (existingEntry.deviceId == newEntry.deviceId) continue;

      // Determine LWW winner.
      final winner = _lwwWins(newEntry, existingEntry)
          ? newEntry
          : existingEntry;

      forkEvents.add(
        ForkEvent(
          collectionName: newEntry.collectionName,
          key: newEntry.key,
          writeA: existingEntry,
          writeB: newEntry,
          lwwWinner: winner,
        ),
      );
    }

    // Record this device's latest write for this key.
    writersForKey[newEntry.deviceId] = newEntry;
  }

  /// Returns `true` if [a] should win over [b] under LWW semantics.
  ///
  /// Primary ordering: higher [WriteLogEntry.hlcEncoded] wins. When HLC data
  /// is not available (null), action ID is used as a proxy for write ordering.
  /// On a tie, the higher device ID wins as a deterministic tiebreaker.
  static bool _lwwWins(WriteLogEntry a, WriteLogEntry b) {
    final aHlc = a.hlcEncoded;
    final bHlc = b.hlcEncoded;

    if (aHlc != null && bHlc != null) {
      if (aHlc != bHlc) return aHlc > bHlc;
    } else {
      // Fall back to action ID order when HLC is not available.
      if (a.actionId != b.actionId) return a.actionId > b.actionId;
    }

    // Deterministic tiebreaker: higher device ID wins.
    return a.deviceId > b.deviceId;
  }

  /// Resets all logs and state. Useful for test isolation.
  void reset() {
    writeLog.clear();
    syncLog.clear();
    forkEvents.clear();
    _lastWritePerKey.clear();
    for (final ds in _deviceStates.values) {
      ds.documents.clear();
      ds.lastSyncActionId = -1;
    }
  }
}
