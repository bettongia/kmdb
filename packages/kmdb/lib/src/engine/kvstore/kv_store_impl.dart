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

import 'package:meta/meta.dart' show internal;

import '../platform/storage_adapter_interface.dart';
import 'crash_recovery.dart';
import 'device_id.dart';
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
  KvStoreImpl._(this._engine, this._meta, {required bool dirtyFlagPresent})
    : _dirtyFlagPresent = dirtyFlagPresent;

  final LsmEngine _engine;
  final MetaStore _meta;

  /// Whether the dirty-open flag has been written this session.
  ///
  /// The flag is written lazily on the first user write so read-only sessions
  /// never mark the database dirty.
  bool _sessionDirtyMarked = false;

  /// Whether the dirty-open flag currently exists in `$meta`.
  ///
  /// Set to true when:
  /// - [hadUnclosedSession] was true at open time (flag left by a crash), or
  /// - [_maybeMarkDirty] writes the flag this session.
  ///
  /// Only when this is true does [close] need to write a tombstone to clear the
  /// flag. Avoids an unnecessary memtable write (and flush + compaction) for
  /// sessions that never write.
  bool _dirtyFlagPresent;

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
    final (engine, recoveryResult) = await recovery.open(
      dbDir,
      deviceId: deviceId,
    );
    final meta = MetaStore(engine);

    // Check for the dirty-open flag written by the previous session.
    final hadUnclosedSession = await meta.getDirtyFlag();

    final openResult = OpenResult(
      hadInterruptedWrites: recoveryResult.hadInterruptedWrites,
      affectedNamespaces: recoveryResult.affectedNamespaces,
      hadUnclosedSession: hadUnclosedSession,
    );

    return (
      KvStoreImpl._(engine, meta, dirtyFlagPresent: hadUnclosedSession),
      openResult,
    );
  }

  // ── KvStore implementation ────────────────────────────────────────────────

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {
    _guardNamespace(namespace);
    _validateKey(key);
    await _maybeMarkDirty();
    await _engine.put(namespace, key, value);
    await _meta.incrementGenerationCounter(namespace);
    await _meta.registerNamespace(namespace);
  }

  @override
  Future<void> delete(String namespace, String key) async {
    _guardNamespace(namespace);
    _validateKey(key);
    await _maybeMarkDirty();
    await _engine.delete(namespace, key);
    await _meta.incrementGenerationCounter(namespace);
    await _meta.registerNamespace(namespace);
  }

  @override
  Future<void> writeBatch(WriteBatch batch) async {
    for (final entry in batch.entries) {
      _guardNamespace(entry.namespace);
      _validateKey(entry.key);
    }
    await _maybeMarkDirty();
    await _engine.writeBatch(batch);
    // Increment the generation counter for each affected namespace.
    final namespaces = batch.entries.map((e) => e.namespace).toSet();
    for (final ns in namespaces) {
      await _meta.incrementGenerationCounter(ns);
      await _meta.registerNamespace(ns);
    }
  }

  @override
  Future<Uint8List?> get(String namespace, String key) =>
      _engine.get(namespace, key);

  @override
  Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey}) =>
      _engine.scan(namespace, startKey: startKey, endKey: endKey);

  @override
  Future<void> flush() => _engine.flush();

  @override
  Future<void> compactAll() => _engine.compactAll();

  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) async {
    // Write the SSTable bytes to the local sst/ directory first, then
    // register it in the manifest via the engine. The engine validates
    // the footer checksum during open() inside ingestAt0().
    final sstPath = '${_engine.sstDir}/$filename';
    await _engine.adapter.writeFile(sstPath, bytes);
    await _engine.adapter.syncFile(sstPath);
    await _engine.ingestAt0(filename);
  }

  @override
  Stream<String> get writeEvents => _engine.writeEvents;

  @override
  Future<void> reassignDeviceId(String newDeviceId) async {
    // Delegate the heavy lifting (validation, flush, file renames, VersionEdit)
    // to the engine. The engine updates _deviceId after the VersionEdit is
    // persisted to the Manifest.
    await _engine.reassignDeviceId(newDeviceId);

    // Persist the new device ID to $meta. This is done after the engine write
    // so that, on crash before this point, the next open sees the old ID and
    // recovers into a consistent state (the renamed files will be orphans, which
    // crash recovery will delete, and the old-named originals in the Manifest
    // will be valid).
    await _meta.putDeviceId(newDeviceId);
  }

  @override
  Future<void> close({bool flush = true}) async {
    // Only write a tombstone to clear the dirty flag if the flag actually exists
    // in $meta. Writing an unnecessary tombstone would cause a memtable write,
    // which triggers a flush and potentially a compaction — both wasteful for
    // read-only sessions and dangerous if L0 contains externally-ingested files
    // that may have been overwritten in tests.
    if (_dirtyFlagPresent) {
      await _meta.clearDirty();
    }
    await _engine.close(flush: flush);
  }

  /// Loads the stored device ID from `$meta`, or generates and persists a new
  /// one if none has been set.
  ///
  /// Returns an 8-character lowercase hex string. Callers outside the package
  /// (e.g. the CLI) should call this once after opening the store so that all
  /// subsequent writes and SSTable files are attributed to a stable identity.
  Future<String> ensureDeviceId() => DeviceId.load(_meta);

  @override
  Future<List<String>> listNamespaces() => _meta.getNamespaces();

  @override
  Future<StoreStats> stats() async {
    final ls = await _engine.levelStats();
    return StoreStats(
      dbDir: _engine.dbDir,
      l0Count: ls.l0,
      l1Count: ls.l1,
      l2Count: ls.l2,
      totalSstBytes: ls.totalSstBytes,
      totalDbBytes: ls.totalDbBytes,
    );
  }

  @override
  Future<StoreInfo> storeInfo() async {
    final deviceId = await _meta.getDeviceId() ?? _engine.deviceId;
    return StoreInfo(
      dbDir: _engine.dbDir,
      deviceId: deviceId,
      currentHlc: _engine.currentHlcString,
    );
  }

  // ── Internal access (query layer + tests) ────────────────────────────────

  /// Direct access to the [MetaStore] for use by the Query Layer and tests.
  ///
  /// External application code should not use this.
  @internal
  MetaStore get meta => _meta;

  /// Performs an atomic write batch that may include system namespace entries.
  ///
  /// Unlike [writeBatch], this method does not reject entries whose namespace
  /// begins with `$`. It is used by the Query Layer to write secondary index
  /// entries (`$index:…`) atomically with the document they index, in a single
  /// [WriteBatch] that cannot be observed in a partial state.
  ///
  /// Generation counters are incremented only for user (non-`$`) namespaces so
  /// that cache invalidation stays tied to document writes, not index writes.
  /// The dirty-open flag is set on the first call, identical to [writeBatch].
  @internal
  Future<void> writeBatchInternal(WriteBatch batch) async {
    await _maybeMarkDirty();
    // Increment generation counters BEFORE the engine write so that when the
    // engine emits write events (synchronously during writeBatch), any
    // subscribers that immediately re-read via the CacheLayer will see the
    // updated generation and bypass the stale cache entry.
    final namespaces = batch.entries
        .where((e) => !e.namespace.startsWith(r'$'))
        .map((e) => e.namespace)
        .toSet();
    for (final ns in namespaces) {
      await _meta.incrementGenerationCounter(ns);
      await _meta.registerNamespace(ns);
    }
    await _engine.writeBatch(batch);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Writes the dirty-open flag on the first user write of the session.
  Future<void> _maybeMarkDirty() async {
    if (_sessionDirtyMarked) return;
    await _meta.setDirty();
    _sessionDirtyMarked = true;
    _dirtyFlagPresent = true;
  }

  /// Throws [ArgumentError] when [namespace] begins with `$`.
  static void _guardNamespace(String namespace) {
    if (namespace.startsWith(r'$')) {
      throw ArgumentError.value(
        namespace,
        'namespace',
        'System namespaces (starting with \$) are reserved',
      );
    }
  }

  /// Throws [ArgumentError] if [key] is not a valid UUIDv7 hex string.
  ///
  /// This check mirrors [KeyCodec.keyToBytes] validation but provides a
  /// friendlier [ArgumentError] for the public API boundary.
  static void _validateKey(String key) {
    final stripped = key.replaceAll('-', '');
    if (stripped.length != 32) {
      throw ArgumentError.value(
        key,
        'key',
        'Key must be 32 hex characters (UUIDv7)',
      );
    }
    if (stripped[12] != '7') {
      throw ArgumentError.value(
        key,
        'key',
        'Key must be a valid UUIDv7 (version 7 required)',
      );
    }
    final variantChar = stripped[16].toLowerCase();
    if (variantChar != '8' &&
        variantChar != '9' &&
        variantChar != 'a' &&
        variantChar != 'b') {
      throw ArgumentError.value(
        key,
        'key',
        'Key must be a valid UUIDv7 (variant 2 required)',
      );
    }
  }
}
