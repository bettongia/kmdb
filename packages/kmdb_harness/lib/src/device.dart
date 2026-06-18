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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_test_cloud_support.dart' show CloudSemanticsAdapter;

import 'actions.dart';
import 'partitionable_adapter.dart';
import 'reconciliation_agent.dart';

/// FSM states for a [Device].
///
/// Transitions:
/// ```
/// uninitialised → (CreateDb) → initialised → (CreateCollection) → ready
/// ```
/// A [Device] in [ready] state accepts all action types.
enum DeviceState {
  /// The device has not yet opened its [KmdbDatabase].
  uninitialised,

  /// The [KmdbDatabase] is open but no collections have been created.
  initialised,

  /// At least one collection has been created; all actions are accepted.
  ready,
}

/// A harness device that wraps a [KmdbDatabase] with FSM-guarded action dispatch.
///
/// Each [Device] has a stable [deviceIndex] (0-based) and an 8-character hex
/// [deviceId] that is injected into [KmdbDatabase.open]. The underlying
/// [SyncStorageAdapter] is wrapped in a [PartitionableAdapter] so that network
/// partitions can be simulated per device.
///
/// Actions that cannot be applied in the current [state] are recorded as
/// [ActionType.noOp] — the [ReconciliationAgent] is informed but does not
/// advance its expected-state model for that key.
final class Device {
  /// Creates a [Device] with the given index and adapter.
  ///
  /// [deviceIndex] is the 0-based index of this device in the harness.
  /// [syncAdapter] is the shared remote sync adapter.
  /// [_reconciler] receives all action results immediately after execution.
  Device({
    required this.deviceIndex,
    required SyncStorageAdapter syncAdapter,
    required this._reconciler,
    required this._dbPath,
    String? deviceId,
  }) : _syncAdapter = PartitionableAdapter(syncAdapter),
       deviceId = deviceId ?? _generateDeviceId(deviceIndex);

  /// The 0-based index of this device within the harness.
  final int deviceIndex;

  /// The 8-character hex device identifier injected into [KmdbDatabase].
  final String deviceId;

  /// The current FSM state of this device.
  DeviceState get state => _state;

  DeviceState _state = DeviceState.uninitialised;

  final PartitionableAdapter _syncAdapter;
  final ReconciliationAgent _reconciler;
  final String _dbPath;

  KmdbDatabase? _db;

  /// The collections created on this device, keyed by collection name.
  final Map<String, KmdbCollection<Map<String, dynamic>>> _collections = {};

  /// The local [MemoryStorageAdapter] used for this device's KvStore.
  ///
  /// Each device has its own local adapter (simulating independent local
  /// storage) but shares the [PartitionableAdapter] for sync.
  final MemoryStorageAdapter _localStorageAdapter = MemoryStorageAdapter();

  // ── Action dispatch ──────────────────────────────────────────────────────

  /// Executes [action], emits the result to the [ReconciliationAgent], and
  /// returns the [ActionResult].
  ///
  /// Actions that are inapplicable in the current FSM state are recorded as
  /// no-ops. The [ReconciliationAgent] receives every result, including no-ops.
  Future<ActionResult> execute(Action action) async {
    final result = await _dispatch(action);
    _reconciler.record(result);
    return result;
  }

  Future<ActionResult> _dispatch(Action action) async {
    switch (action.type) {
      case ActionType.createDb:
        return _createDb(action);
      case ActionType.createCollection:
        if (_state == DeviceState.uninitialised) {
          return _noOp(action);
        }
        return _createCollection(action);
      case ActionType.put:
        if (_state != DeviceState.ready) return _noOp(action);
        return _put(action);
      case ActionType.get:
        if (_state != DeviceState.ready) return _noOp(action);
        return _get(action);
      case ActionType.delete:
        if (_state != DeviceState.ready) return _noOp(action);
        return _delete(action);
      case ActionType.sync:
        if (_state == DeviceState.uninitialised) return _noOp(action);
        return _sync(action);
      case ActionType.networkPartition:
        return _networkPartition(action);
      case ActionType.noOp:
        return _noOp(action);
    }
  }

