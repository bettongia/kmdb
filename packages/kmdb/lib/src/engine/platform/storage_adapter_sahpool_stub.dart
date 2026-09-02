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

// coverage:ignore-file
// Stub for platforms where dart:js_interop is unavailable (native VM).
// StorageAdapterSahPool requires OPFS (browser-only) and cannot be used on
// these platforms. Attempting to instantiate it throws [UnsupportedError].
//
// This file exists solely so `StorageAdapterSahPool` is a resolvable,
// constructible *name* on native platforms — the barrel
// (`packages/kmdb/lib/kmdb.dart`) exports the concrete type unconditionally
// (0.10.01 WI-9 Phase C, release-ninja finding #2), so the name must
// type-check everywhere even though only the web branch is ever functional.
// Mirrors `local_directory_adapter_stub.dart`'s convention exactly: throw in
// the constructor, and give every public member (interface and non-interface
// alike) a throwing body — see `storage_adapter_sahpool_export.dart`'s doc
// comment for why the stub must mirror the concrete class's *full* public
// surface, including the non-interface `close()`.

import 'dart:typed_data';

import 'storage_adapter_interface.dart';

/// Unsupported stub of `StorageAdapterSahPool` for native (non-web)
/// platforms.
///
/// The real `StorageAdapterSahPool` requires `dart:js_interop` (OPFS via a
/// Web Worker) and is therefore unavailable outside the browser. All members
/// throw [UnsupportedError]. Use [StorageAdapterNative] on native platforms.
final class StorageAdapterSahPool implements StorageAdapter {
  /// Always throws [UnsupportedError].
  StorageAdapterSahPool() {
    throw UnsupportedError(
      'StorageAdapterSahPool is not supported on native platforms; it '
      'requires OPFS/dart:js_interop. Use StorageAdapterNative instead.',
    );
  }

  static Never _unsupported() => throw UnsupportedError(
    'StorageAdapterSahPool is not supported on native platforms.',
  );

  @override
  Future<Uint8List> readFile(String path) => _unsupported();

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      _unsupported();

  @override
  Future<void> writeFile(String path, Uint8List bytes) => _unsupported();

  @override
  Future<void> appendFile(String path, Uint8List bytes) => _unsupported();

  @override
  Future<void> syncFile(String path) => _unsupported();

  @override
  Future<void> syncDir(String dirPath) => _unsupported();

  @override
  Future<void> deleteFile(String path) => _unsupported();

  @override
  Future<bool> fileExists(String path) => _unsupported();

  @override
  Future<List<String>> listFiles(String dirPath, {String? extension}) =>
      _unsupported();

  @override
  Future<List<String>> listFilesRecursive(String dirPath) => _unsupported();

  @override
  Future<int> fileSize(String path) => _unsupported();

  @override
  Future<void> renameFile(String from, String to) => _unsupported();

  @override
  Future<void> createDirectory(String dirPath) => _unsupported();

  @override
  Future<void> acquireLock(String lockPath) => _unsupported();

  @override
  Future<void> releaseLock(String lockPath) => _unsupported();

  /// Always throws [UnsupportedError].
  ///
  /// Not part of the [StorageAdapter] interface — mirrors the concrete web
  /// `StorageAdapterSahPool.close()` so cross-platform consumer code calling
  /// `adapter.close()` compiles on native as well as web.
  Future<void> close() => _unsupported();
}
