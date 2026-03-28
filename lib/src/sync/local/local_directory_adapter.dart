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

// This file is native-only and imports dart:io directly.
// It must not be imported on web platforms.

import 'dart:io';
import 'dart:typed_data';

import '../cloud/cloud_adapter.dart';

/// A [CloudAdapter] backed by the local filesystem.
///
/// Suitable for use with NAS mounts, SMB/CIFS shares, locally-synced cloud
/// folders (e.g. a Dropbox or OneDrive folder), or any directory accessible
/// via `dart:io`.
///
/// ## ETag implementation
///
/// For Phase 5, the ETag is the file size in bytes as a decimal string. This
/// is simple and collision-resistant enough for the lease protocol in typical
/// usage. A proper content-hash-based ETag is implemented in Phase 8.
///
/// ## compareAndSwap limitations
///
/// On POSIX, [compareAndSwap] uses a write-to-temp-then-rename strategy. The
/// rename is atomic, but the read-check-write sequence is not. This means
/// two processes could both read the same ETag and both proceed to write,
/// creating a race condition. For the consolidation coordinator lease protocol
/// this is a best-effort implementation — tests use [MemorySyncAdapter] which
/// provides true CAS semantics.
///
/// ## Usage
///
/// ```dart
/// final adapter = LocalDirectoryAdapter('/mnt/nas/kmdb-sync');
/// await adapter.upload('sstables/abc.sst', bytes);
/// ```
final class LocalDirectoryAdapter implements CloudAdapter {
  /// Creates a [LocalDirectoryAdapter] rooted at [rootPath].
  ///
  /// [rootPath] is the base directory for all remote paths. It is created if
  /// it does not exist.
  LocalDirectoryAdapter(this.rootPath);

  /// Base directory for all remote paths.
  final String rootPath;

  /// Resolves a remote path to a full filesystem path.
  String _resolve(String remotePath) => '$rootPath/$remotePath';

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) async {
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
  Future<Uint8List?> download(String remotePath) async {
    final file = File(_resolve(remotePath));
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    final file = File(_resolve(remotePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String remotePath) async {
    final file = File(_resolve(remotePath));
    if (file.existsSync()) await file.delete();
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
  }) async {
    final resolvedPath = _resolve(path);
    final file = File(resolvedPath);

    if (ifMatchEtag == null) {
      // if-none-match: * — succeed only if file does not currently exist.
      // Write to a temp file then rename. On POSIX, rename is atomic but
      // not conditional — if a concurrent writer also finds the file absent
      // and renames simultaneously, one will overwrite the other. For Phase 5
      // this is acceptable; the consolidation coordinator handles contention
      // via re-reads after write.
      if (file.existsSync()) return false;
      final tmpPath = '$resolvedPath.cas-tmp-${DateTime.now().microsecondsSinceEpoch}';
      final tmp = File(tmpPath);
      await file.parent.create(recursive: true);
      await tmp.writeAsBytes(newBytes, flush: true);
      try {
        await tmp.rename(resolvedPath);
        return true;
      } catch (_) {
        // Rename failed — another writer won the race.
        try {
          await tmp.delete();
        } catch (_) {}
        return false;
      }
    }

    // ETag provided: read current ETag, check match, then overwrite.
    // Note: this read-check-write is NOT atomic on POSIX. Tests should use
    // MemorySyncAdapter for proper CAS guarantees.
    final currentEtag = await getEtag(path);
    if (currentEtag != ifMatchEtag) return false;

    final tmpPath = '$resolvedPath.cas-tmp-${DateTime.now().microsecondsSinceEpoch}';
    final tmp = File(tmpPath);
    await tmp.writeAsBytes(newBytes, flush: true);
    try {
      await tmp.rename(resolvedPath);
      return true;
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  @override
  Future<String?> getEtag(String path) async {
    final file = File(_resolve(path));
    if (!file.existsSync()) return null;
    // Use file size as the ETag (Phase 5 approximation).
    final size = await file.length();
    return size.toString();
  }
}
