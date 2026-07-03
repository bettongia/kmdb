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

// This file is native-only and imports dart:io directly.
// It must not be imported on web platforms.

import 'dart:io';
import 'dart:typed_data';

import '../../engine/util/xxhash.dart';
import '../sync_context.dart';
import '../sync_storage_adapter.dart';

/// A [SyncStorageAdapter] backed by the local filesystem.
///
/// Suitable for use with NAS mounts, SMB/CIFS shares, locally-synced cloud
/// folders (e.g. a Dropbox or OneDrive folder), or any directory accessible
/// via `dart:io`.
///
/// ## Cancellation
///
/// This adapter calls `ctx?.throwIfExpired()` before each filesystem I/O
/// call. If the [SyncContext] is cancelled or has exceeded its deadline,
/// [SyncCancelledException] is thrown promptly before the I/O is attempted.
///
/// ## ETag implementation
///
/// The ETag is an XXH64 content hash of the file bytes, formatted as a
/// zero-padded 16-character hex string. This is collision-resistant and
/// correctly detects changes even when two versions of a file are the same
/// size.
///
/// ## compareAndSwap atomicity
///
/// Atomicity of [compareAndSwap] depends on the directory the adapter is
/// pointed at:
///
/// * **True local filesystem (default mode, `atomicCas: false`):** the current
///   implementation is a best-effort read-check-write; two processes can both
///   pass the check and write — the second wins. Atomic-CAS is **not**
///   advertised, so `ConsolidationCoordinator` will skip consolidation against
///   this adapter (loss-free; SSTables simply accumulate un-consolidated).
/// * **Cloud-synced folder (Dropbox / OneDrive / iCloud-as-local-FS):** the
///   folder is an eventually-consistent replica and *cannot* honestly provide
///   atomic CAS across devices. Always construct with `atomicCas: false` —
///   the default.
/// * **Opt-in atomic mode (`atomicCas: true`):** the create-if-absent path
///   uses `File.create(exclusive: true)` (POSIX `O_CREAT|O_EXCL`), which is
///   atomic on local POSIX filesystems and Windows. The update-if-match path
///   acquires a `FileLock.blockingExclusive` advisory lock before reading the
///   current ETag, ensuring the read-compare-write is serialised against other
///   cooperative processes on the same host.
///
/// ## Usage
///
/// ```dart
/// // Synced folder (the safe default): consolidation is skipped.
/// final adapter = LocalDirectoryAdapter('/Users/me/Dropbox/kmdb-sync');
///
/// // True local disk shared between processes on the same host: opt in.
/// final adapter = LocalDirectoryAdapter('/var/lib/kmdb-sync', atomicCas: true);
/// ```
final class LocalDirectoryAdapter implements SyncStorageAdapter {
  /// Creates a [LocalDirectoryAdapter] rooted at [rootPath].
  ///
  /// [rootPath] is the base directory for all remote paths. It is created if
  /// it does not exist.
  ///
  /// [atomicCas] opts in to atomic CAS primitives: `File.create(exclusive: true)`
  /// for create-if-absent and an advisory lock for update-if-match. Only set
  /// this when the directory is on a true local filesystem (not a cloud-synced
  /// replica). Defaults to `false`; see the class doc-comment for the trade-off.
  LocalDirectoryAdapter(this.rootPath, {this.atomicCas = false});

  /// Base directory for all remote paths.
  final String rootPath;

  /// Caller-declared atomic-CAS capability for this directory. See class doc.
  final bool atomicCas;

  @override
  bool get providesAtomicCas => atomicCas;

