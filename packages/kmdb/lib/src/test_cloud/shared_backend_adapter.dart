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

import 'package:kmdb/kmdb.dart';

import 'shared_cloud_backend.dart';
import 'visibility_cursor_adapter.dart';

/// A strongly-consistent [SyncStorageAdapter] front-end over a
/// [SharedCloudBackend].
///
/// [SharedBackendAdapter] gives direct, synchronous access to the backend's
/// file map with no propagation delay. Every write is immediately visible on
/// the next read — equivalent in behaviour to [MemorySyncAdapter], but sharing
/// state with other adapters that reference the same [SharedCloudBackend].
///
/// This is the baseline adapter for tests that require multiple device adapters
/// to share a logical remote while keeping strongly-consistent semantics (e.g.
/// the existing single-adapter harness presets).
///
/// ## Cancellation
///
/// [SharedBackendAdapter] has no long-running waits; all operations complete in
/// the same microtask. The `ctx` parameter is accepted on all methods (to
/// satisfy the interface) but is silently ignored — this is permitted by the
/// [SyncStorageAdapter] contract.
///
/// ## CAS atomicity
///
/// [compareAndSwap] delegates to [SharedCloudBackend.compareAndSwap], which is
/// truly atomic (no `await` between check and write). [providesAtomicCas]
/// returns `true`.
///
/// ## Example
///
/// ```dart
/// final backend = SharedCloudBackend();
/// // Both adapters share the same backend — writes from one are
/// // immediately visible to the other.
/// final adapterA = SharedBackendAdapter(backend, deviceId: 'device-0');
/// final adapterB = SharedBackendAdapter(backend, deviceId: 'device-1');
/// await adapterA.upload('sstables/foo.sst', bytes);
/// expect(await adapterB.download('sstables/foo.sst'), equals(bytes));
/// ```
final class SharedBackendAdapter
    implements SyncStorageAdapter, VisibilityCursorAdapter {
  /// Creates a [SharedBackendAdapter] over [backend].
  ///
  /// [deviceId] is used to stamp writes with the writer's identity in
  /// [StoredFile.writerDeviceId]. It is optional and purely informational.
  SharedBackendAdapter(this.backend, {this.deviceId = ''});

  /// The canonical backing store shared by all front-end adapters.
  final SharedCloudBackend backend;

  /// The device identifier for writes performed through this adapter.
  final String deviceId;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    // Normalise: ensure remoteDir ends with '/' for prefix matching.
    final prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    final results = <String>[];
    for (final path in backend.listPaths(prefix)) {
      final remainder = path.substring(prefix.length);
      // Only include direct children (no deeper nested paths).
      if (remainder.contains('/')) continue;
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    final file = backend.getFile(remotePath);
    if (file == null) return null;
    return Uint8List.fromList(file.bytes);
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    backend.write(remotePath, bytes, writerDeviceId: deviceId);
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    backend.delete(remotePath);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    final result = backend.compareAndSwap(
      path,
      newBytes,
      ifMatchEtag: ifMatchEtag,
      writerDeviceId: deviceId,
    );
    return result != null;
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) async {
    // ctx is intentionally ignored — no long-running waits in this adapter.
    return backend.getEtag(path);
  }

  @override
  bool get providesAtomicCas => true;

  /// The current backend write-sequence high-water mark.
  ///
  /// Because this is a strongly-consistent adapter, the visible write-sequence
  /// always equals the backend's current maximum. This is used by the
  /// visibility model: when [SharedBackendAdapter] is the front-end, all
  /// committed writes are immediately visible.
  @override
  int get visibleWriteSeq => backend.currentWriteSeq;
}