  Future<ActionResult> _createDb(Action action) async {
    if (_state != DeviceState.uninitialised) {
      // Already initialised — record as no-op.
      return _noOp(action);
    }
    try {
      _db = await KmdbDatabase.open(
        path: _dbPath,
        adapter: _localStorageAdapter,
        deviceId: deviceId,
        config: const KvStoreConfig(maxValueBytes: 2 * 1024 * 1024),
      );
      _state = DeviceState.initialised;
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.createDb,
        isNoOp: false,
      );
    } catch (e) {
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.createDb,
        isNoOp: false,
        error: e.toString(),
      );
    }
  }

  Future<ActionResult> _createCollection(Action action) async {
    final name = action.collectionName ?? 'collection_$deviceIndex';
    if (!_collections.containsKey(name)) {
      final col = _db!.rawCollection(name);
      _collections[name] = col;
      if (_state == DeviceState.initialised) {
        _state = DeviceState.ready;
      }
    }
    return ActionResult(
      actionId: action.id,
      deviceId: action.deviceId,
      type: ActionType.createCollection,
      isNoOp: false,
      collectionName: name,
    );
  }

  Future<ActionResult> _put(Action action) async {
    final collectionName = action.collectionName;
    final key = action.key;
    final document = action.document;

    if (collectionName == null || key == null || document == null) {
      return _errorResult(action, 'put requires collectionName, key, document');
    }
    final col = _getOrCreateCollection(collectionName);
    try {
      // Attach the _id field so the codec can key the document.
      final doc = Map<String, dynamic>.from(document);
      doc['_id'] = key;
      await col.put(doc);
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.put,
        isNoOp: false,
        key: key,
        collectionName: collectionName,
        document: document,
      );
    } catch (e) {
      return _errorResult(action, e.toString());
    }
  }

  Future<ActionResult> _get(Action action) async {
    final collectionName = action.collectionName;
    final key = action.key;
    if (collectionName == null || key == null) {
      return _errorResult(action, 'get requires collectionName and key');
    }
    final col = _getOrCreateCollection(collectionName);
    try {
      final doc = await col.get(key);
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.get,
        isNoOp: false,
        key: key,
        collectionName: collectionName,
        document: doc,
      );
    } catch (e) {
      return _errorResult(action, e.toString());
    }
  }

  Future<ActionResult> _delete(Action action) async {
    final collectionName = action.collectionName;
    final key = action.key;
    if (collectionName == null || key == null) {
      return _errorResult(action, 'delete requires collectionName and key');
    }
    final col = _getOrCreateCollection(collectionName);
    try {
      await col.delete(key);
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.delete,
        isNoOp: false,
        key: key,
        collectionName: collectionName,
      );
    } catch (e) {
      return _errorResult(action, e.toString());
    }
  }

  Future<ActionResult> _sync(Action action) async {
    final db = _db;
    if (db == null) return _noOp(action);
    try {
      await db.sync(
        syncAdapter: _syncAdapter,
        localAdapter: _localStorageAdapter,
      );
      // Read the visibility cursor after sync completes.
      // For strongly-consistent adapters (MemorySyncAdapter, SharedBackendAdapter)
      // this equals the backend's global max — all writes visible.
      // For CloudSemanticsAdapter it returns the propagation cursor, which may
      // lag. The ReconciliationAgent uses this to merge only the visible subset
      // of peer writes into the device's expected state.
      final visSeq = _syncAdapter.visibleWriteSeq;
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.sync,
        isNoOp: false,
        syncCompleted: true,
        syncDirection: 'both',
        visibleWriteSeqHigh: visSeq,
      );
    } on NetworkPartitionException {
      // Partition was active during sync — record as incomplete.
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.sync,
        isNoOp: false,
        syncCompleted: false,
        syncDirection: 'both',
        error: 'Network partition active during sync',
      );
    } catch (e) {
      return ActionResult(
        actionId: action.id,
        deviceId: action.deviceId,
        type: ActionType.sync,
        isNoOp: false,
        syncCompleted: false,
        syncDirection: 'both',
        error: e.toString(),
      );
    }
  }

  Future<ActionResult> _networkPartition(Action action) async {
    final active = action.partitioned ?? true;
    _syncAdapter.setPartitioned(active);
    return ActionResult(
      actionId: action.id,
      deviceId: action.deviceId,
      type: ActionType.networkPartition,
      isNoOp: false,
    );
  }

  ActionResult _noOp(Action action) => ActionResult(
    actionId: action.id,
    deviceId: action.deviceId,
    type: ActionType.noOp,
    isNoOp: true,
  );

  ActionResult _errorResult(Action action, String message) => ActionResult(
    actionId: action.id,
    deviceId: action.deviceId,
    type: action.type,
    isNoOp: false,
    error: message,
  );

  KmdbCollection<Map<String, dynamic>> _getOrCreateCollection(String name) {
    return _collections.putIfAbsent(name, () => _db!.rawCollection(name));
  }

  // ── Teardown ─────────────────────────────────────────────────────────────

  /// Closes the underlying [KmdbDatabase] if open.
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _state = DeviceState.uninitialised;
    _collections.clear();
    MemoryStorageAdapter.releaseAllLocks();
  }

  // ── Verification helpers ──────────────────────────────────────────────────

  /// Advances the propagation clock on this device's sync adapter, if the
  /// underlying adapter is a [CloudSemanticsAdapter].
  ///
  /// Under an eventually-consistent profile, a [CloudSemanticsAdapter]'s
  /// visibility cursor lags behind the backend's maximum write-sequence. This
  /// method makes all writes committed so far immediately visible to this
  /// device's adapter — equivalent to simulating the passage of the backend's
  /// maximum propagation delay.
  ///
  /// No-op when the underlying adapter is not a [CloudSemanticsAdapter]
  /// (e.g. `MemorySyncAdapter`, `SharedBackendAdapter`).
  ///
  /// Called by [TestManager._settleAndVerifyConvergence] before the final
  /// sync pass to ensure all writes are visible before asserting global
  /// convergence.
  void advancePropagationClock() {
    final delegate = _syncAdapter.delegate;
    if (delegate is CloudSemanticsAdapter) {
      delegate.advancePropagationClock();
    }
  }

  /// Forces a sync without recording the result in the [ReconciliationAgent].
  ///
  /// Unpartitions the adapter first so any partition active at the end of the
  /// run loop does not block the verification step. Used by [TestManager]
  /// before calling [getVersions] to ensure `$ver:` entries from all devices
  /// have propagated.
  Future<void> syncForVerification() async {
    if (_state == DeviceState.uninitialised) return;
    final db = _db;
    if (db == null) return;
    _syncAdapter.setPartitioned(false);
    try {
      await db.sync(
        syncAdapter: _syncAdapter,
        localAdapter: _localStorageAdapter,
      );
    } catch (_) {
      // Best-effort; don't fail verification if the sync itself fails.
    }
  }

  /// Returns all version history entries for [docKey] in [collectionName].
  ///
  /// Returns an empty list when the device is not ready, the collection does
  /// not exist, or no version entries exist for the key. Used by [TestManager]
  /// to assert that fork-loser values are preserved in the version history
  /// after sync.
  Future<List<DocumentVersion>> getVersions(
    String collectionName,
    String docKey,
  ) async {
    if (_state != DeviceState.ready) return const [];
    final col = _getOrCreateCollection(collectionName);
    return col.getVersions(docKey);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Generates a deterministic 8-character hex device ID from the device index.
  static String _generateDeviceId(int index) {
    // Use the device index padded to 8 hex chars for determinism.
    return index.toRadixString(16).padLeft(8, '0');
  }

  /// Returns all collection names registered on this device.
  Iterable<String> get collectionNames => _collections.keys;

  /// Returns whether this device's sync adapter is currently partitioned.
  bool get isPartitioned => _syncAdapter.isPartitioned;
}
