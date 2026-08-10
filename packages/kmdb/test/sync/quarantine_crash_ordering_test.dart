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

/// Fault-injection regression for the A3 / WI-7 quarantine-reporting plan's
/// D3 decision — the load-bearing durability test named explicitly by the
/// plan: a crash **between** the durable `$$quarantine` log write
/// (`MetaStore.appendQuarantine`, called from inside `SyncEngine.pull`'s
/// per-file loop) and the single post-loop `HighwaterMark.save` must never
/// leave the HWM advanced without the record durably persisted first.
///
/// Two scenarios, matching the plan's Phase 5 checklist exactly:
///
/// (a) The log write itself fails (e.g. a full local disk) — the HWM must
///     never advance (fail-safe direction).
/// (b) The log write succeeds but the *subsequent* HWM save fails (e.g. a
///     transient cloud-upload error) — the record must survive a reopen
///     (genuine WAL replay, not a fresh in-memory store), and a later
///     healthy pull must re-quarantine idempotently (no duplicate log
///     entry) and then successfully advance the HWM.
///
/// ## Why a reopen is required before "the subsequent healthy pull" in both
/// scenarios
///
/// `KvStoreImpl.ingestSstable` writes the incoming SSTable's raw bytes to
/// `sst/` and `syncFile`+`syncDir`s them — durably linking the file — before
/// `ingestAt0` ever validates it (an existing, out-of-scope crash-safety
/// ordering documented at `sync_engine_test.dart`'s original quarantine
/// test). This means that by the time `pull()` reaches the rejection branch
/// this test targets, the corrupted file is *already* durable in `sst/`,
/// even though it was never registered in the Manifest. A later `pull()`
/// call therefore skips it immediately via the `_localAdapter.fileExists`
/// check at the top of the per-file loop — *unless* the store is reopened
/// first, which runs §17's orphan-sweep (`CrashRecovery` step 4: "delete
/// orphan SSTable files … not referenced by Manifest") and removes the
/// stranded file, allowing a genuinely fresh download-and-reprocess on the
/// next `pull()`. This matches the plan's own checklist wording ("reopen
/// shows the record present, and a subsequent healthy pull …").
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/quarantine.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/highwater.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_context.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:kmdb/src/sync/sync_storage_adapter.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _syncRoot = 'sync';
const _localDeviceId = 'dev00001';
const _peerDeviceId = 'peer0001';

/// Thrown by [_CrashOnQuarantinePutAdapter] when it intercepts the armed WAL
/// append triggered by `MetaStore.appendQuarantine` — stands in for the
/// process dying (or the disk filling up) at that exact instant.
final class _SimulatedLogWriteFailure implements Exception {
  const _SimulatedLogWriteFailure();
  @override
  String toString() =>
      '_SimulatedLogWriteFailure: the \$\$quarantine log write failed';
}

/// Wraps [FaultyStorageAdapter], forwarding every call unchanged, except
/// that — once [armed] — the *next* [appendFile] call targeting a
/// `wal-*.log` file triggers [FaultyStorageAdapter.crash] and throws
/// [_SimulatedLogWriteFailure] instead of performing the write.
///
/// Nothing else in `SyncEngine.pull`'s rejection branch writes to a WAL file
/// — `_store.ingestSstable`'s raw-bytes write goes through the SSTable path,
/// not the WAL, and `HighwaterMark.save` writes to the *cloud* adapter, not
/// this local one — so arming this immediately before `pull()` deterministically
/// targets the `appendQuarantine` call and nothing else.
final class _CrashOnQuarantinePutAdapter implements StorageAdapter {
  _CrashOnQuarantinePutAdapter(this._inner);

  final FaultyStorageAdapter _inner;

  /// Set by the test immediately before the `pull()` call whose quarantine
  /// log write should trigger the simulated failure.
  bool armed = false;

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    if (armed && path.contains('wal-')) {
      armed = false;
      _inner.crash();
      throw const _SimulatedLogWriteFailure();
    }
    return _inner.appendFile(path, bytes);
  }

  @override
  Future<Uint8List> readFile(String path) => _inner.readFile(path);
  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      _inner.readFileRange(path, offset, length);
  @override
  Future<void> writeFile(String path, Uint8List bytes) =>
      _inner.writeFile(path, bytes);
  @override
  Future<void> syncFile(String path) => _inner.syncFile(path);
  @override
  Future<void> syncDir(String dirPath) => _inner.syncDir(dirPath);
  @override
  Future<void> deleteFile(String path) => _inner.deleteFile(path);
  @override
  Future<bool> fileExists(String path) => _inner.fileExists(path);
  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) =>
      _inner.listFiles(dirPath, extension: extension);
  @override
  Future<List<String>> listFilesRecursive(String dirPath) =>
      _inner.listFilesRecursive(dirPath);
  @override
  Future<int> fileSize(String path) => _inner.fileSize(path);
  @override
  Future<void> renameFile(String from, String to) =>
      _inner.renameFile(from, to);
  @override
  Future<void> createDirectory(String dirPath) =>
      _inner.createDirectory(dirPath);
  @override
  Future<void> acquireLock(String lockPath) => _inner.acquireLock(lockPath);
  @override
  Future<void> releaseLock(String lockPath) => _inner.releaseLock(lockPath);
}

