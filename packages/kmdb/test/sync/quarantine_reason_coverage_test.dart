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

/// Covers every [QuarantineReason] mapping (finding A3 / WI-7, plan Phase 5)
/// against `SyncEngine.pull`'s real ingest path — not synthetic
/// construction of the enum values.
///
/// Four of the five reasons are reachable directly through
/// `KvStoreImpl.ingestSstable`/`LsmEngine.ingestAt0` today and are exercised
/// here:
///
/// - [QuarantineReason.corruptedSstable] — a checksum-invalid file
///   (`CorruptedSstableException` from `SstableReader.open`).
/// - [QuarantineReason.storageError] — a local write failure while
///   `KvStoreImpl.ingestSstable` writes the incoming file's raw bytes to
///   `sst/`, *before* `SstableReader` ever opens it (`StorageException`).
/// - [QuarantineReason.invalidFormat] — a structurally valid, checksum-valid
///   SSTable whose sole entry's internal key claims a namespace-length byte
///   that is internally consistent (so `SstableReader` parses the block
///   without complaint) but whose namespace bytes are not valid UTF-8:
///   `LsmEngine.ingestAt0`'s ingest-side gen-bump scan calls
///   `KeyCodec.decodeNamespace` directly on every scanned entry — outside
///   `SstableReader`'s own structural-failure wrapping — so `utf8.decode`'s
///   bare `FormatException` propagates uncaught.
/// - [QuarantineReason.structuralBoundsViolation] — the same call site, but
///   the internal key's namespace-length byte is inconsistent with the
///   key's actual length, so `Uint8List.sublist` throws a bare `RangeError`.
///
/// [QuarantineReason.outOfMemory] no longer has a *file-driven* trigger: the
/// S-1/S-8 bounds hardening now rejects a hostile SSTable (an attacker-declared
/// `filterSize`/`indexSize` reaching `malloc`) with a structural exception
/// *before* any unbounded allocation is attempted — so a crafted file maps to
/// [QuarantineReason.corruptedSstable], not `outOfMemory` (asserted directly in
/// `sync_engine_native_adapter_test.dart`). The `on OutOfMemoryError` catch in
/// `SyncEngine.pull` remains as belt-and-suspenders defence-in-depth for any
/// future ingest path that could still exhaust memory, so its reason mapping is
/// covered here by injecting an [OutOfMemoryError] straight from
/// `KvStore.ingestSstable` (see `_OutOfMemoryOnIngestStore`) — a faithful test
/// of the catch clause without relying on a real allocation failure.
///
/// ## Why `invalidFormat`/`structuralBoundsViolation` need a hand-built key
///
/// `SstableReader.open`/`scan` wrap every `RangeError`/`FormatException`/
/// `StorageException` raised while parsing the footer, index, or a data
/// block's own varint framing into `CorruptedSstableException` (see that
/// file's doc comments) — precisely so ordinary structural corruption always
/// reads as one type. `KeyCodec.decodeNamespace`, however, is called by
/// `LsmEngine.ingestAt0` directly on an already-successfully-decoded
/// [SstEntry.key] — a semantic validation step *outside* `SstableReader`'s
/// wrapping. A key whose bytes are well-formed as raw shared/unshared block
/// framing (so the block decodes cleanly) but semantically invalid as an
/// internal key (bogus namespace-length byte, or non-UTF-8 namespace bytes)
/// reaches this exact gap — which is why `SyncEngine.pull` still carries
/// bare `on RangeError`/`on FormatException` catches (its own doc comments
/// call them "belt-and-suspenders"). [SstableWriter.add] accepts a raw
/// [Uint8List] key with no structural validation, so a hostile key can be
/// constructed directly rather than needing a binary-patching helper.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/kvstore/quarantine.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/sync/consolidation_config.dart';
import 'package:kmdb/src/sync/local/memory_sync_adapter.dart';
import 'package:kmdb/src/sync/sync_engine.dart';
import 'package:test/test.dart';

