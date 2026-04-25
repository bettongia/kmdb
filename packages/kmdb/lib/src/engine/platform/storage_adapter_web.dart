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

// coverage:ignore-file
// This file is compiled only when `dart.library.js_interop` is available
// (i.e. on web targets). It must not import `dart:io`.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'storage_adapter_interface.dart';

// ── JS interop extensions for directory iteration ─────────────────────────────
//
// `package:web` does not yet expose the async iterator on
// `FileSystemDirectoryHandle`. We declare a minimal extension type here that
// wraps the same underlying object and exposes `values()`.

/// Provides the `values()` async iterator on [web.FileSystemDirectoryHandle].
extension _DirHandleIterExt on web.FileSystemDirectoryHandle {
  // Calls the `values()` method that returns a `FileSystemDirectoryHandle`
  // async iterator (an object whose `next()` returns a Promise).
  @JS('values')
  external _FSHandleAsyncIterator _values();
}

/// Minimal binding to an async iterator of [web.FileSystemHandle] entries.
@JS()
extension type _FSHandleAsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_FSIteratorResult> next();
}

/// The `{done, value}` shape returned by the iterator's `next()`.
@JS()
extension type _FSIteratorResult._(JSObject _) implements JSObject {
  external bool get done;
  external web.FileSystemHandle get value;
}

// ─────────────────────────────────────────────────────────────────────────────

/// Web [StorageAdapter] backed by the browser's Origin Private File System
/// (OPFS).
///
/// OPFS provides a sandboxed, origin-scoped filesystem that persists across
/// browser sessions. It is accessible only from the same origin and is not
/// visible to the user via the normal file picker.
///
/// ## Path mapping
///
/// Paths like `/db/sst/foo.sst` are split on `/`, empty segments are dropped,
/// and each non-final segment is created/opened as a nested OPFS directory.
/// The final segment is the filename.
///
/// ## Locking
///
/// OPFS does not provide cross-process file locking from the main thread.
/// This adapter uses an in-memory set to prevent the same browser tab from
/// opening the same database path twice. Cross-tab access is not prevented;
/// use a `SharedWorker` or `BroadcastChannel` for cross-tab coordination.
///
/// ## Sync
///
/// Writes through the Writable Stream API are durable on close.
/// [syncFile] and [syncDir] are no-ops.
///
/// ## SAHPool
///
/// The SAHPool pattern (Sync Access Handles in a dedicated Web Worker)
/// provides 3–4× better throughput. It should be adopted when the database
/// regularly exceeds 10 MB. See spec §19.
final class StorageAdapterWeb implements StorageAdapter {
  StorageAdapterWeb();

  // In-memory lock table — prevents double-open within the same tab.
  static final _locks = <String>{};

  // ── StorageAdapter ────────────────────────────────────────────────────────

