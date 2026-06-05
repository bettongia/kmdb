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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart' show SyncContext, SyncStorageAdapter;
import 'package:kmdb/kmdb_test_cloud_support.dart'
    show CloudProfile, QuotaProfile, SharedCloudBackend;
import 'package:kmdb_harness/kmdb_harness.dart' show QuotaAwareAdapter;
import 'package:kmdb_icloud/src/icloud_adapter.dart' show ICloudAdapter;
import 'package:kmdb_icloud/src/icloud_profile.dart' show kICloudProfile;
import 'package:kmdb_icloud/src/icloud_sync_channel_interface.dart'
    show ICloudSyncChannel;

// ── FakeICloudSyncChannel ──────────────────────────────────────────────────

/// In-memory, immediately-consistent implementation of [ICloudSyncChannel]
/// backed by a [SharedCloudBackend].
///
/// ## Design intent
///
/// `FakeICloudSyncChannel` is an **immediately-consistent, atomic functional
/// fake** — it delegates all operations directly to [SharedCloudBackend] with
/// no propagation delay and no simulated non-atomic race window.
///
/// This matches the landed [DriveSimulator] pattern exactly: the non-atomic /
/// eventual-consistency fidelity is a *harness* concern applied via
/// `CloudSemanticsAdapter` in the `kICloudProfile`-parameterised harness
/// scenario, not an adapter-simulator concern. Keeping the fake simple is safe
/// because [ConsolidationCoordinator] gates consolidation off entirely when
/// `ICloudAdapter.providesAtomicCas == false` — it never reaches a
/// `compareAndSwap` call and therefore there is no split-lease race for this
/// fake to reproduce.
///
/// ## CloudKit error contract mapping
///
/// - `CKError.unknownItem` (file not found): [download] and [getEtag] return
///   `null`; [delete] is a no-op; [compareAndSwap] update-if-match returns
///   `false` when the file does not exist.
/// - `CKError.serverRecordChanged` (ETag mismatch or create-if-absent
///   conflict): [compareAndSwap] returns `false`.
/// - `CKError.requestRateLimited`: not modelled — the fake never throws
///   [ICloudRateLimitException]. Rate-limit testing should use real CloudKit.
///
/// ## Usage
///
/// ```dart
/// final backend = SharedCloudBackend();
/// final channel = FakeICloudSyncChannel(backend);
/// final adapter = ICloudAdapter(channel: channel, syncRoot: 'test-root');
/// ```
///
/// Multiple [FakeICloudSyncChannel] instances may share the same [backend]
/// to simulate multiple devices accessing the same CloudKit zone.
final class FakeICloudSyncChannel implements ICloudSyncChannel {
  /// Creates a [FakeICloudSyncChannel] backed by [backend].
  ///
  /// [backend] is the shared in-memory store. Pass the same instance to
  /// multiple [FakeICloudSyncChannel] objects to simulate multiple devices
  /// sharing the same CloudKit zone.
  FakeICloudSyncChannel(this._backend);

  final SharedCloudBackend _backend;

  /// The underlying shared backend (exposed for test introspection).
  SharedCloudBackend get backend => _backend;