import '../vault/test_kv_store.dart';

const _dbDir = '/db';
const _syncRoot = 'sync';
const _localDeviceId = 'dev00001';
const _peerDeviceId = 'peer0001';

/// Builds a hand-crafted internal key with the standard
/// `[nsLen(1B)][nsBytes][userKey(16B)][hlc(8B)][type(1B)]` layout (matching
/// `KeyCodec.encodeInternalKey`'s layout), but with [claimedNsLen] written
/// as the length byte instead of `nsBytes.length` — letting the two diverge
/// so a bogus claimed length can be constructed.
Uint8List _buildRawInternalKey({
  required int claimedNsLen,
  required List<int> nsBytes,
}) {
  final userKeyBytes = Uint8List(16);
  final out = Uint8List(1 + nsBytes.length + 16 + 8 + 1);
  var offset = 0;
  out[offset++] = claimedNsLen;
  out.setAll(offset, nsBytes);
  offset += nsBytes.length;
  out.setAll(offset, userKeyBytes);
  offset += 16;
  // HLC bytes are never read on this failure path — zero is fine.
  offset += 8;
  out[offset] = RecordType.put.byte;
  return out;
}

/// Builds a single-entry, otherwise well-formed SSTable containing
/// [internalKey] — real footer/filter/index/checksum via [SstableWriter], so
/// it passes `SstableReader.open` cleanly regardless of whether
/// [internalKey]'s own semantic structure is valid.
Uint8List _buildHostileKeySstable(Uint8List internalKey) {
  final writer = SstableWriter()..add(internalKey, Uint8List.fromList([1]));
  return writer.finish();
}

/// A [TestKvStore] whose [ingestSstable] throws [OutOfMemoryError], covering
/// `SyncEngine.pull`'s `on OutOfMemoryError` → [QuarantineReason.outOfMemory]
/// mapping without a real allocation failure (see this file's class doc for why
/// no file-driven trigger exists post-S-1/S-8). Every other method inherits
/// [TestKvStore]'s safe in-memory stubs; the durable-log write on the quarantine
/// path is already exercised by the four file-driven reason tests above.
final class _OutOfMemoryOnIngestStore extends TestKvStore {
  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) async {
    throw OutOfMemoryError();
  }
}

/// A [TestKvStore] whose [ingestSstable] throws [StaleSstableIngestException]
/// (the ingest-side GC-floor rejection, H4-FU3), isolating `SyncEngine.pull`'s
/// *transient* deferral path. A genuine sub-floor rejection from the real engine
/// is proven separately by the H4-FU3 multi-store test in `sync_engine_test.dart`;
/// this store isolates pull's routing of that exception into
/// [PullResult.deferred] — never [PullResult.quarantined], and never the durable
/// log. [appendQuarantineCalls] records whether the never-persist contract holds.
final class _SubFloorOnIngestStore extends TestKvStore {
  _SubFloorOnIngestStore({required this.maxHlc, required this.floor});

  /// The `maxHlc` reported in the thrown [StaleSstableIngestException].
  final Hlc maxHlc;

  /// The GC floor reported in the thrown [StaleSstableIngestException].
  final Hlc floor;

  /// Count of [appendQuarantine] invocations — must remain `0` for a deferral.
  int appendQuarantineCalls = 0;

  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) async {
    throw StaleSstableIngestException(
      filename: filename,
      maxHlc: maxHlc,
      floor: floor,
    );
  }

  @override
  Future<void> appendQuarantine(QuarantinedSstable record) async {
    appendQuarantineCalls++;
  }
}

/// Creates a [SyncEngine] wired to [store]/[cloudAdapter]/[localAdapter].
SyncEngine _makeEngine(
  KvStore store,
  MemorySyncAdapter cloudAdapter,
  StorageAdapter localAdapter,
) => SyncEngine(
  store: store,
  cloudAdapter: cloudAdapter,
  localAdapter: localAdapter,
  deviceId: _localDeviceId,
  dbDir: _dbDir,
  syncRoot: _syncRoot,
  syncNamespaces: {'ns'},
  consolidationConfig: const ConsolidationConfig(),
);

