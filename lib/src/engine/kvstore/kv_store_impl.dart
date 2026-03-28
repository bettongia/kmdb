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

import '../platform/storage_adapter_interface.dart';
import 'crash_recovery.dart';
import 'kv_store.dart';
import 'lsm_engine.dart';

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
/// ## Example
///
/// ```dart
/// final (store, result) = await KvStoreImpl.open('/path/to/db', adapter);
/// await store.put('tasks', keyHex, encodedBytes);
/// final raw = await store.get('tasks', keyHex);
/// await store.close();
/// ```
final class KvStoreImpl implements KvStore {
  KvStoreImpl._(this._engine);

  final LsmEngine _engine;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Opens the database at [dbDir] and performs crash recovery.
  ///
  /// [deviceId] must be an 8-character lowercase hex string used to name
  /// SSTable files. Defaults to `'00000000'` for tests; production code
  /// should supply a stable per-device UUID prefix (Phase 4).
  ///
  /// Throws [LockException] if another process holds the database lock.
  static Future<(KvStoreImpl, OpenResult)> open(
    String dbDir,
    StorageAdapter adapter, {
    KvStoreConfig config = const KvStoreConfig(),
    String deviceId = '00000000',
  }) async {
    final recovery = CrashRecovery(adapter: adapter, config: config);
    final (engine, result) = await recovery.open(dbDir, deviceId: deviceId);
    return (KvStoreImpl._(engine), result);
  }

  // ── KvStore implementation ────────────────────────────────────────────────

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {
    // Guard is called inside async so the ArgumentError is wrapped in a
    // rejected Future rather than thrown synchronously.
    _guardNamespace(namespace);
    await _engine.put(namespace, key, value);
  }

  @override
  Future<void> delete(String namespace, String key) async {
    _guardNamespace(namespace);
    await _engine.delete(namespace, key);
  }

  @override
  Future<void> writeBatch(WriteBatch batch) async {
    for (final entry in batch.entries) {
      _guardNamespace(entry.namespace);
    }
    await _engine.writeBatch(batch);
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
  Future<void> close() => _engine.close();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Throws [ArgumentError] when [namespace] begins with `$`.
  static void _guardNamespace(String namespace) {
    if (namespace.startsWith(r'$')) {
      throw ArgumentError.value(
          namespace, 'namespace', 'System namespaces (starting with \$) are reserved');
    }
  }
}
