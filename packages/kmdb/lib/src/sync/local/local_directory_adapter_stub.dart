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

// Stub for platforms where dart:io is unavailable (web/WASM).
// LocalDirectoryAdapter requires filesystem access and cannot be used on these
// platforms. Attempting to instantiate it throws [UnsupportedError].

import 'dart:typed_data';

import '../sync_storage_adapter.dart';

/// Unsupported stub of [LocalDirectoryAdapter] for web/WASM platforms.
///
/// [LocalDirectoryAdapter] requires `dart:io` and is therefore unavailable on
/// web. All methods throw [UnsupportedError]. Use [MemorySyncAdapter] in tests
/// or a cloud adapter (e.g. a future `GoogleDriveAdapter`) on web.
final class LocalDirectoryAdapter implements SyncStorageAdapter {
  /// Always throws [UnsupportedError].
  LocalDirectoryAdapter(String rootPath) {
    throw UnsupportedError(
      'LocalDirectoryAdapter is not supported on web/WASM. '
      'Use a cloud-backed SyncStorageAdapter instead.',
    );
  }

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');

  @override
  Future<Uint8List?> download(String remotePath) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');

  @override
  Future<void> upload(String remotePath, Uint8List bytes) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');

  @override
  Future<void> delete(String remotePath) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
  }) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');

  @override
  Future<String?> getEtag(String path) =>
      throw UnsupportedError('LocalDirectoryAdapter is not supported on web.');
}