  /// Resolves a remote path to a full filesystem path.
  String _resolve(String remotePath) => '$rootPath/$remotePath';

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    final dir = Directory(_resolve(remoteDir));
    if (!dir.existsSync()) return [];
    final results = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (extension != null && !name.endsWith(extension)) continue;
      results.add(name);
    }
    return results;
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    final file = File(_resolve(remotePath));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    final file = File(_resolve(remotePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    final file = File(_resolve(remotePath));
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    final resolvedPath = _resolve(path);
    final file = File(resolvedPath);

    if (ifMatchEtag == null) {
      await file.parent.create(recursive: true);
      if (atomicCas) {
        return _createExclusive(file, newBytes);
      }
      // Non-atomic fallback: best-effort read-check-write. The coordinator
      // gates on [providesAtomicCas] so this path is only reached when the
      // caller has acknowledged the racy semantics (atomicCas: false).
      if (file.existsSync()) return false;
      return _writeViaTempRename(file, newBytes);
    }

    // ETag provided — update only if the current ETag matches.
    if (atomicCas) {
      return _updateWithLock(file, resolvedPath, newBytes, ifMatchEtag);
    }
    // Non-atomic fallback: racy read-check-write.
    final currentEtag = await getEtag(path);
    if (currentEtag != ifMatchEtag) return false;
    return _writeViaTempRename(file, newBytes);
  }

  /// Atomically creates [file] with [bytes] using `File.create(exclusive: true)`
  /// (POSIX `O_CREAT|O_EXCL`). Returns `false` if the file already exists.
  Future<bool> _createExclusive(File file, Uint8List bytes) async {
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      // File already exists — another writer won the race.
      return false;
    }
    // File was exclusively created; write the content and fsync.
    await file.writeAsBytes(bytes, flush: true);
    return true;
  }

  /// Monotonic counter mixed into [_writeViaTempRename]'s temp filename.
  ///
  /// A microsecond timestamp alone is not a reliable uniqueness source under
  /// concurrent contention: multiple `compareAndSwap` calls issued in the
  /// same event-loop turn can observe the same
  /// `DateTime.now().microsecondsSinceEpoch` value (timer resolution varies
  /// by platform), which previously let two concurrent writers race to
  /// create/write the *same* temp filename — silently corrupting whichever
  /// wrote last on POSIX, or failing outright with a Windows sharing
  /// violation ("being used by another process").
  static int _tmpCounter = 0;

  /// Writes [bytes] to [file] via a temp-file rename. Returns `true` on
  /// success; swallows rename errors (another concurrent writer won) and
  /// returns `false`.
  Future<bool> _writeViaTempRename(File file, Uint8List bytes) async {
    final tmpPath =
        '${file.path}.cas-tmp-${DateTime.now().microsecondsSinceEpoch}'
        '-${_tmpCounter++}';
    final tmp = File(tmpPath);
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(file.path);
      return true;
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Updates [file] with [newBytes] if and only if the current content hash
  /// matches [expectedEtag]. Uses an advisory lock to serialise concurrent
  /// writers within the same process (and across processes on the same host
  /// that cooperate via `fcntl` advisory locks).
  Future<bool> _updateWithLock(
    File file,
    String resolvedPath,
    Uint8List newBytes,
    String expectedEtag,
  ) async {
    if (!file.existsSync()) return false;
    // Open with `FileMode.append` (read/write, no truncation) rather than
    // write-only: the locked ETag re-read below must go through *this same*
    // handle. `RandomAccessFile.lock` maps to `flock`/`fcntl` advisory locks
    // on POSIX (cooperative — a plain read via an unrelated handle is
    // unaffected) but to `LockFileEx` on Windows, which is a *mandatory*
    // lock — any other handle, even from the same process, that touches the
    // locked byte range is denied access. Reading the ETag via a separate
    // `file.readAsBytes()` call (a second, unrelated handle) therefore
    // deadlocked against our own lock on Windows. A handle always retains
    // access to byte ranges it holds the lock on, so reading through `raf`
    // itself works on every platform.
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.blockingExclusive);
      // Re-read ETag inside the lock so any write that completed before we
      // acquired the lock is visible.
      final length = await raf.length();
      await raf.setPosition(0);
      final lockedBytes = await raf.read(length);
      final lockedEtag = XxHash64.toHex(XxHash64.digest(lockedBytes));
      if (lockedEtag != expectedEtag) return false;
      return _writeViaTempRename(file, newBytes);
    } finally {
      try {
        await raf.unlock();
      } catch (_) {}
      await raf.close();
    }
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    final file = File(_resolve(path));
    if (!file.existsSync()) return null;
    // Compute an XXH64 content hash as the ETag. This is collision-resistant
    // and correctly detects when two files have the same size but different
    // content — which the Phase 5 file-size approximation could not.
    final bytes = await file.readAsBytes();
    return XxHash64.toHex(XxHash64.digest(bytes));
  }
}
