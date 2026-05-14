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

/// Abstracts file I/O so the LSM engine can run on native (dart:io),
/// web (OPFS), and in-memory (tests) without conditional logic in engine code.
///
/// All paths are absolute. Callers are responsible for ensuring parent
/// directories exist before writing.
abstract interface class StorageAdapter {
  /// Reads the entire contents of the file at [path].
  ///
  /// Throws [StorageException] if the file does not exist.
  Future<Uint8List> readFile(String path);

  /// Reads [length] bytes from [path] starting at [offset].
  ///
  /// Used by the SSTable reader for random-access block reads without loading
  /// the entire file. Throws [StorageException] if the file does not exist or
  /// the range is out of bounds.
  Future<Uint8List> readFileRange(String path, int offset, int length);

  /// Writes [bytes] to [path], replacing any existing content.
  Future<void> writeFile(String path, Uint8List bytes);

  /// Appends [bytes] to the end of [path].
  ///
  /// Creates the file if it does not exist. Used exclusively by the WAL writer
  /// and Manifest writer for their append-only log formats.
  Future<void> appendFile(String path, Uint8List bytes);

  /// Flushes OS write buffers for [path] to durable storage (fsync).
  ///
  /// Called after every WAL record append and after writing a new SSTable.
  /// No-op in the memory adapter and when [KvStoreConfig.fsyncOnWrite] is
  /// false (test mode).
  Future<void> syncFile(String path);

  /// Syncs the directory entry at [dirPath] to durable storage.
  ///
  /// Required on Linux after creating a new file so the directory entry
  /// itself is flushed. No-op on macOS/Windows/web/memory.
  Future<void> syncDir(String dirPath);

  /// Deletes the file at [path]. No-op if the file does not exist.
  Future<void> deleteFile(String path);

  /// Returns true if a file exists at [path].
  Future<bool> fileExists(String path);

  /// Returns the names (not full paths) of all files in [dirPath].
  ///
  /// If [extension] is provided (e.g. `'.sst'`), only files with that
  /// extension are returned. Returns an empty list if the directory is empty
  /// or does not exist.
  Future<List<String>> listFiles(String dirPath, {String? extension});

  /// Returns the size in bytes of the file at [path].
  ///
  /// Throws [StorageException] if the file does not exist.
  Future<int> fileSize(String path);

  /// Atomically renames [from] to [to].
  ///
  /// On POSIX this is a single `rename(2)` syscall — the linearisation point
  /// used by the Manifest writer when updating the CURRENT file. Both paths
  /// must be on the same filesystem.
  Future<void> renameFile(String from, String to);

  /// Creates [dirPath] and all intermediate directories if they do not exist.
  Future<void> createDirectory(String dirPath);

  /// Acquires an exclusive lock on [lockPath].
  ///
  /// Creates the lock file if it does not exist. Throws [LockException] if
  /// the lock is already held by another process or adapter instance.
  Future<void> acquireLock(String lockPath);

  /// Releases the exclusive lock on [lockPath].
  Future<void> releaseLock(String lockPath);
}

/// Thrown when a file operation fails (not found, permission denied, I/O
/// error, etc.).
final class StorageException implements Exception {
  const StorageException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() => path != null
      ? 'StorageException($path): $message'
      : 'StorageException: $message';
}

/// Thrown when an exclusive database lock cannot be acquired because another
/// process already holds it.
final class LockException implements Exception {
  const LockException(this.lockPath);

  final String lockPath;

  @override
  String toString() =>
      'LockException: cannot acquire exclusive lock on $lockPath — '
      'another process may have the database open';
}