/// Thrown by [_FailHwmUploadAdapter] when armed and an `upload()` call
/// targets a `.hwm` path — stands in for a transient cloud-upload failure
/// (e.g. a network blip) landing strictly *after* the local quarantine log
/// write already succeeded.
final class _SimulatedHwmUploadFailure implements Exception {
  const _SimulatedHwmUploadFailure();
  @override
  String toString() => '_SimulatedHwmUploadFailure: HWM upload failed';
}

/// Wraps [SyncStorageAdapter], forwarding every call unchanged, except that
/// — while [failHwmUpload] is `true` — the next [upload] call targeting a
/// `.hwm` path throws [_SimulatedHwmUploadFailure] instead of performing the
/// upload. The test disarms it after observing the failure so a later pull
/// can complete the HWM save normally.
final class _FailHwmUploadAdapter implements SyncStorageAdapter {
  _FailHwmUploadAdapter(this._inner);

  final SyncStorageAdapter _inner;

  /// Set by the test immediately before the `pull()` call whose HWM save
  /// should fail.
  bool failHwmUpload = false;

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    if (failHwmUpload && remotePath.endsWith('.hwm')) {
      failHwmUpload = false;
      throw const _SimulatedHwmUploadFailure();
    }
    return _inner.upload(remotePath, bytes, ctx: ctx);
  }

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) => _inner.list(remoteDir, extension: extension, ctx: ctx);
  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) =>
      _inner.download(remotePath, ctx: ctx);
  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) =>
      _inner.delete(remotePath, ctx: ctx);
  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) =>
      _inner.compareAndSwap(path, newBytes, ifMatchEtag: ifMatchEtag, ctx: ctx);
  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) =>
      _inner.getEtag(path, ctx: ctx);
  @override
  bool get providesAtomicCas => _inner.providesAtomicCas;
}

/// Uploads a checksum-invalid ("garbage bytes") SSTable to [cloudAdapter] at
/// the standard peer-flush path, and returns its bare filename. Fails the
/// footer checksum, which the reader validates before any other parsing —
/// `CorruptedSstableException`, the same rejection reason exercised by the
/// pre-existing S-1 quarantine test.
Future<String> _uploadCorruptPeerSstable(
  SyncStorageAdapter cloudAdapter, {
  required Hlc minHlc,
  required Hlc maxHlc,
}) async {
  final filename = SstableInfo.flushName(_peerDeviceId, minHlc, maxHlc);
  await cloudAdapter.upload(
    '$_syncRoot/sstables/$filename',
    Uint8List.fromList(List.filled(64, 0xAB)),
  );
  return filename;
}

