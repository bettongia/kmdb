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
import 'package:kmdb/kmdb_test_cloud_support.dart' show VisibilityCursorAdapter;

/// Exception thrown by [PartitionableAdapter] when a network partition is
/// active and a sync operation is attempted.
final class NetworkPartitionException implements Exception {
  /// Creates a [NetworkPartitionException].
  const NetworkPartitionException([this.message]);

  /// Optional description of the partition context.
  final String? message;

  @override
  String toString() {
    final suffix = message != null ? ': $message' : '';
    return 'NetworkPartitionException$suffix';
  }
}

/// A [SyncStorageAdapter] wrapper that can simulate a network partition.
///
/// When [isPartitioned] is `true`, every adapter method throws a
/// [NetworkPartitionException] instead of forwarding to the underlying
/// [delegate]. This simulates complete connectivity loss at the storage
/// adapter layer without requiring OS-level TCP interception.
///
/// Use [setPartitioned] to toggle the partition state. The [ReconciliationAgent]
/// tracks which sync operations were interrupted (completed: false) so that
/// expected-state computation is not incorrectly advanced for the affected
/// device.
///
/// ## Cancellation
///
/// [PartitionableAdapter] forwards the `ctx` parameter opaquely to its
/// [delegate] on all six methods. The delegate is responsible for honouring
/// (or ignoring) the [SyncContext].
///
/// ## Example
///
/// ```dart
/// final adapter = PartitionableAdapter(MemorySyncAdapter());
/// // Normal operation.
/// await adapter.upload('sstables/foo.sst', bytes);
///
/// // Activate partition.
/// adapter.setPartitioned(true);
/// // This now throws NetworkPartitionException:
/// await adapter.upload('sstables/bar.sst', bytes);
///
/// // Restore connectivity.
/// adapter.setPartitioned(false);
/// ```
final class PartitionableAdapter implements SyncStorageAdapter {
  /// Wraps [delegate] with partition-simulation capability.
  PartitionableAdapter(this._delegate);

  final SyncStorageAdapter _delegate;

  /// The underlying delegate adapter.
  ///
  /// Exposed so callers can reach decorator-specific APIs (e.g.
  /// `CloudSemanticsAdapter.advancePropagationClock`) without requiring
  /// [PartitionableAdapter] to know about every concrete delegate type.
  SyncStorageAdapter get delegate => _delegate;

  bool _partitioned = false;

  /// Whether the simulated network partition is currently active.
  bool get isPartitioned => _partitioned;

  /// Activates or deactivates the simulated network partition.
  ///
  /// When [value] is `true`, all subsequent adapter calls throw
  /// [NetworkPartitionException] until this is called with `false`.
  void setPartitioned(bool value) => _partitioned = value;

  void _checkPartition() {
    if (_partitioned) {
      throw const NetworkPartitionException('Network partition is active');
    }
  }

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) {
    _checkPartition();
    return _delegate.list(remoteDir, extension: extension, ctx: ctx);
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) {
    _checkPartition();
    return _delegate.download(remotePath, ctx: ctx);
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx}) {
    _checkPartition();
    return _delegate.upload(remotePath, bytes, ctx: ctx);
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) {
    _checkPartition();
    return _delegate.delete(remotePath, ctx: ctx);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) {
    _checkPartition();
    return _delegate.compareAndSwap(
      path,
      newBytes,
      ifMatchEtag: ifMatchEtag,
      ctx: ctx,
    );
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) {
    _checkPartition();
    return _delegate.getEtag(path, ctx: ctx);
  }

  @override
  bool get providesAtomicCas => _delegate.providesAtomicCas;

  /// The visible write-sequence high-water mark for this adapter's delegate,
  /// or `null` if the delegate does not implement [VisibilityCursorAdapter].
  ///
  /// Used by [Device._sync] to populate [ActionResult.visibleWriteSeqHigh].
  /// When `null`, the [ReconciliationAgent] falls back to the legacy full
  /// global-merge path (backward compatible with [MemorySyncAdapter]).
  int? get visibleWriteSeq {
    final delegate = _delegate;
    if (delegate is VisibilityCursorAdapter) {
      return (delegate as VisibilityCursorAdapter).visibleWriteSeq;
    }
    return null;
  }
}
