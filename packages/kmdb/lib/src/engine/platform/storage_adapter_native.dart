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

import 'dart:io';
import 'dart:typed_data';

import 'storage_adapter_interface.dart';

/// Native [StorageAdapter] using [dart:io].
///
/// File locking uses [RandomAccessFile.lock] with [FileLock.exclusive],
/// which maps to `flock(LOCK_EX | LOCK_NB)` on POSIX and `LockFileEx` on
/// Windows. The lock is non-blocking — if the lock is already held,
/// [LockException] is thrown immediately rather than waiting.
///
/// `syncFile` calls [RandomAccessFile.flush] (which issues fsync).
/// `syncDir` opens the directory as a file descriptor and fsyncs it,
/// which is required on Linux to durably persist new directory entries.
/// On macOS and Windows this is a no-op (handled by the OS or not needed).
final class StorageAdapterNative implements StorageAdapter {
  StorageAdapterNative();

  // Tracks open lock file handles so releaseLock can close them.
  final Map<String, RandomAccessFile> _lockHandles = {};

  @override
  Future<Uint8List> readFile(String path) async {
    try {
      return await File(path).readAsBytes();
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    }
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      await raf.setPosition(offset);
      final buf = Uint8List(length);
      final read = await raf.readInto(buf);
      if (read < length) {
        throw StorageException(
          'Requested $length bytes at offset $offset but only $read available',
          path: path,
        );
      }
      return buf;
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    try {
      await File(path).writeAsBytes(bytes, flush: false);
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    }
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      raf = await file.open(mode: FileMode.append);
      await raf.writeFrom(bytes);
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<void> syncFile(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      // A plain read-mode handle (the default `open()` mode) is sufficient
      // for `flush` on POSIX, but Windows' `FlushFileBuffers` requires the
      // handle to have been opened with write access, or it fails with an
      // access-denied error surfaced here as a generic "flush failed"
      // `FileSystemException`. `FileMode.append` grants write access without
      // truncating existing content — but it also auto-creates a missing
      // file, which `syncFile` must not do, so existence is checked first to
      // preserve the "missing file" failure contract.
      if (!await file.exists()) {
        throw StorageException('File not found', path: path);
      }
      raf = await file.open(mode: FileMode.append);
      await raf.flush();
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    } finally {
      await raf?.close();
    }
  }

  @override
  Future<void> syncDir(String dirPath) async {
    // On Linux, syncing the directory fd ensures new directory entries are
    // durable. On macOS/Windows this is unnecessary — the OS guarantees it.
    if (!Platform.isLinux) return;
    RandomAccessFile? raf;
    // coverage:ignore-start
    // Lines below are Linux-only; macOS/Windows tests never reach them because
    // the `if (!Platform.isLinux) return` guard exits early on those platforms.
    try {
      // Opening a directory as a file is Linux-specific.
      raf = await File(dirPath).open();
      await raf.flush();
    } on FileSystemException {
      // Non-fatal: directory sync failures degrade durability but do not
      // corrupt data — the WAL guarantees recovery.
    } finally {
      await raf?.close();
    }
    // coverage:ignore-end
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException catch (e) {
      // Ignore "not found" — delete is specified as a no-op in that case.
      if (e.osError?.errorCode == 2 /* ENOENT */ ) return;
      throw StorageException(e.message, path: path); // coverage:ignore-line
    }
  }

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (extension != null && !name.endsWith(extension)) continue;
      names.add(name);
    }
    return names;
  }

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    // `Directory.list(recursive: true)` yields entity paths prefixed by
    // `dirPath` (e.g. `{dirPath}/ab/cd/manifest.json`), but every vault path
    // is built with a literal `/` separator regardless of platform (see
    // `VaultStore.blobsDir`/`hashDir`), while dart:io emits the platform's
    // native separator (`\` on Windows). Normalize both sides to `/` before
    // relativising so the returned paths are always e.g. `ab/cd/manifest.json`
    // — no leading separator. A leading separator would make
    // `_collectSubdirsInto`'s `path.indexOf('/')` / `slash > 0` guard
    // silently skip every entry, re-creating the exact silent-empty failure
    // this method exists to fix.
    final normalizedDir = dirPath.replaceAll('\\', '/');
    final prefix = normalizedDir.endsWith('/')
        ? normalizedDir
        : '$normalizedDir/';
    final paths = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      // Every entity yielded by `dir.list()` is necessarily nested under
      // `dirPath`, so `normalized` is guaranteed to start with `prefix`.
      paths.add(normalized.substring(prefix.length));
    }
    return paths;
  }

  @override
  Future<int> fileSize(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: path);
    }
  }

  @override
  Future<void> renameFile(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: from);
    }
  }

  @override
  Future<void> createDirectory(String dirPath) async {
    try {
      await Directory(dirPath).create(recursive: true);
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: dirPath);
    }
  }

  @override
  Future<void> acquireLock(String lockPath) async {
    if (_lockHandles.containsKey(lockPath)) return; // already held by us
    try {
      final raf = await File(lockPath).open(mode: FileMode.writeOnlyAppend);
      try {
        // Non-blocking exclusive lock (FileLock.exclusive). Throws immediately
        // if another process holds the lock — we surface this as LockException.
        await raf.lock(FileLock.exclusive);
      } catch (_) {
        // coverage:ignore-start
        // POSIX fcntl locks are per-process, so within-process tests cannot
        // trigger this path. Cross-process lock contention is verified manually
        // (RC-3 in docs/spec/28_release_checklist.md).
        await raf.close();
        throw LockException(lockPath);
        // coverage:ignore-end
      }
      _lockHandles[lockPath] = raf;
    } on FileSystemException catch (e) {
      throw StorageException(e.message, path: lockPath);
    }
  }

  @override
  Future<void> releaseLock(String lockPath) async {
    final raf = _lockHandles.remove(lockPath);
    if (raf == null) return;
    await raf.unlock();
    await raf.close();
  }
}