void main() {
  group('SyncEngine.pull — quarantine log vs. HWM save crash ordering (A3 / '
      'WI-7, D3)', () {
    test('(a) the log write itself fails: the HWM is never advanced, and no '
        'quarantine record is left behind — the fail-safe direction', () async {
      final inner = FaultyStorageAdapter();
      final wrappedLocal = _CrashOnQuarantinePutAdapter(inner);
      final cloudAdapter = MemorySyncAdapter();

      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        wrappedLocal,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _localDeviceId,
      );

      final peerFilename = await _uploadCorruptPeerSstable(
        cloudAdapter,
        minHlc: const Hlc(5000, 0),
        maxHlc: const Hlc(5001, 0),
      );

      final engine = SyncEngine(
        store: store,
        cloudAdapter: cloudAdapter,
        localAdapter: wrappedLocal,
        deviceId: _localDeviceId,
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        consolidationConfig: const ConsolidationConfig(),
      );

      // Arm the crash for the very next WAL append — the quarantine log
      // write `pull()` is about to attempt inside its rejection branch.
      wrappedLocal.armed = true;
      await expectLater(
        engine.pull(),
        throwsA(isA<_SimulatedLogWriteFailure>()),
      );

      // The HWM must never have been saved — the log write that would
      // have made the drop permanent never landed.
      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/$_localDeviceId.hwm',
        cloudAdapter,
      );
      expect(
        hwm,
        isNull,
        reason:
            'a failed quarantine-log write must leave the HWM untouched '
            '— advancing it here would be the dangerous, unrecoverable '
            'direction (permanent loss with no record)',
      );

      // Reopen over the *unwrapped* inner adapter — its state now reflects
      // exactly what a real crash would have left durable. This also runs
      // the orphan-sweep that clears the stranded (unregistered) corrupted
      // SSTable out of sst/, per this file's class doc comment.
      final (reopened, _) = await KvStoreImpl.open(
        _dbDir,
        inner,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _localDeviceId,
      );

      final loggedAfterCrash = await reopened.meta.listQuarantines();
      expect(
        loggedAfterCrash,
        isEmpty,
        reason:
            'the quarantine record must not exist — its write never '
            'completed, so there must be no trace of a decision that was '
            'never actually made durable',
      );

      // A subsequent healthy pull (fault removed, file re-fetchable now
      // that the orphan sweep cleared it) must succeed, report the
      // quarantine, persist the log entry, and advance the HWM — proving
      // the file was genuinely reconsidered, not permanently lost.
      final engine2 = SyncEngine(
        store: reopened,
        cloudAdapter: cloudAdapter,
        localAdapter: inner,
        deviceId: _localDeviceId,
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        consolidationConfig: const ConsolidationConfig(),
      );
      final result = await engine2.pull();
      expect(result.quarantined, hasLength(1));
      expect(result.quarantined.single.filename, equals(peerFilename));

      final loggedAfterHealthyPull = await reopened.meta.listQuarantines();
      expect(loggedAfterHealthyPull, hasLength(1));

      final hwmAfterHealthyPull = await HighwaterMark.load(
        '$_syncRoot/highwater/$_localDeviceId.hwm',
        cloudAdapter,
      );
      expect(
        hwmAfterHealthyPull!.peers[_peerDeviceId],
        equals(const Hlc(5001, 0)),
      );

      await reopened.close();
    });

    test('(b) the HWM save fails after a successful log write: the record '
        'survives a reopen, and a later healthy pull re-quarantines '
        'idempotently (no duplicate) and then advances the HWM', () async {
      final localAdapter = MemoryStorageAdapter();
      final innerCloud = MemorySyncAdapter();
      final faultyCloud = _FailHwmUploadAdapter(innerCloud);

      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        localAdapter,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );

      final peerFilename = await _uploadCorruptPeerSstable(
        faultyCloud,
        minHlc: const Hlc(6000, 0),
        maxHlc: const Hlc(6001, 0),
      );

      final engine = SyncEngine(
        store: store,
        cloudAdapter: faultyCloud,
        localAdapter: localAdapter,
        deviceId: _localDeviceId,
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        consolidationConfig: const ConsolidationConfig(),
      );

      // Arm the HWM-upload failure. The local quarantine-log write is
      // untouched — it succeeds normally, strictly before this failure
      // fires.
      faultyCloud.failHwmUpload = true;
      await expectLater(
        engine.pull(),
        throwsA(isA<_SimulatedHwmUploadFailure>()),
      );

      // The HWM must never have been saved (the upload that would have
      // written it threw).
      final hwm = await HighwaterMark.load(
        '$_syncRoot/highwater/$_localDeviceId.hwm',
        innerCloud,
      );
      expect(hwm, isNull);

      // Unlike scenario (a), nothing local crashed here — only the remote
      // upload failed — so release the lock with a normal close() before
      // reopening (a "the app restarted to retry sync" scenario, not a
      // simulated power loss).
      await store.close();

      // Reopen over the *same, retained* local adapter — genuine WAL
      // replay, not a fresh in-memory store — and confirm the quarantine
      // record survived. This also runs the orphan-sweep (see class doc).
      final (reopened, _) = await KvStoreImpl.open(
        _dbDir,
        localAdapter,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );
      final loggedAfterReopen = await reopened.meta.listQuarantines();
      expect(loggedAfterReopen, hasLength(1));
      expect(loggedAfterReopen.single.filename, equals(peerFilename));
      expect(
        loggedAfterReopen.single.reason,
        equals(QuarantineReason.corruptedSstable),
      );

      // Disarm the fault and run a healthy pull. The corrupted file is
      // re-fetched (orphan-swept away by the reopen above), rejected
      // again, and re-quarantined — an idempotent overwrite of the same
      // log key, never a duplicate entry — then the HWM save succeeds.
      faultyCloud.failHwmUpload = false;
      final engine2 = SyncEngine(
        store: reopened,
        cloudAdapter: faultyCloud,
        localAdapter: localAdapter,
        deviceId: _localDeviceId,
        dbDir: _dbDir,
        syncRoot: _syncRoot,
        syncNamespaces: {'ns'},
        consolidationConfig: const ConsolidationConfig(),
      );
      final result = await engine2.pull();
      expect(result.quarantined, hasLength(1));
      expect(result.quarantined.single.filename, equals(peerFilename));

      final loggedAfterHealthyPull = await reopened.meta.listQuarantines();
      expect(
        loggedAfterHealthyPull,
        hasLength(1),
        reason:
            're-quarantining the same file must overwrite the existing '
            'key, never add a second entry',
      );

      final hwmAfterHealthyPull = await HighwaterMark.load(
        '$_syncRoot/highwater/$_localDeviceId.hwm',
        innerCloud,
      );
      expect(
        hwmAfterHealthyPull!.peers[_peerDeviceId],
        equals(const Hlc(6001, 0)),
      );

      await reopened.close();
    });
  });
}
