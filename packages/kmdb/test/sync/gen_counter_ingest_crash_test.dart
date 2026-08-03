// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Mandatory fault-injection regression for the 0.10.01 WI-13 ingest-side
/// gen bump's crash-safety ordering (test surface item #5).
///
/// [LsmEngine.ingestAt0] bumps the local `$$genstate` counter for every
/// namespace found in the ingested SSTable (via a WAL-durable [WriteBatch])
/// *before* it appends the [VersionEdit] that admits the file into the
/// Manifest. This test proves the ordering is crash-safe in the direction
/// that matters: a crash between the two leaves the counter bumped but the
/// file un-admitted — a harmless spurious cache miss on next open, never a
/// stale hit. The reverse ordering (manifest-then-bump) would instead leave
/// new data visible under a stale counter — a real correctness bug — but
/// that ordering does not exist in the shipped code, so it is documented
/// here rather than separately coded (per the plan's test surface item #5).
///
/// Uses [FaultyStorageAdapter] wrapped by a manifest-append interceptor that
/// simulates a power-loss crash at the exact instant [ManifestWriter.append]
/// would write the ingest's own [VersionEdit] — i.e. strictly *after* the
/// gen-bump WriteBatch's WAL frame has been appended+fsynced (durable), and
/// strictly *before* the manifest edit that would admit the ingested file.
library;

import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/kvstore/kv_store_impl.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_interface.dart';
import 'package:kmdb/src/engine/sstable/sstable_info.dart';
import 'package:kmdb/src/engine/sstable/sstable_writer.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

const _dbDir = '/db';
const _deviceIdB = 'deviceb1';

/// Thrown by [_CrashOnManifestAppendAdapter] when it intercepts the armed
/// manifest write — stands in for the process dying at that exact instant.
final class _SimulatedCrash implements Exception {
  const _SimulatedCrash();
  @override
  String toString() => '_SimulatedCrash: process died before manifest write';
}

/// Wraps [FaultyStorageAdapter], forwarding every call unchanged, except that
/// — once [armed] — the *next* [appendFile] call targeting a `MANIFEST-*`
/// file triggers [FaultyStorageAdapter.crash] and throws [_SimulatedCrash]
/// instead of performing the write.
///
/// This lets a test simulate a crash landing at a precise point *inside* a
/// single async engine method ([LsmEngine.ingestAt0]) that the test has no
/// other way to interrupt — the interception point is chosen to fall
/// strictly between the WAL-durable gen-bump write (a different file: a
/// `wal-*.log` path, never intercepted here) and the ingest's own manifest
/// append.
final class _CrashOnManifestAppendAdapter implements StorageAdapter {
  _CrashOnManifestAppendAdapter(this._inner);

  final FaultyStorageAdapter _inner;

  /// Set by the test immediately before the operation whose manifest append
  /// should trigger the simulated crash.
  bool armed = false;

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    if (armed && path.contains('MANIFEST')) {
      armed = false;
      _inner.crash();
      throw const _SimulatedCrash();
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

/// Builds a single-entry SSTable containing a document put for
/// `ns/keyHex = value` at [hlc].
Uint8List _buildSingleEntrySst({
  required String ns,
  required String keyHex,
  required Uint8List value,
  required Hlc hlc,
}) {
  final writer = SstableWriter()
    ..add(
      KeyCodec.encodeInternalKey(
        ns,
        KeyCodec.keyToBytes(keyHex),
        hlc,
        RecordType.put,
      ),
      value,
    );
  return writer.finish();
}

void main() {
  group('LsmEngine.ingestAt0 — gen-bump/manifest-append crash ordering '
      '(WI-13, test surface #5)', () {
    test('a crash between the WAL-durable gen bump and the ingest manifest '
        'append leaves the counter bumped and the file un-admitted — never '
        'the reverse', () async {
      final inner = FaultyStorageAdapter();
      final wrapped = _CrashOnManifestAppendAdapter(inner);

      final (store, _) = await KvStoreImpl.open(
        _dbDir,
        wrapped,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _deviceIdB,
      );

      const ns = 'notes';
      const keyHex = '00000000000070008000000000000cc1';
      final value = Uint8List.fromList([9, 9]);
      final hlc = Hlc(DateTime.now().millisecondsSinceEpoch + 10000, 0);
      final sstable = _buildSingleEntrySst(
        ns: ns,
        keyHex: keyHex,
        value: value,
        hlc: hlc,
      );
      final filename = SstableInfo.flushName('devicea1', hlc, hlc);

      // Arm the crash for the very next manifest append — this is the
      // one ingestAt0 itself will attempt, strictly after its
      // WAL-durable gen-bump WriteBatch has completed.
      wrapped.armed = true;
      await expectLater(
        store.ingestSstable(filename, sstable),
        throwsA(isA<_SimulatedCrash>()),
      );

      // Reopen using the *unwrapped* inner adapter directly — its state
      // now reflects exactly what a real crash would have left durable:
      // the gen-bump's WAL frame (synced before the intercepted
      // manifest write was ever attempted) survives, but the ingest's
      // own manifest edit was never written.
      final (reopened, _) = await KvStoreImpl.open(
        _dbDir,
        inner,
        config: const KvStoreConfig(fsyncOnWrite: true),
        deviceId: _deviceIdB,
      );

      // The counter bump survived via WAL replay — a spurious but
      // harmless state (no corresponding data ever arrived).
      expect(
        await reopened.meta.getGenerationCounter(ns),
        equals(1),
        reason:
            'the WAL-durable gen bump must survive the crash via WAL '
            'replay, even though the ingest it belonged to never '
            'completed',
      );

      // The ingested SSTable's data must NOT be visible — no manifest
      // edit was ever durably committed for it, so crash recovery's
      // orphan sweep must have excluded/removed it. This is the safe
      // direction: a spurious cache miss (gen bumped, no new data),
      // never the unsafe reverse (new data visible under a stale gen).
      expect(
        await reopened.get(ns, keyHex),
        isNull,
        reason:
            'a crash before the manifest edit must leave the ingested '
            'data completely absent — never partially visible',
      );

      await reopened.close();
    });
  });
}