  // ── ICloudSyncChannel ──────────────────────────────────────────────────────

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) async {
    // Normalise: ensure remoteDir ends with '/' for prefix matching, consistent
    // with the path convention used by ICloudAdapter.
    final prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    final results = <String>[];
    for (final path in _backend.listPaths(prefix)) {
      final remainder = path.substring(prefix.length);
      // Only include direct children — exclude deeper nested paths.
      if (remainder.contains('/')) continue;
      // Apply optional extension filter.
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<Uint8List?> download(String remotePath) async {
    final file = _backend.getFile(remotePath);
    if (file == null) return null;
    return Uint8List.fromList(file.bytes);
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    _backend.write(remotePath, bytes);
  }

  @override
  Future<void> delete(String remotePath) async {
    // CloudKit maps CKError.unknownItem to a no-op; we swallow absent-file
    // deletions by delegating to backend.delete, which is already a no-op when
    // the path is absent.
    _backend.delete(remotePath);
  }

  @override
  Future<bool> compareAndSwap(
    String remotePath,
    Uint8List bytes, {
    String? ifMatchEtag,
  }) async {
    // Delegates directly to SharedCloudBackend.compareAndSwap, which is truly
    // atomic (no await between check and write). Maps to the CloudKit error
    // contract:
    //   - null etag (create-if-absent):  returns false when file already exists
    //     (models CKError.serverRecordChanged on successful race by another
    //     writer — though in this fake the backend CAS is atomic, the false
    //     result still correctly models the no-overwrite semantic).
    //   - non-null etag (update-if-match): returns false on ETag mismatch
    //     (models CKError.serverRecordChanged from .ifServerRecordUnchanged).
    final result = _backend.compareAndSwap(
      remotePath,
      bytes,
      ifMatchEtag: ifMatchEtag,
    );
    return result != null;
  }

  @override
  Future<String?> getEtag(String remotePath) async {
    return _backend.getEtag(remotePath);
  }
}

// ── SimulatorICloudQuotaAdapter ────────────────────────────────────────────

/// Wraps an [ICloudAdapter] (over a [FakeICloudSyncChannel]) and adds
/// [QuotaAwareAdapter] for `kmdb_harness` integration.
///
/// ## Design
///
/// Lives in the **test tree** and depends on `kmdb_harness`. The production
/// [ICloudAdapter] does **not** implement [QuotaAwareAdapter] — this keeps
/// `kmdb_icloud`'s production code free of any `kmdb_harness` dependency.
/// This mirrors [SimulatorQuotaAdapter] in
/// `packages/kmdb_google_drive/test/support/drive_simulator.dart`.
///
/// [safeOperationThreshold] is derived from the [CloudProfile]'s
/// `quota.maxOpsPerMinute`, allowing 10 minutes of operations at that rate.
/// When `maxOpsPerMinute` is `null` the threshold is effectively unlimited.
final class SimulatorICloudQuotaAdapter
    implements SyncStorageAdapter, QuotaAwareAdapter {
  /// Creates a [SimulatorICloudQuotaAdapter].
  ///
  /// [adapter] — the underlying [ICloudAdapter] to delegate to.
  /// [quotaProfile] — the quota profile from [kICloudProfile].
  SimulatorICloudQuotaAdapter({
    required ICloudAdapter adapter,
    required QuotaProfile quotaProfile,
  }) : _adapter = adapter,
       _quotaProfile = quotaProfile;

  final ICloudAdapter _adapter;
  final QuotaProfile _quotaProfile;

  /// The safe operation threshold for [QuotaAwareAdapter].
  ///
  /// Returns 10 × [QuotaProfile.maxOpsPerMinute] so the harness
  /// [TestManager] can pace operations to stay below the declared rate limit.
  /// Returns a large number when [QuotaProfile.maxOpsPerMinute] is `null`
  /// (effectively unlimited).
  @override
  int get safeOperationThreshold {
    final maxOps = _quotaProfile.maxOpsPerMinute;
    if (maxOps == null) return 1000000;
    // Allow 10 minutes of operations at the declared rate before the harness
    // slows down — consistent with the DriveSimulator precedent.
    return maxOps * 10;
  }

  // ── Delegate all SyncStorageAdapter methods ──────────────────────────────

  @override
  bool get providesAtomicCas => _adapter.providesAtomicCas;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) => _adapter.list(remoteDir, extension: extension, ctx: ctx);

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) =>
      _adapter.download(remotePath, ctx: ctx);

  @override
  Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx}) =>
      _adapter.upload(remotePath, bytes, ctx: ctx);

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) =>
      _adapter.delete(remotePath, ctx: ctx);

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) => _adapter.compareAndSwap(
    path,
    newBytes,
    ifMatchEtag: ifMatchEtag,
    ctx: ctx,
  );

  @override
  Future<String?> getEtag(String remotePath, {SyncContext? ctx}) =>
      _adapter.getEtag(remotePath, ctx: ctx);
}

// ── Factory helpers ────────────────────────────────────────────────────────

/// Creates an [ICloudAdapter] wired to [backend] via a [FakeICloudSyncChannel].
///
/// [syncRoot] defaults to `'__sim_test__'` — override in tests that need
/// a specific zone name.
ICloudAdapter adapterOverBackend(
  SharedCloudBackend backend, {
  String syncRoot = '__sim_test__',
}) {
  final channel = FakeICloudSyncChannel(backend);
  return ICloudAdapter(channel: channel, syncRoot: syncRoot);
}

/// Creates a [SimulatorICloudQuotaAdapter] wired to [backend], using
/// [kICloudProfile]'s quota settings.
SimulatorICloudQuotaAdapter quotaAdapterOverBackend(
  SharedCloudBackend backend, {
  String syncRoot = '__sim_test__',
  CloudProfile profile = kICloudProfile,
}) {
  final adapter = adapterOverBackend(backend, syncRoot: syncRoot);
  return SimulatorICloudQuotaAdapter(
    adapter: adapter,
    quotaProfile: profile.quota,
  );
}