/// A local [StorageAdapter] wrapper that throws [StorageException] on the
/// next [writeFile] call whose path matches [failOnPath], modelling a local
/// disk-full error while `KvStoreImpl.ingestSstable` writes an incoming
/// SSTable's raw bytes — a step that runs *before* `SstableReader` ever
/// opens the file.
final class _FailWriteFileAdapter implements StorageAdapter {
  _FailWriteFileAdapter(this._inner, {required this.failOnPath});

  final StorageAdapter _inner;
  final String failOnPath;

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    if (path == failOnPath) {
      throw StorageException('simulated disk-full error', path: path);
    }
    return _inner.writeFile(path, bytes);
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) =>
      _inner.appendFile(path, bytes);
  @override
  Future<Uint8List> readFile(String path) => _inner.readFile(path);
  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      _inner.readFileRange(path, offset, length);
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

void main() {
  setUp(MemoryStorageAdapter.releaseAllLocks);
  tearDown(MemoryStorageAdapter.releaseAllLocks);

  group('QuarantineReason coverage (A3 / WI-7)', () {
    test('corruptedSstable — checksum-invalid file', () async {
      final localAdapter = MemoryStorageAdapter();
      final cloudAdapter = MemorySyncAdapter();
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        localAdapter,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(1000, 0),
        const Hlc(1001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$filename',
        Uint8List.fromList(List.filled(64, 0xAB)), // fails footer checksum
      );

      final result = await _makeEngine(
        store,
        cloudAdapter,
        localAdapter,
      ).pull();

      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.corruptedSstable),
      );
      await store.close();
    });

    test('storageError — local write failure while linking the incoming '
        'file', () async {
      final innerLocal = MemoryStorageAdapter();
      final cloudAdapter = MemorySyncAdapter();

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(2000, 0),
        const Hlc(2001, 0),
      );

      // The fault must wrap the STORE's own internal adapter — the one
      // KvStoreImpl.open is given — because `ingestSstable`'s raw-bytes
      // write goes through that adapter directly, not through the separate
      // `localAdapter` parameter SyncEngine otherwise uses for its own
      // fileExists/push bookkeeping.
      final wrapped = _FailWriteFileAdapter(
        innerLocal,
        failOnPath: '$_dbDir/sst/$filename',
      );
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        wrapped,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );

      // Any well-formed SSTable works here — the fault fires before
      // SstableReader ever opens it.
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$filename',
        _buildHostileKeySstable(
          _buildRawInternalKey(claimedNsLen: 2, nsBytes: [0x6e, 0x73]), // "ns"
        ),
      );

      final result = await _makeEngine(store, cloudAdapter, wrapped).pull();

      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.storageError),
      );
      await store.close();
    });

    test('invalidFormat — well-formed block framing, non-UTF-8 namespace '
        'bytes', () async {
      final localAdapter = MemoryStorageAdapter();
      final cloudAdapter = MemorySyncAdapter();
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        localAdapter,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(3000, 0),
        const Hlc(3001, 0),
      );
      // claimedNsLen matches nsBytes.length exactly (1), so the slice
      // succeeds — but 0x80 alone is not valid UTF-8 (a lone continuation
      // byte with no lead byte), so utf8.decode throws FormatException.
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$filename',
        _buildHostileKeySstable(
          _buildRawInternalKey(claimedNsLen: 1, nsBytes: [0x80]),
        ),
      );

      final result = await _makeEngine(
        store,
        cloudAdapter,
        localAdapter,
      ).pull();

      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.invalidFormat),
      );
      await store.close();
    });

    test('structuralBoundsViolation — claimed namespace length exceeds the '
        'key\'s actual bytes', () async {
      final localAdapter = MemoryStorageAdapter();
      final cloudAdapter = MemorySyncAdapter();
      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        localAdapter,
        config: KvStoreConfig.forTesting(),
        deviceId: _localDeviceId,
      );

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(4000, 0),
        const Hlc(4001, 0),
      );
      // claimedNsLen (200) vastly exceeds the actual nsBytes (2) — and the
      // whole internal key buffer, which is far shorter than 1 + 200 bytes
      // — so `internalKey.sublist(1, 1 + 200)` throws RangeError.
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$filename',
        _buildHostileKeySstable(
          _buildRawInternalKey(claimedNsLen: 200, nsBytes: [0x6e, 0x73]),
        ),
      );

      final result = await _makeEngine(
        store,
        cloudAdapter,
        localAdapter,
      ).pull();

      expect(result.quarantined, hasLength(1));
      expect(
        result.quarantined.single.reason,
        equals(QuarantineReason.structuralBoundsViolation),
      );
      await store.close();
    });

    test(
      'outOfMemory — ingest exhausts memory (defence-in-depth catch)',
      () async {
        final localAdapter = MemoryStorageAdapter();
        final cloudAdapter = MemorySyncAdapter();

        final filename = SstableInfo.flushName(
          _peerDeviceId,
          const Hlc(5000, 0),
          const Hlc(5001, 0),
        );
        // The bytes are irrelevant: `_OutOfMemoryOnIngestStore.ingestSstable`
        // throws `OutOfMemoryError` before the content is examined.
        await cloudAdapter.upload(
          '$_syncRoot/sstables/$filename',
          _buildHostileKeySstable(
            _buildRawInternalKey(claimedNsLen: 2, nsBytes: [0x6e, 0x73]),
          ),
        );

        final result = await _makeEngine(
          _OutOfMemoryOnIngestStore(),
          cloudAdapter,
          localAdapter,
        ).pull();

        expect(result.quarantined, hasLength(1));
        expect(
          result.quarantined.single.reason,
          equals(QuarantineReason.outOfMemory),
        );
      },
    );
  });

  group('sub-floor deferral (A3 / WI-7)', () {
    test('sub-floor StaleSstableIngest → deferred, not quarantined, never '
        'persisted', () async {
      final localAdapter = MemoryStorageAdapter();
      final cloudAdapter = MemorySyncAdapter();

      final filename = SstableInfo.flushName(
        _peerDeviceId,
        const Hlc(6000, 0),
        const Hlc(6001, 0),
      );
      await cloudAdapter.upload(
        '$_syncRoot/sstables/$filename',
        _buildHostileKeySstable(
          _buildRawInternalKey(claimedNsLen: 2, nsBytes: [0x6e, 0x73]),
        ),
      );

      final store = _SubFloorOnIngestStore(
        maxHlc: const Hlc(6001, 0),
        floor: const Hlc(9000, 0),
      );
      final result = await _makeEngine(
        store,
        cloudAdapter,
        localAdapter,
      ).pull();

      // A sub-floor file is transient (it may become ingestable once a newer
      // consolidated file supersedes it), so it is reported as a `deferred`
      // entry — a structurally distinct type from `quarantined` so the host can
      // never mistake a self-healing retry for permanent data loss.
      expect(result.deferred, hasLength(1));
      expect(result.quarantined, isEmpty);
      // ...and it is NEVER written to the durable quarantine log — persisting a
      // transient deferral would be exactly the confusion the split prevents.
      expect(
        store.appendQuarantineCalls,
        equals(0),
        reason:
            'a transient sub-floor deferral must never reach the durable '
            'quarantine log',
      );
      final d = result.deferred.single;
      expect(d.filename, equals(filename));
      expect(d.peerDeviceId, equals(_peerDeviceId));
      expect(d.floor, equals(const Hlc(9000, 0)));
    });
  });
}
