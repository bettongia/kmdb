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

import 'package:meta/meta.dart';

import '../platform/storage_adapter_interface.dart';
import 'crash_recovery.dart';
import 'kv_store.dart';
import 'lsm_engine.dart';
import 'meta_store.dart';

/// Concrete [KvStore] implementation backed by [LsmEngine].
///
/// Obtain an instance via [KvStoreImpl.open]. Do not construct directly.
///
/// ## System namespace protection
///
/// Namespaces starting with `$` are reserved for internal use (cache,
/// metadata, secondary indexes). Writing to a `$` namespace via the public
/// [put] / [delete] / [writeBatch] methods throws [ArgumentError].
///
/// ## Dirty-open flag
///
/// On the first user write after open, [KvStoreImpl] writes a dirty-open flag
/// to `$meta` (§17, step 8). The flag is cleared on [close]. If the process
/// is killed before [close] is called, the flag remains set and the next
/// [OpenResult.hadUnclosedSession] will be `true`.
///
/// ## Generation counters
///
/// After every user write, [KvStoreImpl] increments the generation counter for
/// the affected namespace(s) in `$meta`. The Cache Layer (Phase 6) reads these
/// counters to detect stale cached query results.
///
/// ## Example
///
/// ```dart
/// final (store, result) = await KvStoreImpl.open('/path/to/db', adapter);
/// await store.put('tasks', keyHex, encodedBytes);
/// final raw = await store.get('tasks', keyHex);
/// await store.close();
/// ```
final class KvStoreImpl implements KvStore {
  KvStoreImpl._(this._engine, this._meta);

  final LsmEngine _engine;
  final MetaStore _meta;

  /// Whether the dirty-open flag has been written this session.
  ///
  /// The flag is written lazily on the first user write so read-only sessions
  /// never mark the database dirty.
  bool _sessionDirtyMarked = false;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Opens the database at [dbDir] and performs crash recovery.
  ///
  /// [deviceId] must be an 8-character lowercase hex string used to name
  /// SSTable files. Defaults to `'00000000'` for tests; production code
  /// should supply a stable per-device UUID prefix via [DeviceId.load].
  ///
  /// Throws [LockException] if another process holds the database lock.
  static Future<(KvStoreImpl, OpenResult)> open(
    String dbDir,
    StorageAdapter adapter, {
    KvStoreConfig config = const KvStoreConfig(),
    String deviceId = '00000000',
  }) async {
    final recovery = CrashRecovery(adapter: adapter, config: config);
    final (engine, recoveryResult) =
        await recovery.open(dbDir, deviceId: deviceId);
    final meta = MetaStore(engine);

    // Check for the dirty-open flag written by the previous session.
    final hadUnclosedSession = await meta.getDirtyFlag();

    final openResult = OpenResult(
      hadInterruptedWrites: recoveryResult.hadInterruptedWrites,
      affectedNamespaces: recoveryResult.affectedNamespaces,
      hadUnclosedSession: hadUnclosedSession,
    );

    return (KvStoreImpl._(engine, meta), openResult);
  }

  // ── KvStore implementation ────────────────────────────────────────────────

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {
    _guardNamespace(namespace);
    await _maybeMarkDirty();
    await _engine.put(namespace, key, value);
    await _meta.incrementGenerationCounter(namespace);
  }

  @override
  Future<void> delete(String namespace, String key) async {
    _guardNamespace(namespace);
    await _maybeMarkDirty();
    await _engine.delete(namespace, key);
    await _meta.incrementGenerationCounter(namespace);
  }

  @override
  Future<void> writeBatch(WriteBatch batch) async {
    for (final entry in batch.entries) {
      _guardNamespace(entry.namespace);
    }
    await _maybeMarkDirty();
    await _engine.writeBatch(batch);
    // Increment the generation counter for each affected namespace.
    final namespaces = batch.entries.map((e) => e.namespace).toSet();
    for (final ns in namespaces) {
      await _meta.incrementGenerationCounter(ns);
    }
  }

  @override
  Future<Uint8List?> get(String namespace, String key) =>
      _engine.get(namespace, key);

  @override
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  }) =>
      _engine.scan(namespace, startKey: startKey, endKey: endKey);

  @override
  Future<void> flush() => _engine.flush();

  @override
  Future<void> compactAll() => _engine.compactAll();

  @override
  Stream<String> get writeEvents => _engine.writeEvents;

  @override
  Future<void> close() async {
    // Clear the dirty-open flag before flushing so the flag is absent on the
    // next open even if we crash immediately after (the delete is in the WAL).
    await _meta.clearDirty();
    await _engine.close();
  }

  // ── Internal access (tests only) ─────────────────────────────────────────

  /// Direct access to the [MetaStore] for use in tests.
  ///
  /// External production code should not use this.
  @visibleForTesting
  MetaStore get meta => _meta;

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Writes the dirty-open flag on the first user write of the session.
  Future<void> _maybeMarkDirty() async {
    if (_sessionDirtyMarked) return;
    await _meta.setDirty();
    _sessionDirtyMarked = true;
  }

  /// Throws [ArgumentError] when [namespace] begins with `$`.
  static void _guardNamespace(String namespace) {
    if (namespace.startsWith(r'$')) {
      throw ArgumentError.value(
          namespace, 'namespace', 'System namespaces (starting with \$) are reserved');
    }
  }
}
