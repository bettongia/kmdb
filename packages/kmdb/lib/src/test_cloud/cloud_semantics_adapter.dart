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

import 'cloud_profile.dart';
import 'shared_backend_adapter.dart';
import 'shared_cloud_backend.dart';
import 'visibility_cursor_adapter.dart';

/// A [SyncStorageAdapter] decorator that applies cloud-provider semantics on
/// top of a [SharedBackendAdapter].
///
/// [CloudSemanticsAdapter] models the gap between a strongly-consistent
/// in-memory backend and the observable behaviour of a real cloud provider.
/// It wraps a [SharedBackendAdapter] and uses a [CloudProfile] to inject:
///
/// - **Propagation delay / eventual consistency**: reads (list, download,
///   getEtag) see only files whose [StoredFile.writeSeq] is at or below the
///   current visibility cursor for this observer. The cursor advances as
///   simulated time passes (see [advancePropagationClock]).
/// - **CAS atomicity**: [compareAndSwap] either delegates to the strongly-
///   consistent backend (when [CloudProfile.atomicConditionalCreate] is `true`)
///   or performs a non-atomic read-check-write (when `false`), faithfully
///   simulating the race the [ConsolidationCoordinator] must tolerate on
///   non-atomic backends.
/// - **[providesAtomicCas]**: mirrors
///   [CloudProfile.atomicConditionalCreate], so [ConsolidationCoordinator]'s
///   gate engages correctly.
///
/// ## Cancellation
///
/// [CloudSemanticsAdapter] calls `ctx?.throwIfExpired()` at the start of each
/// method. Eventual consistency is modelled with a synchronous visibility
/// cursor (`_visibilitySeq`, advanced explicitly via
/// [advancePropagationClock]) — there are no awaitable propagation delays.
/// The only `Future.delayed` in this adapter is
/// `Future<void>.delayed(Duration.zero)` in the non-atomic [compareAndSwap]
/// path — that is the CAS race-window yield, not a long-running cancellable
/// wait, and it is left as-is.
///
/// ## Visibility model
///
/// Under [EventualConsistency], each write committed to the backend gets a
/// [StoredFile.writeSeq]. A [CloudSemanticsAdapter] observer tracks a
/// [_visibilitySeq] cursor — the highest `writeSeq` that is visible to this
/// observer. Only files with `writeSeq <= _visibilitySeq` are returned by
/// [list], [download], and [getEtag].
///
/// The cursor is advanced by [advancePropagationClock], which simulates the
/// backend's propagation clock advancing past the maximum delay. The harness's
/// `_settleAndVerifyConvergence()` calls this after the run loop drains to
/// guarantee that all writes are visible before asserting convergence.
///
/// Under [StrongConsistency], [_visibilitySeq] is always
/// `backend.currentWriteSeq`, so all writes are immediately visible — identical
/// to [SharedBackendAdapter].
///
/// ## Modelled on [PartitionableAdapter]
///
/// The structure mirrors `packages/kmdb_harness/lib/src/partitionable_adapter.dart`:
/// a thin decorator that overrides specific methods while forwarding others.
/// Writes (upload, the write path of compareAndSwap) always go through to the
/// strongly-consistent backend; the eventual-consistency effect is applied only
/// on reads.
///
/// ## Example — eventual consistency with 200 ms delay
///
/// ```dart
/// final backend = SharedCloudBackend();
/// final profile = CloudProfile.eventual(maxPropagationDelayMs: 200);
/// final adapter = CloudSemanticsAdapter(
///   backend: SharedBackendAdapter(backend, deviceId: 'device-0'),
///   profile: profile,
/// );
/// // Writes are committed immediately but reads see a stale view.
/// await adapter.upload('sstables/foo.sst', bytes);
/// // foo.sst is not yet visible — _visibilitySeq hasn't advanced past it.
/// expect(await adapter.download('sstables/foo.sst'), isNull);
/// // Advance the clock past the max delay.
/// adapter.advancePropagationClock();
/// expect(await adapter.download('sstables/foo.sst'), isNotNull);
/// ```
final class CloudSemanticsAdapter
    implements SyncStorageAdapter, VisibilityCursorAdapter {
  /// Creates a [CloudSemanticsAdapter].
  ///
  /// [backend] is the strongly-consistent base adapter. [profile] describes
  /// the cloud semantics to apply.
  CloudSemanticsAdapter({required this.backend, required this.profile})
    : // Under strong consistency, the cursor starts at max so all writes
      // are immediately visible. Under eventual consistency, start at 0 so
      // all future writes are invisible until the clock advances.
      _visibilitySeq = profile.consistency.isStrong ? _kMaxSeq : 0;

  /// The underlying strongly-consistent adapter.
  final SharedBackendAdapter backend;

  /// The [CloudProfile] describing the simulated backend behaviour.
  final CloudProfile profile;

  /// The current visibility cursor for this observer.
  ///
  /// Only files with [StoredFile.writeSeq] `<= _visibilitySeq` are returned by
  /// read operations. Starts at [_kMaxSeq] for strong profiles (all visible)
  /// or `0` for eventual profiles (nothing visible until the clock advances).
  int _visibilitySeq;

  // Sentinel: a seq high enough that all committed writes are visible.
  static const int _kMaxSeq = 0x7fffffffffffffff;

  // ── Visibility model ──────────────────────────────────────────────────────

  /// The highest write-sequence that is currently visible to this observer.
  ///
  /// For strongly-consistent adapters this always equals the backend's
  /// [SharedCloudBackend.currentWriteSeq]. For eventually-consistent adapters
  /// it advances only when [advancePropagationClock] is called.
  @override
  int get visibleWriteSeq {
    if (profile.consistency.isStrong) return backend.visibleWriteSeq;
    return _visibilitySeq;
  }

  /// Advances the propagation clock so that all writes committed up to
  /// [backend]'s current write-sequence become visible.
  ///
  /// Call this after draining all in-flight actions to simulate the
  /// backend's propagation window having elapsed — i.e. to model the
  /// "settle" step before asserting global convergence.
  ///
  /// Under strong consistency this is a no-op (all writes are already visible).
  void advancePropagationClock() {
    if (profile.consistency.isStrong) return;
    _visibilitySeq = backend.visibleWriteSeq;
  }

  /// Advances the propagation clock partially, making writes up to [seqHigh]
  /// visible.
  ///
  /// Used in tests that want to observe a partially-propagated state (e.g.
  /// some but not all writes visible). Ignored under strong consistency.
  void advancePropagationClockTo(int seqHigh) {
    if (profile.consistency.isStrong) return;
    _visibilitySeq = seqHigh > _visibilitySeq ? seqHigh : _visibilitySeq;
  }

  // ── Read-your-writes ─────────────────────────────────────────────────────

  // Advance _visibilitySeq to the backend's currentWriteSeq after each write
  // so this adapter can immediately read back its own writes. Other adapter
  // instances are unaffected — each tracks its own _visibilitySeq.
  void _advanceToCurrentWriteSeq() {
    if (profile.consistency.isStrong) return;
    final current = backend.visibleWriteSeq;
    if (current > _visibilitySeq) _visibilitySeq = current;
  }

  // ── SyncStorageAdapter ────────────────────────────────────────────────────

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    final prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    final allPaths = backend.backend.listPaths(prefix);
    final results = <String>[];
    final seqHigh = visibleWriteSeq;
    for (final path in allPaths) {
      final file = backend.backend.getFile(path);
      if (file == null) continue;
      // Filter by visibility cursor.
      if (file.writeSeq > seqHigh) continue;
      final remainder = path.substring(prefix.length);
      if (remainder.contains('/')) continue;
      if (extension != null && !remainder.endsWith(extension)) continue;
      results.add(remainder);
    }
    return results;
  }

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    final file = backend.backend.getFile(remotePath);
    if (file == null) return null;
    if (file.writeSeq > visibleWriteSeq) return null;
    return Uint8List.fromList(file.bytes);
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    await backend.upload(remotePath, bytes);
    _advanceToCurrentWriteSeq();
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) {
    ctx?.throwIfExpired();
    return backend.delete(remotePath);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    ctx?.throwIfExpired();
    if (profile.atomicConditionalCreate) {
      // Atomic path: delegate directly to the strongly-consistent backend.
      final result = await backend.compareAndSwap(
        path,
        newBytes,
        ifMatchEtag: ifMatchEtag,
      );
      if (result) _advanceToCurrentWriteSeq();
      return result;
    }

    // Non-atomic path: check ACTUAL backend state (bypassing the visibility
    // filter) so that files written by other devices — even if not yet in this
    // adapter's visible window — are correctly detected as pre-existing. This
    // is the correct model: a real CAS always checks the server's ground truth,
    // not the client's stale cache.
    final file = backend.backend.getFile(path);
    final currentEtag = file?.version.toString();
    if (ifMatchEtag == null) {
      if (currentEtag != null) return false; // file exists — precondition fails
    } else {
      if (currentEtag != ifMatchEtag) return false; // etag mismatch
    }

    // Yield to the event loop — this is the race window. Another concurrent
    // caller may also have passed the check and may now also write.
    // NOTE: this is the CAS race-window yield, NOT a propagation delay.
    // Do not wrap this with ctx cancellation — it is not a long-running wait.
    await Future<void>.delayed(Duration.zero);

    // Unconditionally write (non-atomic — no re-check after the yield).
    await backend.upload(path, newBytes);
    _advanceToCurrentWriteSeq();
    return true;
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) async {
    ctx?.throwIfExpired();
    final file = backend.backend.getFile(path);
    if (file == null) return null;
    if (file.writeSeq > visibleWriteSeq) return null;
    return file.version.toString();
  }

  /// Whether [compareAndSwap] provides atomic semantics on this adapter.
  ///
  /// Mirrors [CloudProfile.atomicConditionalCreate] so that
  /// [ConsolidationCoordinator]'s gate engages correctly under non-atomic
  /// profiles.
  @override
  bool get providesAtomicCas => profile.atomicConditionalCreate;
}
