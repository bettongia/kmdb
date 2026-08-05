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

/// Fault-injection regression for the SC-16 plan's Q4 (versioning
/// correctness): [KmdbCollection.put] writes the document and its `$ver:`
/// entry in a single [WriteBatch] / WAL frame (review finding H2), so a crash
/// mid-write can never leave the pair in a split state — the update either
/// fully lands (doc advances, chain length 2) or fully does not (doc and
/// chain unchanged), never a fork or a partially-applied write.
///
/// Per CLAUDE.md, durability/crash-safety must be exercised with fault
/// injection rather than the golden path alone — the in-memory adapter used
/// elsewhere in this directory cannot exhibit this class of bug because it
/// never loses buffered data. This test uses [FaultyStorageAdapter], wrapped
/// by an adapter that simulates a power-loss crash at the exact instant the
/// *second* write's WAL frame would be appended — strictly after the first
/// write (the initial insert) is fully durable.
library;

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

import '../support/faulty_storage_adapter.dart';

/// Thrown by [_CrashOnWalAppendAdapter] when it intercepts the armed WAL
/// append — stands in for the process dying at that exact instant.
final class _SimulatedCrash implements Exception {
  const _SimulatedCrash();
  @override
  String toString() => '_SimulatedCrash: process died before WAL append';
}

/// Wraps [FaultyStorageAdapter], forwarding every call unchanged, except that
/// — once [armed] — the *next* [appendFile] call targeting a `wal-*.log` file
/// triggers [FaultyStorageAdapter.crash] and throws [_SimulatedCrash] instead
/// of performing the write.
///
/// This models a crash landing before the write's bytes ever reach even the
/// volatile page cache — the strictest form of "this write never happened".
/// Combined with `fsyncOnWrite: true` (the default), the preceding write is
/// already fully durable by the time this one is attempted, so the resulting
/// state after reopening the *unwrapped* inner adapter must show exactly the
/// pre-crash document — never a partially-applied doc/`$ver:` pair.
final class _CrashOnWalAppendAdapter implements StorageAdapter {
  _CrashOnWalAppendAdapter(this._inner);

  final FaultyStorageAdapter _inner;

  /// Set by the test immediately before the write whose WAL append should
  /// trigger the simulated crash.
  bool armed = false;

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    if (armed && path.contains('wal-')) {
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

void main() {
  group('KmdbCollection.put — crash-safety of the doc/\$ver: pair', () {
    test('a crash mid-write during an update leaves the doc and its version '
        'chain unchanged — never a fork or a partial update', () async {
      final inner = FaultyStorageAdapter();
      final wrapped = _CrashOnWalAppendAdapter(inner);

      final db = await KmdbDatabase.open(
        path: '/db',
        adapter: wrapped,
        config: const KvStoreConfig(fsyncOnWrite: true),
      );
      final col = db.rawCollection('notes');

      // First write: fully durable (WAL append + fsync both succeed).
      final inserted = await col.insert({'title': 'Original'});
      final key = inserted['_id'] as String;

      // Arm the crash for the very next WAL append — the update below.
      wrapped.armed = true;
      await expectLater(
        col.put({'_id': key, 'title': 'Updated'}),
        throwsA(isA<_SimulatedCrash>()),
      );

      // Reopen using the *unwrapped* inner adapter directly — its state
      // now reflects exactly what a real crash would have left durable:
      // the update's WAL frame (doc + $ver: entry, one atomic batch) was
      // never appended at all, so it must be entirely absent.
      final reopened = await KmdbDatabase.open(
        path: '/db',
        adapter: inner,
        config: const KvStoreConfig(fsyncOnWrite: true),
      );
      final reCol = reopened.rawCollection('notes');

      // Exactly one document exists, unchanged from the first write.
      final current = await reCol.get(key);
      expect(current, isNotNull);
      expect(
        current!['title'],
        equals('Original'),
        reason:
            'the update must not be partially applied — the document '
            'must show its pre-crash value entirely',
      );

      // The version chain did not advance — no forked or partial entry.
      final versions = await reCol.getVersions(key);
      expect(
        versions,
        hasLength(1),
        reason:
            'the \$ver: chain must not advance when the paired document '
            'write never landed — one atomic WAL frame, all or nothing',
      );

      await reopened.close();
    });
  });
}
