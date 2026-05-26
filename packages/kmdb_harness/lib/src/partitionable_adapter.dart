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
  Future<List<String>> list(String remoteDir, {String? extension}) {
    _checkPartition();
    return _delegate.list(remoteDir, extension: extension);
  }

  @override
  Future<Uint8List?> download(String remotePath) {
    _checkPartition();
    return _delegate.download(remotePath);
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) {
    _checkPartition();
    return _delegate.upload(remotePath, bytes);
  }

  @override
  Future<void> delete(String remotePath) {
    _checkPartition();
    return _delegate.delete(remotePath);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
  }) {
    _checkPartition();
    return _delegate.compareAndSwap(path, newBytes, ifMatchEtag: ifMatchEtag);
  }

  @override
  Future<String?> getEtag(String path) {
    _checkPartition();
    return _delegate.getEtag(path);
  }

  @override
  bool get providesAtomicCas => _delegate.providesAtomicCas;
}