  @override
  Future<Uint8List> readFile(String path) async {
    final (dir, name) = await _resolve(path);
    final web.FileSystemFileHandle handle;
    try {
      handle = await dir.getFileHandle(name).toDart;
    } catch (_) {
      throw StorageException('File not found', path: path);
    }
    final file = await handle.getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    // JSArrayBuffer.toDart returns a ByteBuffer; asUint8List() gives Uint8List.
    return buffer.toDart.asUint8List();
  }

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    final all = await readFile(path);
    if (offset + length > all.length) {
      throw StorageException(
        'Range [$offset, ${offset + length}) out of bounds '
        '(file size ${all.length})',
        path: path,
      );
    }
    return all.sublist(offset, offset + length);
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    final (dir, name) = await _resolve(path, createDirs: true);
    final handle = await dir
        .getFileHandle(name, web.FileSystemGetFileOptions(create: true))
        .toDart;
    final writable = await handle.createWritable().toDart;
    // Uint8List.toJS is provided by dart:js_interop; write() accepts JSAny.
    await writable.write(bytes.toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> appendFile(String path, Uint8List bytes) async {
    // OPFS has no native append mode. Read existing bytes, concatenate, write
    // back. Safe for WAL/Manifest use because web has a single execution thread.
    Uint8List existing;
    try {
      existing = await readFile(path);
    } on StorageException {
      existing = Uint8List(0);
    }
    final combined = Uint8List(existing.length + bytes.length)
      ..setAll(0, existing)
      ..setAll(existing.length, bytes);
    await writeFile(path, combined);
  }

  @override
  Future<void> syncFile(String path) async {
    // OPFS WritableFileStream is durable on close — no explicit fsync needed.
  }

  @override
  Future<void> syncDir(String dirPath) async {
    // No-op on OPFS.
  }

  @override
  Future<void> deleteFile(String path) async {
    final (dir, name) = await _resolve(path);
    try {
      await dir.removeEntry(name).toDart;
    } catch (_) {
      // no-op if not found
    }
  }

  @override
  Future<bool> fileExists(String path) async {
    final (dir, name) = await _resolve(path);
    try {
      await dir.getFileHandle(name).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) async {
    final root = await _storageRoot();
    final segments = _segments(dirPath);
    var dir = root;
    for (final seg in segments) {
      try {
        dir = await dir
            .getDirectoryHandle(
              seg,
              web.FileSystemGetDirectoryOptions(create: false),
            )
            .toDart;
      } catch (_) {
        return []; // directory does not exist
      }
    }

    final results = <String>[];
    // Iterate entries via the async iterator exposed by _DirHandleIterExt.
    final iter = dir._values();
    while (true) {
      final result = await iter.next().toDart;
      if (result.done) break;
      final entry = result.value;
      if (entry.kind != 'file') continue;
      final name = entry.name;
      if (extension != null && !name.endsWith(extension)) continue;
      results.add(name);
    }
    return results;
  }

  @override
  Future<int> fileSize(String path) async => (await readFile(path)).length;

  @override
  Future<void> renameFile(String from, String to) async {
    // OPFS has no atomic rename API (as of 2026). Simulate with read-write-
    // delete. This is safe for the Manifest CURRENT pointer update because the
    // new file is written before the old one is deleted.
    final bytes = await readFile(from);
    await writeFile(to, bytes);
    await deleteFile(from);
  }

  @override
  Future<void> createDirectory(String dirPath) async {
    final root = await _storageRoot();
    final segments = _segments(dirPath);
    var current = root;
    for (final seg in segments) {
      current = await current
          .getDirectoryHandle(
            seg,
            web.FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
    }
  }

  @override
  Future<void> acquireLock(String lockPath) async {
    if (_locks.contains(lockPath)) throw LockException(lockPath);
    _locks.add(lockPath);
    // Write a sentinel file so a stale lock is detectable on next open.
    await writeFile(
      lockPath,
      Uint8List.fromList([0x4C, 0x4F, 0x43, 0x4B]),
    ); // "LOCK"
  }

  @override
  Future<void> releaseLock(String lockPath) async {
    _locks.remove(lockPath);
    await deleteFile(lockPath);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<web.FileSystemDirectoryHandle> _storageRoot() =>
      web.window.navigator.storage.getDirectory().toDart;

  List<String> _segments(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  /// Resolves [path] to `(parentDirHandle, filename)`.
  ///
  /// If [createDirs] is `true`, missing intermediate directories are created.
  Future<(web.FileSystemDirectoryHandle, String)> _resolve(
    String path, {
    bool createDirs = false,
  }) async {
    final segments = _segments(path);
    if (segments.isEmpty) {
      throw StorageException('Cannot resolve empty path', path: path);
    }
    final name = segments.last;
    final dirSegments = segments.sublist(0, segments.length - 1);
    var dir = await _storageRoot();
    for (final seg in dirSegments) {
      dir = await dir
          .getDirectoryHandle(
            seg,
            web.FileSystemGetDirectoryOptions(create: createDirs),
          )
          .toDart;
    }
    return (dir, name);
  }
}
