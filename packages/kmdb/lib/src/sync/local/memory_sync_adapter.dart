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

import '../sync_storage_adapter.dart';

/// In-memory [SyncStorageAdapter] for tests.
///
/// All file contents live in a [Map] keyed by full remote path. Operations are
/// synchronous internally — [Future]s complete in the same microtask.
///
/// ## Compare-and-swap semantics
///
/// [compareAndSwap] implements true atomic CAS semantics: the version counter
/// is checked and incremented within the same synchronous operation, so no
/// other operation can interleave between the check and the write. This makes
/// [MemorySyncAdapter] suitable for testing the lease acquisition protocol.
///
/// When [ifMatchEtag] is `null`, the write succeeds only if the file does not
/// exist (if-none-match: * semantics). When [ifMatchEtag] is a string, the
/// write succeeds only if the current version matches the given ETag.
///
/// ## Example
///
/// ```dart
/// final adapter = MemorySyncAdapter();
/// await adapter.upload('sync/sstables/a.sst', bytes);
/// final files = await adapter.list('sync/sstables', extension: '.sst');
/// ```
final class MemorySyncAdapter implements SyncStorageAdapter {
  /// Creates an empty [MemorySyncAdapter].
  MemorySyncAdapter();

  /// Internal file storage. Keys are full remote paths.
  final Map<String, Uint8List> _files = {};

  /// ETag counters. Each write increments the counter for that path.
  final Map<String, int> _versions = {};

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) async {
    // Normalise: ensure remoteDir ends with '/' for prefix matching.
    final prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    final results = <String>[];
    for (final path in _files.keys) {
      if (!path.startsWith(prefix)) continue;
      // Only include direct children (no deeper nested paths).
      final remainder = path.substring(prefix.length);
      if (remainder.contains('/')) continue;
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<Uint8List?> download(String remotePath) async {
    final data = _files[remotePath];
    if (data == null) return null;
    return Uint8List.fromList(data);
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    _files[remotePath] = Uint8List.fromList(bytes);
    _versions[remotePath] = (_versions[remotePath] ?? 0) + 1;
  }

  @override
  Future<void> delete(String remotePath) async {
    _files.remove(remotePath);
    _versions.remove(remotePath);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
  }) async {
    // All of this runs synchronously within one microtask — true atomic CAS.
    final currentVersion = _versions[path];
    final fileExists = _files.containsKey(path);

    if (ifMatchEtag == null) {
      // if-none-match: * semantics — succeed only if file does NOT exist.
      if (fileExists) return false;
      _files[path] = Uint8List.fromList(newBytes);
      _versions[path] = 1;
      return true;
    }

    // ifMatchEtag provided — check that current ETag matches.
    if (!fileExists || currentVersion == null) return false;
    if (currentVersion.toString() != ifMatchEtag) return false;

    _files[path] = Uint8List.fromList(newBytes);
    _versions[path] = currentVersion + 1;
    return true;
  }

  @override
  Future<String?> getEtag(String path) async {
    final version = _versions[path];
    if (version == null || !_files.containsKey(path)) return null;
    return version.toString();
  }

  /// Removes all files and version counters.
  ///
  /// Useful in test tearDown to reset adapter state between tests.
  void clear() {
    _files.clear();
    _versions.clear();
  }

  /// Returns the number of files currently stored.
  int get fileCount => _files.length;

  /// Returns `true` if a file exists at [path].
  bool containsFile(String path) => _files.containsKey(path);
}
