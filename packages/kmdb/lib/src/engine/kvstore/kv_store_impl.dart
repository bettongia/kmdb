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

import 'package:meta/meta.dart' show internal;

import '../compaction/reclamation_policy.dart' show ReclamationPolicyRegistry;
import '../platform/storage_adapter_interface.dart';
import '../util/hlc.dart';
import '../util/namespace_codec.dart';
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
  KvStoreImpl._(
    this._engine,
    this._meta,
    this._config, {
    required this._dirtyFlagPresent,
  });

  /// Testing constructor that wraps a pre-built [LsmEngine].
  ///
  /// Use this only in tests where [CrashRecovery.open] has been called with an
  /// injected [HlcClock]. Production code must use [KvStoreImpl.open].
  @internal
  KvStoreImpl.forTesting(
    this._engine,
    this._meta,
    this._config, {
    required this._dirtyFlagPresent,
  });

  final LsmEngine _engine;
  final MetaStore _meta;
  final KvStoreConfig _config;

  /// Whether the dirty-open flag has been written this session.
  ///
  /// The flag is written lazily on the first user write so read-only sessions
  /// never mark the database dirty.
  bool _sessionDirtyMarked = false;

  /// Whether the dirty-open flag currently exists in `$meta`.
  ///
  /// Set to true when:
  /// - [hadUnclosedSession] was true at open time (flag left by a crash), or
  /// - [_appendMetaWrites] adds the flag to a batch this session.
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

    // Inject the MetaStore into the engine so _compactAll can advance the
    // tombstone GC floor after dropping tombstones (H4-FU3).
    engine.setMetaStore(meta);

    // Check for the dirty-open flag written by the previous session.
    final hadUnclosedSession = await meta.getDirtyFlag();

    final openResult = OpenResult(
      hadInterruptedWrites: recoveryResult.hadInterruptedWrites,
      affectedNamespaces: recoveryResult.affectedNamespaces,
      hadUnclosedSession: hadUnclosedSession,
    );

    return (
      KvStoreImpl._(engine, meta, config, dirtyFlagPresent: hadUnclosedSession),
      openResult,
    );
  }

  // ── KvStore implementation ────────────────────────────────────────────────

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {
    final ns = _normaliseAndGuardNamespace(namespace);
    _validateKey(key);
    _validateValueSize(value);
    // Build an engine WriteBatch that folds the document write and all meta
    // writes (dirty flag, gen counter, namespace registry) into one atomic WAL
    // frame. This ensures a crash can never leave the document without its
    // corresponding metadata (or vice versa) — review finding H2, decision D2.
    final batch = WriteBatch()..put(ns, key, value);
    await _appendMetaWrites(batch, {ns});
    await _engine.writeBatch(batch);
  }

  @override
  Future<void> delete(String namespace, String key) async {
    final ns = _normaliseAndGuardNamespace(namespace);
    _validateKey(key);
    // Same atomic-batch approach as put: fold the delete tombstone and all meta
    // writes into one engine WriteBatch so they land in a single WAL frame.
    final batch = WriteBatch()..delete(ns, key);
    await _appendMetaWrites(batch, {ns});
    await _engine.writeBatch(batch);
  }

  @override
  Future<void> writeBatch(WriteBatch batch) async {
    // Normalise every user-supplied namespace to NFC before validation.
    // We copy entries into an internal batch so we do not mutate the caller's
    // WriteBatch (the Query Layer may inspect its entries after committing).
    final extended = WriteBatch();
    for (final e in batch.entries) {
      final ns = _normaliseAndGuardNamespace(e.namespace);
      _validateKey(e.key);
      if (e.value != null) {
        _validateValueSize(e.value!);
        extended.put(ns, e.key, e.value!);
      } else {
        extended.delete(ns, e.key);
      }
    }
    // Extend the normalised batch with meta writes so everything lands in one
    // atomic WAL frame.
    final namespaces = extended.entries.map((e) => e.namespace).toSet();
    await _appendMetaWrites(extended, namespaces);
    await _engine.writeBatch(extended);
  }

  @override
  Future<Uint8List?> get(String namespace, String key) =>
      // NFC-normalise so that lookups match the canonical key stored on write.
      _engine.get(normaliseNamespace(namespace), key);

  @override
  Stream<KvEntry> scan(String namespace, {String? startKey, String? endKey}) =>
      // NFC-normalise so that scan prefixes match the canonical key bytes.
      _engine.scan(
        normaliseNamespace(namespace),
        startKey: startKey,
        endKey: endKey,
      );

  @override
  Stream<VersionHistoryEntry> scanVersionHistory(
    String namespace,
    String docKey,
  ) =>
      // System namespaces ($ver:…) are ASCII by construction; no normalisation
      // is needed. User-provided docKey is a 32-char hex UUIDv7 — no normalisation.
      _engine.scanVersionHistory(namespace, docKey);

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
    // Durably link the ingested file's directory entry before ingestAt0 records
    // it in the manifest (review finding H1); the manifest append then fsyncs.
    await _engine.adapter.syncDir(_engine.sstDir);
    await _engine.ingestAt0(filename);
  }

  @override
  Future<void> dropAllSstables() => _engine.dropAllSstables();

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

    // Also update the DEVICE_ID file so that future opens prefer it over the
    // $meta value (which is susceptible to peer-overwrite via sync ingestion).
    // Make it durable — this is the identity-churn case decision D4 targets.
    final deviceIdPath = '${_engine.dbDir}/$kDeviceIdFilename';
    await _engine.adapter.writeFile(
      deviceIdPath,
      Uint8List.fromList(newDeviceId.codeUnits),
    );
    await _engine.adapter.syncFile(deviceIdPath);
    await _engine.adapter.syncDir(_engine.dbDir);
  }

  @override
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider) {
    _engine.setTombstoneHorizonProvider(provider);
  }

  @override
  void setVersionDropCallback(
    Future<void> Function(List<Uint8List> droppedValues)? callback,
  ) {
    _engine.setVersionDropCallback(callback);
  }

  @override
  void setVersionRegistryProvider(
    Future<ReclamationPolicyRegistry> Function()? provider,
  ) {
    _engine.setVersionRegistryProvider(provider);
  }

  @override
  Future<void> resetTombstoneFloor() =>
      _meta.setTombstoneFloor(const Hlc(0, 0));

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

  /// Loads the stored device ID, or generates and persists a new one if none
  /// has been set.
  ///
  /// Returns an 8-character lowercase hex string. Callers outside the package
  /// (e.g. the CLI) should call this once after opening the store so that all
  /// subsequent writes and SSTable files are attributed to a stable identity.
  ///
  /// ## Storage strategy
  ///
  /// The device ID is stored in **two** places:
  ///
  /// 1. `{dbDir}/DEVICE_ID` — a plain-text file in the database root.  This
  ///    file is never uploaded by [SyncEngine] (which only uploads `.sst` files
  ///    from the `sst/` subdirectory), so peer devices can never overwrite it.
  ///
  /// 2. `$meta` inside the LSM — retained for backward compatibility only.
  ///    Because SSTables (including their `$meta` entries) are exchanged during
  ///    sync, a peer's device ID can land in the local LSM via Last-Write-Wins
  ///    compaction.  The DEVICE_ID file is therefore always preferred over the
  ///    `$meta` value when both are present.
  Future<String> ensureDeviceId() async {
    // 1. Try the dedicated DEVICE_ID file first.  It lives outside sst/ so
    //    sync never touches it.
    final filePath = '${_engine.dbDir}/$kDeviceIdFilename';
    try {
      final bytes = await _engine.adapter.readFile(filePath);
      final id = String.fromCharCodes(bytes).trim();
      if (RegExp(r'^[0-9a-f]{8}$').hasMatch(id)) return id;
    } on StorageException {
      // File absent — fall through.
    }

    // 2. Fall back to $meta (backward-compatible path for existing databases).
    final id = await DeviceId.load(_meta);

    // 3. Write to the DEVICE_ID file so future opens skip the $meta lookup.
    //    Make it durable (content + directory entry): a lost DEVICE_ID falls back
    //    to $meta but a changed identity forces a full SSTable re-upload, so the
    //    fsync is cheap insurance against needless churn (decision D4).
    await _engine.adapter.writeFile(filePath, Uint8List.fromList(id.codeUnits));
    await _engine.adapter.syncFile(filePath);
    await _engine.adapter.syncDir(_engine.dbDir);

    return id;
  }

  /// Filename of the local device-identity file stored in the database root.
  ///
  /// The file contains exactly 8 lowercase hex characters (no newline required,
  /// but a trailing newline is tolerated).  It is intentionally placed in the
  /// database root rather than in `sst/` so that [SyncEngine] never uploads it
  /// to the sync folder.
  static const String kDeviceIdFilename = 'DEVICE_ID';

  @override
  Future<List<String>> listNamespaces() => _meta.getNamespaces();

  @override
  Future<bool> createNamespace(String namespace) async {
    final ns = _normaliseAndGuardNamespace(namespace);
    final existing = await _meta.getNamespaces();
    if (existing.contains(ns)) return false;
    // Fold the dirty-flag set and the namespace-registry update into one
    // atomic batch frame. Unlike a document write we do **not** bump the
    // generation counter here: creating an empty namespace doesn't invalidate
    // any cached document state.
    final batch = WriteBatch();
    if (!_sessionDirtyMarked) {
      _meta.appendDirtyFlag(batch);
      _sessionDirtyMarked = true;
      _dirtyFlagPresent = true;
    }
    await _meta.appendNamespaceRegistration(ns, batch);
    await _engine.writeBatch(batch);
    return true;
  }

  /// Removes [namespace] from the persisted namespace registry and deletes its
  /// generation counter.
  ///
  /// This is the inverse of [createNamespace]. It does **not** delete any
  /// documents — callers should delete all documents in the namespace via
  /// [writeBatch] before calling this method.
  ///
  /// It is a no-op if the namespace is not currently registered.
  ///
  /// [namespace] must not start with `$` (system namespaces are reserved).
  /// Throws [ArgumentError] if that constraint is violated.
  Future<void> unregisterNamespace(String namespace) async {
    final ns = _normaliseAndGuardNamespace(namespace);
    await _meta.unregisterNamespace(ns);
  }

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
  /// [WriteBatch] that cannot be observed in a partial state — either across a
  /// crash (WAL frame atomicity, review finding H2) or in-process (synchronous
  /// memtable application with no intervening awaits).
  ///
  /// Generation counters are incremented only for user (non-`$`) namespaces so
  /// that cache invalidation stays tied to document writes, not index writes.
  /// Because the gen-counter bump is now folded into the same atomic WAL frame
  /// as the document and index entries, cache subscribers always see the updated
  /// generation when the write event fires — they observe the full batch or none.
  ///
  /// The dirty-open flag is set on the first call, identical to [writeBatch].
  @internal
  Future<void> writeBatchInternal(WriteBatch batch) async {
    for (final entry in batch.entries) {
      if (entry.value != null) _validateValueSize(entry.value!);
    }
    // Copy the caller's entries into an extended batch so we do not mutate the
    // original (the Query Layer may inspect its entries after committing).
    // NFC-normalise every user namespace (non-$ prefixed) so all paths through
    // the storage engine see a canonical form.
    final extended = WriteBatch();
    for (final e in batch.entries) {
      // System namespaces ($index:…, $fts:…, etc.) are ASCII by construction
      // and do not need normalisation. User namespaces are normalised.
      final ns = e.namespace.startsWith(r'$')
          ? e.namespace
          : normaliseNamespace(e.namespace);
      if (e.isDelete) {
        extended.delete(ns, e.key);
      } else {
        extended.put(ns, e.key, e.value!);
      }
    }
    // Collect user namespaces (non-$ prefixed) for gen counter + registry.
    final namespaces = extended.entries
        .where((e) => !e.namespace.startsWith(r'$'))
        .map((e) => e.namespace)
        .toSet();
    // Fold dirty flag + gen counter + namespace registry into the same frame.
    await _appendMetaWrites(extended, namespaces);
    await _engine.writeBatch(extended);
  }

  /// Returns every distinct namespace string present in storage, including
  /// system namespaces like `$meta` and `$index:…`.
  ///
  /// This is an expensive full-merge scan intended only for infrequent
  /// administrative operations such as [IndexManager.removeIndex]. Application
  /// code should use [listNamespaces] for user-visible namespaces.
  @internal
  Future<Set<String>> allStoredNamespaces() => _engine.allStoredNamespaces();

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Appends the dirty-open flag, generation counter bumps, and namespace
  /// registrations to [batch] so they are committed in the same atomic WAL
  /// frame as the document writes.
  ///
  /// ## Ordering guarantee
  ///
  /// Because [LsmEngine.writeBatch] applies all memtable mutations synchronously
  /// before emitting write events, cache subscribers always observe the updated
  /// generation counter when they react to the event — the meta writes are
  /// visible at the same instant as the documents.
  ///
  /// ## Dirty-open flag
  ///
  /// On the first call per session the dirty flag is appended to [batch]. On
  /// subsequent calls the flag is already present and the append is skipped.
  /// Folding it into the first document write ensures that a crash during the
  /// very first write of a session sets the flag (so the next open detects the
  /// interrupted session) rather than leaving it absent.
  Future<void> _appendMetaWrites(
    WriteBatch batch,
    Set<String> userNamespaces,
  ) async {
    if (!_sessionDirtyMarked) {
      _meta.appendDirtyFlag(batch);
      _sessionDirtyMarked = true;
      _dirtyFlagPresent = true;
    }
    for (final ns in userNamespaces) {
      await _meta.appendGenerationCounterBump(ns, batch);
      await _meta.appendNamespaceRegistration(ns, batch);
    }
  }

  /// Throws [ArgumentError] if [value] exceeds [KvStoreConfig.maxValueBytes].
  void _validateValueSize(Uint8List value) {
    final limit = _config.maxValueBytes;
    if (limit != KvStoreConfig.maxValueBytesUnlimited && value.length > limit) {
      throw ArgumentError.value(
        value.length,
        'value',
        'Value size (${value.length} bytes) exceeds maxValueBytes ($limit). '
            'Store large payloads in the vault instead.',
      );
    }
  }

  /// NFC-normalises [namespace] and throws [ArgumentError] if the result starts
  /// with `$` (system namespaces are reserved for internal use).
  ///
  /// Returns the NFC-normalised namespace string so the caller can use the
  /// canonical form for all subsequent storage operations.
  ///
  /// By normalising before the guard check, callers that supply the same logical
  /// name in different Unicode normalisation forms (NFC vs NFD) all receive the
  /// same canonical string and thus write to the same namespace.
  static String _normaliseAndGuardNamespace(String namespace) {
    final ns = normaliseNamespace(namespace);
    if (ns.startsWith(r'$')) {
      throw ArgumentError.value(
        namespace,
        'namespace',
        'System namespaces (starting with \$) are reserved',
      );
    }
    return ns;
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
